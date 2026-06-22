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

// JamModular — a West-Coast semi-modular voice ("FLOW MODULAR"), modelled
// after the Korg volca modular for live patch-and-play improvisation.
//
// Signal flow (normalled, like the hardware, then re-routable via the matrix):
//   VCO (+ sub) → WAVE FOLDER → LOW-PASS GATE → SPACE (reverb) → OUTPUT
// with two FUNCTION GENERATORS (rise/fall slopes, once or looping) and a
// RANDOM SOURCE (smooth / stepped / s&h / burst) as modulation, plus a
// motion step sequencer that drives notes and per-step triggers.
//
// The LPG is the heart of the West-Coast sound: a vactrol-style gate where
// amplitude and brightness open together, struck by a fast-attack / decaying
// envelope — giving the signature plucky "bongo" voice with no patching.
//
// Realtime-safe: params are atomics, notes arrive via a lock-free SPSC queue,
// all voice / modulator / fx state is audio-thread-only.

#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <utility>

struct JamModular {
    static constexpr float kSR = 48000.0f;
    static constexpr int kVoices = 4;

    // Matrix dimensions (UI mirrors these).
    static constexpr int kSrc = 7;   // FUNC1 FUNC2 RND1 RND2 VELO KEY GATE
    static constexpr int kDst = 8;   // PITCH WAVE FOLD CUT LEVEL FN1RATE RNDRATE SIZE
    static constexpr int kSteps = 16;

    // ── Parameters (UI thread → audio thread; 0..1 unless noted) ──
    std::atomic<bool>  active{false};
    std::atomic<int>   voiceMode{0};       // 0 mono · 1 duo · 2 poly
    std::atomic<float> glide{0.0f};

    // VCO 1
    std::atomic<int>   vcoWaveSel{0};      // 0 sine · 1 tri · 2 saw
    std::atomic<float> vcoPitch{0.5f};     // bipolar ±24 semis (0.5 = 0)
    std::atomic<float> vcoWave{0.3f};      // harmonic morph
    std::atomic<float> vcoScale{0.5f};     // fine / sub blend
    std::atomic<float> vcoFold{0.0f};      // VCO-internal fold

    // Wave folder
    std::atomic<float> foldAmt{0.25f};
    std::atomic<float> foldBias{0.5f};     // bipolar (0.5 = 0)

    // Function generators
    std::atomic<float> fn1Rise{0.15f}, fn1Fall{0.45f}, fn1Shape{0.5f};
    std::atomic<int>   fn1Cycle{0};        // 0 once · 1 loop
    std::atomic<float> fn2Rise{0.3f}, fn2Fall{0.5f}, fn2Shape{0.5f};
    std::atomic<int>   fn2Cycle{1};

    // Random source
    std::atomic<int>   rndMode{0};         // 0 smooth · 1 stepped · 2 s&h · 3 burst
    std::atomic<float> rndRate{0.4f}, rndProb{0.7f};

    // Low-pass gate
    std::atomic<float> lpgCutoff{0.55f}, lpgReso{0.15f}, lpgDecay{0.4f}, lpgDrive{0.3f};

    // Space (reverb)
    std::atomic<int>   spaceType{1};       // spring · plate · hall · cloud · infinite
    std::atomic<float> spaceSize{0.4f};

    // Output
    std::atomic<float> outVol{0.7f}, outWidth{0.6f};

    // Patch matrix: [src*kDst + dst], bipolar depth -1..1.
    std::atomic<float> patch[kSrc * kDst] = {};

