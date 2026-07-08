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

#pragma once
#import <Cocoa/Cocoa.h>
#import <CoreMIDI/CoreMIDI.h>
#include <magentart/realtime_runner.h>
#include <atomic>
#include <cmath>
#include "audio_level_processor.h"
#include "JamSynth.h"
#include "JamModular.h"
#include "JamLaneFx.h"

using magentart::core::RealtimeRunner;

// Shared state between audio/MIDI threads and the UI controller
struct JamSharedState {
    static constexpr int kStems = 8;                   // 6 separated + 2 AUX
    static constexpr int kMidiLanes = 7;               // stems 1..7
    static constexpr int kLaneBlockMax = 4096;

    std::atomic<bool> midiNotes[128] = {};
    // Only the jam tab conditions the generative engine from live MIDI; on
    // other tabs (instrument/pgm) keys play the performance synth instead of
    // starting an AI jam.
    std::atomic<bool> jamTabActive{true};
    // Instrument tab: when true, keys played on the performance synth ALSO
    // condition the generative engine (the AI jam follows along). Off = the
    // instrument plays solo without driving the jam.
    std::atomic<bool> instrumentFollowsJam{false};

    // Live-performance synth (Instrument tab). When `synth.active`, incoming
    // notes route here instead of conditioning the generative engine.
    JamSynth synth;

    // West-Coast semi-modular voice (Modular tab). When `modular.active`,
    // incoming notes route here instead of the synth / engine.
    JamModular modular;

    // PGM live MIDI-input instrument source: the built-in synth, or an SF2
    // GM program. SF2 note events flow through a lock-free queue applied on
    // the audio thread (tsf voice state is not safe to touch from MIDI threads).
    std::atomic<int> liveSource{0};        // 0 = built-in synth, 1 = SF2
    std::atomic<void*> liveSf{nullptr};    // tsf* (live input)
    std::atomic<int> liveSfProgram{0};     // GM program 0..127
    std::atomic<float> liveGain{0.9f};     // PGM live-input volume (0..1.2)
    JamLaneFx liveFx;                      // PGM live-input reverb + echo
    int liveSfProgApplied = -1;            // render-thread
    int liveSourceSeen = 0;                // render-thread (flush on change)
    bool liveHeld[128] = {};               // render-thread held SF2 notes
    struct LiveEv { uint8_t note; uint8_t vel; bool on; };
    LiveEv liveEv[256] = {};
    std::atomic<int> liveEvW{0}, liveEvR{0};
    void pushLiveNote(uint8_t note, uint8_t vel, bool on) {
        const int w = liveEvW.load(std::memory_order_relaxed);
        const int n = (w + 1) & 255;
        if (n == liveEvR.load(std::memory_order_acquire)) return;
        liveEv[w] = {note, vel, on};
        liveEvW.store(n, std::memory_order_release);
    }
    // Route a live note to the selected source. Note-offs go to BOTH so a
    // source switch mid-hold never strands a sounding note.
    void routeLiveNote(uint8_t note, uint8_t vel, bool on) {
        // Note-offs always reach every sink so a tab/source switch mid-hold
        // never strands a sounding note.
        if (!on) {
            synth.pushNote(note, 0, false);
            modular.pushNote(note, 0, false);
            pushLiveNote(note, 0, false);
            return;
        }
        if (modular.active.load(std::memory_order_relaxed)) { modular.pushNote(note, vel, true); return; }
        if (liveSource.load(std::memory_order_relaxed) == 1) pushLiveNote(note, vel, true);
        else synth.pushNote(note, vel, true);
    }

