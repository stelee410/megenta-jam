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

// Faithful port of qiuqiangkong/piano_transcription_inference (MIT):
// 10 s segments with 50% hop → CRNN → deframe (keep segment centers) →
// regression post-processing (sub-frame onset/offset refinement).

#import "JamTranscribePiano.h"

#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>

static constexpr int kPtSR = 16000;
static constexpr int kSegment = kPtSR * 10;          // 160000 samples / 10 s
static constexpr int kHopSamples = kSegment / 2;
static constexpr int kFps = 100;                     // frames per second
static constexpr int kSegFrames = 1001;              // model output frames/segment
static constexpr int kKeys = 88;                     // piano keys (midi 21..108)
static constexpr float kOnsetThr = 0.3f;
static constexpr float kOffsetThr = 0.3f;
static constexpr float kFrameThr = 0.1f;

// ── Cached ORT session ──
static std::mutex gPtMutex;
static std::unique_ptr<Ort::Env> gPtEnv;
static std::unique_ptr<Ort::Session> gPtSession;
static NSString* gPtModelPath = nil;

static bool ensureSession(NSString* modelPath, NSString* __strong * error) {
    if (gPtSession && [gPtModelPath isEqualToString:modelPath]) return true;
    try {
        if (!gPtEnv) gPtEnv = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_ERROR, "jam-piano");
        Ort::SessionOptions opts;
        opts.SetIntraOpNumThreads(4);
        // ORT 1.20's MatMul+BatchNorm fusion (a BASIC-level pass) mis-infers
        // a rank-3 Gemm on this graph — optimizations must stay off entirely.
        // Still ~3x realtime on Apple Silicon CPU.
        opts.SetGraphOptimizationLevel(ORT_DISABLE_ALL);
        // CRNN with GRU layers: CoreML EP falls over on the recurrences, so
        // this model runs on CPU (still ~10x realtime on Apple Silicon).
        gPtSession = std::make_unique<Ort::Session>(
            *gPtEnv, modelPath.fileSystemRepresentation, opts);
        gPtModelPath = [modelPath copy];
        return true;
    } catch (const std::exception& e) {
        if (error) *error = [NSString stringWithFormat:@"piano model load failed: %s", e.what()];
        gPtSession.reset();
        return false;
    }
}

// 48 kHz stereo int16 → 16 kHz mono float (windowed-sinc lowpass, decimate ×3).
static void resampleTo16k(const int16_t* stereo, long frames, std::vector<float>& out) {
    std::vector<float> mono(frames);
    for (long i = 0; i < frames; ++i) {
        mono[i] = (stereo[i * 2] + stereo[i * 2 + 1]) * (0.5f / 32768.0f);
    }
    constexpr int kTaps = 45;                    // odd, center kTaps/2
    static float h[kTaps];
    static bool hInit = false;
    if (!hInit) {
        const double fc = 1.0 / 6.0;             // 8 kHz at 48 kHz rate
        double sum = 0;
        for (int i = 0; i < kTaps; ++i) {
            const int m = i - kTaps / 2;
            const double sinc = (m == 0) ? 2 * fc : sin(2 * M_PI * fc * m) / (M_PI * m);
            const double w = 0.54 - 0.46 * cos(2 * M_PI * i / (kTaps - 1));
            h[i] = (float)(sinc * w);
            sum += h[i];
        }
        for (int i = 0; i < kTaps; ++i) h[i] /= (float)sum;
        hInit = true;
    }
    const long outN = frames / 3;
    out.assign(outN, 0.0f);
    for (long m = 0; m < outN; ++m) {
        const long c = m * 3;
        float acc = 0.0f;
        for (int t = 0; t < kTaps; ++t) {
            const long idx = c + t - kTaps / 2;
            if (idx >= 0 && idx < frames) acc += mono[idx] * h[t];
        }
        out[m] = acc;
    }
}

