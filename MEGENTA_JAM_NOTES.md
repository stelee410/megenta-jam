# Megenta Jam Notes

## Current Direction

This project starts from Google Magenta RealTime 2 and uses the official Jam app
as the first runnable base. The target model is `mrt2_base`.

The current machine is suitable for this route:

- Apple M5 Max
- 128 GB memory
- Xcode 26.5

## Local Setup Completed

- Repository cloned from `magenta/magenta-realtime`.
- Python 3.12 virtual environment created at `.venv/`.
- Installed local `magenta-rt[mlx]`.
- Installed CMake through the Python environment.
- Installed Xcode Metal Toolchain with:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## Model Assets

Assets are in the official default location:

```text
~/Documents/Magenta/magenta-rt-v2/
```

Downloaded:

- Shared MusicCoCa resources
- Shared SpectroStream resources
- `models/mrt2_base/mrt2_base.mlxfn`
- `models/mrt2_base/mrt2_base_state.safetensors`

## Smoke Test

Command:

```bash
source .venv/bin/activate
mrt mlx generate --prompt "disco funk" --duration 1.0 --model=mrt2_base
```

Result:

- Generated 25 frames in 0.5s.
- 20.8 ms/step.
- Real-time target is 40 ms/step.
- Output saved to:

```text
~/Documents/Magenta/magenta-rt-v2/outputs/output_audio_mlx_mrt2_base.wav
```

## Jam App

Built and deployed:

```bash
source .venv/bin/activate
cmake --build build --target deploy_mrt2_jam -j10
```

App location:

```text
~/Applications/MRT2 - Jam.app
```

## Build Troubleshooting

If selecting a model crashes during `load_model`, check whether MLX generated
bad Metal JIT sources before the Xcode Metal Toolchain was installed.

The failure looked like an uncaught exception from:

```text
mlx::core::metal::Device::build_library_
```

with Metal compiler errors such as missing `bfloat16_t` or `complex64_t`.

Fix:

```bash
rm -f build/_deps/mlx-build/mlx/backend/metal/jit/*.cpp \
  build/_deps/mlx-build/CMakeFiles/mlx.dir/mlx/backend/metal/jit/*.o \
  build/_deps/mlx-build/CMakeFiles/mlx.dir/mlx/backend/metal/jit/*.o.d

source .venv/bin/activate
cmake --build build --target hello_mrt2 deploy_mrt2_jam -j10
```

Then verify:

```bash
./build/examples/hello_mrt2/hello_mrt2 \
  ~/Documents/Magenta/magenta-rt-v2/models/mrt2_base/mrt2_base.mlxfn \
  ~/Documents/Magenta/magenta-rt-v2/resources \
  25 \
  --prompt "disco funk"
```

## Next Product Work

Recommended next step: customize `mrt2-jam/ui/src/App.tsx` and related Jam
UI components while keeping the native host, MIDI, audio, and model loading code
mostly intact.

High-value MVP changes:

- Make `mrt2_base` the explicit first-run recommendation in the UI.
- Simplify model onboarding for the already downloaded base model.
- Design a performance-first Jam interface: prompt presets, chord pads, active
  notes, audio meter, and a compact generation settings panel.
- Keep `mrt2_small` available later as fallback, but do not optimize the first
  version around it.
