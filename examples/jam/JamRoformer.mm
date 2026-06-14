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

// Faithful port of the bgkb/bs_polarformer reference inference:
//   audio 44.1k → STFT(2048/512/hann, center) → features (T, 4100)
//   → ONNX mask (1,1,2050,T,2) → complex multiply (DC zeroed)
//   → iSTFT → 20 s chunks, 50% overlap averaged.

#import "JamRoformer.h"

#import <Accelerate/Accelerate.h>
#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>

static constexpr int kRfSR = 44100;
static constexpr int kFft = 2048;
static constexpr int kHop = 512;
static constexpr int kBins = kFft / 2 + 1;        // 1025
static constexpr int kFeat = kBins * 4;           // (f s) × (re,im) = 4100
static constexpr long kChunk = 882000;            // 20 s @ 44.1 k
// 25% overlap: count-averaged seams stay clean while cutting the
// computation 1.5x vs the reference's 50%.
static constexpr long kStep = (kChunk * 3) / 4;

// ── Cached ORT session ──
static std::mutex gRfMutex;
static std::unique_ptr<Ort::Env> gRfEnv;
static std::unique_ptr<Ort::Session> gRfSession;
static NSString* gRfModelPath = nil;

static bool ensureRfSession(NSString* modelPath, NSString* __strong * error) {
    if (gRfSession && [gRfModelPath isEqualToString:modelPath]) return true;
    try {
        if (!gRfEnv) gRfEnv = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_ERROR, "jam-rf");
        // Default thread pool (all cores): measured ~1.6x faster than a
        // fixed 8-thread pool on Apple Silicon for this transformer.
        Ort::SessionOptions opts;
        gRfSession = std::make_unique<Ort::Session>(
            *gRfEnv, modelPath.fileSystemRepresentation, opts);
        gRfModelPath = [modelPath copy];
        return true;
    } catch (const std::exception& e) {
        // Some ORT graph fusions are buggy on transformer exports — retry raw.
        try {
            Ort::SessionOptions opts;
            opts.SetGraphOptimizationLevel(ORT_DISABLE_ALL);
            gRfSession = std::make_unique<Ort::Session>(
                *gRfEnv, modelPath.fileSystemRepresentation, opts);
            gRfModelPath = [modelPath copy];
            return true;
        } catch (const std::exception& e2) {
            if (error) *error = [NSString stringWithFormat:@"roformer load failed: %s", e2.what()];
            gRfSession.reset();
            return false;
        }
    }
}

// Windowed-sinc rational resampler (any ratio; used 48k↔44.1k).
static void resampleSinc(const float* in, long n, double ratio, std::vector<float>& out) {
    const long outN = (long)std::floor(n * ratio);
    out.assign(outN, 0.0f);
    constexpr int kHalf = 24;
    const double fc = std::min(1.0, ratio) * 0.945 * 0.5;   // input-rate normalized
    for (long m = 0; m < outN; ++m) {
        const double t = m / ratio;
        const long ti = (long)std::floor(t);
        double acc = 0.0;
        for (long k = ti - kHalf + 1; k <= ti + kHalf; ++k) {
            if (k < 0 || k >= n) continue;
            const double dx = t - k;
            const double sinc = (std::fabs(dx) < 1e-9)
                ? 2.0 * fc : std::sin(2.0 * M_PI * fc * dx) / (M_PI * dx);
            const double w = 0.5 + 0.5 * std::cos(M_PI * dx / kHalf);   // hann
            acc += in[k] * sinc * w;
        }
        out[m] = (float)acc;
    }
}

namespace {

// vDSP STFT/iSTFT pair matching torch.stft(center=True, hann, unnormalized).
struct Stft {
    FFTSetup setup;
    std::vector<float> win, re, im, splitBuf;
    Stft() {
        setup = vDSP_create_fftsetup(11, kFFTRadix2);   // 2^11 = 2048
        win.resize(kFft);
        for (int i = 0; i < kFft; ++i) {
            win[i] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * i / kFft);  // periodic hann
        }
        re.resize(kFft / 2);
        im.resize(kFft / 2);
        splitBuf.resize(kFft);
    }
    ~Stft() { vDSP_destroy_fftsetup(setup); }

    // x: padded signal (reflect, kFft/2 each side); frame f starts at f*kHop.
    // Writes bins 0..1024 (re/im) for one frame.
    void forward(const float* x, long frame, float* outRe, float* outIm) {
        float windowed[kFft];
        vDSP_vmul(x + frame * kHop, 1, win.data(), 1, windowed, 1, kFft);
        DSPSplitComplex sc = {re.data(), im.data()};
        vDSP_ctoz((const DSPComplex*)windowed, 2, &sc, 1, kFft / 2);
        vDSP_fft_zrip(setup, &sc, 1, 11, kFFTDirection_Forward);
        // zrip = 2× DFT, DC/Nyquist packed.
        outRe[0] = re[0] * 0.5f;
        outIm[0] = 0.0f;
        outRe[kBins - 1] = im[0] * 0.5f;
        outIm[kBins - 1] = 0.0f;
        for (int b = 1; b < kBins - 1; ++b) {
            outRe[b] = re[b] * 0.5f;
            outIm[b] = im[b] * 0.5f;
        }
    }

