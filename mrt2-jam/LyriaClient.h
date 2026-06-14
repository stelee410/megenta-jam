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

// WebSocket client for the Lyria RealTime gateway
// (wss://agentllm.linkyun.co/v1beta/google/lyria/ws). Streams stereo 48 kHz
// 16-bit PCM into a lock-free ring drained by the audio render thread.
//
// Cost-control contract: the socket only exists while the user is actively
// playing in Lyria mode. disconnect() is a hard cutoff (STOP + cancel) and is
// called on pause, on engine switch, and at app termination.

#pragma once
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstring>
#include <vector>

// Lock-free SPSC ring of interleaved stereo float samples. Written by the
// websocket delegate queue, drained by the audio render thread.
struct LyriaAudioRing {
    static constexpr size_t kCapFrames = 48000 * 30;        // 30 s
    // A deeper start cushion absorbs network jitter (VPN/proxy hops stall the
    // stream for a second or two). After the first prime, an underrun only needs
    // a short top-up to resume — so a brief stall costs ~0.4 s, not a full 4 s.
    static constexpr size_t kPrebufferFrames = 48000 * 4;       // 4 s before first start
    static constexpr size_t kReprimeFrames   = 48000 * 2 / 5;   // 0.4 s to recover after an underrun

    std::vector<float> buf;               // interleaved L/R
    std::atomic<uint64_t> writeFrames{0}; // monotonic frames written
    std::atomic<uint64_t> readFrames{0};  // monotonic frames read
    std::atomic<bool> primed{false};      // enough buffered to start draining
    std::atomic<uint64_t> underruns{0};   // diagnostics: # of underrun events
    bool everPrimed = false;              // producer-thread only

    LyriaAudioRing() : buf(2 * kCapFrames, 0.0f) {}

    void clear() {
        primed.store(false, std::memory_order_relaxed);
        readFrames.store(0, std::memory_order_relaxed);
        writeFrames.store(0, std::memory_order_relaxed);
        everPrimed = false;
    }

    uint64_t available() const {
        return writeFrames.load(std::memory_order_acquire) -
               readFrames.load(std::memory_order_relaxed);
    }

    // Producer (websocket thread): append int16 interleaved stereo samples.
    void writeInt16Stereo(const int16_t* samples, size_t frames) {
        uint64_t w = writeFrames.load(std::memory_order_relaxed);
        const uint64_t r = readFrames.load(std::memory_order_acquire);
        // Overflow → drop the oldest by advancing the read cursor. Should not
        // happen in practice (we disconnect when not draining).
        if (w + frames - r > kCapFrames) {
            readFrames.store(w + frames - kCapFrames, std::memory_order_relaxed);
        }
        for (size_t i = 0; i < frames; ++i) {
            const size_t slot = ((w + i) % kCapFrames) * 2;
            buf[slot] = samples[i * 2] / 32768.0f;
            buf[slot + 1] = samples[i * 2 + 1] / 32768.0f;
        }
        writeFrames.store(w + frames, std::memory_order_release);
        if (!primed.load(std::memory_order_relaxed)) {
            const uint64_t avail = writeFrames.load(std::memory_order_relaxed) -
                                   readFrames.load(std::memory_order_relaxed);
            // First start waits for the full cushion; recovering from an underrun
            // only needs a small top-up so playback resumes quickly.
            const size_t need = everPrimed ? kReprimeFrames : kPrebufferFrames;
            if (avail >= need) {
                primed.store(true, std::memory_order_release);
                everPrimed = true;
            }
        }
    }

    // Consumer (audio render thread): fill L/R, zero-padding on underrun.
    void readStereo(float* L, float* R, size_t frames) {
        if (!primed.load(std::memory_order_acquire)) {
            memset(L, 0, frames * sizeof(float));
            memset(R, 0, frames * sizeof(float));
            return;
        }
        const uint64_t w = writeFrames.load(std::memory_order_acquire);
        uint64_t r = readFrames.load(std::memory_order_relaxed);
        const size_t have = (size_t)std::min<uint64_t>(frames, w - r);
        for (size_t i = 0; i < have; ++i) {
            const size_t slot = ((r + i) % kCapFrames) * 2;
            L[i] = buf[slot];
            R[i] = buf[slot + 1];
        }
        if (have < frames) {
            memset(L + have, 0, (frames - have) * sizeof(float));
            memset(R + have, 0, (frames - have) * sizeof(float));
            if (primed.load(std::memory_order_relaxed)) {
                underruns.fetch_add(1, std::memory_order_relaxed);
            }
            primed.store(false, std::memory_order_relaxed); // re-buffer (fast)
        }
        readFrames.store(r + have, std::memory_order_release);
    }
};

@interface LyriaClient : NSObject

/// Raw ring pointer for the audio render thread (stable for the lifetime of
/// the client). Outputs silence whenever the stream isn't primed.
- (LyriaAudioRing*)ring;

/// Open the socket, run setup, replay the cached prompts/config, then PLAY.
/// No-op if already connecting/connected.
- (void)connectWithApiKey:(NSString*)apiKey;

/// Hard cutoff: best-effort STOP, cancel the socket, clear the ring. Safe to
/// call repeatedly from any state.
- (void)disconnect;

/// Cache (and, if connected, send) the weighted prompts.
/// Each entry: @{ @"text": NSString, @"weight": NSNumber }.
- (void)setWeightedPrompts:(NSArray<NSDictionary*>*)prompts;

/// Merge into the cached musicGenerationConfig (and, if connected, send).
/// Recognized keys: bpm, temperature, density, brightness, scale.
- (void)setConfig:(NSDictionary*)config;

/// Status callback, delivered on the main queue. Values: "idle",
/// "connecting", "buffering", "streaming", or "error: …".
- (void)setStatusHandler:(void (^)(NSString* status))handler;

@end
