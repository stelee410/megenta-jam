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

// JamRoformer — SOTA vocal separation via a BS-RoFormer-family model
// (band-split transformer, ByteDance SDX'23 architecture; PolarFormer ONNX
// export, MIT). STFT/iSTFT run in vDSP; the ONNX graph estimates a complex
// spectral mask for the vocals. Blocking; call from a background queue.

#pragma once
#import <Foundation/Foundation.h>
#include <vector>

/// Separate vocals from a stereo 48 kHz float mix.
/// Returns 48 kHz vocals in vocL/vocR (same length as the input).
BOOL JamRoformerVocals(NSString* modelPath,
                       const float* inL, const float* inR, long frames48k,
                       std::vector<float>& vocL, std::vector<float>& vocR,
                       void (^progress)(float),
                       NSString* __strong * error);