    // ── PGM studio I/O (render-thread side) ─────────────────────────────
    // Preview player: one-shot stereo playback of an original stem or a cover
    // take. Buffers are owned by the controller, which never frees them while
    // `prevActive` could still be observed by the render thread.
    std::atomic<const float*> prevL{nullptr};
    std::atomic<const float*> prevR{nullptr};
    std::atomic<long> prevLen{0};
    std::atomic<long> prevPos{0};
    std::atomic<bool> prevActive{false};
    // Stem mixer (PGM console): the render thread sums the loaded stems with
    // per-stem gain + mute/solo, driven by a master transport.
    std::atomic<const int16_t*> stemBuf[kStems] = {};
    std::atomic<long> stemLen{0};
    std::atomic<long> stemPos{0};
    std::atomic<int> stemMask{0};          // legacy (unused by the mixer)
    std::atomic<bool> stemActive{false};   // transport: playing
    std::atomic<float> stemGain[kStems] = {{1}, {1}, {1}, {1}, {1}, {1}, {1}, {1}};
    std::atomic<int> stemMuteMask{0};
    std::atomic<int> stemSoloMask{0};
    // Per-stem playback alignment offset (samples). At transport `pos` the stem
    // reads from `pos - offset`: +offset delays it (shifts right/later), -offset
    // advances it (shifts left/earlier). For nudging imported/replaced tracks
    // whose length doesn't match the base song.
    std::atomic<long> stemOffset[kStems] = {};
    // Per-stem "dry blend": mix a fraction of the original mix back into a
    // separated stem to fill hard-mask gaps and mask musical-noise artifacts
    // (more natural, at the cost of a little bleed). 0 = pure separation.
    std::atomic<float> stemDry[kStems] = {};
    std::atomic<const float*> songMixL{nullptr};   // original mix (controller-owned)
    std::atomic<const float*> songMixR{nullptr};
    std::atomic<long> songMixLen{0};
    float stemSmoothG[kStems] = {};             // render-thread gain smoothing
    // Count-in (预备拍) + click metronome for the stem transport.
    std::atomic<int> countInBeats{0};      // setting: 0 / 4 / 8 beats
    std::atomic<long> countInUntil{-1};    // rolled-back region: force click until this sample
    std::atomic<long> countInLeft{0};      // frozen pre-roll samples remaining (no room to roll back)
    std::atomic<long> countInVPos{0};      // virtual sample swept during the frozen pre-roll
    std::atomic<bool> clickOn{false};      // metronome during playback
    std::atomic<float> clickGain{1.0f};    // click/metronome volume (0..2)
    std::atomic<float> stemBpm{120.0f};    // song tempo driving click/count-in
    std::atomic<int> beatsPerBar{4};       // metronome time signature: 4 (4/4) or 3 (3/4)
    std::atomic<long> stemBeatOff{0};      // first-beat offset (samples)
    std::atomic<int> stemBarPhase{0};      // beat index 0..3 that is a downbeat
    std::atomic<long> stemCue{-1};         // cue point (samples; -1 = none)
    // render-local click synth state:
    float clickPhase = 0.0f, clickEnv = 0.0f, clickFreq = 1000.0f;

    // ── Metronome click voice (render thread only) ────────────────────────
    // One shared sine-ping voice reused by every click source (count-in,
    // stem playback metronome, looper count-in). Trigger on a beat, then
    // tick once per frame. NO alloc / NO lock / NO logging.
    static constexpr float kClickAccentHz = 1760.0f;   // downbeat ("1")
    static constexpr float kClickBeatHz   = 1175.0f;   // other beats
    void triggerClick(bool accent) {
        clickEnv = 1.0f;
        clickPhase = 0.0f;
        clickFreq = accent ? kClickAccentHz : kClickBeatHz;
    }
    // Advance the click voice one frame; returns the sample (0 when idle).
    float tickClick(float amp) {
        if (clickEnv <= 0.0005f) return 0.0f;
        clickPhase += clickFreq / 48000.0f;
        if (clickPhase >= 1.0f) clickPhase -= 1.0f;
        const float s = sinf(clickPhase * 2.0f * (float)M_PI)
                        * clickEnv * amp
                        * clickGain.load(std::memory_order_relaxed);
        clickEnv *= 0.9988f;    // ~25 ms decay at 48 kHz
        return s;
    }

