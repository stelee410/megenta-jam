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

// LyriaConductor — seamless "infinite" playback over the Lyria RealTime
// gateway, which hard-closes every connection at ~10 minutes (clean code
// 1000, no GoAway warning — measured empirically). The gateway exposes no
// session-resumption, so we use the dual-channel DJ crossfade approach:
//
//   - Two LyriaClient instances (channel 0 and 1), each with its own ring.
//   - One channel streams to the output at a time. ~75 s before the active
//     channel's 10-minute deadline, the idle channel is silently connected
//     with the same cached prompts/config; ~60 s before, an equal-power
//     crossfade hands the output over to it; the spent channel is then
//     disconnected. Roles alternate, giving hours of gapless playback.
//
// Cost-control contract (unchanged from LyriaClient): sockets only exist
// while actively playing. disconnect() hard-cuts BOTH channels and is called
// on pause, engine switch, and app termination. The only extra cost is ~20 s
// of double-billing per 10-minute cycle (the prewarm + fade overlap).
//
// Drop-in surface-compatible with LyriaClient so the app wiring barely changes.

#pragma once
#import <Foundation/Foundation.h>

@interface LyriaConductor : NSObject

/// Audio-thread-safe: mix both channels' rings by the current equal-power
/// crossfade position into interleaved-free L/R buffers. Silence until primed.
- (void)readStereoLeft:(float*)L right:(float*)R frames:(size_t)frames;

/// Open the primary channel, replay cached prompts/config, PLAY, and arm the
/// rolling crossfade schedule. No-op if already running.
- (void)connectWithApiKey:(NSString*)apiKey;

/// Hard cutoff: cancel the schedule and disconnect BOTH channels.
- (void)disconnect;

/// Cache + broadcast weighted prompts to all live channels.
- (void)setWeightedPrompts:(NSArray<NSDictionary*>*)prompts;

/// Cache + broadcast musicGenerationConfig to all live channels.
- (void)setConfig:(NSDictionary*)config;

/// Status callback on the main queue (idle / connecting / buffering /
/// streaming / relinking / error: …).
- (void)setStatusHandler:(void (^)(NSString* status))handler;

@end
