# mrt2-jam (VerveFlow) 重构评估与路线图

> 2026-07-08 · 基于四路并行代码分析(控制器 / 音频引擎 / React UI / ML 管线),
> 所有发现均经 grep/构建交叉验证。行号以本文档提交时的工作树为准,后续会漂移。
>
> **总原则**:这是上台演出的应用,稳定性优先。本轮只自动实施了"行为保持、
> 构建可验证"的低风险项(见 §1);所有结构性重构列入路线图(§3),需人工决策后分批做。

## 0. 代码现状概览

| 区域 | 规模 | 状态评价 |
|---|---|---|
| JamAppController.mm | 5649 行,单类 118 方法 | God Object:8 个子系统混在一个类里 |
| JamApp.mm | ~1830 行 | AppDelegate + ~650 行单体 render block |
| JamSynth.h / JamModular.h / JamLaneFx.h | 762/627/104 行 | 头文件内联 DSP,质量好,但原语曾重复(已修) |
| ui/src(React) | ~9.1k 行 | App.tsx 独占 4312 行(101 个 useState,0 个 useMemo) |
| ML 管线(Roformer/Transcribe/Separate/Lyria) | ~1.9k 行 | 功能干净,但 ORT 样板 4 份拷贝、重采样器 3 套 |
| common/ | ~1.1k 行 | **整目录是 examples/common/ 的逐字节副本** |

**好的部分**(分析确认,不需要动):
- 硬实时 DSP(JamSharedState 内联、JamSynth、JamModular)无锁、无分配、无日志,干净;
- UI→native 消息出口单点收敛(`sendStateUpdate:` → 唯一一处 `evaluateJavaScript`);
- UI 发送端单点封装(`post()`),面板内部零桥接调用;
- VisualLayer 用 ref + rAF 解耦 25Hz 数据推送,不触发 React 重渲染;
- Lyria 线程模型清晰(main queue 控制面 + 单 atomic 交界);
- 全代码库几乎无死代码、无 `#if 0`/TODO 堆积(死代码仅 3 处,均已删)。

## 1. 本轮已自动实施(每项独立提交,均构建验证)

| 提交 | 内容 | 动机 |
|---|---|---|
| `2351312` | 删除 render block 内仅存的两处 NSLog(SpeedComp 一次性日志、[Solo ramp] ~1Hz 调试日志 + static 计数器) | 渲染线程禁止日志(演出规矩);Foundation 调用可能阻塞/优先级反转 |
| `054f50a` | 三处逐字复制的节拍器 click 生成器(count-in / stem 播放 / looper)合并为 `JamSharedState::triggerClick/tickClick`,重音/常规频率具名化 | 去重;输出逐位一致,各处幅度(0.5/0.4/0.5)保留 |
| `b0de895` | 新建 `JamDsp.h`,合并 JamSynth/JamModular 各自逐字拷贝的 `clamp01f/clampB/polyblep/frand/frand01` | 共享 DSP 原语单一来源 |
| `21cb600` | 控制器:参数地址表 `{0,1,3,…,48}`(3 份拷贝)与 8-stem 名称数组(4 份拷贝)提为文件级常量 | 单一事实来源;新增参数地址时只改一处 |
| `e91394e` | 删除 LyriaClient 只写不读的 `_connecting` 字段(6 处) | 死状态(连接守卫实际用 `_task`) |
| `de84ff4` | UI:删除 0 使用的 JamSlider.tsx / JamSliderElastic.tsx(-476 行);StudioPanel / InstrumentPanel / ModularPanel / VisualLayer 加 `React.memo` | 死代码;App 以 ~25Hz(audioLevels/metrics 推送)全量重渲染,memo 隔离未变 props 的子树 reconcile |

## 2. 分析发现但**未**自动实施的问题(按风险分级)

### 2.1 实时/线程安全(建议优先人工处理)

- **render block 内的 objc_msgSend**:`JamApp.mm` Lyria 分支
  `[lyriaConductor readStereoLeft:right:frames:]` 是渲染路径上唯一一处 ObjC 派发。
  建议 LyriaConductor 暴露 C++/函数指针读接口。仅 Lyria 云模式受影响。
- **麦克风采集 tap 的锁与分配**(`JamAppController.mm` `beginMicCapture`):
  tap 回调(音频采集线程)内每次 `[[AVAudioPCMBuffer alloc] …]` 堆分配 +
  `@synchronized` 与主线程 `stopRecordingAudioPrompt` 竞争同一把锁;
  `_isRecording` 是非原子 BOOL 跨线程读写。建议改为 SPSC ring(仓库里
  `pushLiveNote` 已有同型范式)。注意:这是采集线程,不是主渲染线程,危害低一级。
