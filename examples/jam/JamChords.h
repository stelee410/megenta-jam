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

// JamChords — offline chord recognition + re-voicing for the PGM studio.
//
//   * detect():  frame chroma (vDSP FFT) → 25-state HMM (12 maj + 12 min +
//                no-chord) Viterbi smoothing → beat-snapped chord segments.
//                Best run on a drums-free stem mix.
//   * voice():   chord timeline → MIDI clip in a performance style
//                (pad / pluck / stab / arp / bass) with simple voice-leading.
//
// Pure offline C++; call from a background queue.

#pragma once
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "JamTranscribe.h"   // JamNote

namespace jamchords {

struct Chord {
    double start = 0, end = 0;
    int root = 0;        // 0=C … 11=B
    bool minor = false;
    bool none = false;   // N (no chord)
};

static const char* kPcNames[12] = {"C", "C#", "D", "D#", "E", "F",
                                   "F#", "G", "G#", "A", "A#", "B"};

inline std::string chordName(const Chord& c) {
    if (c.none) return "—";
    return std::string(kPcNames[c.root]) + (c.minor ? "m" : "");
}

// ── Detection ────────────────────────────────────────────────────────────────

// keyIdx/keyMinor (from the key detector) add a diatonic prior that resolves
// major/minor third ambiguity; pass keyIdx = -1 to disable.
inline std::vector<Chord> detect(const float* mono, long n, float bpm,
                                 int keyIdx = -1, bool keyMinor = false) {
    std::vector<Chord> out;
    constexpr float kSR = 48000.0f;
    constexpr int N = 8192;        // 5.86 Hz bins
    constexpr int HOP = 12000;     // 0.25 s
    const long frames = (n - N) / HOP + 1;
    if (frames < 8) return out;

    // 1. Frame chroma.
    FFTSetup setup = vDSP_create_fftsetup(13, kFFTRadix2);   // 2^13
    std::vector<float> win(N), re(N / 2), im(N / 2), frame(N);
    vDSP_hann_window(win.data(), N, vDSP_HANN_NORM);
    DSPSplitComplex sc = {re.data(), im.data()};

    std::vector<float> chroma(frames * 12, 0.0f);
    std::vector<float> energy(frames, 0.0f);
    for (long f = 0; f < frames; ++f) {
        vDSP_vmul(mono + f * HOP, 1, win.data(), 1, frame.data(), 1, N);
        vDSP_ctoz((const DSPComplex*)frame.data(), 2, &sc, 1, N / 2);
        vDSP_fft_zrip(setup, &sc, 1, 13, kFFTDirection_Forward);
        float* c = &chroma[f * 12];
        // Magnitudes over the harmony band.
        const int bLo = (int)(60.0f * N / kSR);
        const int bHi = (int)(2200.0f * N / kSR);
        static thread_local std::vector<float> mags;
        mags.resize(N / 2);
        double e = 0;
        for (int b = bLo; b <= bHi; ++b) {
            mags[b] = std::sqrt(re[b] * re[b] + im[b] * im[b]);
            e += mags[b];
        }
        energy[f] = (float)e;
        // Noise floor: median magnitude in the band.
        static thread_local std::vector<float> medBuf;
        medBuf.assign(mags.begin() + bLo, mags.begin() + bHi + 1);
        std::nth_element(medBuf.begin(), medBuf.begin() + medBuf.size() / 2, medBuf.end());
        const float floorMag = medBuf[medBuf.size() / 2] * 1.6f;
        // Spectral PEAKS only: local maxima above the floor → true partials;
        // broadband drum/noise energy never forms peaks and is discarded.
        for (int b = bLo + 1; b < bHi; ++b) {
            const float m = mags[b];
            if (m <= floorMag || m < mags[b - 1] || m < mags[b + 1]) continue;
            // Parabolic frequency refinement.
            const float den = mags[b - 1] - 2.0f * m + mags[b + 1];
            const float delta = (std::fabs(den) > 1e-12f)
                ? 0.5f * (mags[b - 1] - mags[b + 1]) / den : 0.0f;
            const float freq = (b + delta) * kSR / N;
            const float midi = 69.0f + 12.0f * std::log2(freq / 440.0f);
            const int pc = ((int)std::lround(midi) % 12 + 12) % 12;
            c[pc] += m;
        }
        // Square-root compression keeps contrast but tames dominant voices.
        for (int p = 0; p < 12; ++p) c[p] = std::sqrt(c[p]);
    }
    vDSP_destroy_fftsetup(setup);

    // Temporal smoothing (±1 frame) then per-frame L2 normalisation.
    {
        std::vector<float> sm(chroma.size());
        for (long f = 0; f < frames; ++f) {
            for (int p = 0; p < 12; ++p) {
                float a = chroma[f * 12 + p];
                float cnt = 1;
                if (f > 0) { a += chroma[(f - 1) * 12 + p]; cnt++; }
                if (f + 1 < frames) { a += chroma[(f + 1) * 12 + p]; cnt++; }
                sm[f * 12 + p] = a / cnt;
            }
        }
        chroma.swap(sm);
        for (long f = 0; f < frames; ++f) {
            float* c = &chroma[f * 12];
            float norm = 0;
            for (int p = 0; p < 12; ++p) norm += c[p] * c[p];
            norm = std::sqrt(norm);
            if (norm > 1e-9f) for (int p = 0; p < 12; ++p) c[p] /= norm;
        }
    }

    // Energy gate threshold (frames quieter than 15% of median favour N).
    std::vector<float> esort(energy);
    std::nth_element(esort.begin(), esort.begin() + frames / 2, esort.end());
    const float eGate = esort[frames / 2] * 0.15f;

    // 2. Templates: 12 maj + 12 min (weighted root/third/fifth), L2-normed.
    float tmpl[24][12] = {};
    for (int r = 0; r < 12; ++r) {
        tmpl[r][r] = 1.0f;  tmpl[r][(r + 4) % 12] = 0.9f;  tmpl[r][(r + 7) % 12] = 0.85f;
        tmpl[12 + r][r] = 1.0f; tmpl[12 + r][(r + 3) % 12] = 0.9f; tmpl[12 + r][(r + 7) % 12] = 0.85f;
    }
    for (int k = 0; k < 24; ++k) {
        float norm = 0;
        for (int p = 0; p < 12; ++p) norm += tmpl[k][p] * tmpl[k][p];
        norm = std::sqrt(norm);
        for (int p = 0; p < 12; ++p) tmpl[k][p] /= norm;
    }

    // Diatonic prior: triads of the detected key get an emission bonus.
    float keyBonus[25] = {};
    if (keyIdx >= 0) {
        auto majState = [&](int r) { return ((r % 12) + 12) % 12; };
        auto minState = [&](int r) { return 12 + ((r % 12) + 12) % 12; };
        if (!keyMinor) {   // I ii iii IV V vi
            keyBonus[majState(keyIdx)] = 0.9f;
            keyBonus[minState(keyIdx + 2)] = 0.7f;
            keyBonus[minState(keyIdx + 4)] = 0.7f;
            keyBonus[majState(keyIdx + 5)] = 0.9f;
            keyBonus[majState(keyIdx + 7)] = 0.9f;
            keyBonus[minState(keyIdx + 9)] = 0.8f;
        } else {           // i III iv v/V VI VII
            keyBonus[minState(keyIdx)] = 0.9f;
            keyBonus[majState(keyIdx + 3)] = 0.8f;
            keyBonus[minState(keyIdx + 5)] = 0.7f;
            keyBonus[minState(keyIdx + 7)] = 0.6f;
            keyBonus[majState(keyIdx + 7)] = 0.6f;
            keyBonus[majState(keyIdx + 8)] = 0.8f;
            keyBonus[majState(keyIdx + 10)] = 0.8f;
        }
    }

    // 3. Viterbi over 25 states (24 chords + N).
    constexpr int S = 25;
    const float logStay = std::log(0.90f);
    const float logSwitch = std::log(0.10f / (S - 1));
    std::vector<float> dp(frames * S, -1e30f);
    std::vector<int> bp(frames * S, 0);
    auto emit = [&](long f, int s) -> float {
        if (s == 24) {   // N state
            return (energy[f] < eGate) ? 7.0f : 4.2f;
        }
        const float* c = &chroma[f * 12];
        float dot = 0;
        for (int p = 0; p < 12; ++p) dot += c[p] * tmpl[s][p];
        return dot * 10.0f + keyBonus[s];
    };
    for (int s = 0; s < S; ++s) dp[s] = emit(0, s);
    for (long f = 1; f < frames; ++f) {
        // Best previous state (for the switch case).
        int bestPrev = 0;
        float bestVal = dp[(f - 1) * S];
        for (int s = 1; s < S; ++s) {
            if (dp[(f - 1) * S + s] > bestVal) { bestVal = dp[(f - 1) * S + s]; bestPrev = s; }
        }
        for (int s = 0; s < S; ++s) {
            const float staySc = dp[(f - 1) * S + s] + logStay;
            const float switchSc = bestVal + logSwitch;
            if (staySc >= switchSc) {
                dp[f * S + s] = staySc + emit(f, s);
                bp[f * S + s] = s;
            } else {
                dp[f * S + s] = switchSc + emit(f, s);
                bp[f * S + s] = bestPrev;
            }
        }
    }
    std::vector<int> path(frames);
    {
        int s = 0;
        float best = dp[(frames - 1) * S];
        for (int k = 1; k < S; ++k) {
            if (dp[(frames - 1) * S + k] > best) { best = dp[(frames - 1) * S + k]; s = k; }
        }
        for (long f = frames - 1; f >= 0; --f) {
            path[f] = s;
            s = bp[f * S + s];
        }
    }

    // 4. Segments → merge shorties → snap to the beat grid.
    const double beat = 60.0 / (bpm < 40 ? 120 : bpm);
    auto snap = [&](double t) { return std::round(t / beat) * beat; };
    long segStart = 0;
    for (long f = 1; f <= frames; ++f) {
        if (f == frames || path[f] != path[segStart]) {
            Chord c;
            c.start = segStart * (HOP / kSR);
            c.end = f * (HOP / kSR);
            const int s = path[segStart];
            if (s == 24) c.none = true;
            else { c.root = s % 12; c.minor = s >= 12; }
            out.push_back(c);
            segStart = f;
        }
    }
    // Merge segments shorter than ~0.45 s into the previous one.
    std::vector<Chord> merged;
    for (auto& c : out) {
        if (!merged.empty() && (c.end - c.start) < 0.45) {
            merged.back().end = c.end;
        } else if (!merged.empty() && merged.back().root == c.root &&
                   merged.back().minor == c.minor && merged.back().none == c.none) {
            merged.back().end = c.end;
        } else {
            merged.push_back(c);
        }
    }
    for (auto& c : merged) {
        c.start = snap(c.start);
        c.end = std::max(c.start + beat, snap(c.end));
    }
    return merged;
}

// ── Re-voicing ───────────────────────────────────────────────────────────────
// Styles: 0 pad · 1 pluck · 2 stab · 3 arp · 4 bass. Voice-leading: pads pick
// the triad inversion whose top note moves least from the previous chord.

inline std::vector<JamNote> voice(const std::vector<Chord>& chords,
                                  float bpm, int style) {
    std::vector<JamNote> out;
    const double beat = 60.0 / (bpm < 40 ? 120 : bpm);
    int prevTop = -1;

    for (const auto& c : chords) {
        if (c.none) continue;
        const int third = c.minor ? 3 : 4;
        const int r = c.root;

        if (style == 0) {   // pad: open voicing, one chord per bar
            // Candidate inversions (top note pitch class varies).
            int candidates[3][4] = {
                {48 + r, 55 + r, 60 + r + third, 67 + r},          // root top-5th
                {48 + r, 52 + r + third, 60 + r, 64 + r + third},  // third top
                {48 + r, 55 + r, 64 + r + third, 72 + r},          // high root
            };
            int pick = 0;
            if (prevTop >= 0) {
                int bestD = 127;
                for (int k = 0; k < 3; ++k) {
                    const int d = std::abs(candidates[k][3] - prevTop);
                    if (d < bestD) { bestD = d; pick = k; }
                }
            }
            prevTop = candidates[pick][3];
            const double bar = beat * 4;
            for (double t = c.start; t < c.end - 0.01; t += bar) {
                const double dur = std::min(bar, c.end - t) - 0.05;
                for (int k = 0; k < 4; ++k) {
                    out.push_back({t, std::max(0.1, dur), candidates[pick][k], 0.62f});
                }
            }
        } else if (style == 1) {   // pluck: 8th-note broken triad
            const int tones[4] = {60 + r, 60 + r + third, 67 + r, 60 + r + third};
            int k = 0;
            for (double t = c.start; t < c.end - 0.01; t += beat / 2) {
                out.push_back({t, beat * 0.42, tones[k % 4], 0.7f});
                k++;
            }
        } else if (style == 2) {   // stab: offbeat closed triads
            for (double t = c.start + beat / 2; t < c.end - 0.01; t += beat) {
                out.push_back({t, beat * 0.28, 60 + r, 0.78f});
                out.push_back({t, beat * 0.28, 60 + r + third, 0.74f});
                out.push_back({t, beat * 0.28, 67 + r, 0.74f});
            }
        } else if (style == 3) {   // arp: 16th up-down over two octaves
            const int seq[8] = {60 + r, 60 + r + third, 67 + r, 72 + r,
                                72 + r + third, 72 + r, 67 + r, 60 + r + third};
            int k = 0;
            for (double t = c.start; t < c.end - 0.01; t += beat / 4) {
                out.push_back({t, beat * 0.22, seq[k % 8], 0.68f});
                k++;
            }
        } else {   // bass: root 8ths with a fifth pickup on beat 4&
            int k = 0;
            for (double t = c.start; t < c.end - 0.01; t += beat / 2) {
                const bool pickup = (k % 8) == 7;
                out.push_back({t, beat * 0.4, 36 + r + (pickup ? 7 : 0), 0.8f});
                k++;
            }
        }
    }
    return out;
}

}  // namespace jamchords