    // ── Multi-track looper (jam tab) ──────────────────────────────────────
    // Capture the program output (pre-loop) into loop tracks and layer them
    // back in, all synced to a master grid set by the first loop's bars × BPM.
    // States: 0 empty · 1 armed · 2 recording · 3 playing · 4 armed-overdub ·
    // 5 overdubbing · 6 stopped. Transitions are driven on the audio thread;
    // the UI/controller only sets intent (arm/overdub/stop/clear).
    static constexpr int  kLoopTracks    = 4;
    static constexpr long kLoopMaxFrames = 48000 * 16;   // 16 s max loop
    float loopData[kLoopTracks][2 * kLoopMaxFrames] = {}; // stereo interleaved
    std::atomic<int>   loopState[kLoopTracks] = {};
    std::atomic<float> loopGain[kLoopTracks]  = {{1.0f}, {1.0f}, {1.0f}, {1.0f}};
    std::atomic<bool>  loopMute[kLoopTracks]  = {};
    std::atomic<long>  loopLen{0};          // master loop length (frames; 0 = none)
    std::atomic<long>  loopPhase{0};        // master phase [0, loopLen)
    std::atomic<int>   loopBars{4};         // requested loop length in bars
    std::atomic<bool>  loopResetPhase{false}; // first loop: restart the grid at 0
    std::atomic<bool>  loopAuto{true};      // auto-overdub: keep layering after the 1st pass
    std::atomic<bool>  loopCountInOn{true}; // 1-bar click count-in before the first loop
    std::atomic<long>  loopCountInLeft{0};  // frames remaining in the count-in
    std::atomic<long>  loopCountInTotal{0}; // count-in length (frames)
    long loopRecRemaining[kLoopTracks] = {}; // audio-thread-owned record countdown
    // Output routing: the main mix and the click can target different device
    // channels (e.g. main → outs 1/2 to FOH, click → out 3 to the drummer's
    // ear). Bit c of a mask = device output channel c. The render block
    // produces internal busses and distributes them per these masks.
    static constexpr int kBusMax = 8192;
    std::atomic<int> outChannels{2};            // current device channel count
    // Opt-in multichannel output (default off = safe stereo). Forcing a
    // multichannel output format plays slow on devices that misreport their
    // rate (raw SP-404); only enable with a true 48 kHz device / aggregate.
    std::atomic<bool> multichannelOut{false};
    std::atomic<uint32_t> mainOutMask{0x3};     // default: channels 1+2
    std::atomic<uint32_t> clickOutMask{0x3};

    // Auto speed compensation: measure the device's effective 48k-content rate
    // from the render-callback clock and resample so playback holds the true
    // original BPM on devices that clock slow. comp = 48000 / measured-rate.
    std::atomic<float> outSpeedComp{1.0f};      // applied compensation factor
    std::atomic<bool>  rateMeasReset{true};     // main thread: restart measurement
    double   hostTicksToSec{0.0};               // mach timebase (set once at setup)
    uint64_t rateMeasStartHost{0};              // audio-thread-owned measurement state
    double   rateMeasFrames{0.0};
    bool     rateMeasLocked{false};

    // Calibration gate: on device/channel change the program audio is muted and
    // a standard 120 BPM reference click plays through the new output so the
    // operator can verify timing against their rig before performing.
    std::atomic<bool> calibrating{false};
    uint64_t calibSamplePos{0};                 // audio-thread-owned, reset on entry

