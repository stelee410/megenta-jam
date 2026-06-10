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

using magentart::core::RealtimeRunner;

// Shared state between audio/MIDI threads and the UI controller
struct JamSharedState {
    std::atomic<bool> midiNotes[128] = {};

    static constexpr int VIZ_BUF_SIZE = 8192;
    float vizRing[VIZ_BUF_SIZE] = {};
    std::atomic<int> vizHead{0};

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

    void processPerformanceFX(float* left, float* right, int count) {
        constexpr float sampleRate = 48000.0f;
        constexpr float pi = 3.14159265358979323846f;

        const float fx = clamp01(filterX.load(std::memory_order_relaxed));
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
        const float dMix = clamp01(delayMix.load(std::memory_order_relaxed)) * 0.65f;
        const float dFeedback = clamp01(delayFeedback.load(std::memory_order_relaxed)) * 0.86f;
        const int delaySamples = 18000;
        const float rMix = clamp01(reverbMix.load(std::memory_order_relaxed)) * 0.55f;
        const float rFeedback = 0.58f + clamp01(reverbMix.load(std::memory_order_relaxed)) * 0.30f;
        const int reverbSamples = 11317;
        const float limitAmt = clamp01(limiter.load(std::memory_order_relaxed));
        const float threshold = 1.0f - limitAmt * 0.55f;

        // Master character FX params.
        const float widthAmt = clamp01(stereoWidth.load(std::memory_order_relaxed)) * 2.0f; // 0..2
        const float toneG = (clamp01(tone.load(std::memory_order_relaxed)) - 0.5f) * 2.0f;   // -1..1
        const float toneCoef = 2.0f * pi * 320.0f / sampleRate;                              // ~320 Hz split
        const float gainAmt = clamp01(outGain.load(std::memory_order_relaxed)) * 2.0f;       // unity at 0.5
        const float crushAmt = clamp01(crush.load(std::memory_order_relaxed));
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
            vizRing[h] = (left[i] + right[i]) * 0.5f;
            h = (h + 1) % VIZ_BUF_SIZE;
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
