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

// JamSeparate — neural 4-stem separation (htdemucs via the vendored
// demucs.cpp) behind a small ObjC++ facade so the controller stays free of
// Eigen headers. All functions are blocking; call from a background queue.

#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>
#include <vector>

/// True if a ggml htdemucs weights file exists at `path`.
BOOL JamDemucsAvailable(NSString* path);

/// Separate the audio file at `songURL` into stems, each interleaved stereo
/// int16 at 48 kHz, song-length. With 4-source weights the order is
/// drums/bass/other/vocals; 6-source adds guitar/piano. `*outCount` receives
/// 4 or 6. `progress` is called on the calling thread with 0..1. Returns NO
/// and sets `*error` on failure.
BOOL JamDemucsSeparate(NSString* modelPath,
                       NSURL* songURL,
                       std::vector<int16_t> stems[6],
                       int* outCount,
                       void (^progress)(float),
                       NSString* __strong * error);