    // Offline backing bounce: the render block, when armed, captures the stem-mix
    // delta (outL/R before vs after the stem section, isolating the backing from
    // any engine/synth output) + optional click into bounceL/R. Driven faster
    // than real time by an offline pump of the render block (engine paused).
    std::atomic<bool>  bounceArmed{false};
    std::atomic<bool>  bounceClick{false};      // fold the metronome into the bounce
    std::atomic<float*> bounceL{nullptr};
    std::atomic<float*> bounceR{nullptr};
    std::atomic<long>  bounceCap{0};            // frames to capture
    std::atomic<long>  bounceWritten{0};
    float bounceSnapL[kBusMax] = {};            // audio-thread scratch (pre-stem snapshot)
    float bounceSnapR[kBusMax] = {};
    float busL[kBusMax] = {}, busR[kBusMax] = {};   // main stereo bus
    float clickBus[kBusMax] = {};                   // mono click bus
    // Per-stem MIDI lanes: each melodic stem (1..5 — bass, other, vocals,
    // guitar, piano) can switch its playback source between the original
    // audio and a MIDI clip rendered by a dedicated synth instance with a
    // stem-appropriate patch. All instances render serially on the audio
    // thread, clocked by the stem transport — construction-level sync.
    // Drums (0) stay audio-only (pitch transcription doesn't apply).
    struct AuxEv { long sample; uint8_t note; uint8_t vel; bool on; };
    JamSynth laneSynth[kMidiLanes];
    std::atomic<uint8_t> stemSource[kStems] = {};      // 0 = audio, 1 = MIDI
    std::atomic<const AuxEv*> laneEv[kMidiLanes] = {};
    std::atomic<long> laneCount[kMidiLanes] = {};
    std::atomic<uint32_t> laneGen[kMidiLanes] = {};
    // SF2 sample engine (TinySoundFont): each lane may switch from the
    // MicroFreak synth to a GM SoundFont program. laneSf holds a tsf*
    // (opaque here); instances share the master font's sample data and are
    // published once fully initialized — never freed while playing.
    std::atomic<int> laneEngine[kMidiLanes] = {};      // 0 = synth, 1 = SF2
    std::atomic<void*> laneSf[kMidiLanes] = {};        // tsf* per lane
    std::atomic<int> laneSfProgram[kMidiLanes] = {};   // GM program 0..127
    JamLaneFx laneFx[kMidiLanes];                      // per-lane echo/reverb
    // render-thread local:
    long laneCursor[kMidiLanes] = {};
    uint32_t laneGenSeen[kMidiLanes] = {};
    int laneEngineSeen[kMidiLanes] = {};
    int laneSfProgApplied[kMidiLanes] = {-1, -1, -1, -1, -1, -1, -1};
    long laneLastPos = -1;
    bool laneHeld[kMidiLanes][128] = {};
    long laneTail[kMidiLanes] = {};                    // keep rendering for FX tails
    float laneSmoothG[kMidiLanes] = {};                // de-click gain smoothing
    float laneBufL[kMidiLanes][kLaneBlockMax] = {};    // per-lane synth scratch
    float laneBufR[kMidiLanes][kLaneBlockMax] = {};
    float laneSfTmp[kLaneBlockMax * 2] = {};           // unweaved SF2 scratch

    // Take recorder: captures the raw generative-engine output (pre-FX) while
    // armed, so a cover take can be A/B'd against the original stem.
    std::atomic<float*> recL{nullptr};
    std::atomic<float*> recR{nullptr};
    std::atomic<long> recCap{0};
    std::atomic<long> recWritten{0};
    std::atomic<bool> recArmed{false};

    static constexpr int VIZ_BUF_SIZE = 8192;
    float vizRing[VIZ_BUF_SIZE] = {};
    std::atomic<int> vizHead{0};

    // ── BPM detection ────────────────────────────────────────────────────
    // The audio thread writes a low-band onset-strength envelope (energy flux
    // of a ~200 Hz lowpass, one value per 512-sample hop ≈ 93.75 fps). The
    // main thread autocorrelates the most recent ~10 s on demand.
    static constexpr int BPM_HOP = 512;
    static constexpr int BPM_RING = 1024;          // ≈ 10.9 s of envelope
    float bpmOnset[BPM_RING] = {};
    std::atomic<int> bpmWrite{0};                  // monotonic block counter
    float bpmLp = 0.0f, bpmAccum = 0.0f, bpmPrevE = 0.0f;  // audio-thread only
    int bpmAccumN = 0;

    magentart::common::AudioLevelProcessor levelProcessor;

    std::atomic<float> filterX{1.0f};
    std::atomic<float> filterY{0.02f};
    std::atomic<float> drive{0.0f};
    std::atomic<float> delayMix{0.0f};
    std::atomic<float> delayFeedback{0.25f};
    std::atomic<float> reverbMix{0.0f};
    std::atomic<float> limiter{0.35f};
    // Master character FX (apply to both local and Lyria output).
    std::atomic<float> stereoWidth{0.5f};  // 0 = mono, 0.5 = normal, 1 = wide
    std::atomic<float> tone{0.5f};         // 0 = dark, 0.5 = flat, 1 = bright (tilt EQ)
    std::atomic<float> outGain{0.5f};      // 0.5 = unity, 1 = +6 dB
    std::atomic<float> crush{0.0f};        // 0 = off, 1 = heavy bitcrush
    std::atomic<float> tremolo{0.0f};      // 0 = off, 1 = full depth (BPM-synced)
    std::atomic<float> fxTempo{120.0f};    // BPM driving the tremolo LFO