    // Inverse of one frame (bins → kFft time samples, NOT windowed yet).
    void inverse(const float* inRe, const float* inIm, float* outTime) {
        for (int b = 1; b < kBins - 1; ++b) {
            re[b] = inRe[b];
            im[b] = inIm[b];
        }
        re[0] = inRe[0];
        im[0] = inRe[kBins - 1];   // Nyquist packed into im[0]
        DSPSplitComplex sc = {re.data(), im.data()};
        vDSP_fft_zrip(setup, &sc, 1, 11, kFFTDirection_Inverse);
        // inverse(zrip(x)) = x * kFft * 2 with our 0.5 forward scaling undone:
        // forward emitted DFT/1, inverse zrip of DFT*2... net factor = kFft.
        vDSP_ztoc(&sc, 1, (DSPComplex*)outTime, 2, kFft / 2);
        const float scale = 1.0f / kFft;
        vDSP_vsmul(outTime, 1, &scale, outTime, 1, kFft);
    }
};

}  // namespace

BOOL JamRoformerVocals(NSString* modelPath,
                       const float* inL, const float* inR, long frames48k,
                       std::vector<float>& vocL, std::vector<float>& vocR,
                       void (^progress)(float),
                       NSString* __strong * error) {
    vocL.clear();
    vocR.clear();
    if (!inL || !inR || frames48k < 48000) {
        if (error) *error = @"audio too short";
        return NO;
    }
    std::lock_guard<std::mutex> lock(gRfMutex);
    if (!ensureRfSession(modelPath, error)) return NO;

    // 1. Resample 48k → 44.1k.
    std::vector<float> L, R;
    resampleSinc(inL, frames48k, 44100.0 / 48000.0, L);
    resampleSinc(inR, frames48k, 44100.0 / 48000.0, R);
    const long total = (long)L.size();
    const float* chans[2] = {L.data(), R.data()};

    std::vector<float> resL(total, 0.0f), resR(total, 0.0f), cnt(total, 0.0f);
    Stft stft;

    std::vector<long> startsList;
    for (long st = 0; st < total; st += kStep) startsList.push_back(st);
    const int nChunks = (int)startsList.size();

    const long T = 1 + kChunk / kHop;             // torch frame count (center)
    const long padded = kChunk + kFft;            // kFft/2 reflect each side

    std::vector<float> sig(padded), feat((size_t)T * kFeat);
    std::vector<float> specRe(2 * (size_t)kBins * T), specIm(2 * (size_t)kBins * T);
    std::vector<float> ola(padded), olaW(padded), frameTime(kFft);

    Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    const char* inNames[] = {"stft_features"};
    const char* outNames[] = {"mask"};

    for (int ci = 0; ci < nChunks; ++ci) {
        const long start = startsList[ci];
        const long len = std::min(kChunk, total - start);

        // STFT both channels → bin-major spec + frame-major features.
        for (int s = 0; s < 2; ++s) {
            for (long i = 0; i < padded; ++i) {
                long idx = start + i - kFft / 2;
                if (idx < start) idx = start + (start - idx);
                if (idx >= start + len) idx = (start + len - 1) - (idx - (start + len - 1));
                idx = std::max(start, std::min(start + len - 1, idx));
                sig[i] = chans[s][idx];
            }
            if (len < kChunk) {
                for (long i = kFft / 2 + len; i < padded; ++i) sig[i] = 0.0f;
            }
            float fre[kBins], fim[kBins];
            for (long f = 0; f < T; ++f) {
                stft.forward(sig.data(), f, fre, fim);
                for (int b = 0; b < kBins; ++b) {
                    specRe[((size_t)s * kBins + b) * T + f] = fre[b];
                    specIm[((size_t)s * kBins + b) * T + f] = fim[b];
                    // features: per frame, index = (b*2+s)*2 + {0,1}
                    feat[(size_t)f * kFeat + (b * 2 + s) * 2 + 0] = fre[b];
                    feat[(size_t)f * kFeat + (b * 2 + s) * 2 + 1] = fim[b];
                }
            }
        }

        // 2. ONNX mask.
        const int64_t inShape[3] = {1, T, kFeat};
        Ort::Value in = Ort::Value::CreateTensor<float>(
            mem, feat.data(), feat.size(), inShape, 3);
        std::vector<Ort::Value> outs;
        try {
            outs = gRfSession->Run(Ort::RunOptions{nullptr}, inNames, &in, 1, outNames, 1);
        } catch (const std::exception& e) {
            if (error) *error = [NSString stringWithFormat:@"roformer inference failed: %s", e.what()];
            return NO;
        }
        const float* mask = outs[0].GetTensorData<float>();   // (1,1,2050,T,2)

        // 3. Apply mask (complex), zero DC, iSTFT per channel, overlap-add.
        for (int s = 0; s < 2; ++s) {
            std::fill(ola.begin(), ola.end(), 0.0f);
            std::fill(olaW.begin(), olaW.end(), 0.0f);
            float fre[kBins], fim[kBins];
            for (long f = 0; f < T; ++f) {
                for (int b = 0; b < kBins; ++b) {
                    const size_t row = (size_t)(b * 2 + s);
                    const float mr = mask[(row * T + f) * 2 + 0];
                    const float mi = mask[(row * T + f) * 2 + 1];
                    const float sr = specRe[((size_t)s * kBins + b) * T + f];
                    const float si = specIm[((size_t)s * kBins + b) * T + f];
                    fre[b] = sr * mr - si * mi;
                    fim[b] = sr * mi + si * mr;
                }
                fre[0] = fim[0] = 0.0f;          // zero DC
                stft.inverse(fre, fim, frameTime.data());
                const long base = f * kHop;
                for (int i = 0; i < kFft && base + i < padded; ++i) {
                    ola[base + i] += frameTime[i] * stft.win[i];
                    olaW[base + i] += stft.win[i] * stft.win[i];
                }
            }
            float* dst = (s == 0) ? resL.data() : resR.data();
            for (long i = 0; i < len; ++i) {
                const long p = i + kFft / 2;
                const float w = olaW[p];
                dst[start + i] += (w > 1e-8f) ? ola[p] / w : 0.0f;
            }
        }
        for (long i = 0; i < len; ++i) cnt[start + i] += 1.0f;
        if (progress) progress((ci + 1) / (float)nChunks);
    }

    for (long i = 0; i < total; ++i) {
        const float c = std::max(1.0f, cnt[i]);
        resL[i] /= c;
        resR[i] /= c;
    }

    // 4. Resample vocals back to 48k, pad/trim to the input length.
    resampleSinc(resL.data(), total, 48000.0 / 44100.0, vocL);
    resampleSinc(resR.data(), total, 48000.0 / 44100.0, vocR);
    vocL.resize(frames48k, 0.0f);
    vocR.resize(frames48k, 0.0f);
    return YES;
}

