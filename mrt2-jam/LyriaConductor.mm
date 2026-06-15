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

#import "LyriaConductor.h"
#import "LyriaClient.h"
#include <atomic>
#include <cmath>

// Measured gateway behavior: every connection is cleanly closed (code 1000)
// at ~600 s with no advance warning. We must hand over BEFORE that, driven
// entirely by our own clock. Times are seconds since the channel connected.
//
// The fade must not begin until the relief channel is actually producing audio
// (its ring is primed) — otherwise we fade into silence. So we open the relief
// early, then start the fade as soon as it is primed (after a short settle),
// with a hard deadline as a backstop if priming is unusually slow.
static const double kPrewarmAt       = 500.0;  // open the relief channel (early → lead time)
static const double kCrossfadeMinAt  = 512.0;  // earliest fade (let the relief settle)
static const double kCrossfadeMaxAt  = 565.0;  // backstop: fade even if not yet primed
static const double kXfadeSec        = 8.0;    // fade duration
// → fade completes by ~573 s at the latest, ~27 s before the 600 s hard close.

static const float kHalfPi = 1.57079632679f;
static const float kSampleRate = 48000.0f;

typedef NS_ENUM(int, ConductorPhase) {
    PhaseSteady = 0,   // one channel streaming
    PhasePrewarmed,    // relief channel connected, not yet fading
    PhaseCrossfading,  // fading primary → relief
};

@interface LyriaConductor ()
- (void)handleChannelDown:(int)idx;
@end

@implementation LyriaConductor {
    LyriaClient* _ch[2];
    LyriaAudioRing* _ring[2];
    NSString* _apiKey;
    NSArray<NSDictionary*>* _cachedPrompts;
    NSMutableDictionary* _cachedConfig;
    void (^_statusHandler)(NSString*);
    void (^_channelsHandler)(NSArray<NSString*>*);
    NSArray<NSString*>* _lastChannelStates;

    BOOL _running;
    int _primary;                 // main-thread only
    ConductorPhase _phase;        // main-thread only
    double _channelConnectAt[2];  // CFAbsoluteTime of each channel's connect
    double _crossfadeStartedAt;
    NSTimer* _timer;
    uint64_t _lastUnderruns[2];   // diagnostics: last logged underrun counts

    // Shared with the audio thread:
    std::atomic<float> _mixTarget; // 0 → ch0, 1 → ch1
    float _mix;                    // audio-thread-local fade position
}

- (instancetype)init {
    if ((self = [super init])) {
        _cachedConfig = [NSMutableDictionary dictionary];
        _mixTarget.store(0.0f);
        _mix = 0.0f;
        _primary = 0;
        for (int i = 0; i < 2; i++) {
            _ch[i] = [[LyriaClient alloc] init];
            _ring[i] = [_ch[i] ring];
            // Forward only error status from either channel; the conductor
            // emits its own lifecycle status (connecting/streaming/relinking).
            __weak LyriaConductor* weakSelf = self;
            const int idx = i;
            [_ch[i] setStatusHandler:^(NSString* status) {
                LyriaConductor* s = weakSelf;
                if (!s) return;
                if ([status hasPrefix:@"error"]) {
                    [s emit:status];
                    // A socket dropping (gateway close, network blip) is the very
                    // thing that causes an audible cut — recover immediately.
                    dispatch_async(dispatch_get_main_queue(), ^{ [s handleChannelDown:idx]; });
                }
            }];
        }
    }
    return self;
}

- (void)setStatusHandler:(void (^)(NSString*))handler {
    _statusHandler = [handler copy];
}

- (void)setChannelStateHandler:(void (^)(NSArray<NSString*>*))handler {
    _channelsHandler = [handler copy];
}

