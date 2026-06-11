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

#import "JamTranscribe.h"

#include <onnxruntime_cxx_api.h>
#include <coreml_provider_factory.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>

// ── Basic Pitch constants (basic_pitch/constants.py) ─────────────────────────
static constexpr int kBpSR = 22050;
static constexpr int kFftHop = 256;
static constexpr int kAudioNSamples = 22050 * 2 - kFftHop;       // 43844
static constexpr int kOverlapFrames = 30;
static constexpr int kOverlapSamples = kOverlapFrames * kFftHop; // 7680
static constexpr int kHopSamples = kAudioNSamples - kOverlapSamples; // 36164
static constexpr int kWinFrames = 172;
static constexpr int kPitches = 88;
static constexpr double kFps = (double)kBpSR / kFftHop;          // ≈86.13
static constexpr float kOnsetThresh = 0.5f;
static constexpr float kFrameThresh = 0.3f;
static constexpr int kEnergyTol = 11;                            // frames
static constexpr double kMinNoteSec = 0.12;

// Session cache.
static std::mutex gOrtMutex;
static std::unique_ptr<Ort::Env> gEnv;
static std::unique_ptr<Ort::Session> gSession;
static std::string gModelPath;

static bool ensureSession(NSString* modelPath, NSString* __strong * error) {
    std::lock_guard<std::mutex> lock(gOrtMutex);
    if (gSession && gModelPath == modelPath.UTF8String) return true;
    try {
        if (!gEnv) gEnv = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_ERROR, "jam");
        Ort::SessionOptions opts;
        opts.SetIntraOpNumThreads(4);
        // Prefer CoreML (GPU/ANE); silently fall back to CPU.
        @try {
            OrtSessionOptionsAppendExecutionProvider_CoreML(opts, 0);
        } @catch (...) {}
        gSession = std::make_unique<Ort::Session>(*gEnv, modelPath.UTF8String, opts);
        gModelPath = modelPath.UTF8String;
        return true;
    } catch (const std::exception& e) {
        if (error) *error = [NSString stringWithFormat:@"onnx: %s", e.what()];
        gSession.reset();
        return false;
    }
}