- **`resampleTo16k` 的 static 滤波表惰性初始化非线程安全**
  (`JamTranscribePiano.mm`),当前靠调用方 `gPtMutex` 隐式保护——脆弱耦合,
  建议改 constexpr 表或 `std::once_flag`。

### 2.2 结构性(收益大,需设计决策)

- **JamAppController 拆分**(最大杠杆,5649 → 预计 4 个 ~1.5k 文件):
  `JamStudioController`(34 方法,约占 40%)、`JamModelManager`(23 方法,
  下载状态机)、`JamLooperController` + `JamLaneController`、剩余为核心桥接。
- **消息桥 106 分支 if-else**(`didReceiveScriptMessage:` 约 1000 行):
  改为 消息类型→handler 的 dispatch table,按 `studio*/lane*/loop*/ai*` 前缀
  路由到拆分后的子控制器。每个分支体已基本是 `[self handleXxx:]`,机械可拆。
- **render block 拆分**(~650 行 → ~20 个阶段):各阶段已用裸 `{}` 隔离、
  只通过 `outL/outR/clickBus/genFrames` 传递,可逐段提取为 `JamSharedState`
  的 **C++ 成员函数**(切勿 ObjC 方法/std::function,会引入 msgSend/堆分配)。
  建议每次只提一段、构建 + 试听验证后再提下一段。
- **App.tsx 拆分**(4312 行):`window.updateState` 巨型处理器(~545 行,
  ~70 个字段)+ 分域 state 收敛为 `useStudio/useSynth/useModular/useAiAssist/
  useLyria` 等 hooks;为 native 推送定义 `NativeStateUpdate` 类型(目前 `any`,
  是全 UI 最高杠杆的类型改进)。StudioPanel 的 50 个 props 随 hook 化收敛。
- **common/ 整目录与 examples/common/ 逐字节重复**(diff 验证 6 文件全同):
  应在构建系统层共享同一份源(符号链接或静态库),而非拷贝。改 CMake,人工做。

### 2.3 一般代码质量(低风险,可随手做)

- ORT session 创建样板 4 份拷贝(`ensure*Session` × Roformer×2/Transcribe/
  TranscribePiano),差异仅线程数/优化级别/EP,可参数化为一个 helper;
- Roformer 内部 Vocals 与 SWStem 两份复制的"reflect-pad + STFT + OLA + 归一化"
  骨架(数值代码,合并后需 A/B 听感验证);
- 三套重采样器(sinc/45-tap/线性)+ 一处内联,可统一到 `common/cpp` 的 dsp 头;
- `32767/32768` int16 转换表达式 30+ 处、`isKindOfClass:[NSNumber]` 取值样板
  76 处、`dispatch_async(global→main)` 骨架 40+ 处——各值一个 helper;
- `studioPush*` 家族 16 个同构方法可表驱动收敛;
- 错误处理吞错点:`JamSeparate.mm` 忽略 `ExtAudioFileSetProperty` 返回值、
  `LyriaClient.mm` JSON 解析错误静默丢弃、`MagentaModelDownloader.mm`
  `createDirectoryAtPath:error:nil`;
- ML session 均为进程级常驻缓存(有意的性能设计),但缺统一的
  `releaseAllSessions()` 内存回收入口;
- UI:`Knob`(ModularPanel)与 `FreakKnob`(InstrumentPanel)是近双胞胎
  (FreakKnob 是超集),可合并;指针拖拽三连样板 6 处可抽 `useDragValue`;
  内联 `sx`/`buttonSx` 对象 23 处可提常量;App.tsx 0 个 useMemo。
- `JamAppController.h:103` `stemMask` 自注释 "legacy (unused by the mixer)",
  渲染回调确认后可删。

## 3. 建议执行顺序(路线图)

1. **[小]** render 内 lyriaConductor 调用改 C++ 接口;mic tap 改 SPSC ring(§2.1)
2. **[小]** ORT session helper + 吞错误点补日志(§2.3)
3. **[中]** 消息桥 dispatch table 化——为第 4 步铺路(§2.2)
4. **[大]** JamAppController 拆分四个子控制器,handler 跟随迁移(§2.2)
5. **[中]** render block 逐段提取为 JamSharedState 成员函数,每段试听(§2.2)
6. **[中]** App.tsx hooks 化 + `NativeStateUpdate` 类型(§2.2)
7. **[中]** common/ 构建级共享,消除整树拷贝(§2.2)
8. **[听感]** 三处 Schroeder 混响(LaneFx / performanceFX / modular space)
   是否合并——音色会变,必须 A/B 试听,放最后

每步的验收标准:构建通过 + 应用启动 + 音频绑定正常(多输出设备)+
MIDI→发声端到端可听 + 相关功能手动过一遍。演出前一周冻结重构。