// Compute each channel's indicator state and push it to the UI when it changes.
//   "playing" → steady lit (audible output)
//   "warming" → fast blink (connected/prewarming, not yet audible)
//   "off"     → dark (not connected)
- (void)broadcastChannelStates {
    NSString* s0 = @"off";
    NSString* s1 = @"off";
    if (_running) {
        const int other = 1 - _primary;
        NSString* prim = @"playing";
        NSString* oth  = @"off";
        if (_phase == PhasePrewarmed)      oth = @"warming";
        else if (_phase == PhaseCrossfading) oth = @"playing";
        if (_primary == 0) { s0 = prim; s1 = oth; }
        else               { s1 = prim; s0 = oth; }
    }
    NSArray<NSString*>* states = @[s0, s1];
    if ([states isEqualToArray:_lastChannelStates]) return;
    _lastChannelStates = states;
    if (_channelsHandler) {
        void (^h)(NSArray<NSString*>*) = _channelsHandler;
        dispatch_async(dispatch_get_main_queue(), ^{ h(states); });
    }
}

- (void)emit:(NSString*)status {
    if (_statusHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_statusHandler) self->_statusHandler(status);
        });
    }
}

// ─── Audio thread: equal-power mix of both rings ─────────────────────────────

- (void)readStereoLeft:(float*)L right:(float*)R frames:(size_t)frames {
    const float target = _mixTarget.load(std::memory_order_relaxed);
    const float step = 1.0f / (kXfadeSec * kSampleRate);
    float mix = _mix;

    // Process in windows so the per-channel temp buffers stay small. Both
    // rings are always drained (a silent/unprimed ring yields zeros and does
    // not advance), so the relief channel stays time-aligned while prewarming.
    constexpr size_t kWin = 512;
    float l0[kWin], r0[kWin], l1[kWin], r1[kWin];
    size_t done = 0;
    while (done < frames) {
        const size_t n = (frames - done < kWin) ? (frames - done) : kWin;
        _ring[0]->readStereo(l0, r0, n);
        _ring[1]->readStereo(l1, r1, n);
        for (size_t i = 0; i < n; i++) {
            if (mix < target)      { mix += step; if (mix > target) mix = target; }
            else if (mix > target) { mix -= step; if (mix < target) mix = target; }
            const float g0 = cosf(mix * kHalfPi);
            const float g1 = sinf(mix * kHalfPi);
            L[done + i] = l0[i] * g0 + l1[i] * g1;
            R[done + i] = r0[i] * g0 + r1[i] * g1;
        }
        done += n;
    }
    _mix = mix;
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)connectWithApiKey:(NSString*)apiKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_running) return;
        if (apiKey.length == 0) { [self emit:@"error: no api key"]; return; }
        self->_apiKey = [apiKey copy];
        self->_running = YES;
        self->_primary = 0;
        self->_phase = PhaseSteady;
        self->_mixTarget.store(0.0f);
        self->_mix = 0.0f;

        [self emit:@"connecting"];
        [self->_ch[0] connectWithApiKey:apiKey];
        self->_channelConnectAt[0] = CFAbsoluteTimeGetCurrent();
        NSLog(@"Lyria conductor: connect primary ch0 (prewarm@%.0fs xfade@%.0f-%.0fs)",
              kPrewarmAt, kCrossfadeMinAt, kCrossfadeMaxAt);

        self->_timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        target:self
                                                      selector:@selector(tick)
                                                      userInfo:nil
                                                       repeats:YES];
        [self broadcastChannelStates];
    });
}

- (void)disconnect {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_running = NO;
        [self->_timer invalidate];
        self->_timer = nil;
        [self->_ch[0] disconnect];
        [self->_ch[1] disconnect];
        self->_mixTarget.store(0.0f);
        self->_phase = PhaseSteady;
        [self emit:@"idle"];
        [self broadcastChannelStates];
    });
}

// ─── Rolling crossfade schedule (main queue) ─────────────────────────────────

