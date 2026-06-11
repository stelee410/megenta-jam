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

// JamStudio — offline song analysis + stem separation for the PGM studio.
//
//   * analyze():  BPM (onset autocorrelation), key (chroma + Krumhansl),
//                 structure sections (bar-energy novelty)
//   * separate(): median-filtering HPSS (harmonic/percussive source
//                 separation) on a chunked STFT, then a 150 Hz split of the
//                 harmonic stem → three stems: drums / bass / other.
//
// Pure offline C++ (vDSP FFT); call from a background queue.

#pragma once
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace jamstudio {

static constexpr float kSR = 48000.0f;

struct Section {
    double start = 0, end = 0;   // seconds
    int label = 0;               // 0 low (intro/break) · 1 mid (verse) · 2 high (drop/chorus) · 3 build
    float energy = 0;
};

struct Analysis {
    float bpm = 120.0f;
    int keyIdx = 0;              // 0=C … 11=B
    bool minor = false;
    std::vector<Section> sections;
};

// ── Small helpers ────────────────────────────────────────────────────────────

inline float medianOf(float* tmp, int n) {
    std::nth_element(tmp, tmp + n / 2, tmp + n);
    return tmp[n / 2];
}

// ── Analysis ─────────────────────────────────────────────────────────────────

inline Analysis analyze(const float* mono, long n) {
    Analysis out;
    if (n < (long)kSR * 8) return out;

    // 1. Onset envelope: ~200 Hz lowpass energy flux per 512-sample hop.
    const int hop = 512;
    const float fps = kSR / hop;
    const long frames = n / hop;
    std::vector<float> env(frames, 0.0f);
    {
        float lp = 0.0f, prevE = 0.0f;
        for (long f = 0; f < frames; ++f) {
            float acc = 0.0f;
            const float* x = mono + f * hop;
            for (int i = 0; i < hop; ++i) {
                lp += 0.026f * (x[i] - lp);
                acc += lp * lp;
            }
            const float e = acc / hop;
            env[f] = std::max(0.0f, e - prevE);
            prevE = e;
        }
    }

    // 2. BPM: autocorrelation of the onset envelope (50–200 BPM).
    {
        double mean = 0;
        for (float v : env) mean += v;
        mean /= frames;
        std::vector<float> x(env);
        for (auto& v : x) v -= (float)mean;
        const int minLag = (int)(60.0f * fps / 200.0f);
        const int maxLag = std::min((long)(60.0f * fps / 50.0f), frames / 2);
        std::vector<float> r(maxLag + 1, 0.0f);
        for (int lag = minLag; lag <= maxLag; ++lag) {
            double acc = 0;
            for (long i = 0; i + lag < frames; ++i) acc += x[i] * x[i + lag];
            r[lag] = (float)(acc / (frames - lag));
        }
        int best = minLag;
        float bestS = -1;
        for (int lag = minLag; lag <= maxLag; ++lag) {
            float s = r[lag] + (lag * 2 <= maxLag ? 0.5f * r[lag * 2] : 0.0f);
            if (s > bestS) { bestS = s; best = lag; }
        }
        float lagF = (float)best;
        if (best > minLag && best < maxLag) {
            const float y0 = r[best - 1], y1 = r[best], y2 = r[best + 1];
            const float den = y0 - 2 * y1 + y2;
            if (std::fabs(den) > 1e-12f) lagF += 0.5f * (y0 - y2) / den;
        }
        float bpm = 60.0f * fps / lagF;
        while (bpm < 70.0f) bpm *= 2.0f;
        while (bpm > 180.0f) bpm *= 0.5f;
        out.bpm = bpm;
    }

    // 3. Key: chroma accumulation + Krumhansl-Schmuckler template match.
    {
        const int N = 4096;
        const int hopK = 4096;
        FFTSetup setup = vDSP_create_fftsetup(12, kFFTRadix2);  // 2^12
        std::vector<float> win(N), re(N / 2), im(N / 2);
        vDSP_hann_window(win.data(), N, vDSP_HANN_NORM);
        DSPSplitComplex sc = {re.data(), im.data()};
        double chroma[12] = {};
        std::vector<float> frame(N);
        for (long s = 0; s + N <= n; s += hopK) {
            vDSP_vmul(mono + s, 1, win.data(), 1, frame.data(), 1, N);
            vDSP_ctoz((const DSPComplex*)frame.data(), 2, &sc, 1, N / 2);
            vDSP_fft_zrip(setup, &sc, 1, 12, kFFTDirection_Forward);
            for (int b = 1; b < N / 2; ++b) {
                const float freq = b * kSR / N;
                if (freq < 60.0f || freq > 5000.0f) continue;
                const float mag2 = re[b] * re[b] + im[b] * im[b];
                const float midi = 69.0f + 12.0f * std::log2(freq / 440.0f);
                const int pc = ((int)std::lround(midi) % 12 + 12) % 12;
                chroma[pc] += std::sqrt(mag2);
            }
        }
        vDSP_destroy_fftsetup(setup);
        static const double majP[12] = {6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88};
        static const double minP[12] = {6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17};
        auto corr = [&](const double* p, int rot) {
            double mp = 0, mc = 0;
            for (int i = 0; i < 12; ++i) { mp += p[i]; mc += chroma[i]; }
            mp /= 12; mc /= 12;
            double num = 0, dp = 0, dc = 0;
            for (int i = 0; i < 12; ++i) {
                const double a = p[i] - mp;
                const double b = chroma[(i + rot) % 12] - mc;
                num += a * b; dp += a * a; dc += b * b;
            }
            return (dp > 0 && dc > 0) ? num / std::sqrt(dp * dc) : 0.0;
        };
        double best = -2;
        for (int rot = 0; rot < 12; ++rot) {
            const double cM = corr(majP, rot);
            const double cm = corr(minP, rot);
            if (cM > best) { best = cM; out.keyIdx = rot; out.minor = false; }
            if (cm > best) { best = cm; out.keyIdx = rot; out.minor = true; }
        }
    }

    // 4. Sections: bar-energy novelty → boundaries → labels by energy tercile.
    {
        const double barSec = 4.0 * 60.0 / out.bpm;
        const long barSamp = (long)(barSec * kSR);
        const long bars = std::max(4L, n / barSamp);
        std::vector<float> rms(bars, 0.0f);
        for (long b = 0; b < bars; ++b) {
            const long s0 = b * barSamp;
            const long len = std::min(barSamp, n - s0);
            float acc = 0;
            vDSP_svesq(mono + s0, 1, &acc, len);
            rms[b] = std::sqrt(acc / std::max(1L, len));
        }
        // Smooth (3-bar moving average).
        std::vector<float> sm(bars);
        for (long b = 0; b < bars; ++b) {
            float a = rms[b], cnt = 1;
            if (b > 0) { a += rms[b-1]; cnt++; }
            if (b + 1 < bars) { a += rms[b+1]; cnt++; }
            sm[b] = a / cnt;
        }
        // Novelty peaks with ≥8-bar spacing → boundaries.
        std::vector<long> bounds = {0};
        std::vector<std::pair<float, long>> nov;
        for (long b = 1; b < bars; ++b) {
            nov.push_back({std::fabs(sm[b] - sm[b-1]), b});
        }
        std::sort(nov.rbegin(), nov.rend());
        for (auto& [v, b] : nov) {
            if (bounds.size() >= 12) break;
            bool ok = true;
            for (long e : bounds) if (std::labs(e - b) < 8) { ok = false; break; }
            if (ok) bounds.push_back(b);
        }
        bounds.push_back(bars);
        std::sort(bounds.begin(), bounds.end());
        // Energy terciles for labels.
        std::vector<float> sorted(sm);
        std::sort(sorted.begin(), sorted.end());
        const float t1 = sorted[bars / 3];
        const float t2 = sorted[bars * 2 / 3];
        for (size_t i = 0; i + 1 < bounds.size(); ++i) {
            Section sec;
            sec.start = bounds[i] * barSec;
            sec.end = bounds[i + 1] * barSec;
            float acc = 0;
            for (long b = bounds[i]; b < bounds[i + 1]; ++b) acc += sm[b];
            sec.energy = acc / std::max(1L, bounds[i + 1] - bounds[i]);
            const float first = sm[bounds[i]];
            const float last = sm[std::max(bounds[i], bounds[i + 1] - 1)];
            if (last > first * 1.6f && sec.energy < t2) sec.label = 3;          // build
            else if (sec.energy < t1) sec.label = 0;
            else if (sec.energy < t2) sec.label = 1;
            else sec.label = 2;
            out.sections.push_back(sec);
        }
    }
    return out;
}

// ── HPSS separation ──────────────────────────────────────────────────────────
// Chunked STFT median-filter HPSS per channel, soft Wiener masks, then a
// complementary 150 Hz biquad split of the harmonic stem into bass / other.
// Outputs interleaved stereo int16.

inline void separate(const float* inL, const float* inR, long n,
                     std::vector<int16_t>& drums,
                     std::vector<int16_t>& bass,
                     std::vector<int16_t>& other,
                     void (^progress)(float)) {
    constexpr int N = 2048, HOP = 512, HALO = 12, BLOCK = 1024;
    constexpr int BINS = N / 2;        // packed-real bins we filter
    constexpr int MED = 2 * HALO + 1;  // 25-point medians

    const long frames = (n - N) / HOP + 1;
    std::vector<float> harm(2 * n, 0.0f), perc(2 * n, 0.0f);  // interleaved accumulation
    std::vector<float> norm(n, 0.0f);                          // window-square overlap norm

    FFTSetup setup = vDSP_create_fftsetup(11, kFFTRadix2);     // 2^11
    std::vector<float> win(N);
    vDSP_hann_window(win.data(), N, vDSP_HANN_NORM);

    const long blocks = (frames + BLOCK - 1) / BLOCK;
    std::vector<float> mag((BLOCK + 2 * HALO) * BINS);
    std::vector<float> re((BLOCK + 2 * HALO) * BINS), im((BLOCK + 2 * HALO) * BINS);
    std::vector<float> hMask(BLOCK * BINS), pMask(BLOCK * BINS);
    std::vector<float> frame(N), tmp(MED);
    std::vector<float> reF(BINS), imF(BINS);

    for (int ch = 0; ch < 2; ++ch) {
        const float* x = (ch == 0) ? inL : inR;
        for (long blk = 0; blk < blocks; ++blk) {
            const long f0 = blk * BLOCK;
            const long bCount = std::min((long)BLOCK, frames - f0);
            const long lo = std::max(0L, f0 - HALO);
            const long hi = std::min(frames, f0 + bCount + HALO);
            const long span = hi - lo;

            // STFT of block + halo.
            for (long f = 0; f < span; ++f) {
                const long s = (lo + f) * HOP;
                vDSP_vmul(x + s, 1, win.data(), 1, frame.data(), 1, N);
                DSPSplitComplex sc = {&re[f * BINS], &im[f * BINS]};
                vDSP_ctoz((const DSPComplex*)frame.data(), 2, &sc, 1, BINS);
                vDSP_fft_zrip(setup, &sc, 1, 11, kFFTDirection_Forward);
                float* m = &mag[f * BINS];
                for (int b = 0; b < BINS; ++b) {
                    m[b] = std::sqrt(re[f * BINS + b] * re[f * BINS + b] +
                                     im[f * BINS + b] * im[f * BINS + b]);
                }
            }

            // Masks for the core frames.
            for (long f = 0; f < bCount; ++f) {
                const long fc = (f0 + f) - lo;          // index within span
                float* hm = &hMask[f * BINS];
                float* pm = &pMask[f * BINS];
                for (int b = 0; b < BINS; ++b) {
                    // Harmonic: median across TIME at this bin.
                    int cnt = 0;
                    for (int k = -HALO; k <= HALO; ++k) {
                        const long ff = fc + k;
                        if (ff >= 0 && ff < span) tmp[cnt++] = mag[ff * BINS + b];
                    }
                    const float H = medianOf(tmp.data(), cnt);
                    // Percussive: median across FREQUENCY at this frame.
                    cnt = 0;
                    for (int k = -HALO; k <= HALO; ++k) {
                        const int bb = b + k;
                        if (bb >= 0 && bb < BINS) tmp[cnt++] = mag[fc * BINS + bb];
                    }
                    const float P = medianOf(tmp.data(), cnt);
                    const float h2 = H * H, p2 = P * P;
                    const float den = h2 + p2 + 1e-12f;
                    hm[b] = h2 / den;
                    pm[b] = p2 / den;
                }
            }

            // Masked iSTFT + overlap-add for the core frames.
            for (long f = 0; f < bCount; ++f) {
                const long fc = (f0 + f) - lo;
                const long s = (f0 + f) * HOP;
                for (int pass = 0; pass < 2; ++pass) {
                    const float* mask = pass == 0 ? &hMask[f * BINS] : &pMask[f * BINS];
                    for (int b = 0; b < BINS; ++b) {
                        reF[b] = re[fc * BINS + b] * mask[b];
                        imF[b] = im[fc * BINS + b] * mask[b];
                    }
                    DSPSplitComplex sc = {reF.data(), imF.data()};
                    vDSP_fft_zrip(setup, &sc, 1, 11, kFFTDirection_Inverse);
                    vDSP_ztoc(&sc, 1, (DSPComplex*)frame.data(), 2, BINS);
                    const float scale = 1.0f / (2.0f * N);
                    float* dst = pass == 0 ? harm.data() : perc.data();
                    for (int i = 0; i < N && s + i < n; ++i) {
                        dst[(s + i) * 2 + ch] += frame[i] * scale * win[i];
                    }
                }
                if (ch == 0) {
                    for (int i = 0; i < N && s + i < n; ++i) {
                        norm[s + i] += win[i] * win[i];
                    }
                }
            }
            if (progress && (blk % 8 == 0)) {
                progress((ch * blocks + blk) / (float)(2 * blocks));
            }
        }
    }
    vDSP_destroy_fftsetup(setup);

    // Normalise the overlap-add, split harmonic at 150 Hz (complementary),
    // and quantise the three stems to interleaved stereo int16.
    drums.assign(2 * n, 0);
    bass.assign(2 * n, 0);
    other.assign(2 * n, 0);
    // 220 Hz 4th-order lowpass (two cascaded biquads) per channel for a
    // fuller bass stem; `other` stays the exact complement.
    const float w0 = 2.0f * (float)M_PI * 220.0f / kSR;
    const float alpha = std::sin(w0) / (2.0f * 0.707f);
    const float b0 = (1 - std::cos(w0)) / 2, b1 = 1 - std::cos(w0), b2 = b0;
    const float a0 = 1 + alpha, a1 = -2 * std::cos(w0), a2 = 1 - alpha;
    float z1[2] = {}, z2[2] = {}, z3[2] = {}, z4[2] = {};
    auto toI16 = [](float v) {
        v *= 32767.0f;
        if (v > 32767.0f) v = 32767.0f;
        if (v < -32768.0f) v = -32768.0f;
        return (int16_t)v;
    };
    for (long i = 0; i < n; ++i) {
        const float wn = norm[i] > 1e-6f ? 1.0f / norm[i] : 0.0f;
        for (int ch = 0; ch < 2; ++ch) {
            const float h = harm[i * 2 + ch] * wn;
            const float p = perc[i * 2 + ch] * wn;
            // Two cascaded biquad LPs (direct form II transposed).
            const float lp1 = (b0 * h + z1[ch]) / a0;
            z1[ch] = (b1 * h - a1 * lp1) + z2[ch];
            z2[ch] = b2 * h - a2 * lp1;
            const float lp = (b0 * lp1 + z3[ch]) / a0;
            z3[ch] = (b1 * lp1 - a1 * lp) + z4[ch];
            z4[ch] = b2 * lp1 - a2 * lp;
            drums[i * 2 + ch] = toI16(p);
            bass[i * 2 + ch] = toI16(lp);
            other[i * 2 + ch] = toI16(h - lp);
        }
    }
    if (progress) progress(1.0f);
}

}  // namespace jamstudio