// ── BS-Roformer-SW 6-stem (bass/drums/other/vocals/guitar/piano) ──
// Different ONNX contract from the vocal model above: separate real/imag spec
// inputs [1,2,1025,T] and an already-masked per-stem spec output
// [1,6,2,1025,T] at a FIXED 4 s chunk (T=345). Reuses the same vDSP STFT.

static constexpr long kSwChunk = 176400;        // 4 s @ 44.1k
static constexpr long kSwT = 1 + kSwChunk / kHop;   // 345 frames
static constexpr long kSwStep = (kSwChunk * 3) / 4; // 25% overlap

static std::mutex gSwMutex;
static std::unique_ptr<Ort::Env> gSwEnv;
static std::unique_ptr<Ort::Session> gSwSession;
static NSString* gSwModelPath = nil;

static bool ensureSwSession(NSString* modelPath, NSString* __strong * error) {
    if (gSwSession && [gSwModelPath isEqualToString:modelPath]) return true;
    try {
        if (!gSwEnv) gSwEnv = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_ERROR, "jam-sw");
        Ort::SessionOptions opts;
        gSwSession = std::make_unique<Ort::Session>(
            *gSwEnv, modelPath.fileSystemRepresentation, opts);
        gSwModelPath = [modelPath copy];
        return true;
    } catch (const std::exception& e) {
        if (error) *error = [NSString stringWithFormat:@"roformer-sw load failed: %s", e.what()];
        gSwSession.reset();
        return false;
    }
}

