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

// JamSynth — a MicroFreak-modelled stage synth for live improvisation.
//
// Voice architecture (per the hardware, upgraded for the stage):
//   * 5 oscillator engines with Wave/Timbre/Shape macros, random-phase starts,
//     per-voice analog drift, JP-style stereo supersaw
//   * Zavalishin/TPT state-variable filter (stereo pair, opens to Nyquist,
//     musical resonance) — paraphonic, with mono ADSR filter env
//   * Cycling envelope (Rise/Shape · Fall/Shape · Hold/Sustain · Amount;
//     Env / Run / Loop) and a synced LFO, both mod-matrix sources
//   * 5×5 mod matrix (CycEnv, Env, LFO, Velo, Key → Pitch, Wave, Timbre,
//     Shape, Cutoff)
//   * Arp: up/down/updown/random/order/pattern + dice, swing, gate, spice,
//     1-4 octaves, hold latch, BPM-synced divisions incl. triplets
//   * Built-in stereo ensemble chorus and a Schroeder plate ("Space") so
//     patches carry a stage on their own
//
// Realtime-safe: params are atomics, notes arrive via a lock-free SPSC queue,
// all voice/filter/fx state is audio-thread-only.

#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

struct JamSynth {
    static constexpr float kSR = 48000.0f;
    static constexpr int kVoices = 6;

    // ── Parameters (UI thread → audio thread; 0..1 unless noted) ──
    std::atomic<bool> active{false};
    std::atomic<bool> monoMode{false};
    std::atomic<int> oscType{1};
    std::atomic<float> wave{0.5f};
    std::atomic<float> timbre{0.5f};
    std::atomic<float> shape{0.3f};
    std::atomic<float> glide{0.0f};
    std::atomic<float> attack{0.05f}, decay{0.4f}, sustain{0.6f}, release{0.3f};
    std::atomic<int> filterType{0};
    std::atomic<float> cutoff{0.7f}, resonance{0.2f};
    std::atomic<float> envFilter{0.5f};
    std::atomic<int> lfoShape{0};
    std::atomic<float> lfoRate{0.3f};
    std::atomic<bool> lfoSync{false};
    std::atomic<int> cycMode{0};
    std::atomic<float> cycRise{0.2f}, cycFall{0.4f};
    std::atomic<float> cycHold{0.5f};
    std::atomic<float> cycRiseShape{0.5f};
    std::atomic<float> cycFallShape{0.5f};
    std::atomic<float> cycAmount{1.0f};
    std::atomic<int> arpMode{0};
    std::atomic<int> arpOct{1};
    std::atomic<int> arpDiv{3};
    std::atomic<bool> arpHold{false};
    std::atomic<float> arpSwing{0.0f};
    std::atomic<float> arpGate{0.55f};
    std::atomic<float> arpSpice{0.0f};
    std::atomic<uint32_t> diceSeed{1};
    std::atomic<float> chorus{0.25f};    // stereo ensemble amount
    std::atomic<float> space{0.2f};      // plate reverb amount
    std::atomic<float> volume{0.6f};

    std::atomic<float> matrix[25] = {};  // [src*5+dest], -1..1

    // ── Note events (main → audio), lock-free SPSC ──
    struct NoteEvent { uint8_t note; uint8_t vel; bool on; };
    static constexpr int kEvCap = 256;
    NoteEvent events[kEvCap] = {};
    std::atomic<int> evWrite{0};
    std::atomic<int> evRead{0};

    void pushNote(uint8_t note, uint8_t vel, bool on) {
        const int w = evWrite.load(std::memory_order_relaxed);
        const int next = (w + 1) % kEvCap;
        if (next == evRead.load(std::memory_order_acquire)) return;
        events[w] = {note, vel, on};
        evWrite.store(next, std::memory_order_release);
    }

    // ── Voices (audio thread only) ──
    struct Voice {
        int note = -1;
        bool gate = false;
        float vel = 0.0f;
        double phase = 0.0, phase2 = 0.0;
        float fmFb = 0.0f;
        float saw[7] = {};
        float env = 0.0f;
        int stage = 0;
        float pitch = 60.0f, target = 60.0f;
        float det = 0.0f;          // per-voice fixed analog detune (cents-ish)
        float driftPhase = 0.0f;   // slow per-voice pitch wobble
        uint32_t age = 0;
        uint32_t rng = 1;
    };
    Voice voices[kVoices];
    uint32_t clock_ = 1;
    float lastPitch = 60.0f;

    static constexpr int kHeldMax = 16;
    int held[kHeldMax] = {};
    float heldVel[kHeldMax] = {};
    int heldCount = 0;
    int physCount = 0;