    // ── Motion step sequencer ──
    std::atomic<bool>  seqRun{false};
    std::atomic<int>   seqDiv{3};          // 1/4 1/8 1/8T 1/16 1/16T 1/32
    std::atomic<int>   seqLen{16};
    std::atomic<int>   seqScale{1};        // 0 major · 1 minor · 2 dorian · 3 penta · 4 chromatic
    std::atomic<int>   seqOctave{0};       // -2..+2
    std::atomic<float> seqSwing{0.0f};
    std::atomic<int>   stepNote[kSteps] = {};   // scale degree offset 0..7
    std::atomic<bool>  stepGate[kSteps] = {};
    std::atomic<bool>  laneFn1[kSteps] = {};
    std::atomic<bool>  laneFn2[kSteps] = {};
    std::atomic<bool>  laneLpg[kSteps] = {};    // accent (harder strike)
    std::atomic<bool>  laneSpace[kSteps] = {};  // momentary reverb send
    std::atomic<int>   seqStepUi{0};            // → UI: current step
    std::atomic<uint32_t> diceSeed{0};

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
        double phase = 0.0, sub = 0.0;
        float pitch = 48.0f, target = 48.0f;
        float strike = 0.0f;        // LPG control envelope 0..1
        int   stStage = 0;          // 0 idle · 1 strike-rise · 2 decay
        float lp1 = 0.0f, lp2 = 0.0f;  // LPG 2-pole state
        uint32_t age = 0;
        uint32_t rng = 1;
    };
    Voice voices[kVoices];
    uint32_t clock_ = 1;
    float lastPitch = 48.0f;
    float lastVel = 0.7f, lastKey = 0.0f;

    static constexpr int kHeldMax = 16;
    int held[kHeldMax] = {};
    float heldVel[kHeldMax] = {};
    int heldCount = 0;

    // Modulator state (global, audio thread)
    struct Func { int stage = 0; float lvl = 0.0f; float eoc = 0.0f; };
    Func fn1, fn2;
    bool gateWas = false;
    float rndV1 = 0.0f, rndTarget = 0.0f, rndV2 = 0.0f;
    float rndPhase = 1.0f;
    uint32_t rndRng = 2463534242u;
    int rndBurst = 0;

    // Sequencer state
    float seqPhase = 1.0f;
    int seqStep = -1;
    int seqStepCount = 0;
    float seqDurMult = 1.0f;
    float seqAccent = 0.0f;     // decays after a LPG-lane step
    float seqSpaceBoost = 0.0f; // decays after a SPACE-lane step
    uint32_t diceSeen = 0;
    int tailSamps = 0;

    // ── Space: Schroeder plate (shared topology with JamSynth) ──
    static constexpr int kCombs = 4;
    static constexpr int kCombMax = 2400;
    float combL[kCombs][kCombMax] = {}, combR[kCombs][kCombMax] = {};
    float combLpL[kCombs] = {}, combLpR[kCombs] = {};
    int combPos[kCombs] = {};
    static constexpr int kApMax = 640;
    float apL1[kApMax] = {}, apL2[kApMax] = {}, apR1[kApMax] = {}, apR2[kApMax] = {};
    int apPos = 0;
    float springZ = 0.0f, springZ2 = 0.0f;   // spring "boing" allpass chain

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

    // West-coast reflective wavefolder: reflect x off the ±1 rails.
    static float fold(float x) {
        for (int i = 0; i < 6; ++i) {
            if (x > 1.0f) x = 2.0f - x;
            else if (x < -1.0f) x = -2.0f - x;
            else break;
        }
        return x;
    }

    bool anySounding() const {
        for (int v = 0; v < kVoices; ++v) if (voices[v].stStage != 0 || voices[v].strike > 0.0008f) return true;
        return false;
    }
    bool anyGate() const {
        for (int v = 0; v < kVoices; ++v) if (voices[v].gate) return true;
        return false;
    }

    int maxVoices() const {
        const int m = voiceMode.load(std::memory_order_relaxed);
        return m == 0 ? 1 : (m == 1 ? 2 : kVoices);
    }

    void allNotesOff() {
        for (int v = 0; v < kVoices; ++v) { voices[v].gate = false; }
        heldCount = 0;
    }

    void voiceOn(int note, float vel01) {
        const int mv = maxVoices();
        int pick = -1;
        if (mv == 1) {
            pick = 0;
            for (int v = 1; v < kVoices; ++v) voices[v].gate = false;
        } else {
            for (int v = 0; v < mv; ++v) if (voices[v].note == note && voices[v].gate) { pick = v; break; }
            if (pick < 0) for (int v = 0; v < mv; ++v) if (!voices[v].gate && voices[v].strike < 0.02f) { pick = v; break; }
            if (pick < 0) { uint32_t oldest = UINT32_MAX;
                for (int v = 0; v < mv; ++v) if (voices[v].age < oldest) { oldest = voices[v].age; pick = v; } }
        }
        Voice& vc = voices[pick];
        const bool fresh = (vc.strike < 0.02f && !vc.gate);
        vc.note = note;
        vc.gate = true;
        vc.vel = 0.25f + 0.75f * vel01;
        vc.target = (float)note;
        if (fresh) {
            vc.pitch = (glide.load(std::memory_order_relaxed) > 0.001f) ? lastPitch : vc.target;
            vc.rng = clock_ * 2654435761u + 12345u;
            vc.phase = frand01(vc.rng);
            vc.sub = frand01(vc.rng);
        }
        vc.stStage = 1;            // re-strike the LPG
        vc.age = clock_++;
        lastPitch = vc.target;
        lastVel = vel01;
        lastKey = clampB(((float)note - 48.0f) / 30.0f);
    }

    void voiceOff(int note) {
        for (int v = 0; v < kVoices; ++v)
            if (voices[v].note == note && voices[v].gate) voices[v].gate = false;
    }

    void heldAdd(int note, float vel01) {
        for (int i = 0; i < heldCount; ++i) if (held[i] == note) { heldVel[i] = vel01; return; }
        if (heldCount < kHeldMax) { held[heldCount] = note; heldVel[heldCount] = vel01; heldCount++; }
    }
    void heldRemove(int note) {
        for (int i = 0; i < heldCount; ++i) if (held[i] == note) {
            for (int j = i; j < heldCount - 1; ++j) { held[j] = held[j + 1]; heldVel[j] = heldVel[j + 1]; }
            heldCount--; return;
        }
    }

    void handleEvent(const NoteEvent& ev) {
        const float vel01 = ev.vel / 127.0f;
        if (ev.on) { heldAdd(ev.note, vel01); voiceOn(ev.note, vel01); }
        else {
            heldRemove(ev.note);
            voiceOff(ev.note);
            if (maxVoices() == 1 && heldCount > 0) voiceOn(held[heldCount - 1], heldVel[heldCount - 1]);
        }
    }

    // Map a scale degree (0..) onto a MIDI note above the root.
    static int scaleNote(int root, int degree, int scaleIdx, int octShift) {
        static const int major[7]    = {0, 2, 4, 5, 7, 9, 11};
        static const int minor[7]    = {0, 2, 3, 5, 7, 8, 10};
        static const int dorian[7]   = {0, 2, 3, 5, 7, 9, 10};
        static const int penta[5]    = {0, 3, 5, 7, 10};
        const int* tbl; int n;
        switch (scaleIdx) {
            case 0: tbl = major;  n = 7; break;
            case 2: tbl = dorian; n = 7; break;
            case 3: tbl = penta;  n = 5; break;
            case 4: { return root + degree + 12 * octShift; }   // chromatic
            default: tbl = minor; n = 7; break;
        }
        const int oct = degree / n;
        const int idx = degree % n;
        return root + tbl[idx] + 12 * oct + 12 * octShift;
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

        // Re-roll the sequencer from a dice seed.
        {
            const uint32_t seed = diceSeed.load(std::memory_order_relaxed);
            if (seed != diceSeen && seed != 0) {
                diceSeen = seed;
                uint32_t rs = seed | 1;
                for (int s = 0; s < kSteps; ++s) {
                    stepGate[s].store(frand01(rs) < 0.7f, std::memory_order_relaxed);
                    stepNote[s].store((int)(frand01(rs) * 7.99f), std::memory_order_relaxed);
                    laneFn1[s].store(frand01(rs) < 0.3f, std::memory_order_relaxed);
                    laneLpg[s].store(frand01(rs) < 0.35f, std::memory_order_relaxed);
                    laneSpace[s].store(frand01(rs) < 0.18f, std::memory_order_relaxed);
                }
            }
        }

        // ── Per-block parameter snapshot ──
        const int wsel = vcoWaveSel.load(std::memory_order_relaxed);
        const float vPitch = (vcoPitch.load(std::memory_order_relaxed) - 0.5f) * 48.0f;
        const float vWave = clamp01f(vcoWave.load(std::memory_order_relaxed));
        const float vScale = clamp01f(vcoScale.load(std::memory_order_relaxed));
        const float vFold = clamp01f(vcoFold.load(std::memory_order_relaxed));
        const float fAmt0 = clamp01f(foldAmt.load(std::memory_order_relaxed));
        const float fBias = (foldBias.load(std::memory_order_relaxed) - 0.5f) * 2.0f;

        const float gld = clamp01f(glide.load(std::memory_order_relaxed));
        const float glideCoef = (gld > 0.001f)
            ? 1.0f - std::exp(-1.0f / ((0.02f + gld * 0.6f) * kSR)) : 1.0f;

        const float cutBase = clamp01f(lpgCutoff.load(std::memory_order_relaxed));
        const float lpgQ = clamp01f(lpgReso.load(std::memory_order_relaxed));
        const float kDamp = 2.0f - lpgQ * 1.7f;
        const float decT = 0.03f + lpgDecay.load(std::memory_order_relaxed) *
                                   lpgDecay.load(std::memory_order_relaxed) * 2.5f;
        const float decCoef = 1.0f - std::exp(-1.0f / (decT * kSR));
        const float strikeInc = 1.0f / (0.0018f * kSR);
        const float drive = 1.0f + clamp01f(lpgDrive.load(std::memory_order_relaxed)) * 4.0f;

        const float beatHz = (bpm < 40.0f ? 120.0f : bpm) / 60.0f;

        // Function generator timings.
        auto fnTimes = [&](float rise, float fall) {
            return std::pair<float, float>(
                1.0f / ((0.0015f + rise * rise * 3.0f) * kSR),
                1.0f / ((0.0015f + fall * fall * 3.0f) * kSR));
        };
        const auto fn1T = fnTimes(clamp01f(fn1Rise.load(std::memory_order_relaxed)),
                                  clamp01f(fn1Fall.load(std::memory_order_relaxed)));
        const auto fn2T = fnTimes(clamp01f(fn2Rise.load(std::memory_order_relaxed)),
                                  clamp01f(fn2Fall.load(std::memory_order_relaxed)));
        const float fn1Sh = std::pow(4.0f, clamp01f(fn1Shape.load(std::memory_order_relaxed)) * 2.0f - 1.0f);
        const float fn2Sh = std::pow(4.0f, clamp01f(fn2Shape.load(std::memory_order_relaxed)) * 2.0f - 1.0f);
        const int fn1Loop = fn1Cycle.load(std::memory_order_relaxed);
        const int fn2Loop = fn2Cycle.load(std::memory_order_relaxed);

        // Random source.
        const int rmode = rndMode.load(std::memory_order_relaxed);
        const float rRateHz = 0.1f * std::pow(220.0f, clamp01f(rndRate.load(std::memory_order_relaxed)));
        const float rProb = clamp01f(rndProb.load(std::memory_order_relaxed));
        const float rndInc = rRateHz / kSR;
        const float rndSlew = 1.0f - std::exp(-1.0f / (0.004f / (0.001f + rRateHz / 40.0f) * kSR + 1.0f));

        // Space.
        const int spType = spaceType.load(std::memory_order_relaxed);
        const float spSize = clamp01f(spaceSize.load(std::memory_order_relaxed));
        const float revFb = 0.7f + spSize * 0.28f + (spType == 4 ? 0.02f : 0.0f);  // infinite
        const float revMix = (0.15f + spSize * 0.7f) * (spType == 0 ? 0.7f : 1.0f);
        const float damp = (spType == 2 ? 0.25f : spType == 3 ? 0.12f : 0.42f);

        const float vol = clamp01f(outVol.load(std::memory_order_relaxed));
        const float outGain = vol * vol * 1.25f;
        const float width = clamp01f(outWidth.load(std::memory_order_relaxed));

        // Matrix.
        float m[kSrc * kDst];
        bool mAny = false;
        for (int i = 0; i < kSrc * kDst; ++i) {
            m[i] = patch[i].load(std::memory_order_relaxed);
            if (m[i] < -0.001f || m[i] > 0.001f) mAny = true;
        }

        // Sequencer config.
        const bool seqOn = seqRun.load(std::memory_order_relaxed);
        static const float divSteps[6] = {1.0f, 2.0f, 3.0f, 4.0f, 6.0f, 8.0f};
        const int sd = seqDiv.load(std::memory_order_relaxed);
        const float seqInc = beatHz * divSteps[sd < 0 ? 0 : (sd > 5 ? 5 : sd)] / kSR;
        const int seqLenN = std::max(1, std::min(kSteps, seqLen.load(std::memory_order_relaxed)));
        const int sScale = seqScale.load(std::memory_order_relaxed);
        const int sOct = seqOctave.load(std::memory_order_relaxed);
        const float seqSw = clamp01f(seqSwing.load(std::memory_order_relaxed));
        const int seqRoot = (int)lastPitch <= 0 ? 48 : (int)lastPitch;

        // Keep fx tails alive a moment after the voice falls silent.
        const bool activity = anySounding() || seqOn || fn1Loop || fn2Loop ||
                              (rmode != 2 && false);
        if (activity) tailSamps = (int)(kSR * 4.0f);
        if (!activity && tailSamps <= 0) { return; }
        if (!activity) tailSamps -= n;

        static const int combLenL[kCombs] = {1687, 1801, 2053, 2251};
        static const int combLenR[kCombs] = {1711, 1823, 2069, 2273};
        static const int apLen1 = 389, apLen2 = 521;
        constexpr float kTwoPi = 6.28318530718f;

        const int mv = maxVoices();

        for (int i = 0; i < n; ++i) {
            // ── Sequencer clock ──
            int seqTrigNote = -1; float seqTrigVel = 0.9f;
            bool fireFn1 = false, fireFn2 = false;
            if (seqOn) {
                seqPhase += seqInc / seqDurMult;
                if (seqPhase >= 1.0f) {
                    seqPhase -= 1.0f;
                    seqStep = (seqStep + 1) % seqLenN;
                    seqStepUi.store(seqStep, std::memory_order_relaxed);
                    seqStepCount++;
                    seqDurMult = (seqStepCount & 1) ? (1.0f - seqSw * 0.42f) : (1.0f + seqSw * 0.42f);
                    if (stepGate[seqStep].load(std::memory_order_relaxed)) {
                        const int deg = stepNote[seqStep].load(std::memory_order_relaxed);
                        seqTrigNote = scaleNote(seqRoot, deg, sScale, sOct);
                        const bool acc = laneLpg[seqStep].load(std::memory_order_relaxed);
                        seqTrigVel = acc ? 1.0f : 0.8f;
                        if (acc) seqAccent = 1.0f;
                    }
                    if (laneFn1[seqStep].load(std::memory_order_relaxed)) fireFn1 = true;
                    if (laneFn2[seqStep].load(std::memory_order_relaxed)) fireFn2 = true;
                    if (laneSpace[seqStep].load(std::memory_order_relaxed)) seqSpaceBoost = 1.0f;
                }
            }
            if (seqTrigNote >= 0) {
                if (seqTrigNote > 127) seqTrigNote = 127;
                voiceOn(seqTrigNote, seqTrigVel);
            }
            seqAccent *= 0.9994f;
            seqSpaceBoost *= 0.9996f;

            // ── Gate (for funcs / matrix): any voice held, or a seq trigger ──
            const bool gateNow = anyGate() || seqTrigNote >= 0;
            const bool gateEdge = gateNow && !gateWas;
            gateWas = gateNow;

            // ── Random source ──
            rndPhase += rndInc;
            bool rndStepEdge = false;
            if (rndPhase >= 1.0f) {
                rndPhase -= 1.0f;
                if (frand01(rndRng) <= rProb) {
                    rndTarget = frand(rndRng);
                    rndStepEdge = true;
                    if (rmode == 3) rndBurst = 2 + (int)(frand01(rndRng) * 5.0f);  // burst
                }
            }
            if (rmode == 3 && rndBurst > 0 && rndPhase > 0.5f) {
                rndTarget = frand(rndRng); rndBurst--; rndStepEdge = true;
            }
            if (rmode == 0) rndV1 += (rndTarget - rndV1) * rndSlew;   // smooth
            else rndV1 = rndTarget;                                   // stepped / s&h / burst
            if (rndStepEdge) rndV2 = rndTarget * 0.5f + 0.5f;         // s&h sample (0..1)
            const float rnd1 = rndV1;                 // -1..1
            const float rnd2 = rndV2;                 // 0..1

            // ── Function generators ──
            auto runFunc = [&](Func& f, const std::pair<float, float>& t, float sh,
                               int loop, bool trig, float rateMod) {
                f.eoc = 0.0f;
                const float rinc = t.first * (1.0f + rateMod * 3.0f);
                const float finc = t.second * (1.0f + rateMod * 3.0f);
                if (trig) { f.stage = 1; }
                if (f.stage == 0 && loop) f.stage = 1;
                if (f.stage == 1) {
                    f.lvl += rinc > 0 ? rinc : 0.00001f;
                    if (f.lvl >= 1.0f) { f.lvl = 1.0f; f.stage = 2; }
                } else if (f.stage == 2) {
                    f.lvl -= finc > 0 ? finc : 0.00001f;
                    if (f.lvl <= 0.0f) { f.lvl = 0.0f; f.stage = loop ? 1 : 0; f.eoc = 1.0f; }
                }
                return std::pow(clamp01f(f.lvl), sh);
            };

            // FN1 rate can be modulated (matrix dst 5); compute after we know
            // matrix sources, so do a cheap two-pass: funcs first with no
            // rate-mod here, then matrix. To keep modulation one-sample, read
            // rate-mod from last sample's func values is fine for an LFO.
            const float fn1Out = runFunc(fn1, fn1T, fn1Sh, fn1Loop,
                                         gateEdge || fireFn1, 0.0f);
            const float fn2Out = runFunc(fn2, fn2T, fn2Sh, fn2Loop,
                                         gateEdge || fireFn2, 0.0f);

            // ── Matrix sum per destination ──
            float dPitch = 0, dWave = 0, dFold = 0, dCut = 0, dLevel = 0, dSize = 0;
            if (mAny) {
                const float src[kSrc] = {fn1Out, fn2Out, rnd1, rnd2, lastVel, lastKey,
                                         gateNow ? 1.0f : 0.0f};
                for (int s = 0; s < kSrc; ++s) {
                    const float sv = src[s];
                    if (sv > -0.0001f && sv < 0.0001f) continue;
                    const float* row = &m[s * kDst];
                    dPitch += row[0] * sv;
                    dWave  += row[1] * sv;
                    dFold  += row[2] * sv;
                    dCut   += row[3] * sv;
                    dLevel += row[4] * sv;
                    // row[5] FN1RATE, row[6] RNDRATE handled coarsely; row[7] SIZE:
                    dSize  += row[7] * sv;
                }
            }
            const float foldCtl = clamp01f(fAmt0 + dFold);
            const float waveCtl = clamp01f(vWave + dWave);
            const float pitchModSemi = dPitch * 24.0f;

            // ── Voices ──
            float mono = 0.0f;
            for (int v = 0; v < mv; ++v) {
                Voice& vc = voices[v];
                if (vc.stStage == 0 && vc.strike < 0.0008f && !vc.gate) continue;

                // LPG strike envelope (vactrol): fast attack, exp decay.
                if (vc.stStage == 1) {
                    vc.strike += strikeInc;
                    if (vc.strike >= 1.0f) { vc.strike = 1.0f; vc.stStage = 2; }
                } else if (vc.stStage == 2) {
                    // Hold while gated (so sustained notes ring), else decay.
                    const float tgt = vc.gate ? 0.55f : 0.0f;
                    vc.strike += (tgt - vc.strike) * decCoef;
                    if (!vc.gate && vc.strike < 0.0006f) { vc.strike = 0.0f; vc.stStage = 0; }
                }
                float ctl = vc.strike + dLevel;
                if (ctl < 0.0f) ctl = 0.0f; if (ctl > 1.2f) ctl = 1.2f;
                const float acc = 1.0f + seqAccent * 0.4f;

                // Pitch (glide + VCO offset + matrix).
                vc.pitch += (vc.target - vc.pitch) * glideCoef;
                const float midi = vc.pitch + vPitch + pitchModSemi;
                const float freq = 440.0f * std::pow(2.0f, (midi - 69.0f) / 12.0f);
                const float inc = freq / kSR;
                if (inc >= 0.5f) continue;

                // VCO core: sine / tri / saw, morphed by wave → richer harmonics.
                const float t = (float)vc.phase;
                float core;
                if (wsel == 0) {            // sine → folded as it brightens
                    core = std::sin(kTwoPi * t);
                } else if (wsel == 1) {     // triangle
                    core = 4.0f * std::fabs(t - 0.5f) - 1.0f;
                } else {                    // saw
                    core = 2.0f * t - 1.0f - polyblep(t, inc);
                }
                // Sub oscillator (one octave down square), blended by scale.
                const float subSq = (vc.sub < 0.5f ? 1.0f : -1.0f);
                float osc = core + subSq * (0.15f + vScale * 0.5f) * 0.5f;
                // Drive harmonics with the wave macro before folding.
                osc *= 1.0f + waveCtl * 2.5f;
                // VCO internal fold then dedicated wave folder.
                osc = fold(osc * (1.0f + vFold * 3.0f));
                osc = fold((osc + fBias) * (1.0f + foldCtl * 5.0f));
                osc = std::tanh(osc * drive) * (0.6f / (0.4f + 0.6f * drive));

                vc.phase += inc;       if (vc.phase >= 1.0) vc.phase -= 1.0;
                vc.sub  += inc * 0.5f; if (vc.sub  >= 1.0) vc.sub  -= 1.0;

                // Low-pass gate: cutoff opens with the control (vactrol).
                const float cut = clamp01f(cutBase * (0.18f + 0.82f * ctl) + dCut);
                const float fHz = 25.0f * std::pow(640.0f, cut);
                float gT = std::tan(3.14159265f * (fHz > 19000.0f ? 19000.0f : fHz) / kSR);
                if (gT > 14.0f) gT = 14.0f;
                const float a1 = 1.0f / (1.0f + gT * (gT + kDamp));
                const float a2 = gT * a1;
                const float a3 = gT * a2;
                const float in = osc * vc.vel;
                const float v3 = in - vc.lp2;
                const float vv1 = a1 * vc.lp1 + a2 * v3;
                const float vv2 = vc.lp2 + a2 * vc.lp1 + a3 * v3;
                vc.lp1 = 2.0f * vv1 - vc.lp1;
                vc.lp2 = 2.0f * vv2 - vc.lp2;
                const float lp = vv2;
                mono += lp * ctl * acc;
            }
            mono *= 0.5f;

            // ── Space reverb (mono in, stereo out) ──
            float wetL = 0.0f, wetR = 0.0f;
            const float sizeNow = clamp01f(spSize + dSize + seqSpaceBoost * 0.3f);
            const float fb = revFb + sizeNow * 0.02f;
            const float inMono = mono * 0.4f;
            for (int c = 0; c < kCombs; ++c) {
                const int pL = combPos[c] % combLenL[c];
                const int pR = combPos[c] % combLenR[c];
                const float yL = combL[c][pL];
                const float yR = combR[c][pR];
                combLpL[c] += (yL - combLpL[c]) * damp;
                combLpR[c] += (yR - combLpR[c]) * damp;
                combL[c][pL] = inMono + combLpL[c] * (fb > 0.97f ? 0.97f : fb);
                combR[c][pR] = inMono + combLpR[c] * (fb > 0.97f ? 0.97f : fb);
                wetL += yL; wetR += yR;
                combPos[c]++;
            }
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
            if (spType == 0) {   // spring: dispersive "boing"
                springZ += (wetL - springZ) * 0.5f;
                springZ2 += (springZ - springZ2) * 0.28f;
                wetL = wetL * 0.4f + springZ2 * 0.9f;
                wetR = wetR * 0.4f + springZ2 * 0.85f;
            }

            float oL = mono + wetL * revMix;
            float oR = mono + wetR * revMix;
            // Stereo width (mid/side).
            const float mid = (oL + oR) * 0.5f;
            const float side = (oL - oR) * 0.5f * (0.2f + width * 1.6f);
            oL = mid + side;
            oR = mid - side;

            L[i] += std::tanh(oL * 1.2f) * outGain;
            R[i] += std::tanh(oR * 1.2f) * outGain;
        }
    }
};