    // Punch-in FX (EP-133 style): a momentary master effect while a pad is held.
    //   0 stutter, 1 tape stop, 2 reverse, 3 pitch down, 4 pitch up,
    //   5 lpf, 6 hpf, 7 delay throw, 8 reverb wash, 9 crush, 10 gate, 11 squash
    std::atomic<int> punchFx{-1};          // -1 = none
    std::atomic<float> punchAmt{0.5f};     // 0..1, modulated by vertical drag
    std::atomic<uint32_t> punchGen{0};     // bumped on engage → resets DSP state

    static constexpr int PUNCH_RING = 48000 * 4;   // 4 s history for time FX
    float punchRingL[PUNCH_RING] = {};
    float punchRingR[PUNCH_RING] = {};
    long long punchWriteAbs = 0;   // monotonically increasing write position
    long long punchAnchor = 0;     // write position at engage
    long long punchCount = 0;      // samples since engage
    double punchPos = 0.0;         // fractional read position (tape/pitch/reverse)
    float punchRate = 1.0f;        // tape-stop playback rate
    uint32_t punchGenSeen = 0;
    float punchGateG = 1.0f, punchGatePhase = 0.0f;  // gate chop state
    float punchHpL = 0.0f, punchHpR = 0.0f;          // punch HPF state

    float lpZ1L = 0.0f, lpZ2L = 0.0f, lpZ1R = 0.0f, lpZ2R = 0.0f;
    float toneLpL = 0.0f, toneLpR = 0.0f;     // tilt-EQ low-band state
    float tremPhase = 0.0f;                   // tremolo LFO phase
    float crushHoldL = 0.0f, crushHoldR = 0.0f, crushPhase = 0.0f; // bitcrush S&H
    static constexpr int DELAY_SIZE = 48000;
    float delayL[DELAY_SIZE] = {};
    float delayR[DELAY_SIZE] = {};
    int delayHead = 0;
    static constexpr int REVERB_SIZE = 18000;
    float reverbL[REVERB_SIZE] = {};
    float reverbR[REVERB_SIZE] = {};
    int reverbHead = 0;

    static float clamp01(float v) {
        return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
    }

    // Punch time FX: the ring always captures the dry signal; while a
    // time-based pad (0..4) is held, the output is replaced by reading the
    // ring — looped (stutter), slowing (tape), backwards (reverse) or
    // resampled (pitch). Runs on the audio thread only.
    void processPunchTime(float* left, float* right, int count, int pfx, float pamt) {
        const uint32_t gen = punchGen.load(std::memory_order_relaxed);
        if (gen != punchGenSeen) {             // pad freshly engaged → reset
            punchGenSeen = gen;
            punchAnchor = punchWriteAbs;
            punchPos = (double)punchWriteAbs;
            punchRate = 1.0f;
            punchCount = 0;
            punchGateG = 1.0f;
            punchGatePhase = 0.0f;
            punchHpL = punchHpR = 0.0f;
        }
        for (int i = 0; i < count; ++i) {
            const int w = (int)(punchWriteAbs % PUNCH_RING);
            punchRingL[w] = left[i];
            punchRingR[w] = right[i];
            punchWriteAbs++;
            if (pfx < 0 || pfx > 4) continue;

            double pos;
            switch (pfx) {
                case 0: { // stutter: loop the moment right before the press
                    const long long len = (long long)(12000 - pamt * 10800); // ~250→25 ms
                    long long base = punchAnchor - len;
                    if (base < 0) base = 0;
                    pos = (double)(base + (punchCount % len));
                    break;
                }
                case 1: { // tape stop: decelerate to a halt
                    punchRate -= (0.25f + 2.2f * pamt) / 48000.0f;
                    if (punchRate < 0.0f) punchRate = 0.0f;
                    punchPos += punchRate;
                    pos = punchPos;
                    break;
                }
                case 2: { // reverse: play history backwards
                    punchPos -= 1.0;
                    pos = punchPos;
                    break;
                }
                case 3: { // pitch down: under-speed resample
                    punchPos += 1.0 - 0.55 * pamt;
                    pos = punchPos;
                    break;
                }
                default: { // 4 pitch up: over-speed, granular jump-back at the head
                    punchPos += 1.0 + 1.0 * pamt;
                    if (punchPos >= (double)punchWriteAbs - 2.0) punchPos -= 4800.0;
                    pos = punchPos;
                    break;
                }
            }
            punchCount++;

            // Clamp into the available history window.
            const double oldest = (double)(punchWriteAbs > PUNCH_RING
                                           ? punchWriteAbs - PUNCH_RING + 2 : 0);
            if (pos < oldest) pos = oldest;
            const long long ip = (long long)pos;
            const float fr = (float)(pos - (double)ip);
            const int i0 = (int)(ip % PUNCH_RING);
            const int i1 = (int)((ip + 1) % PUNCH_RING);
            left[i]  = punchRingL[i0] * (1.0f - fr) + punchRingL[i1] * fr;
            right[i] = punchRingR[i0] * (1.0f - fr) + punchRingR[i1] * fr;
        }
    }