// Kong et al. Section III-D: binarize a regression roll into onset flags +
// sub-frame shifts (local maxima with monotonic neighbours above threshold).
static void binarizeRegression(const std::vector<float>& reg, long framesN, int keys,
                               float thr, int neighbour,
                               std::vector<uint8_t>& bin, std::vector<float>& shift) {
    bin.assign(framesN * keys, 0);
    shift.assign(framesN * keys, 0.0f);
    for (int k = 0; k < keys; ++k) {
        for (long n = neighbour; n < framesN - neighbour; ++n) {
            const float x = reg[n * keys + k];
            if (x <= thr) continue;
            bool mono = true;
            for (int i = 0; i < neighbour && mono; ++i) {
                if (reg[(n - i) * keys + k] < reg[(n - i - 1) * keys + k]) mono = false;
                if (reg[(n + i) * keys + k] < reg[(n + i + 1) * keys + k]) mono = false;
            }
            if (!mono) continue;
            bin[n * keys + k] = 1;
            const float xm = reg[(n - 1) * keys + k], xp = reg[(n + 1) * keys + k];
            float s = 0.0f;
            if (xm > xp) {
                const float den = x - xp;
                if (std::fabs(den) > 1e-9f) s = (xp - xm) / den / 2.0f;
            } else {
                const float den = x - xm;
                if (std::fabs(den) > 1e-9f) s = (xp - xm) / den / 2.0f;
            }
            shift[n * keys + k] = s;
        }
    }
}

