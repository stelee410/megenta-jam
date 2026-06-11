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

// JamLaneFx — per-lane insert FX for the PGM MIDI lanes: a BPM-synced
// dotted-eighth ping-pong echo and a compact Schroeder plate reverb.
// Params are atomics (UI thread); all state is audio-thread-only.

#pragma once
#include <atomic>
#include <cmath>

struct JamLaneFx {
    std::atomic<float> echo{0.0f};     // 0..1 wet mix
    std::atomic<float> reverb{0.0f};   // 0..1 wet mix

    // ── Echo (2 s max) ──
    static constexpr int kDlyMax = 96000;
    float dlL[kDlyMax] = {}, dlR[kDlyMax] = {};
    int dlPos = 0;

    // ── Reverb: 4 combs + 2 allpass per side, slightly detuned R ──
    static constexpr int kCbMax = 1500, kApMax = 640;
    float cbL[4][kCbMax] = {}, cbR[4][kCbMax] = {};
    float cbLpL[4] = {}, cbLpR[4] = {};
    int cbPosL[4] = {}, cbPosR[4] = {};
    float apBufL[2][kApMax] = {}, apBufR[2][kApMax] = {};
    int apPosL[2] = {}, apPosR[2] = {};

    void process(float* L, float* R, int n, float bpm) {
        const float eMix = echo.load(std::memory_order_relaxed);
        const float rMix = reverb.load(std::memory_order_relaxed);
        if (eMix < 0.003f && rMix < 0.003f) return;

        int dly = (int)(60.0f / ((bpm < 40.0f || bpm > 300.0f) ? 120.0f : bpm)
                        * 0.75f * 48000.0f);
        if (dly >= kDlyMax) dly = kDlyMax - 1;
        if (dly < 480) dly = 480;

        static constexpr int cLenL[4] = {1188, 1277, 1356, 1422};
        static constexpr int cLenR[4] = {1211, 1300, 1379, 1445};
        static constexpr int aLenL[2] = {556, 341};
        static constexpr int aLenR[2] = {579, 364};

        for (int i = 0; i < n; ++i) {
            float l = L[i], r = R[i];

            if (eMix >= 0.003f) {
                int rp = dlPos - dly;
                if (rp < 0) rp += kDlyMax;
                const float el = dlL[rp], er = dlR[rp];
                dlL[dlPos] = l + er * 0.45f;   // ping-pong cross feedback
                dlR[dlPos] = r + el * 0.45f;
                if (++dlPos >= kDlyMax) dlPos = 0;
                l += el * eMix;
                r += er * eMix;
            }

            if (rMix >= 0.003f) {
                const float in = (l + r) * 0.22f;
                float wl = 0.0f, wr = 0.0f;
                for (int c = 0; c < 4; ++c) {
                    float outL = cbL[c][cbPosL[c]];
                    cbLpL[c] = outL * 0.55f + cbLpL[c] * 0.45f;   // damping
                    cbL[c][cbPosL[c]] = in + cbLpL[c] * 0.83f;
                    if (++cbPosL[c] >= cLenL[c]) cbPosL[c] = 0;
                    wl += outL;
                    float outR = cbR[c][cbPosR[c]];
                    cbLpR[c] = outR * 0.55f + cbLpR[c] * 0.45f;
                    cbR[c][cbPosR[c]] = in + cbLpR[c] * 0.83f;
                    if (++cbPosR[c] >= cLenR[c]) cbPosR[c] = 0;
                    wr += outR;
                }
                for (int a = 0; a < 2; ++a) {
                    float bl = apBufL[a][apPosL[a]];
                    float yl = bl - 0.5f * wl;
                    apBufL[a][apPosL[a]] = wl + 0.5f * yl;
                    if (++apPosL[a] >= aLenL[a]) apPosL[a] = 0;
                    wl = yl;
                    float br = apBufR[a][apPosR[a]];
                    float yr = br - 0.5f * wr;
                    apBufR[a][apPosR[a]] = wr + 0.5f * yr;
                    if (++apPosR[a] >= aLenR[a]) apPosR[a] = 0;
                    wr = yr;
                }
                l += wl * rMix * 0.6f;
                r += wr * rMix * 0.6f;
            }

            L[i] = l;
            R[i] = r;
        }
    }
};
