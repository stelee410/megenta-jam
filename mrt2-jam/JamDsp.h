// Shared realtime DSP primitives for the synth/voice headers (JamSynth,
// JamModular, …). Header-only free functions: pure, stateless, no
// allocation, no locking — safe to call from the audio render thread.
// These were previously duplicated verbatim inside each synth struct;
// keep additions here equally branch-light.
#pragma once

#include <cstdint>

inline float clamp01f(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }
inline float clampB(float v) { return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v); }

// PolyBLEP residual for band-limited saw/square edges.
inline float polyblep(float t, float dt) {
    if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
    if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
    return 0.0f;
}

// xorshift32 noise, mapped to [-1, 1) / [0, 1).
inline float frand(uint32_t& s) {
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    return (float)(int32_t)s * (1.0f / 2147483648.0f);
}
inline float frand01(uint32_t& s) { return frand(s) * 0.5f + 0.5f; }
