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

// JamTranscribePiano — piano-specialized audio→MIDI via ByteDance's
// high-resolution piano transcription CRNN (Kong et al. 2020, MIT,
// note onset F1 = 96.7% on MAESTRO), exported to ONNX and run on
// ONNX Runtime. Far more accurate than Basic Pitch on piano material.
// Blocking; call from a background queue.

#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>
#include <vector>
#include "JamTranscribe.h"   // JamNote

/// Transcribe interleaved stereo int16 @48 kHz piano audio into notes.
/// `modelPath` points at piano_crnn.onnx. Returns NO and sets *error on failure.
BOOL JamTranscribePiano(NSString* modelPath,
                        const int16_t* stereo48k, long frames,
                        std::vector<JamNote>& outNotes,
                        void (^progress)(float),
                        NSString* __strong * error);
