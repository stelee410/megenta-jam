# MRT2 - Jam 使用说明

## 1. 软件定位

`MRT2 - Jam` 是基于 Google Magenta RealTime 2 的实时 AI jam 乐器。它不是传统采样器，也不是固定伴奏播放器，而是一个会根据你的文字/音频 prompt 和 MIDI 音符持续生成音乐的实时乐器。

当前项目优先使用 `mrt2_base` 模型，适合在 Apple Silicon Max/Pro 级机器上进行实时演奏。

## 2. 启动方式

已构建好的 app 在：

```text
~/Applications/MRT2 - Jam.app
```

双击打开即可。也可以在终端启动：

```bash
open "$HOME/Applications/MRT2 - Jam.app"
```

模型和共享资源默认存放在：

```text
~/Documents/Magenta/magenta-rt-v2/
```

## 3. 第一次使用

1. 打开 `MRT2 - Jam.app`。
2. 在底部 `MODEL` 菜单选择 `mrt2_base`。
3. 在底部 `MIDI INPUT` 选择输入方式：
   - `Computer Keyboard`：用电脑键盘演奏。
   - 外接 MIDI 设备：用 MIDI 键盘或控制器演奏。
4. 在中间 prompt 区输入风格描述，例如：

```text
disco funk with tight drums and warm bass
```

5. 按播放按钮开始生成声音。
6. 按屏幕键盘、电脑键盘或 MIDI 键盘触发音符。

如果没有选择模型，播放按钮会不可用。

## 4. 主界面说明

### 4.1 模式：Jam / Solo

左上角有两个模式：

- `Jam`：模型会围绕你的音符和 prompt 生成完整音乐，通常更像伴奏、合奏或 jam band。
- `Solo`：模型更倾向于只演奏你输入的音符，适合把模型当成某种可演奏音色或独奏乐器。

切换模式时，preset 列表也会切换。`Jam` 更偏风格/编曲 prompt，`Solo` 更偏乐器/音色 prompt。

### 4.2 Prompt 区

中间的大文本框是最核心的控制区。

你可以输入文字 prompt，例如：

```text
ambient pads with soft arpeggios
```

```text
lofi drums, mellow electric piano, tape warmth
```

```text
distorted synth bass and aggressive breakbeat
```

输入后模型会异步编码 prompt。右上角出现小圆形 loading 时，表示 prompt 正在更新。按 `Enter` 或让输入框失焦，会立即发送当前 prompt。

### 4.3 Preset Rocker

Prompt 区左右两侧的箭头用于切换 preset：

- 左箭头：上一个 preset。
- 右箭头：下一个 preset。

当你修改了当前 prompt，右下角会出现保存按钮。点击后会把当前文本保存为该 preset 槽位的自定义内容。

### 4.4 Audio Prompt

Prompt 区右下角的上传按钮可以选择音频文件作为 prompt。音频 prompt 会用音频本身的风格/音色/质感影响生成结果。

上传音频后：

- 文本输入框会变为音频 prompt 状态。
- 右下角会出现关闭按钮。
- 点击关闭按钮可以清除音频 prompt，回到文本 prompt。

### 4.5 播放、重置、设置

右上角有三个主要按钮：

- `Reset`：重置模型状态，让生成从当前 prompt 和当前设置重新开始。
- `Play/Pause`：开始或暂停输出。
- `Settings`：打开详细设置面板。

空格键也可以切换播放/暂停，但输入框聚焦时不会触发。

## 5. 演奏方式

### 5.1 屏幕钢琴键盘

界面下方是可点击的钢琴键盘。点击或按住音符会向模型发送 MIDI note on/off。

在未启用电脑键盘 MIDI 时，屏幕键盘显示较宽的音域；启用电脑键盘 MIDI 后，屏幕键盘会对应电脑键盘当前八度。

### 5.2 电脑键盘 MIDI

在底部 `MIDI INPUT` 选择 `Computer Keyboard` 后，可以用电脑键盘演奏。

布局类似 Ableton Live：

```text
白键：A S D F G H J K L ;
黑键：W E T Y U O P
```

默认基准音是 C4。

八度切换：

- `Z`：降低一个八度。
- `X`：升高一个八度。

右上方也会显示当前 C 音所在八度，可以用左右箭头切换。

### 5.3 外接 MIDI

连接 MIDI 键盘后，在底部 `MIDI INPUT` 菜单选择对应设备。右侧的小圆点是 MIDI 活动指示灯，有音符输入时会亮起。

## 6. 常用参数

### 6.1 Chaos

左侧 `Chaos` 滑杆同时控制：

- `Temperature`
- `Top-K Sampling`

它决定生成的随机性和冒险程度。

建议：

- 低 Chaos：更稳定、更可控，适合现场演奏。
- 中 Chaos：更有变化，适合 jam。
- 高 Chaos：更不可预测，适合探索声音，但可能更容易跑偏。

### 6.2 Volume

`Volume` 控制输出音量，内部以 dB 形式传给引擎。首次试音建议把系统音量和 app 音量都放在较保守的位置。

### 6.3 Strength: Notes

`Notes` 控制模型对输入音符的遵循程度。

建议：

- 高值：模型更严格跟随你按下的音符。
- 低值：模型会更自由地补充旋律、和声或变化。

Solo 模式下通常可以把 `Notes` 调高，让它更像“可演奏音色”。

### 6.4 Strength: Style

