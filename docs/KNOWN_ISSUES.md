# Known Issues

## Multichannel per-channel (click) routing does not reach discrete USB outs

**Status:** Open / not fixed. Deferred — do not chase before a live show; the
fix touches the audio graph and is risky to rush.

**Severity:** Feature-level. Normal stereo output is unaffected. Only the
opt-in "多通道输出 / multichannel out" router (sending the main mix and the
metronome click to *different* physical device channels) is broken.

### Symptom

On a genuine 4-output USB interface (teenage engineering **EP-136**, reports
`8 in / 4 out @ 48 kHz`), routing the click to Output 3/4 and the main mix to
Output 1/2 does **not** separate them physically: the cue output carries the
same audio as the main output. The same EP-136 separates all four outputs
correctly in **djay Pro**, so the device and its drivers are fine — the problem
is on our side.

### What is proven (so it is NOT the bug)

A render-block diagnostic (now removed; see git history of `JamApp.mm`,
commit `f83ba0b` and the WIP commits around 2026-06-24) confirmed:

- The device is opened at **4 channels @ 48 kHz**;
  `outputNode.outputFormatForBus:0` = 4 ch.
- The render block receives **`mNumberBuffers = 4`**, non-interleaved, one
  buffer per channel.
- The router writes **distinct** signal to each buffer. With main = Output 1/2
  (mask `0x3`) and click = Output 4 (mask `0x8`), per-channel peaks were:
  `pk[0..3] = 0.45 0.36 0.000 0.397` — i.e. music on buffers 0/1, click on
  buffer 3, silence on buffer 2, exactly as intended.

So everything up to and including writing the four output buffers is correct.
The collapse to outs 1/2 happens **downstream**, inside AVAudioEngine's
delivery of those buffers to the device.

### Fixes already in place (necessary but not sufficient)

In `JamApp.mm` `-connectSourceNodeForCurrentDevice` (multichannel branch):

1. Connect the multichannel `AVAudioSourceNode` **directly to `outputNode`**,
   bypassing `mainMixerNode`. `mainMixerNode` is a stereo-oriented downmixer and
   folded channels 3+ back into L/R.
2. Build the source node from the **outputNode's exact output-format object**
   (`devFmt`) instead of a fresh `initStandardFormatWithSampleRate:channels:`.
   The "standard" 4-ch format carries a **quadraphonic channel-layout tag** that
   mismatched the device's discrete-channel layout, causing the engine to insert
   a spatialising converter that delivered only 2 buffers (`mNumberBuffers = 2`).
   After this, the render block gets 4 discrete buffers (see "proven" above).

These two are correct and should stay — without them the render block never even
sees 4 channels. They just are not enough on their own.

### What was tried and did NOT work

- Setting an **identity `AUAudioUnit.channelMap`** (`[0,1,2,3]`) on the source
  node. The default was `(null)`. Setting identity did not change the physical
  result — cue still mirrored main. (Reverted.)

### Leads for a real fix (when there is time)

- **AUHAL output-unit channel map.** Set
  `kAudioOutputUnitProperty_ChannelMap` (scope `kAudioUnitScope_Output`,
  element 0) on `outputNode.audioUnit` via the C API, sized to the device's
  output channel count. This is the canonical CoreAudio mechanism and is what
  pro DJ/multi-out apps use; the high-level `AVAudioNode.AUAudioUnit.channelMap`
  may not be the surface that actually controls device routing here.
- **Native sample rate.** The EP-136 reports 48 kHz but its real clock measured
  **~44.1 kHz** (`[SpeedComp] measured device content rate 44099 Hz -> comp
  1.0885`). The app deliberately forces 48 kHz and time-stretches to compensate.
  It is possible AVAudioEngine inserts a stereo-only rate/format converter on
  the output path for this lying device that collapses >2 channels. Worth
  testing the device opened at its native rate.
- **Bypass AVAudioEngine for output.** A raw AUHAL / CoreAudio HAL output unit
  with an explicit channel map gives full control and is how djay Pro does it.
  Largest change; keep as last resort.

### Reproduction

1. Connect a true ≥4-out USB interface; make it the default output device.
2. In the app, open the routing popover, enable 多通道输出.
3. Main → Output 1/2, Click → Output 3 (or 4).
4. Play, and monitor the device's second physical output (EP-136 cue jack).
   Expected: click only. Actual: same as main.