    // Arp state
    float arpPhase = 1.0f;
    int arpIdx = -1;
    int arpDirDown = 0;
    int arpPlaying = -1;
    bool arpWasOn = false;
    uint32_t arpRng = 99991;
    float arpDurMult = 1.0f;
    int arpStepCount = 0;
    int pattern[16] = {};
    uint32_t diceSeen = 0;

    // Filter (stereo TPT SVF) + envelopes + LFO
    float svf1L = 0.0f, svf2L = 0.0f, svf1R = 0.0f, svf2R = 0.0f;
    float fenv = 0.0f;
    int fstage = 0;
    float cyc = 0.0f, cycPhase = 0.0f;
    int cycStage = 0;
    float cycHoldCtr = 0.0f;
    float cycFallFrom = 1.0f;
    float lfoPhase = 0.0f, lfoSH = 0.0f;
    uint32_t lfoRng = 77777;
    float lastVel = 0.0f, lastKey = 0.0f;
    int tailSamps = 0;             // keep fx tails alive after voices stop

    // ── Ensemble chorus (stereo, dual-tap modulated delay) ──
    static constexpr int kChBuf = 4096;
    float chBufL[kChBuf] = {}, chBufR[kChBuf] = {};
    int chPos = 0;
    float chPhase = 0.0f;

    // ── "Space": Schroeder plate (4 combs + 2 allpasses per channel) ──
    static constexpr int kCombs = 4;
    static constexpr int kCombMax = 2400;
    float combL[kCombs][kCombMax] = {}, combR[kCombs][kCombMax] = {};
    float combLpL[kCombs] = {}, combLpR[kCombs] = {};
    int combPos[kCombs] = {};
    static constexpr int kApMax = 640;
    float apL1[kApMax] = {}, apL2[kApMax] = {}, apR1[kApMax] = {}, apR2[kApMax] = {};
    int apPos = 0;