`Style` 控制模型对 prompt 风格的遵循程度。

建议：

- 高值：更贴近 prompt，但可能牺牲一点自然度。
- 低值：音乐性更自由，prompt 影响变弱。

### 6.5 Timing / Buffer

右下角的 timing 区显示模型生成速度和 buffer 状态。`mrt2_base` 实时目标是每帧 40ms 以内。

如果看到推理时间偏高或有掉帧提示，可以增大 buffer size。更大的 buffer 更稳，但会增加演奏响应延迟。

### 6.6 Audio Meter

右下角的电平条显示左右声道输出电平。没有电平通常表示：

- 没有播放。
- 没有选模型。
- 输出设备/系统音量问题。
- prompt 或模型状态还在加载。
- MIDI gate/演奏状态导致暂时静音。

## 7. 设置面板

点击右上角齿轮/调参按钮进入设置面板。

当前 Jam app 暴露的主要设置：

- `Temperature`：生成随机性。
- `Top-K Sampling`：限制候选 token 数量，越低越保守。
- `No Drums`：鼓组抑制，适合无鼓或旋律乐器场景。
- `Auto-Strum`：按住音符时允许模型持续重新触发、扫弦、琶音或拉弓式变化。
- `Restore Defaults`：恢复默认参数。

## 8. 推荐工作流

### 8.1 快速 jam

1. 选择 `mrt2_base`。
2. 选择 `Computer Keyboard` 或 MIDI 键盘。
3. 使用 `Jam` 模式。
4. 输入一个风格 prompt。
5. 播放。
6. 用音符触发和声或旋律。
7. 调 `Chaos` 找变化，调 `Notes` 找跟手程度，调 `Style` 找风格强度。

### 8.2 把模型当乐器

1. 切到 `Solo`。
2. 输入乐器 prompt，例如：

```text
expressive distorted electric guitar
```

```text
warm analog synth lead
```

```text
bowed cello with intimate room sound
```

3. 把 `Notes` 调高。
4. 关闭或降低鼓相关倾向。
5. 用 MIDI 键盘演奏。

### 8.3 探索声音设计

1. 使用更抽象的 prompt。
2. 提高 `Chaos`。
3. 降低 `Notes`，让模型自由发挥。
4. 反复点击 `Reset`，比较不同生成起点。
5. 找到喜欢的 prompt 后保存到 preset。

## 9. Prompt 编写建议

Prompt 可以描述：

- 音乐风格：`disco funk`、`ambient techno`、`lofi hip hop`
- 乐器：`electric piano`、`808 bass`、`distorted guitar`
- 节奏：`tight drums`、`slow triplet groove`、`breakbeat`
- 声音质感：`tape warmth`、`wide reverb`、`dry intimate room`
- 演奏方式：`arpeggiated`、`strummed`、`legato`、`staccato`

有效 prompt 示例：

```text
deep house groove with warm bass and soft chords
```

```text
cinematic ambient pads, slow evolving harmony, no drums
```

```text
funk guitar riff with tight drums and slap bass
```

```text
solo saxophone, smoky jazz club, expressive vibrato
```

## 10. 常见问题

### 10.1 选择模型后 app 退出

本机曾遇到过一次构建问题：在 Xcode Metal Toolchain 安装前生成了坏的 MLX JIT 文件。已经修复并重新部署。

如果以后重新构建后再次出现，执行：

```bash
rm -f build/_deps/mlx-build/mlx/backend/metal/jit/*.cpp \
  build/_deps/mlx-build/CMakeFiles/mlx.dir/mlx/backend/metal/jit/*.o \
  build/_deps/mlx-build/CMakeFiles/mlx.dir/mlx/backend/metal/jit/*.o.d

source .venv/bin/activate
cmake --build build --target deploy_mrt2_jam -j10
```

### 10.2 没声音

按顺序检查：

1. `MODEL` 是否已经选择 `mrt2_base`。
2. 是否点击了播放。
3. macOS 输出设备和音量是否正确。
4. app 内 `Volume` 是否太低。
5. prompt 是否还在 loading。
6. 是否有 MIDI 输入或屏幕键盘触发。
7. Audio Meter 是否有电平。

### 10.3 延迟太高或声音断续

尝试：

- 增大 buffer size。
- 降低 `Chaos`。
- 关闭其他占用 GPU/CPU 的重型应用。
- 确认使用的是 Apple Silicon 原生运行。

### 10.4 模型列表为空

模型默认目录是：

```text
~/Documents/Magenta/magenta-rt-v2/models/
```

如果模型在别的位置，点击 `MODEL` 菜单里的 `Select custom folder...` 选择模型目录。

### 10.5 外接 MIDI 看不到

尝试：

- 重新插拔 MIDI 设备。
- 重启 app。
- 确认设备在 macOS Audio MIDI Setup 中可见。
- 如果只是试用，先选择 `Computer Keyboard`。

## 11. 当前项目状态

当前已经验证：

- `mrt2_base` 下载完成。
- Python MLX smoke test 通过。
- C++ `hello_mrt2` 生成测试通过。
- `MRT2 - Jam.app` 已部署。
- Metal JIT 构建问题已修复。

后续产品化方向：

- 简化 first-run onboarding。
- 把 `mrt2_base` 明确标为推荐模型。
- 重新设计更适合现场演奏的 prompt/preset/chord pad 界面。
- 增加更清晰的状态提示和错误提示。