BOOL JamTranscribe(NSString* modelPath,
                   const int16_t* stereo48k, long frames,
                   std::vector<JamNote>& outNotes,
                   void (^progress)(float),
                   NSString* __strong * error) {
    outNotes.clear();
    if (!stereo48k || frames < 48000) {
        if (error) *error = @"stem too short";
        return NO;
    }
    if (!ensureSession(modelPath, error)) return NO;

    // 1. Downmix + linear resample 48 kHz → 22.05 kHz mono.
    const double ratio = 48000.0 / kBpSR;
    const long n22 = (long)(frames / ratio);
    std::vector<float> mono(n22);
    for (long i = 0; i < n22; ++i) {
        const double p = i * ratio;
        const long i0 = (long)p;
        const long i1 = std::min(frames - 1, i0 + 1);
        const float fr = (float)(p - i0);
        const float a = (stereo48k[i0 * 2] + stereo48k[i0 * 2 + 1]) * (0.5f / 32768.0f);
        const float b = (stereo48k[i1 * 2] + stereo48k[i1 * 2 + 1]) * (0.5f / 32768.0f);
        mono[i] = a * (1.0f - fr) + b * fr;
    }

    // 2. Windowed inference with overlap-trim stitching (basic_pitch/inference.py):
    //    pad the start by half the overlap, hop by kHopSamples, and keep the
    //    central frames of every window.
    std::vector<float> padded(kOverlapSamples / 2, 0.0f);
    padded.insert(padded.end(), mono.begin(), mono.end());
    const long total = (long)padded.size();
    const int nWindows = (int)((total + kHopSamples - 1) / kHopSamples);

    std::vector<float> noteMat, onsetMat;   // [totalFrames][88]
    noteMat.reserve(nWindows * kWinFrames * kPitches);
    onsetMat.reserve(nWindows * kWinFrames * kPitches);

    Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::vector<float> input(kAudioNSamples);
    const int64_t inShape[3] = {1, kAudioNSamples, 1};

    // Resolve IO names once.
    Ort::AllocatorWithDefaultOptions alloc;
    std::vector<std::string> inNames, outNames;
    {
        std::lock_guard<std::mutex> lock(gOrtMutex);
        for (size_t i = 0; i < gSession->GetInputCount(); ++i)
            inNames.push_back(gSession->GetInputNameAllocated(i, alloc).get());
        for (size_t i = 0; i < gSession->GetOutputCount(); ++i)
            outNames.push_back(gSession->GetOutputNameAllocated(i, alloc).get());
    }
    const char* inName = inNames[0].c_str();
    std::vector<const char*> outNamePtrs;
    int noteIdx = -1, onsetIdx = -1;
    for (size_t i = 0; i < outNames.size(); ++i) {
        outNamePtrs.push_back(outNames[i].c_str());
        // nmp.onnx outputs: "note", "onset", "contour" (order may vary).
        if (outNames[i].find("note") != std::string::npos) noteIdx = (int)i;
        if (outNames[i].find("onset") != std::string::npos) onsetIdx = (int)i;
    }
    if (noteIdx < 0 || onsetIdx < 0) {
        // Fallback to the documented order: contour, note, onset by shape probe.
        noteIdx = 0;
        onsetIdx = 1;
    }

    const int trim = kOverlapFrames / 2;   // 15 frames each side
    for (int w = 0; w < nWindows; ++w) {
        const long s = (long)w * kHopSamples;
        for (int i = 0; i < kAudioNSamples; ++i) {
            input[i] = (s + i < total) ? padded[s + i] : 0.0f;
        }
        try {
            Ort::Value inTensor = Ort::Value::CreateTensor<float>(
                mem, input.data(), input.size(), inShape, 3);
            std::lock_guard<std::mutex> lock(gOrtMutex);
            auto outs = gSession->Run(Ort::RunOptions{nullptr},
                                      &inName, &inTensor, 1,
                                      outNamePtrs.data(), outNamePtrs.size());
            // Identify note/onset by last-dim == 88 if name matching failed.
            int ni = noteIdx, oi = onsetIdx;
            auto dimsOk = [&](int idx) {
                auto sh = outs[idx].GetTensorTypeAndShapeInfo().GetShape();
                return sh.size() == 3 && sh[2] == kPitches;
            };
            if (!dimsOk(ni) || !dimsOk(oi)) {
                std::vector<int> cands;
                for (int i = 0; i < (int)outs.size(); ++i) if (dimsOk(i)) cands.push_back(i);
                if (cands.size() >= 2) { ni = cands[0]; oi = cands[1]; }
            }
            const float* noteP = outs[ni].GetTensorData<float>();
            const float* onsetP = outs[oi].GetTensorData<float>();
            const int f0 = (w == 0) ? 0 : trim;
            const int f1 = (w == nWindows - 1) ? kWinFrames : kWinFrames - trim;
            for (int f = f0; f < f1; ++f) {
                noteMat.insert(noteMat.end(), noteP + f * kPitches, noteP + (f + 1) * kPitches);
                onsetMat.insert(onsetMat.end(), onsetP + f * kPitches, onsetP + (f + 1) * kPitches);
            }
        } catch (const std::exception& e) {
            if (error) *error = [NSString stringWithFormat:@"onnx run: %s", e.what()];
            return NO;
        }
        if (progress) progress((float)(w + 1) / nWindows * 0.9f);
    }

    const long T = (long)(noteMat.size() / kPitches);
    auto NOTE = [&](long t, int p) -> float& { return noteMat[t * kPitches + p]; };
    auto ONSET = [&](long t, int p) -> float { return onsetMat[t * kPitches + p]; };

    // 3. Notes from onsets: walk forward while frame activity persists.
    auto emitFrom = [&](long t0, int p) {
        long t = t0 + 1;
        long lastAbove = t0;
        int below = 0;
        while (t < T && below < kEnergyTol) {
            if (NOTE(t, p) >= kFrameThresh) { lastAbove = t; below = 0; }
            else below++;
            t++;
        }
        const double start = t0 / kFps;
        const double dur = (lastAbove - t0 + 1) / kFps;
        float amp = 0;
        for (long k = t0; k <= lastAbove; ++k) amp += NOTE(k, p);
        amp /= (lastAbove - t0 + 1);
        // Consume so the melodia pass doesn't re-detect it.
        for (long k = t0; k <= lastAbove; ++k) NOTE(k, p) = 0;
        if (dur >= kMinNoteSec) {
            outNotes.push_back({start, dur, p + 21,
                                std::min(1.0f, std::max(0.1f, amp))});
        }
    };

    for (long t = 0; t < T; ++t) {
        for (int p = 0; p < kPitches; ++p) {
            const float o = ONSET(t, p);
            if (o < kOnsetThresh) continue;
            if (t > 0 && ONSET(t - 1, p) > o) continue;       // local max only
            if (t + 1 < T && ONSET(t + 1, p) > o) continue;
            if (NOTE(t, p) < kFrameThresh) continue;
            emitFrom(t, p);
        }
    }

    // 4. "Melodia" residual pass: sustained activity without clear onsets
    //    (pads/held chords). Iteratively take the strongest remaining frame.
    for (int iter = 0; iter < 400; ++iter) {
        float best = kFrameThresh + 0.05f;
        long bt = -1;
        int bp = -1;
        for (long t = 0; t < T; ++t) {
            for (int p = 0; p < kPitches; ++p) {
                if (NOTE(t, p) > best) { best = NOTE(t, p); bt = t; bp = p; }
            }
        }
        if (bt < 0) break;
        long t0 = bt;
        while (t0 > 0 && NOTE(t0 - 1, bp) >= kFrameThresh) t0--;
        emitFrom(t0, bp);
    }

    std::sort(outNotes.begin(), outNotes.end(),
              [](const JamNote& a, const JamNote& b) {
                  return a.start < b.start || (a.start == b.start && a.pitch < b.pitch);
              });
    if (progress) progress(1.0f);
    return YES;
}