- (void)tick {
    if (!_running) return;
    const double now = CFAbsoluteTimeGetCurrent();
    const double elapsed = now - _channelConnectAt[_primary];
    const int other = 1 - _primary;

    // Reprime depth: deep jitter buffer when a single stream is live; short
    // during a handover (both channels share bandwidth → keep recovery gaps
    // brief so the crossfade doesn't stall for seconds).
    const uint64_t reprime = (_phase == PhaseSteady)
        ? (uint64_t)LyriaAudioRing::kReprimeSteady
        : (uint64_t)LyriaAudioRing::kReprimeXfade;
    for (int i = 0; i < 2; i++)
        if (_ring[i]) _ring[i]->reprimeFrames.store(reprime, std::memory_order_relaxed);

    // Surface audio-ring underruns (network jitter starving the buffer) — these
    // are the silent cutouts that leave no socket error behind.
    for (int i = 0; i < 2; i++) {
        if (!_ring[i]) continue;
        const uint64_t u = _ring[i]->underruns.load(std::memory_order_relaxed);
        if (u != _lastUnderruns[i]) {
            NSLog(@"Lyria conductor: ch%d audio UNDERRUN (count=%llu)%s — buffer starved (network jitter)",
                  i, (unsigned long long)u, i == _primary ? " [PRIMARY]" : "");
            _lastUnderruns[i] = u;
        }
    }

    switch (_phase) {
        case PhaseSteady:
            if (elapsed >= kPrewarmAt) {
                // Silently open the relief channel with the same prompts/config.
                [_ch[other] setWeightedPrompts:_cachedPrompts];
                [_ch[other] setConfig:_cachedConfig];
                [_ch[other] connectWithApiKey:_apiKey];
                _channelConnectAt[other] = now;
                _phase = PhasePrewarmed;
                [self emit:@"relinking"];
                NSLog(@"Lyria conductor: prewarm relief ch%d at primary elapsed=%.0fs", other, elapsed);
            }
            break;

        case PhasePrewarmed: {
            // Only fade once the relief is actually streaming (ring primed), so
            // we never fade into silence. Backstop forces it near the deadline.
            const BOOL reliefReady = _ring[other] &&
                _ring[other]->primed.load(std::memory_order_relaxed);
            const BOOL forced = elapsed >= kCrossfadeMaxAt;
            if ((elapsed >= kCrossfadeMinAt && reliefReady) || forced) {
                _mixTarget.store(other == 1 ? 1.0f : 0.0f);
                _crossfadeStartedAt = now;
                _phase = PhaseCrossfading;
                NSLog(@"Lyria conductor: crossfade start elapsed=%.0fs reliefPrimed=%d%s",
                      elapsed, reliefReady, forced && !reliefReady ? " (FORCED, relief not primed!)" : "");
            }
            break;
        }

        case PhaseCrossfading:
            if (now - _crossfadeStartedAt >= kXfadeSec) {
                [_ch[_primary] disconnect];   // spent channel released
                _primary = other;
                _phase = PhaseSteady;
                [self emit:@"streaming"];
                NSLog(@"Lyria conductor: handover complete, primary now ch%d", other);
            }
            break;
    }

    [self broadcastChannelStates];
}

// ─── Early-loss recovery ─────────────────────────────────────────────────────
// If the *primary* channel drops before our scheduled handover, bring the relief
// up right now and let the prewarmed→crossfade gate fire as soon as it primes.
- (void)handleChannelDown:(int)idx {
    if (!_running) return;
    if (idx != _primary) return;          // a relief/spent channel closing is expected
    if (_phase != PhaseSteady) return;    // a handover is already in flight
    NSLog(@"Lyria conductor: primary ch%d dropped early — accelerating handover", idx);
    const int other = 1 - _primary;
    const double now = CFAbsoluteTimeGetCurrent();
    [_ch[other] setWeightedPrompts:_cachedPrompts];
    [_ch[other] setConfig:_cachedConfig];
    [_ch[other] connectWithApiKey:_apiKey];
    _channelConnectAt[other] = now;
    // Backdate the primary so the crossfade gate is already past its min and
    // fires the instant the relief primes.
    _channelConnectAt[_primary] = now - kCrossfadeMinAt;
    _phase = PhasePrewarmed;
    [self emit:@"relinking"];
}

// ─── Prompts / config broadcast to all live channels ─────────────────────────

- (void)setWeightedPrompts:(NSArray<NSDictionary*>*)prompts {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (prompts.count == 0) return;
        self->_cachedPrompts = [prompts copy];
        [self->_ch[0] setWeightedPrompts:prompts];
        [self->_ch[1] setWeightedPrompts:prompts];
    });
}

- (void)setConfig:(NSDictionary*)config {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_cachedConfig addEntriesFromDictionary:config];
        [self->_ch[0] setConfig:config];
        [self->_ch[1] setConfig:config];
    });
}

@end