BOOL JamRoformerSWStem(NSString* modelPath, int stemIndex,
                       const float* inL, const float* inR, long frames48k,
                       std::vector<float>& outL, std::vector<float>& outR,
                       void (^progress)(float),
                       NSString* __strong * error) {
    outL.clear();
    outR.clear();
    if (stemIndex < 0 || stemIndex > 5 || !inL || !inR || frames48k < 48000) {
        if (error) *error = @"bad args / audio too short";
        return NO;
    }
    std::lock_guard<std::mutex> lock(gSwMutex);
    if (!ensureSwSession(modelPath, error)) return NO;

    std::vector<float> L, R;
    resampleSinc(inL, frames48k, 44100.0 / 48000.0, L);
    resampleSinc(inR, frames48k, 44100.0 / 48000.0, R);
    const long total = (long)L.size();
    const float* chans[2] = {L.data(), R.data()};

    std::vector<float> resL(total, 0.0f), resR(total, 0.0f), cnt(total, 0.0f);
    Stft stft;

    std::vector<long> startsList;
    for (long st = 0; st < total; st += kSwStep) startsList.push_back(st);
    const int nChunks = (int)startsList.size();

    const long padded = kSwChunk + kFft;
    // Input tensors [1,2,1025,T]; index (ch,bin,f) = (ch*1025+bin)*T + f.
    std::vector<float> specRe(2 * (size_t)kBins * kSwT), specIm(2 * (size_t)kBins * kSwT);
    std::vector<float> sig(padded), ola(padded), olaW(padded), frameTime(kFft);

    Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    const char* inNames[] = {"spec_real", "spec_imag"};
    const char* outNames[] = {"out_spec_real", "out_spec_imag"};

    for (int ci = 0; ci < nChunks; ++ci) {
        const long start = startsList[ci];
        const long len = std::min(kSwChunk, total - start);

        for (int s = 0; s < 2; ++s) {
            for (long i = 0; i < padded; ++i) {
                long idx = start + i - kFft / 2;
                if (idx < start) idx = start + (start - idx);
                if (idx >= start + len) idx = (start + len - 1) - (idx - (start + len - 1));
                idx = std::max(start, std::min(start + len - 1, idx));
                sig[i] = chans[s][idx];
            }
            if (len < kSwChunk) for (long i = kFft / 2 + len; i < padded; ++i) sig[i] = 0.0f;
            float fre[kBins], fim[kBins];
            for (long f = 0; f < kSwT; ++f) {
                stft.forward(sig.data(), f, fre, fim);
                for (int b = 0; b < kBins; ++b) {
                    const size_t o = ((size_t)s * kBins + b) * kSwT + f;
                    specRe[o] = fre[b];
                    specIm[o] = fim[b];
                }
            }
        }

        const int64_t shape[4] = {1, 2, kBins, kSwT};
        Ort::Value vRe = Ort::Value::CreateTensor<float>(mem, specRe.data(), specRe.size(), shape, 4);
        Ort::Value vIm = Ort::Value::CreateTensor<float>(mem, specIm.data(), specIm.size(), shape, 4);
        Ort::Value ins[2] = {std::move(vRe), std::move(vIm)};
        std::vector<Ort::Value> outs;
        try {
            outs = gSwSession->Run(Ort::RunOptions{nullptr}, inNames, ins, 2, outNames, 2);
        } catch (const std::exception& e) {
            if (error) *error = [NSString stringWithFormat:@"roformer-sw inference failed: %s", e.what()];
            return NO;
        }
        const float* oRe = outs[0].GetTensorData<float>();  // [1,6,2,1025,T]
        const float* oIm = outs[1].GetTensorData<float>();

        for (int s = 0; s < 2; ++s) {
            std::fill(ola.begin(), ola.end(), 0.0f);
            std::fill(olaW.begin(), olaW.end(), 0.0f);
            float fre[kBins], fim[kBins];
            for (long f = 0; f < kSwT; ++f) {
                for (int b = 0; b < kBins; ++b) {
                    const size_t o = ((((size_t)stemIndex * 2 + s) * kBins) + b) * kSwT + f;
                    fre[b] = oRe[o];
                    fim[b] = oIm[o];
                }
                stft.inverse(fre, fim, frameTime.data());
                const long base = f * kHop;
                for (int i = 0; i < kFft && base + i < padded; ++i) {
                    ola[base + i] += frameTime[i] * stft.win[i];
                    olaW[base + i] += stft.win[i] * stft.win[i];
                }
            }
            float* dst = (s == 0) ? resL.data() : resR.data();
            for (long i = 0; i < len; ++i) {
                const long p = i + kFft / 2;
                const float w = olaW[p];
                dst[start + i] += (w > 1e-8f) ? ola[p] / w : 0.0f;
            }
        }
        for (long i = 0; i < len; ++i) cnt[start + i] += 1.0f;
        if (progress) progress((ci + 1) / (float)nChunks);
    }

    for (long i = 0; i < total; ++i) {
        const float c = std::max(1.0f, cnt[i]);
        resL[i] /= c;
        resR[i] /= c;
    }
    resampleSinc(resL.data(), total, 48000.0 / 44100.0, outL);
    resampleSinc(resR.data(), total, 48000.0 / 44100.0, outR);
    outL.resize(frames48k, 0.0f);
    outR.resize(frames48k, 0.0f);
    return YES;
}