// ── Standard MIDI File writer (type 0) ───────────────────────────────────────

static void putVarLen(std::vector<uint8_t>& v, uint32_t value) {
    uint32_t buf = value & 0x7F;
    while ((value >>= 7)) {
        buf <<= 8;
        buf |= ((value & 0x7F) | 0x80);
    }
    while (true) {
        v.push_back(buf & 0xFF);
        if (buf & 0x80) buf >>= 8;
        else break;
    }
}
static void put32(std::vector<uint8_t>& v, uint32_t x) {
    v.push_back(x >> 24); v.push_back(x >> 16); v.push_back(x >> 8); v.push_back(x);
}
static void put16(std::vector<uint8_t>& v, uint16_t x) {
    v.push_back(x >> 8); v.push_back(x);
}

BOOL JamWriteMidi(NSURL* url, const std::vector<JamNote>& notes, double bpm) {
    if (notes.empty()) return NO;
    if (bpm < 20 || bpm > 400) bpm = 120;
    const int ppq = 480;
    const double ticksPerSec = ppq * bpm / 60.0;

    struct Ev { uint32_t tick; uint8_t status, d1, d2; };
    std::vector<Ev> evs;
    evs.reserve(notes.size() * 2);
    for (const auto& n : notes) {
        const uint32_t on = (uint32_t)llround(n.start * ticksPerSec);
        uint32_t off = (uint32_t)llround((n.start + n.duration) * ticksPerSec);
        if (off <= on) off = on + 1;
        const uint8_t vel = (uint8_t)std::max(1, std::min(127, (int)lround(n.velocity * 127)));
        evs.push_back({on, 0x90, (uint8_t)n.pitch, vel});
        evs.push_back({off, 0x80, (uint8_t)n.pitch, 0});
    }
    std::sort(evs.begin(), evs.end(), [](const Ev& a, const Ev& b) {
        return a.tick < b.tick || (a.tick == b.tick && a.status < b.status);
    });

    std::vector<uint8_t> trk;
    // Tempo meta.
    putVarLen(trk, 0);
    const uint32_t usPerQ = (uint32_t)llround(60000000.0 / bpm);
    trk.insert(trk.end(), {0xFF, 0x51, 0x03,
                           (uint8_t)(usPerQ >> 16), (uint8_t)(usPerQ >> 8), (uint8_t)usPerQ});
    uint32_t last = 0;
    for (const auto& e : evs) {
        putVarLen(trk, e.tick - last);
        last = e.tick;
        trk.push_back(e.status);
        trk.push_back(e.d1);
        trk.push_back(e.d2);
    }
    putVarLen(trk, 0);
    trk.insert(trk.end(), {0xFF, 0x2F, 0x00});   // end of track

    std::vector<uint8_t> file;
    file.insert(file.end(), {'M', 'T', 'h', 'd'});
    put32(file, 6);
    put16(file, 0);      // format 0
    put16(file, 1);      // one track
    put16(file, ppq);
    file.insert(file.end(), {'M', 'T', 'r', 'k'});
    put32(file, (uint32_t)trk.size());
    file.insert(file.end(), trk.begin(), trk.end());

    NSData* data = [NSData dataWithBytes:file.data() length:file.size()];
    return [data writeToURL:url atomically:YES];
}