    static float clamp01f(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }
    static float clampB(float v) { return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v); }

    static float polyblep(float t, float dt) {
        if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
        if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
        return 0.0f;
    }

    static float frand(uint32_t& s) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        return (float)(int32_t)s * (1.0f / 2147483648.0f);
    }
    static float frand01(uint32_t& s) { return frand(s) * 0.5f + 0.5f; }

    bool anySounding() const {
        for (int v = 0; v < kVoices; ++v) if (voices[v].stage != 0) return true;
        return false;
    }
    bool anyGate() const {
        for (int v = 0; v < kVoices; ++v) if (voices[v].gate) return true;
        return false;
    }

    void allNotesOff() {
        for (int v = 0; v < kVoices; ++v) {
            if (voices[v].stage != 0 && voices[v].stage != 4) voices[v].stage = 4;
            voices[v].gate = false;
        }
        heldCount = 0;
        physCount = 0;
        arpPlaying = -1;
        arpIdx = -1;
        fstage = 4;
    }

    void voiceOn(int note, float vel01, bool mono) {
        int pick = -1;
        if (mono) {
            pick = 0;
            for (int v = 1; v < kVoices; ++v)
                if (voices[v].stage != 0 && voices[v].stage != 4) { voices[v].stage = 4; voices[v].gate = false; }
        } else {
            for (int v = 0; v < kVoices; ++v) if (voices[v].note == note && voices[v].gate) { pick = v; break; }
            if (pick < 0) for (int v = 0; v < kVoices; ++v) if (voices[v].stage == 0) { pick = v; break; }
            if (pick < 0) {
                uint32_t oldest = UINT32_MAX;
                for (int v = 0; v < kVoices; ++v) if (voices[v].age < oldest) { oldest = voices[v].age; pick = v; }
            }
        }
        Voice& vc = voices[pick];
        const bool fresh = (vc.stage == 0);
        const bool legato = mono && !fresh && vc.gate;
        vc.note = note;
        vc.gate = true;
        vc.vel = 0.25f + 0.75f * vel01;
        vc.target = (float)note;
        if (fresh) vc.pitch = (glide.load(std::memory_order_relaxed) > 0.001f) ? lastPitch : vc.target;
        if (!legato) vc.stage = 1;
        vc.age = clock_++;
        if (fresh) {
            // Random phase starts (no phasey "machine-gun" attacks) + analog detune.
            vc.rng = clock_ * 2654435761u + 12345u;
            vc.phase = frand01(vc.rng);
            vc.phase2 = frand01(vc.rng);
            for (int k = 0; k < 7; ++k) vc.saw[k] = frand01(vc.rng);
            vc.fmFb = 0.0f;
            vc.det = frand(vc.rng) * 0.0009f;            // ±~1.5 cents
            vc.driftPhase = frand01(vc.rng) * 6.28318f;
        }
        lastPitch = vc.target;
        lastVel = vel01;
        lastKey = clampB(((float)note - 60.0f) / 30.0f);
        if (!legato) fstage = 1;
        const int cm = cycMode.load(std::memory_order_relaxed);
        if (cm == 0 || cm == 2) { cycStage = 1; cycPhase = 0.0f; cyc = 0.0f; }
    }

    void voiceOff(int note) {
        for (int v = 0; v < kVoices; ++v) {
            if (voices[v].note == note && voices[v].gate) { voices[v].gate = false; voices[v].stage = 4; }
        }
        if (!anyGate()) {
            fstage = 4;
            if (cycMode.load(std::memory_order_relaxed) == 0 &&
                cycStage != 0 && cycStage != 3) {
                cycStage = 3;
                cycPhase = 1.0f;
            }
        }
    }

    void heldAdd(int note, float vel01) {
        for (int i = 0; i < heldCount; ++i) if (held[i] == note) { heldVel[i] = vel01; return; }
        if (heldCount < kHeldMax) { held[heldCount] = note; heldVel[heldCount] = vel01; heldCount++; }
    }
    void heldRemove(int note) {
        for (int i = 0; i < heldCount; ++i) {
            if (held[i] == note) {
                for (int j = i; j < heldCount - 1; ++j) { held[j] = held[j + 1]; heldVel[j] = heldVel[j + 1]; }
                heldCount--;
                return;
            }
        }
    }

    void handleEvent(const NoteEvent& ev) {
        const bool mono = monoMode.load(std::memory_order_relaxed);
        const bool arpOn = arpMode.load(std::memory_order_relaxed) > 0;
        const bool hold = arpHold.load(std::memory_order_relaxed);
        const float vel01 = ev.vel / 127.0f;
        if (ev.on) {
            if (hold && physCount == 0) heldCount = 0;
            physCount++;
            heldAdd(ev.note, vel01);
            if (!arpOn) voiceOn(ev.note, vel01, mono);
        } else {
            if (physCount > 0) physCount--;
            if (!hold) heldRemove(ev.note);
            if (!arpOn) {
                voiceOff(ev.note);
                if (mono && heldCount > 0) {
                    voiceOn(held[heldCount - 1], heldVel[heldCount - 1], true);
                }
            }
        }
    }

    // ── Render `n` frames ADDITIVELY into L/R (audio thread) ──
    void render(float* L, float* R, int n, float bpm) {
        while (true) {
            const int r = evRead.load(std::memory_order_relaxed);
            if (r == evWrite.load(std::memory_order_acquire)) break;
            const NoteEvent ev = events[r];
            evRead.store((r + 1) % kEvCap, std::memory_order_release);
            handleEvent(ev);
        }

        // ── Per-block parameter snapshot ──
        const bool mono = monoMode.load(std::memory_order_relaxed);
        const int type = oscType.load(std::memory_order_relaxed);
        const float wav0 = clamp01f(wave.load(std::memory_order_relaxed));
        const float tim0 = clamp01f(timbre.load(std::memory_order_relaxed));
        const float shp0 = clamp01f(shape.load(std::memory_order_relaxed));
        const float gld = clamp01f(glide.load(std::memory_order_relaxed));
        const float glideCoef = (gld > 0.001f)
            ? 1.0f - std::exp(-1.0f / ((0.02f + gld * 0.6f) * kSR)) : 1.0f;

        const float aT = 0.0015f + attack.load(std::memory_order_relaxed) * attack.load(std::memory_order_relaxed) * 3.0f;
        const float dT = 0.01f + decay.load(std::memory_order_relaxed) * decay.load(std::memory_order_relaxed) * 5.0f;
        const float sus = clamp01f(sustain.load(std::memory_order_relaxed));
        const float rT = 0.01f + release.load(std::memory_order_relaxed) * release.load(std::memory_order_relaxed) * 5.0f;
        const float aInc = 1.0f / (aT * kSR);
        const float dCoef = 1.0f - std::exp(-1.0f / (dT * kSR));
        const float rCoef = 1.0f - std::exp(-1.0f / (rT * kSR));

        const int ftype = filterType.load(std::memory_order_relaxed);
        const float cutBase = clamp01f(cutoff.load(std::memory_order_relaxed));
        const float reso = clamp01f(resonance.load(std::memory_order_relaxed));
        const float kDamp = 2.0f - reso * 1.92f;   // TPT: k = 2/Q
        const float fAmt = (clamp01f(envFilter.load(std::memory_order_relaxed)) - 0.5f) * 2.0f;

        const float beatHz = (bpm < 40.0f ? 120.0f : bpm) / 60.0f;
        const int lshape = lfoShape.load(std::memory_order_relaxed);
        float lrateHz;
        if (lfoSync.load(std::memory_order_relaxed)) {
            static const float mult[6] = {0.25f, 0.5f, 1.0f, 2.0f, 4.0f, 8.0f};
            lrateHz = beatHz * mult[(int)(clamp01f(lfoRate.load(std::memory_order_relaxed)) * 5.99f)];
        } else {
            lrateHz = 0.05f * std::pow(600.0f, clamp01f(lfoRate.load(std::memory_order_relaxed)));
        }
        const float lInc = lrateHz / kSR;

        const int cm = cycMode.load(std::memory_order_relaxed);
        const float crT = 0.002f + cycRise.load(std::memory_order_relaxed) * cycRise.load(std::memory_order_relaxed) * 4.0f;
        const float cfT = 0.002f + cycFall.load(std::memory_order_relaxed) * cycFall.load(std::memory_order_relaxed) * 4.0f;
        const float chParam = clamp01f(cycHold.load(std::memory_order_relaxed));
        const float cRise = 1.0f / (crT * kSR);
        const float cFall = 1.0f / (cfT * kSR);
        const float cSusLevel = chParam;
        const float cHoldSamps = chParam * chParam * 2.0f * kSR;
        const float cSusCoef = 1.0f - std::exp(-1.0f / (0.02f * kSR));
        const float riseK = std::pow(4.0f, clamp01f(cycRiseShape.load(std::memory_order_relaxed)) * 2.0f - 1.0f);
        const float fallK = std::pow(4.0f, clamp01f(cycFallShape.load(std::memory_order_relaxed)) * 2.0f - 1.0f);
        const float cAmt = clamp01f(cycAmount.load(std::memory_order_relaxed));

        const int aMode = arpMode.load(std::memory_order_relaxed);
        const int aOct = arpOct.load(std::memory_order_relaxed);
        static const float divSteps[6] = {1.0f, 2.0f, 3.0f, 4.0f, 6.0f, 8.0f};
        const int aDiv = arpDiv.load(std::memory_order_relaxed);
        const float arpInc = beatHz * divSteps[(aDiv < 0 ? 0 : (aDiv > 5 ? 5 : aDiv))] / kSR;
        const float swing = clamp01f(arpSwing.load(std::memory_order_relaxed));
        const float gateLen = 0.08f + clamp01f(arpGate.load(std::memory_order_relaxed)) * 0.87f;
        const float spice = clamp01f(arpSpice.load(std::memory_order_relaxed));

        {
            const uint32_t seed = diceSeed.load(std::memory_order_relaxed);
            if (seed != diceSeen) {
                diceSeen = seed;
                uint32_t rs = seed | 1;
                for (int k = 0; k < 16; ++k) {
                    const float r = frand01(rs);
                    pattern[k] = (r < 0.18f) ? -1 : (int)(frand01(rs) * 31.0f);
                }
            }
        }

        const float chorusAmt = clamp01f(chorus.load(std::memory_order_relaxed));
        const float spaceAmt = clamp01f(space.load(std::memory_order_relaxed));
        const float revFb = 0.74f + spaceAmt * 0.16f;
        const float revMix = spaceAmt * spaceAmt * 0.85f;
        const float vol = clamp01f(volume.load(std::memory_order_relaxed));
        const float outGain = vol * vol * 1.1f;

        float m[25];
        for (int i = 0; i < 25; ++i) m[i] = matrix[i].load(std::memory_order_relaxed);
        bool mAny = false;
        for (int i = 0; i < 25; ++i) if (m[i] < -0.001f || m[i] > 0.001f) { mAny = true; break; }

        const bool arpOn = aMode > 0;
        if (arpOn && !arpWasOn) { arpPhase = 1.0f; arpIdx = -1; arpDirDown = 0; }
        if (!arpOn && arpWasOn && arpPlaying >= 0) { voiceOff(arpPlaying); arpPlaying = -1; }
        arpWasOn = arpOn;
        if (arpOn && heldCount == 0 && arpPlaying >= 0) { voiceOff(arpPlaying); arpPlaying = -1; }

        // Keep running through chorus/reverb tails, then sleep.
        const bool activity = anySounding() || (arpOn && heldCount > 0) || cycStage != 0 || cm == 1;
        if (activity) tailSamps = (int)(kSR * 3.5f);
        if (!activity && tailSamps <= 0) return;
        if (!activity) tailSamps -= n;

        static const float fmRatios[8] = {0.5f, 1.0f, 1.5f, 2.0f, 2.5f, 3.0f, 4.0f, 6.0f};
        static const float ssDet[7] = {0.0f, -0.11002f, 0.11002f, -0.06288f, 0.06288f, -0.01952f, 0.01952f};
        // Subtle per-voice pan spread (equal-power-ish).
        static const float panL[kVoices] = {0.74f, 0.62f, 0.83f, 0.55f, 0.88f, 0.68f};
        static const float panR[kVoices] = {0.68f, 0.80f, 0.56f, 0.86f, 0.52f, 0.74f};
        // Comb/allpass tunings (samples) — mutually prime, slightly offset L/R.
        static const int combLenL[kCombs] = {1687, 1801, 2053, 2251};
        static const int combLenR[kCombs] = {1711, 1823, 2069, 2273};
        static const int apLen1 = 389, apLen2 = 521;
        constexpr float kTwoPi = 6.28318530718f;

        for (int i = 0; i < n; ++i) {
            // ── Arp clock ──
            if (arpOn && heldCount > 0) {
                arpPhase += arpInc / arpDurMult;
                if (arpPhase >= 1.0f) {
                    arpPhase -= 1.0f;
                    if (arpPlaying >= 0) { voiceOff(arpPlaying); arpPlaying = -1; }
                    arpStepCount++;
                    arpDurMult = (arpStepCount & 1) ? (1.0f - swing * 0.42f)
                                                    : (1.0f + swing * 0.42f);
                    int pool[kHeldMax];
                    float poolVel[kHeldMax];
                    for (int k = 0; k < heldCount; ++k) { pool[k] = held[k]; poolVel[k] = heldVel[k]; }
                    if (aMode == 1 || aMode == 2 || aMode == 3) {
                        for (int a = 1; a < heldCount; ++a) {
                            int nv = pool[a]; float vv = poolVel[a]; int b = a - 1;
                            while (b >= 0 && pool[b] > nv) { pool[b+1] = pool[b]; poolVel[b+1] = poolVel[b]; b--; }
                            pool[b+1] = nv; poolVel[b+1] = vv;
                        }
                    }
                    const int span = heldCount * aOct;
                    int step;
                    bool rest = false;
                    if (aMode == 6) {
                        arpIdx = (arpIdx + 1) % 16;
                        const int p = pattern[arpIdx];
                        if (p < 0) rest = true;
                        step = (p < 0 ? 0 : p) % span;
                    } else if (aMode == 4) {
                        step = (int)(frand01(arpRng) * (span - 0.01f));
                    } else if (aMode == 3 && span > 1) {
                        arpIdx += arpDirDown ? -1 : 1;
                        if (arpIdx >= span - 1) { arpIdx = span - 1; arpDirDown = 1; }
                        else if (arpIdx <= 0) { arpIdx = 0; arpDirDown = 0; }
                        step = arpIdx;
                    } else {
                        arpIdx = (arpIdx + 1) % span;
                        step = (aMode == 2) ? (span - 1 - arpIdx) : arpIdx;
                    }
                    float velScale = 1.0f;
                    int octJump = 0;
                    if (spice > 0.001f && !rest) {
                        const float r = frand01(arpRng);
                        if (r < spice * 0.30f) rest = true;
                        else if (r < spice * 0.55f) octJump = 12;
                        velScale = 1.0f - spice * 0.55f * frand01(arpRng);
                    }
                    if (!rest) {
                        const int nIdx = step % heldCount;
                        const int oIdx = step / heldCount;
                        int note = pool[nIdx] + 12 * oIdx + octJump;
                        if (note > 127) note -= 12 * ((note - 127) / 12 + 1);
                        voiceOn(note, clamp01f(poolVel[nIdx] * velScale), mono);
                        arpPlaying = note;
                    }
                } else if (arpPhase > gateLen && arpPlaying >= 0) {
                    voiceOff(arpPlaying);
                    arpPlaying = -1;
                }
            }

            // ── LFO ──
            lfoPhase += lInc;
            if (lfoPhase >= 1.0f) { lfoPhase -= 1.0f; lfoSH = frand(lfoRng); }
            float lfo;
            switch (lshape) {
                case 1: lfo = 4.0f * std::fabs(lfoPhase - 0.5f) - 1.0f; break;
                case 2: lfo = 2.0f * lfoPhase - 1.0f; break;
                case 3: lfo = lfoPhase < 0.5f ? 1.0f : -1.0f; break;
                case 4: lfo = lfoSH; break;
                default: lfo = std::sin(kTwoPi * lfoPhase); break;
            }

            // ── Cycling envelope ──
            if (cycStage == 1) {
                cycPhase += cRise;
                if (cycPhase >= 1.0f) { cycPhase = 1.0f; cyc = 1.0f; cycStage = 2; cycHoldCtr = 0.0f; }
                else cyc = std::pow(cycPhase, riseK);
            } else if (cycStage == 2) {
                if (cm == 0) {
                    cyc += (cSusLevel - cyc) * cSusCoef;
                } else {
                    cyc = 1.0f;
                    cycHoldCtr += 1.0f;
                    if (cycHoldCtr >= cHoldSamps) { cycStage = 3; cycPhase = 1.0f; cycFallFrom = 1.0f; }
                }
            } else if (cycStage == 3) {
                if (cycPhase >= 1.0f) cycFallFrom = (cyc > 0.0001f ? cyc : cycFallFrom);
                cycPhase -= cFall;
                if (cycPhase <= 0.0f) {
                    cycPhase = 0.0f;
                    cyc = 0.0f;
                    if (cm == 1) cycStage = 1;
                    else if (cm == 2 && anyGate()) cycStage = 1;
                    else cycStage = 0;
                } else {
                    cyc = cycFallFrom * std::pow(cycPhase, fallK);
                }
            } else if (cm == 1 && cycStage == 0) {
                cycStage = 1;
                cycPhase = 0.0f;
            }

            // ── Mono filter envelope ──
            if (fstage == 1) { fenv += aInc; if (fenv >= 1.0f) { fenv = 1.0f; fstage = 2; } }
            else if (fstage == 2) { fenv += (sus - fenv) * dCoef; }
            else if (fstage == 4) { fenv += (0.0f - fenv) * rCoef; if (fenv < 0.0005f) { fenv = 0.0f; fstage = 0; } }

            // ── Mod matrix ──
            float dPitch = 0.0f, dWave = 0.0f, dTim = 0.0f, dShp = 0.0f, dCut = 0.0f;
            if (mAny) {
                const float src[5] = {cyc * cAmt, fenv, lfo, lastVel, lastKey};
                for (int s = 0; s < 5; ++s) {
                    const float sv = src[s];
                    if (sv > -0.0001f && sv < 0.0001f) continue;
                    const float* row = &m[s * 5];
                    dPitch += row[0] * sv;
                    dWave  += row[1] * sv;
                    dTim   += row[2] * sv;
                    dShp   += row[3] * sv;
                    dCut   += row[4] * sv;
                }
            }
            const float wav = clamp01f(wav0 + dWave);
            const float tim = clamp01f(tim0 + dTim);
            const float shp = clamp01f(shp0 + dShp);
            const float pitchMod = dPitch * 12.0f;

            // ── Voices (stereo) ──
            float mixL = 0.0f, mixR = 0.0f;
            for (int v = 0; v < kVoices; ++v) {
                Voice& vc = voices[v];
                if (vc.stage == 0) continue;

                if (vc.stage == 1) { vc.env += aInc; if (vc.env >= 1.0f) { vc.env = 1.0f; vc.stage = 2; } }
                else if (vc.stage == 2) { vc.env += (sus - vc.env) * dCoef; if (std::fabs(vc.env - sus) < 0.001f) vc.stage = 3; }
                else if (vc.stage == 4) { vc.env += (0.0f - vc.env) * rCoef;
                    if (vc.env < 0.0005f) { vc.env = 0.0f; vc.stage = 0; vc.note = -1; continue; } }

                // Pitch: glide + matrix + analog drift (fixed offset + slow wobble).
                vc.pitch += (vc.target - vc.pitch) * glideCoef;
                vc.driftPhase += 0.9f / kSR;
                if (vc.driftPhase > kTwoPi) vc.driftPhase -= kTwoPi;
                const float drift = vc.det + 0.0006f * std::sin(vc.driftPhase + (float)v * 1.7f);
                const float midi = vc.pitch + pitchMod;
                const float freq = 440.0f * std::pow(2.0f, (midi - 69.0f) / 12.0f) * (1.0f + drift);
                const float inc = freq / kSR;
                if (inc >= 0.5f) continue;

                float sL = 0.0f, sR = 0.0f;
                switch (type) {
                    case 0: { // analog: saw↔pulse + sub square
                        const float t = (float)vc.phase;
                        const float saw = 2.0f * t - 1.0f - polyblep(t, inc);
                        const float pw = 0.15f + shp * 0.7f;
                        float t2 = t + pw; if (t2 >= 1.0f) t2 -= 1.0f;
                        const float sq = (t < pw ? 1.0f : -1.0f) + polyblep(t, inc) - polyblep(t2, inc);
                        float s = saw * (1.0f - tim) + sq * tim;
                        const float st = (float)vc.phase2;
                        s += ((st < 0.5f ? 1.0f : -1.0f) + polyblep(st, inc * 0.5f)) * wav * 0.8f;
                        sL = sR = s;
                        vc.phase += inc; if (vc.phase >= 1.0) vc.phase -= 1.0;
                        vc.phase2 += inc * 0.5f; if (vc.phase2 >= 1.0) vc.phase2 -= 1.0;
                        break;
                    }
                    case 1: { // supersaw: JP detune curve, sides spread hard L/R
                        const int unison = 1 + (int)(wav * 6.0f);
                        const float spread = tim;
                        const float side = 0.2f + shp * 0.8f;
                        for (int k = 0; k < unison; ++k) {
                            const float di = inc * (1.0f + ssDet[k] * spread * 0.5f);
                            vc.saw[k] += di; if (vc.saw[k] >= 1.0f) vc.saw[k] -= 1.0f;
                            const float t = vc.saw[k];
                            const float sv = 2.0f * t - 1.0f - polyblep(t, di);
                            if (k == 0) { sL += sv; sR += sv; }
                            else if (k & 1) { sL += sv * side; sR += sv * side * 0.36f; }
                            else { sR += sv * side; sL += sv * side * 0.36f; }
                        }
                        const float norm = 1.45f / (1.0f + unison * 0.55f);
                        sL *= norm; sR *= norm;
                        break;
                    }
                    case 2: { // wavetable: morph + fold + phase bend
                        float t = (float)vc.phase;
                        if (shp > 0.01f) {
                            const float bend = 0.5f - shp * 0.35f;
                            t = (t < bend) ? t * (0.5f / bend)
                                           : 0.5f + (t - bend) * (0.5f / (1.0f - bend));
                        }
                        const float pos = wav * 3.0f;
                        const int seg = (int)pos;
                        const float fr = pos - seg;
                        const float w0 = std::sin(kTwoPi * t);
                        const float w1 = 4.0f * std::fabs(t - 0.5f) - 1.0f;
                        const float w2 = 2.0f * t - 1.0f;
                        const float w3 = t < 0.5f ? 1.0f : -1.0f;
                        float a, b;
                        if (seg == 0)      { a = w0; b = w1; }
                        else if (seg == 1) { a = w1; b = w2; }
                        else               { a = w2; b = w3; }
                        float s = a * (1.0f - fr) + b * fr;
                        s = std::sin(s * (1.5707963f + tim * 7.0f));
                        sL = sR = s;
                        vc.phase += inc; if (vc.phase >= 1.0) vc.phase -= 1.0;
                        break;
                    }
                    case 3: { // fm
                        const float ratio = fmRatios[(int)(wav * 7.99f)];
                        const float index = tim * 7.0f;
                        const float fb = shp * 1.4f;
                        const float modOsc = std::sin(kTwoPi * (float)vc.phase2 + vc.fmFb * fb);
                        vc.fmFb = modOsc;
                        const float s = std::sin(kTwoPi * (float)vc.phase + index * modOsc);
                        sL = sR = s;
                        vc.phase += inc;  if (vc.phase >= 1.0) vc.phase -= 1.0;
                        vc.phase2 += inc * ratio; if (vc.phase2 >= 1.0) vc.phase2 -= 1.0;
                        break;
                    }
                    default: { // harmonic
                        const int parts = 1 + (int)(wav * 7.0f);
                        const float roll = 1.0f + (1.0f - tim) * 2.2f;
                        const float evenG = clamp01f(shp * 2.0f);
                        const float oddG = clamp01f(2.0f - shp * 2.0f);
                        const float t = (float)vc.phase;
                        float s = 0.0f, norm = 0.0f;
                        for (int h = 1; h <= parts; ++h) {
                            if (inc * h >= 0.5f) break;
                            const float g = std::pow(1.0f / h, roll) * ((h & 1) ? oddG : evenG);
                            s += std::sin(kTwoPi * t * h) * g;
                            norm += g;
                        }
                        if (norm > 0.0f) s /= norm;
                        sL = sR = s;
                        vc.phase += inc; if (vc.phase >= 1.0) vc.phase -= 1.0;
                        break;
                    }
                }
                const float g = vc.env * vc.vel;
                mixL += sL * g * panL[v];
                mixR += sR * g * panR[v];
            }

            mixL *= 0.24f;
            mixR *= 0.24f;

            // ── Stereo TPT SVF (Zavalishin) — opens to Nyquist, musical Q ──
            // Velocity adds a touch of brightness so dynamics read on stage.
            const float cut = clamp01f(cutBase + fAmt * fenv * 0.8f + dCut + lastVel * 0.06f);
            const float fHz = 30.0f * std::pow(600.0f, cut);     // 30 Hz → 18 kHz
            float gT = std::tan(3.14159265f * (fHz > 20500.0f ? 20500.0f : fHz) / kSR);
            if (gT > 18.0f) gT = 18.0f;
            const float a1c = 1.0f / (1.0f + gT * (gT + kDamp));
            const float a2c = gT * a1c;
            const float a3c = gT * a2c;
            float outL, outR;
            {
                const float v3 = mixL - svf2L;
                const float v1 = a1c * svf1L + a2c * v3;
                const float v2 = svf2L + a2c * svf1L + a3c * v3;
                svf1L = 2.0f * v1 - svf1L;
                svf2L = 2.0f * v2 - svf2L;
                outL = (ftype == 1) ? v1 : (ftype == 2) ? (mixL - kDamp * v1 - v2) : v2;
            }
            {
                const float v3 = mixR - svf2R;
                const float v1 = a1c * svf1R + a2c * v3;
                const float v2 = svf2R + a2c * svf1R + a3c * v3;
                svf1R = 2.0f * v1 - svf1R;
                svf2R = 2.0f * v2 - svf2R;
                outR = (ftype == 1) ? v1 : (ftype == 2) ? (mixR - kDamp * v1 - v2) : v2;
            }

            // ── Ensemble chorus (quadrature stereo taps) ──
            if (chorusAmt > 0.005f) {
                chBufL[chPos] = outL;
                chBufR[chPos] = outR;
                chPhase += 0.55f / kSR;
                if (chPhase >= 1.0f) chPhase -= 1.0f;
                const float mL = std::sin(kTwoPi * chPhase);
                const float mR = std::sin(kTwoPi * chPhase + 1.5707963f);
                const float dL = 14.0f * 48.0f * 0.001f * 1000.0f / 1000.0f;   // base ~672 smp
                const float tapL = 672.0f + 240.0f * mL;
                const float tapR = 672.0f + 240.0f * mR;
                auto rd = [&](const float* buf, float tap) {
                    float p = (float)chPos - tap;
                    if (p < 0.0f) p += kChBuf;
                    const int i0 = (int)p;
                    const float fr = p - i0;
                    const int i1 = (i0 + 1) % kChBuf;
                    return buf[i0] * (1.0f - fr) + buf[i1] * fr;
                };
                (void)dL;
                const float wetL = rd(chBufL, tapL);
                const float wetR = rd(chBufR, tapR);
                chPos = (chPos + 1) % kChBuf;
                outL = outL * (1.0f - chorusAmt * 0.35f) + wetL * chorusAmt * 0.85f;
                outR = outR * (1.0f - chorusAmt * 0.35f) + wetR * chorusAmt * 0.85f;
            }

            // ── Space: Schroeder plate ──
            if (revMix > 0.002f) {
                const float inMono = (outL + outR) * 0.35f;
                float wetL = 0.0f, wetR = 0.0f;
                for (int c = 0; c < kCombs; ++c) {
                    const int pL = combPos[c] % combLenL[c];
                    const int pR = combPos[c] % combLenR[c];
                    const float yL = combL[c][pL];
                    const float yR = combR[c][pR];
                    combLpL[c] += (yL - combLpL[c]) * 0.42f;     // damping
                    combLpR[c] += (yR - combLpR[c]) * 0.42f;
                    combL[c][pL] = inMono + combLpL[c] * revFb;
                    combR[c][pR] = inMono + combLpR[c] * revFb;
                    wetL += yL;
                    wetR += yR;
                    combPos[c]++;
                }
                // Two series allpasses per channel for diffusion.
                auto ap = [&](float* buf, int len, float x) {
                    const int p = apPos % len;
                    const float b = buf[p];
                    const float y = -x + b;
                    buf[p] = x + b * 0.5f;
                    return y;
                };
                wetL = ap(apL2, apLen2, ap(apL1, apLen1, wetL * 0.25f));
                wetR = ap(apR2, apLen2, ap(apR1, apLen1, wetR * 0.25f));
                apPos++;
                outL += wetL * revMix;
                outR += wetR * revMix;
            }

            // ── Output: gentle saturation + volume taper ──
            L[i] += std::tanh(outL * 1.4f) * outGain;
            R[i] += std::tanh(outR * 1.4f) * outGain;
        }
    }
};