    void processPerformanceFX(float* left, float* right, int count) {
        constexpr float sampleRate = 48000.0f;
        constexpr float pi = 3.14159265358979323846f;

        // Punch-in FX: time-domain pads replace the source; the others override
        // params of the chain below (filter/delay/reverb/crush) or chop at the end.
        const int pfx = punchFx.load(std::memory_order_relaxed);
        const float pamt = clamp01(punchAmt.load(std::memory_order_relaxed));
        processPunchTime(left, right, count, pfx, pamt);

        const float fx = (pfx == 5) ? (1.0f - pamt * 0.93f)
                                    : clamp01(filterX.load(std::memory_order_relaxed));
        const float fy = clamp01(filterY.load(std::memory_order_relaxed));
        const float cutoff = 80.0f * std::pow(18000.0f / 80.0f, fx);
        const float q = 0.55f + fy * 8.0f;
        const float omega = 2.0f * pi * cutoff / sampleRate;
        const float sinw = std::sin(omega);
        const float cosw = std::cos(omega);
        const float alpha = sinw / (2.0f * q);
        const float a0 = 1.0f + alpha;
        const float b0 = ((1.0f - cosw) * 0.5f) / a0;
        const float b1 = (1.0f - cosw) / a0;
        const float b2 = b0;
        const float a1 = (-2.0f * cosw) / a0;
        const float a2 = (1.0f - alpha) / a0;

        const float driveAmt = clamp01(drive.load(std::memory_order_relaxed));
        const float driveGain = 1.0f + driveAmt * 10.0f;
        const float driveNorm = std::tanh(driveGain);
        const float dMix = (pfx == 7) ? (0.35f + 0.30f * pamt)
                                      : clamp01(delayMix.load(std::memory_order_relaxed)) * 0.65f;
        const float dFeedback = (pfx == 7) ? (0.55f + 0.38f * pamt)
                                           : clamp01(delayFeedback.load(std::memory_order_relaxed)) * 0.86f;
        const int delaySamples = 18000;
        const float rMix = (pfx == 8) ? (0.40f + 0.45f * pamt)
                                      : clamp01(reverbMix.load(std::memory_order_relaxed)) * 0.55f;
        const float rFeedback = (pfx == 8) ? 0.88f
                                           : 0.58f + clamp01(reverbMix.load(std::memory_order_relaxed)) * 0.30f;
        const int reverbSamples = 11317;
        const float limitAmt = clamp01(limiter.load(std::memory_order_relaxed));
        const float threshold = 1.0f - limitAmt * 0.55f;

        // Master character FX params.
        const float widthAmt = clamp01(stereoWidth.load(std::memory_order_relaxed)) * 2.0f; // 0..2
        const float toneG = (clamp01(tone.load(std::memory_order_relaxed)) - 0.5f) * 2.0f;   // -1..1
        const float toneCoef = 2.0f * pi * 320.0f / sampleRate;                              // ~320 Hz split
        const float gainAmt = clamp01(outGain.load(std::memory_order_relaxed)) * 2.0f;       // unity at 0.5
        const float crushAmt = (pfx == 9) ? (0.3f + 0.7f * pamt)
                                          : clamp01(crush.load(std::memory_order_relaxed));

        // Punch HPF sweep + BPM-synced gate chop params.
        const float hpFreq = 120.0f * std::pow(30.0f, pamt);                  // 120 Hz → 3.6 kHz
        const float hpCoef = std::min(0.95f, 2.0f * pi * hpFreq / sampleRate);
        const float gateInc = (std::max(40.0f, fxTempo.load(std::memory_order_relaxed)) / 60.0f)
                              * (2.0f + std::floor(pamt * 6.0f)) / sampleRate;
        const float crushLevels = std::pow(2.0f, 16.0f - crushAmt * 13.0f);                  // 16..3 bits
        const float crushHoldLen = 1.0f + crushAmt * crushAmt * 40.0f;                       // sample & hold
        const float tremDepth = clamp01(tremolo.load(std::memory_order_relaxed));
        const float tremRate = std::max(40.0f, fxTempo.load(std::memory_order_relaxed)) / 60.0f * 2.0f; // 1/8 notes
        const float tremInc = 2.0f * pi * tremRate / sampleRate;

        for (int i = 0; i < count; ++i) {
            float l = left[i];
            float r = right[i];

            l = b0 * l + lpZ1L;
            lpZ1L = b1 * left[i] - a1 * l + lpZ2L;
            lpZ2L = b2 * left[i] - a2 * l;
            r = b0 * r + lpZ1R;
            lpZ1R = b1 * right[i] - a1 * r + lpZ2R;
            lpZ2R = b2 * right[i] - a2 * r;

            // Punch HPF sweep: one-pole highpass, cutoff rides the pad drag.
            if (pfx == 6) {
                punchHpL += hpCoef * (l - punchHpL);
                punchHpR += hpCoef * (r - punchHpR);
                l -= punchHpL;
                r -= punchHpR;
            }

            if (driveAmt > 0.001f) {
                l = std::tanh(l * driveGain) / driveNorm;
                r = std::tanh(r * driveGain) / driveNorm;
            }

            // Bitcrush: bit-depth reduction + sample & hold (lo-fi grit).
            if (crushAmt > 0.001f) {
                crushPhase += 1.0f;
                if (crushPhase >= crushHoldLen) {
                    crushPhase -= crushHoldLen;
                    crushHoldL = std::round(l * crushLevels) / crushLevels;
                    crushHoldR = std::round(r * crushLevels) / crushLevels;
                }
                l = crushHoldL;
                r = crushHoldR;
            }

            // Tone: tilt EQ around ~320 Hz (dark ↔ bright).
            if (toneG < -0.001f || toneG > 0.001f) {
                toneLpL += toneCoef * (l - toneLpL);
                toneLpR += toneCoef * (r - toneLpR);
                l = toneLpL * (1.0f - 0.7f * toneG) + (l - toneLpL) * (1.0f + 0.7f * toneG);
                r = toneLpR * (1.0f - 0.7f * toneG) + (r - toneLpR) * (1.0f + 0.7f * toneG);
            }

            int delayRead = delayHead - delaySamples;
            if (delayRead < 0) delayRead += DELAY_SIZE;
            float dl = delayL[delayRead];
            float dr = delayR[delayRead];
            delayL[delayHead] = l + dl * dFeedback;
            delayR[delayHead] = r + dr * dFeedback;
            if (++delayHead >= DELAY_SIZE) delayHead = 0;
            l = l * (1.0f - dMix) + dl * dMix;
            r = r * (1.0f - dMix) + dr * dMix;

            int reverbRead = reverbHead - reverbSamples;
            if (reverbRead < 0) reverbRead += REVERB_SIZE;
            float rl = reverbL[reverbRead];
            float rr = reverbR[reverbRead];
            reverbL[reverbHead] = l + rl * rFeedback;
            reverbR[reverbHead] = r + rr * rFeedback;
            if (++reverbHead >= REVERB_SIZE) reverbHead = 0;
            l = l * (1.0f - rMix) + rl * rMix;
            r = r * (1.0f - rMix) + rr * rMix;

            // Stereo width: mid/side scaling (0 = mono, 1 = normal, 2 = wide).
            if (widthAmt < 0.999f || widthAmt > 1.001f) {
                const float mid = (l + r) * 0.5f;
                const float side = (l - r) * 0.5f * widthAmt;
                l = mid + side;
                r = mid - side;
            }

            // Tremolo + gentle auto-pan, BPM-synced.
            if (tremDepth > 0.001f) {
                tremPhase += tremInc;
                if (tremPhase > 2.0f * pi) tremPhase -= 2.0f * pi;
                const float lfo = 0.5f * (1.0f - std::cos(tremPhase)); // 0..1
                const float amp = 1.0f - tremDepth * (1.0f - lfo);
                l *= amp;
                r *= amp;
                const float pan = tremDepth * 0.35f * std::sin(tremPhase);
                l *= 1.0f - std::max(0.0f, pan);
                r *= 1.0f - std::max(0.0f, -pan);
            }

            // Punch gate chop (BPM-synced square, slewed to avoid clicks) and
            // squash (heavy soft-knee saturation).
            if (pfx == 10) {
                punchGatePhase += gateInc;
                if (punchGatePhase >= 1.0f) punchGatePhase -= 1.0f;
                const float tg = punchGatePhase < 0.5f ? 1.0f : 0.0f;
                punchGateG += (tg - punchGateG) * 0.012f;
                l *= punchGateG;
                r *= punchGateG;
            } else if (pfx == 11) {
                const float g = 1.0f + 8.0f * pamt;
                l = std::tanh(l * g) * 0.85f;
                r = std::tanh(r * g) * 0.85f;
            }

            // Master output gain (unity at 0.5), then the limiter catches boosts.
            l *= gainAmt;
            r *= gainAmt;

            if (limitAmt > 0.001f) {
                l = threshold * std::tanh(l / threshold);
                r = threshold * std::tanh(r / threshold);
            }

            left[i] = l;
            right[i] = r;
        }
    }

