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

// JamTranscribe — on-device audio→MIDI via Spotify's Basic Pitch (nmp.onnx,
// Apache-2.0) running on ONNX Runtime (CoreML EP with CPU fallback).
// Blocking; call from a background queue.

#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>
#include <vector>

struct JamNote {
    double start = 0;     // seconds
    double duration = 0;  // seconds
    int pitch = 60;       // MIDI
    float velocity = 0.8f;
};

/// Transcribe interleaved stereo int16 @48 kHz into notes.
/// Returns NO and sets *error on failure.
BOOL JamTranscribe(NSString* modelPath,
                   const int16_t* stereo48k, long frames,
                   std::vector<JamNote>& outNotes,
                   void (^progress)(float),
                   NSString* __strong * error);

/// Write notes as a single-track Standard MIDI File (type 0) at `bpm`.
BOOL JamWriteMidi(NSURL* url, const std::vector<JamNote>& notes, double bpm);

/// Parse a Standard MIDI File (type 0/1, tempo-map aware) back into notes,
/// sorted by start time. Returns NO if the file is unreadable or empty.
BOOL JamReadMidi(NSURL* url, std::vector<JamNote>& outNotes);
