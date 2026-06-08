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
static const double kPrewarmAt   = 530.0;  // open the relief channel
static const double kCrossfadeAt = 545.0;  // begin the equal-power fade
static const double kXfadeSec    = 8.0;    // fade duration (completes ~553 s)
// → ~47 s safety margin before the 600 s hard close.

static const float kHalfPi = 1.57079632679f;
static const float kSampleRate = 48000.0f;

typedef NS_ENUM(int, ConductorPhase) {
    PhaseSteady = 0,   // one channel streaming
    PhasePrewarmed,    // relief channel connected, not yet fading
    PhaseCrossfading,  // fading primary → relief
};

@implementation LyriaConductor {
    LyriaClient* _ch[2];
    LyriaAudioRing* _ring[2];
    NSString* _apiKey;
    NSArray<NSDictionary*>* _cachedPrompts;
    NSMutableDictionary* _cachedConfig;
    void (^_statusHandler)(NSString*);

    BOOL _running;
    int _primary;                 // main-thread only
    ConductorPhase _phase;        // main-thread only
    double _channelConnectAt[2];  // CFAbsoluteTime of each channel's connect
    double _crossfadeStartedAt;
    NSTimer* _timer;

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
            [_ch[i] setStatusHandler:^(NSString* status) {
                if ([status hasPrefix:@"error"]) [weakSelf emit:status];
            }];
        }
    }
    return self;
}

- (void)setStatusHandler:(void (^)(NSString*))handler {
    _statusHandler = [handler copy];
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

        self->_timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        target:self
                                                      selector:@selector(tick)
                                                      userInfo:nil
                                                       repeats:YES];
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
    });
}

// ─── Rolling crossfade schedule (main queue) ─────────────────────────────────

- (void)tick {
    if (!_running) return;
    const double now = CFAbsoluteTimeGetCurrent();
    const double elapsed = now - _channelConnectAt[_primary];
    const int other = 1 - _primary;

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
            }
            break;

        case PhasePrewarmed:
            if (elapsed >= kCrossfadeAt) {
                _mixTarget.store(other == 1 ? 1.0f : 0.0f);
                _crossfadeStartedAt = now;
                _phase = PhaseCrossfading;
            }
            break;

        case PhaseCrossfading:
            if (now - _crossfadeStartedAt >= kXfadeSec) {
                [_ch[_primary] disconnect];   // spent channel released
                _primary = other;
                _phase = PhaseSteady;
                [self emit:@"streaming"];
            }
            break;
    }
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