    void pushAudioSamples(const float* left, const float* right, int count) {
        int h = vizHead.load(std::memory_order_relaxed);
        for (int i = 0; i < count; i++) {
            const float mono = (left[i] + right[i]) * 0.5f;
            vizRing[h] = mono;
            h = (h + 1) % VIZ_BUF_SIZE;

            // BPM onset envelope: kick-band energy flux per hop.
            bpmLp += 0.026f * (mono - bpmLp);          // ~200 Hz lowpass
            bpmAccum += bpmLp * bpmLp;
            if (++bpmAccumN >= BPM_HOP) {
                const float e = bpmAccum / BPM_HOP;
                float flux = e - bpmPrevE;
                if (flux < 0.0f) flux = 0.0f;
                bpmPrevE = e;
                const int w = bpmWrite.load(std::memory_order_relaxed);
                bpmOnset[w % BPM_RING] = flux;
                bpmWrite.store(w + 1, std::memory_order_release);
                bpmAccum = 0.0f;
                bpmAccumN = 0;
            }
        }
        vizHead.store(h, std::memory_order_release);

        levelProcessor.process_block(left, right, count);
    }

    void noteOn(uint8_t note) { if (note < 128) midiNotes[note].store(true, std::memory_order_relaxed); }
    void noteOff(uint8_t note) { if (note < 128) midiNotes[note].store(false, std::memory_order_relaxed); }
};

