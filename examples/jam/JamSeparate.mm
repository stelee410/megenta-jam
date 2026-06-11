// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "JamSeparate.h"
#import <AudioToolbox/AudioToolbox.h>

#include <Eigen/Dense>
#include <memory>
#include <mutex>
#include <string>

#include "model.hpp"                // vendored demucs.cpp
#include "threaded_inference.hpp"   // segment-parallel driver
#include <sys/sysctl.h>

// Cache the loaded model across runs (loading the ~80 MB ggml file and
// building the Eigen weights takes a few seconds).
static std::mutex gModelMutex;
static std::unique_ptr<demucscpp::demucs_model> gModel;
static std::string gModelPath;

BOOL JamDemucsAvailable(NSString* path) {
    if (path.length == 0) return NO;
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attrs && [attrs fileSize] > 10 * 1024 * 1024;   // sanity: ≥10 MB
}

// Decode an audio file to stereo float at the given sample rate.
static BOOL decodeAt(NSURL* url, double sr, std::vector<float>& L, std::vector<float>& R) {
    ExtAudioFileRef f = nullptr;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &f) != noErr || !f) return NO;
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = sr;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    fmt.mBitsPerChannel = 32;
    fmt.mChannelsPerFrame = 2;
    fmt.mBytesPerFrame = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = 4;
    ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(fmt), &fmt);
    const long maxFrames = (long)(sr * 60 * 8);
    const UInt32 chunk = 1 << 16;
    std::vector<float> bufL(chunk), bufR(chunk);
    L.clear(); R.clear();
    while ((long)L.size() < maxFrames) {
        AudioBufferList abl;
        abl.mNumberBuffers = 2;
        abl.mBuffers[0] = {1, chunk * 4, bufL.data()};
        abl.mBuffers[1] = {1, chunk * 4, bufR.data()};
        UInt32 n = chunk;
        if (ExtAudioFileRead(f, &n, &abl) != noErr || n == 0) break;
        L.insert(L.end(), bufL.begin(), bufL.begin() + n);
        R.insert(R.end(), bufR.begin(), bufR.begin() + n);
    }
    ExtAudioFileDispose(f);
    return L.size() > 0;
}

// Linear-interpolation resample 44.1 kHz → 48 kHz (stems are masked mixtures;
// interpolation error is far below the separation noise floor).
static void resampleTo48k(const float* in, long inN, double inSr, std::vector<float>& out) {
    const double ratio = inSr / 48000.0;
    const long outN = (long)(inN / ratio);
    out.resize(outN);
    for (long i = 0; i < outN; ++i) {
        const double p = i * ratio;
        const long i0 = (long)p;
        const float fr = (float)(p - i0);
        const long i1 = std::min(inN - 1, i0 + 1);
        out[i] = in[i0] * (1.0f - fr) + in[i1] * fr;
    }
}

BOOL JamDemucsSeparate(NSString* modelPath,
                       NSURL* songURL,
                       std::vector<int16_t> stems[6],
                       int* outCount,
                       void (^progress)(float),
                       NSString* __strong * error) {
    if (!JamDemucsAvailable(modelPath)) {
        if (error) *error = @"separation model not found";
        return NO;
    }

    // 1. Load (or reuse) the model.
    {
        std::lock_guard<std::mutex> lock(gModelMutex);
        if (!gModel || gModelPath != modelPath.UTF8String) {
            if (progress) progress(0.01f);
            auto m = std::make_unique<demucscpp::demucs_model>();
            if (!demucscpp::load_demucs_model(modelPath.UTF8String, m.get())) {
                if (error) *error = @"failed to load separation model";
                return NO;
            }
            gModel = std::move(m);
            gModelPath = modelPath.UTF8String;
        }
    }

    // 2. Decode the song at demucs' native 44.1 kHz.
    std::vector<float> L44, R44;
    if (!decodeAt(songURL, 44100.0, L44, R44)) {
        if (error) *error = @"could not decode the song";
        return NO;
    }
    const long n44 = (long)L44.size();
    Eigen::MatrixXf audio(2, n44);
    for (long i = 0; i < n44; ++i) {
        audio(0, i) = L44[i];
        audio(1, i) = R44[i];
    }
    L44.clear(); L44.shrink_to_fit();
    R44.clear(); R44.shrink_to_fit();

    // 3. Inference — segment-parallel across the performance cores
    //    (the model is shared read-only between worker threads).
    if (progress) progress(0.05f);
    int nThreads = 4;
    {
        int perf = 0;
        size_t len = sizeof(perf);
        if (sysctlbyname("hw.perflevel0.physicalcpu", &perf, &len, nullptr, 0) == 0 && perf > 0) {
            nThreads = perf;
        }
        nThreads = std::max(2, std::min(nThreads, 8));
        // Short songs don't need many segments.
        const int maxByLen = std::max(1, (int)(n44 / (44100 * 20)));
        nThreads = std::min(nThreads, std::max(1, maxByLen));
    }
    Eigen::Tensor3dXf targets;
    {
        std::lock_guard<std::mutex> lock(gModelMutex);
        targets = demucscppthreaded::threaded_inference(
            *gModel, audio, nThreads,
            [&](float p, const std::string&) {
                if (progress) progress(0.05f + p * 0.87f);
            });
    }
    audio.resize(0, 0);

    // 4. Resample each stem to 48 kHz and quantise to interleaved int16.
    const int nSources = (int)targets.dimension(0);
    if (outCount) *outCount = nSources;
    const long outN44 = targets.dimension(2);
    std::vector<float> ch(outN44), ch48L, ch48R;
    for (int t = 0; t < nSources && t < 6; ++t) {
        for (long i = 0; i < outN44; ++i) ch[i] = targets(t, 0, i);
        resampleTo48k(ch.data(), outN44, 44100.0, ch48L);
        for (long i = 0; i < outN44; ++i) ch[i] = targets(t, 1, i);
        resampleTo48k(ch.data(), outN44, 44100.0, ch48R);
        const long outN = (long)ch48L.size();
        stems[t].assign(outN * 2, 0);
        for (long i = 0; i < outN; ++i) {
            float l = ch48L[i] * 32767.0f, r = ch48R[i] * 32767.0f;
            l = std::max(-32768.0f, std::min(32767.0f, l));
            r = std::max(-32768.0f, std::min(32767.0f, r));
            stems[t][i * 2] = (int16_t)l;
            stems[t][i * 2 + 1] = (int16_t)r;
        }
        if (progress) progress(0.92f + 0.08f * (t + 1) / nSources);
    }
    for (int t = nSources; t < 6; ++t) stems[t].clear();
    return YES;
}