BOOL JamTranscribePiano(NSString* modelPath,
                        const int16_t* stereo48k, long frames,
                        std::vector<JamNote>& outNotes,
                        void (^progress)(float),
                        NSString* __strong * error) {
    outNotes.clear();
    if (!stereo48k || frames < 48000) {
        if (error) *error = @"audio too short";
        return NO;
    }
    std::lock_guard<std::mutex> lock(gPtMutex);
    if (!ensureSession(modelPath, error)) return NO;

    // 1. Resample, pad to a whole number of segments.
    std::vector<float> audio;
    resampleTo16k(stereo48k, frames, audio);
    const long audioLen = (long)audio.size();
    const long nSeg16 = (audioLen + kSegment - 1) / kSegment;
    audio.resize(nSeg16 * kSegment, 0.0f);

    // 2. Enframe with 50% hop, run the CRNN per segment.
    std::vector<long> starts;
    for (long p = 0; p + kSegment <= (long)audio.size(); p += kHopSamples) starts.push_back(p);
    const int nSeg = (int)starts.size();

    // Rolls deframed straight into full-length buffers. Per their deframe:
    // drop each segment's last frame, keep [0,750) of the first, [250,750) of
    // middles and [250,1000) of the last segment.
    const long segUse = kSegFrames - 1;            // 1000
    const long totalFrames = (nSeg == 1) ? kSegFrames
                                         : (long)(segUse * 0.75) +
                                           (long)(nSeg - 2) * (segUse / 2) +
                                           (segUse - segUse / 4);
    std::vector<float> regOn(totalFrames * kKeys), regOff(totalFrames * kKeys),
                       frameR(totalFrames * kKeys), velR(totalFrames * kKeys);

    Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    const char* inNames[] = {"audio"};
    const char* outNames[] = {"reg_onset", "reg_offset", "frame", "velocity",
                              "pedal_onset", "pedal_offset", "pedal_frame"};
    long wrote = 0;
    for (int sgi = 0; sgi < nSeg; ++sgi) {
        const int64_t inShape[2] = {1, kSegment};
        Ort::Value in = Ort::Value::CreateTensor<float>(
            mem, audio.data() + starts[sgi], kSegment, inShape, 2);
        std::vector<Ort::Value> outs;
        try {
            outs = gPtSession->Run(Ort::RunOptions{nullptr}, inNames, &in, 1, outNames, 7);
        } catch (const std::exception& e) {
            if (error) *error = [NSString stringWithFormat:@"piano inference failed: %s", e.what()];
            return NO;
        }
        const float* on = outs[0].GetTensorData<float>();
        const float* off = outs[1].GetTensorData<float>();
        const float* fr = outs[2].GetTensorData<float>();
        const float* vel = outs[3].GetTensorData<float>();

        long f0 = 0, f1 = segUse;                  // frame range to keep
        if (nSeg > 1) {
            if (sgi == 0) { f0 = 0; f1 = (long)(segUse * 0.75); }
            else if (sgi == nSeg - 1) { f0 = segUse / 4; f1 = segUse; }
            else { f0 = segUse / 4; f1 = (long)(segUse * 0.75); }
        } else {
            f1 = kSegFrames;
        }
        for (long f = f0; f < f1 && wrote < totalFrames; ++f, ++wrote) {
            memcpy(&regOn[wrote * kKeys], on + f * kKeys, kKeys * sizeof(float));
            memcpy(&regOff[wrote * kKeys], off + f * kKeys, kKeys * sizeof(float));
            memcpy(&frameR[wrote * kKeys], fr + f * kKeys, kKeys * sizeof(float));
            memcpy(&velR[wrote * kKeys], vel + f * kKeys, kKeys * sizeof(float));
        }
        if (progress) progress((sgi + 1) / (float)nSeg);
    }
    const long framesN = std::min(wrote, (long)(audioLen / (kPtSR / kFps)) + 1);

    // 3. Regression post-processing.
    std::vector<uint8_t> onBin, offBin;
    std::vector<float> onShift, offShift;
    binarizeRegression(regOn, framesN, kKeys, kOnsetThr, 2, onBin, onShift);
    binarizeRegression(regOff, framesN, kKeys, kOffsetThr, 4, offBin, offShift);

    for (int k = 0; k < kKeys; ++k) {
        long bgn = -1, frameDis = -1, offOcc = -1;
        for (long i = 0; i < framesN; ++i) {
            if (onBin[i * kKeys + k]) {
                if (bgn >= 0) {
                    // Consecutive onsets: close the previous note.
                    const long fin = std::max(i - 1, (long)0);
                    JamNote nn;
                    nn.start = (bgn + onShift[bgn * kKeys + k]) / kFps;
                    nn.duration = std::max(0.05, (double)(fin - bgn) / kFps);
                    nn.pitch = 21 + k;
                    nn.velocity = std::max(0.05f, std::min(1.0f, velR[bgn * kKeys + k]));
                    outNotes.push_back(nn);
                    frameDis = offOcc = -1;
                }
                bgn = i;
            }
            if (bgn >= 0 && i > bgn) {
                if (frameR[i * kKeys + k] <= kFrameThr && frameDis < 0) frameDis = i;
                if (offBin[i * kKeys + k] && offOcc < 0) offOcc = i;
                long fin = -1;
                if (frameDis >= 0) {
                    fin = (offOcc >= 0 && offOcc - bgn > frameDis - offOcc) ? offOcc : frameDis;
                } else if (i - bgn >= 600 || i == framesN - 1) {
                    fin = i;
                }
                if (fin >= 0) {
                    JamNote nn;
                    nn.start = (bgn + onShift[bgn * kKeys + k]) / kFps;
                    nn.duration = std::max(
                        0.05, (fin + offShift[fin * kKeys + k]) / (double)kFps - nn.start);
                    nn.pitch = 21 + k;
                    nn.velocity = std::max(0.05f, std::min(1.0f, velR[bgn * kKeys + k]));
                    outNotes.push_back(nn);
                    bgn = frameDis = offOcc = -1;
                }
            }
        }
    }
    std::sort(outNotes.begin(), outNotes.end(),
              [](const JamNote& a, const JamNote& b) { return a.start < b.start; });
    if (outNotes.empty() && error) *error = @"no piano notes detected";
    return !outNotes.empty();
}