@class LyriaConductor;

@interface JamAppController : NSViewController
@property (nonatomic, assign) RealtimeRunner* engine;
@property (nonatomic, assign) JamSharedState* sharedState;
// Lyria cloud engine bridge (owned by the app delegate). The conductor runs
// two channels and crossfades to survive the gateway's 10-minute limit.
@property (nonatomic, strong) LyriaConductor* lyriaClient;
@property (nonatomic, assign) std::atomic<bool>* useLyria;
@property (nonatomic, assign) MIDIPortRef midiInputPort;
@property (nonatomic, strong) NSMutableSet<NSNumber*>* connectedSources;
@property (nonatomic, assign) std::atomic<bool>* soloMode;
@property (nonatomic, assign) std::atomic<float>* cfgNotesSliderValue;
@property (nonatomic, assign) std::atomic<float>* gateDecaySeconds;

- (void)notifyModelLoaded:(NSString*)modelName;
- (void)sendStateUpdate:(NSDictionary*)state;
// Calibration gate (device/channel change → verify 120 BPM click → resume)
- (void)enterCalibration;
- (void)finishCalibration;
- (void)restoreSavedParams;
- (void)handleLoadModel;
- (void)showReactSettings;
- (void)sendPlayState:(BOOL)playing;
// Param bridging — also used by settings window
- (void)applyParamToEngine:(int)address value:(float)value;
- (float)readParamFromEngine:(int)address;
// Computer-keyboard-as-MIDI (toggled from settings window)
- (void)setComputerKeyboardMidiEnabled:(BOOL)enabled;
// MIDI source management bridging to UI
- (void)handleMIDIStructureChanged;
- (void)selectMidiInput:(uint32_t)endpoint;
@end
