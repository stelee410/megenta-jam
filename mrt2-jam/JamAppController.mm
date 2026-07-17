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

// Jam view controller — hosts the Jam React UI in a WKWebView.
// Simplified from MagentaRTAppController: single prompt, MIDI/waveform visualization.

#import "JamAppController.h"
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#include <vector>
#import "MagentaModelManager.h"
#import "MagentaModelDownloader.h"
#import "MagentaSettings.h"
#import "LyriaClient.h"
#import "LyriaConductor.h"
#import "JamStudio.h"
#import "JamSeparate.h"
#import "JamTranscribe.h"
#import "JamTranscribePiano.h"
#import "JamRoformer.h"
#import "JamHandTracker.h"

static BOOL JamWriteWav(NSURL* url, const int16_t* interleaved, long frames);
#import "JamChords.h"
#define TSF_IMPLEMENTATION
#include "vendor/tsf/tsf.h"
#include "magenta_paths.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

using magentart::core::RealtimeRunner;

// Engine parameter addresses mirrored to the UI (keys resolved through
// MagentaSettings paramKeyForAddress:). One list, used by the metrics
// pusher, connect handshake, and model-loaded push alike.
static const int kBridgedParamAddresses[] = {0,1,3,4,5,6,7,8,9,32,39,46,48};

// Stem slot names, in JamSharedState stem order.
static NSString* const kStemNames[8] = {@"drums", @"bass", @"other", @"vocals",
                                        @"guitar", @"piano", @"aux1", @"aux2"};
using magentart::core::EngineMetrics;

// ─── Dev server probe ────────────────────────────────────────────────────────

static const int kDevServerPort = 62421;

static BOOL isDevServerRunning(void) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 }; // 100ms
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDevServerPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL up = (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) == 0);
    close(sock);
    return up;
}

// ─── WKWebView subclass for keyboard shortcuts ──────────────────────────────

@interface JamWebView : WKWebView
@end

@implementation JamWebView
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars isEqualToString:@"c"]) { [NSApp sendAction:@selector(copy:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"v"]) { [NSApp sendAction:@selector(paste:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"a"]) { [NSApp sendAction:@selector(selectAll:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"x"]) { [NSApp sendAction:@selector(cut:) to:nil from:self]; return YES; }
    }
    return [super performKeyEquivalent:event];
}
@end

// ─── Param helpers ───────────────────────────────────────────────────────────





// Addresses of params to persist across launches


// ─── View Controller ─────────────────────────────────────────────────────────

@interface JamAppController () <WKScriptMessageHandler, WKNavigationDelegate>
- (void)handleSelectDownloadFolder;
- (void)handleListLocalModels;
- (void)handleSelectModel:(NSString*)modelName;
- (void)handleDeleteModel:(NSString*)modelName;
- (void)handleInitResources:(NSString*)modelName;
@end

@implementation JamAppController {
    WKWebView* _webView;
    NSTimer* _metricsTimer;
    NSMutableDictionary* _lastParams;
    int _metricsTicks;

    NSString* _modelName;
    NSString* _currentPromptText;
    BOOL _isPlaying;

    // ── PGM studio ──
    std::vector<float> _songL, _songR;        // original song, 48 kHz
    std::vector<int16_t> _stems[8];           // 6 separated + aux1/aux2
    std::vector<float> _takeL[8], _takeR[8];  // recorded cover takes
    std::vector<float> _prevBufL, _prevBufR;  // active preview buffer
    std::vector<float> _recBufL, _recBufR;    // active recording buffer
    jamstudio::Analysis _songAnalysis;
    NSString* _stemSource[8];   // nil | "neural" | "hpss" | "imported"
    std::vector<JamNote> _stemNotes[8];   // audio→MIDI transcriptions
    std::vector<jamchords::Chord> _chords;
    std::vector<JamNote> _laneClip[8];    // published MIDI clip per stem (UI/package)
    std::vector<JamSharedState::AuxEv> _laneEvBuf[8];  // render-thread event lists
    BOOL _lanePatched[8];                 // lane synth patch applied
    NSDictionary* _lanePatchInfo[8];      // chosen patch {name, origin, params, matrix}
    int _lastPushedOutCh;
    double _cueSec;                       // PGM cue (playback start; -1 = none)
    double _clickAnchorSec;               // click beat-grid anchor (-1 = follow cue)
    tsf* _sfMaster;                       // master SoundFont (lanes share samples)
    BOOL _sfBusy;                         // download/load in flight
    NSString* _songName;
    NSString* _keyOverride;               // manual key label (overrides auto-detect)
    NSString* _songMemo;                  // free-text notes panel content
    IOPMAssertionID _liveAssertionID;     // 现场模式：阻止休眠/锁屏 (0 = none)
    NSTimer* _loopTimer;                  // ~12 Hz push of looper state to the UI
    NSTimer* _modularTimer;               // ~15 Hz push of modular seq step to the UI
    NSURL* _songURL;
    double _songDur;
    BOOL _studioBusy;
    BOOL _coverStartedPlayback;
    BOOL _studioPrevWasActive;
    NSURLSessionDownloadTask* _sepDownload;
    NSTimer* _sepDownloadTimer;
    NSData* _sepResumeData;
    int _sepRetries;
    int64_t _sepLastBytes;
    CFAbsoluteTime _sepLastChange;

    // Audio-prompt recording (mic → 16 kHz mono → engine).
    AVAudioEngine* _recordEngine;
    AVAudioConverter* _recordConverter;
    std::vector<float> _recordSamples;
    BOOL _isRecording;

    JamHandTracker* _handTracker;         // camera gesture control (mix views)
}

// ─── Parameter bridging ──────────────────────────────────────────────────────

- (void)applyParamToEngine:(int)address value:(float)value {
    RealtimeRunner* engine = self.engine;
    if (!engine) return;

    [MagentaSettings applyParamToEngine:engine address:address value:value prefixString:@"Jam"];

    if (address == 4) {
        if (self.cfgNotesSliderValue) {
            self.cfgNotesSliderValue->store(value, std::memory_order_relaxed);
        }
    }
}

- (void)restoreSavedParams {
    [MagentaSettings restoreSavedParams:self.engine prefixString:@"Jam"];
}

- (float)readParamFromEngine:(int)address {
    if (address == 4) {
        return self.cfgNotesSliderValue ? self.cfgNotesSliderValue->load(std::memory_order_relaxed) : kMagentaDefaultCfgNotes;
    }
    return [MagentaSettings readParamFromEngine:self.engine address:address];
}

// ─── View lifecycle ──────────────────────────────────────────────────────────

- (void)loadView {
    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 850, 605)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor colorWithRed:0.96 green:0.94 blue:0.94 alpha:1.0].CGColor;
    self.view = view;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    _isPlaying = NO;

    if (!_webView) {
        WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
        [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
        [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
        @try { [config setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"]; } @catch (NSException *e) { }

        NSString *js = @"window.onerror = function(msg, url, line, col, error) { window.webkit.messageHandlers.auHost.postMessage({type:'log', value:'JS Error: '+msg+ ' @ line '+line}); };"
                       @"var origLog = console.log; console.log = function(msg) { window.webkit.messageHandlers.auHost.postMessage({type:'log', value:''+msg}); origLog(msg); };";
        WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
        [config.userContentController addUserScript:script];
        [config.userContentController addScriptMessageHandler:self name:@"auHost"];

        _webView = [[JamWebView alloc] initWithFrame:self.view.bounds configuration:config];
        _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _webView.navigationDelegate = self;
        [_webView setValue:@(NO) forKey:@"drawsBackground"];
        [self.view addSubview:_webView];

        if (isDevServerRunning()) {
            NSLog(@"Jam: Vite dev server detected on port %d — loading with HMR", kDevServerPort);
            [_webView loadRequest:[NSURLRequest requestWithURL:
                [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%d", kDevServerPort]]]];
        } else {
            NSBundle* bundle = [NSBundle mainBundle];
            NSString* uiPath = [bundle pathForResource:@"index" ofType:@"html" inDirectory:@"jam_ui"];
            if (uiPath) {
                NSURL* url = [NSURL fileURLWithPath:uiPath];
                [_webView loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]];
            } else {
                NSLog(@"Jam: jam_ui/index.html not found in bundle");
            }
        }
    }

    if (_metricsTimer) [_metricsTimer invalidate];
    _metricsTicks = 0;
    _lastParams = [NSMutableDictionary dictionary];

    _metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/25.0
                                                    target:self
                                                  selector:@selector(updateMetrics)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    if (_metricsTimer) { [_metricsTimer invalidate]; _metricsTimer = nil; }
    if (_webView) {
        [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"auHost"];
        [_webView removeFromSuperview];
        _webView = nil;
    }
}

// ─── Metrics polling (25 Hz) ─────────────────────────────────────────────────

- (void)updateMetrics {
    RealtimeRunner* engine = self.engine;
    JamSharedState* shared = self.sharedState;
    if (!engine) return;

    _metricsTicks++;
    NSMutableDictionary* stateUpdate = [NSMutableDictionary dictionary];

    // Send MIDI active notes and audio levels every frame
    if (shared) {
        // Output channel count for the routing UI (pushed when it changes).
        const int outCh = shared->outChannels.load(std::memory_order_relaxed);
        if (outCh != _lastPushedOutCh) {
            _lastPushedOutCh = outCh;
            stateUpdate[@"audioOuts"] = @(outCh);
        }
        NSMutableArray* notes = [NSMutableArray array];
        for (int i = 0; i < 128; i++) {
            if (shared->midiNotes[i].load(std::memory_order_relaxed)) {
                [notes addObject:@(i)];
            }
        }
        stateUpdate[@"activeNotes"] = notes;

        float pL = 0.0f;
        float pR = 0.0f;
        shared->levelProcessor.read_and_reset_peaks(pL, pR);
        stateUpdate[@"audioLevels"] = @{
            @"left": @(pL),
            @"right": @(pR)
        };

        // Compact waveform for the UI visual layer: newest ~2048 samples of
        // the viz ring downsampled to 96 points (25 Hz × 96 floats is cheap).
        constexpr int kWavePoints = 96;
        constexpr int kWaveWindow = 2048;
        const int head = shared->vizHead.load(std::memory_order_acquire);
        NSMutableArray* wave = [NSMutableArray arrayWithCapacity:kWavePoints];
        for (int i = 0; i < kWavePoints; i++) {
            int idx = head - kWaveWindow + (i * kWaveWindow) / kWavePoints;
            idx = ((idx % JamSharedState::VIZ_BUF_SIZE) + JamSharedState::VIZ_BUF_SIZE)
                  % JamSharedState::VIZ_BUF_SIZE;
            [wave addObject:@(roundf(shared->vizRing[idx] * 1000.0f) / 1000.0f)];
        }
        stateUpdate[@"waveform"] = wave;

        // PGM console playhead: song preview, or the stem transport (also
        // while paused so the position stays visible/seekable).
        if (shared->prevActive.load(std::memory_order_relaxed)) {
            stateUpdate[@"studioPlayhead"] = @{
                @"pos": @(shared->prevPos.load(std::memory_order_relaxed) / 48000.0),
                @"len": @(shared->prevLen.load(std::memory_order_relaxed) / 48000.0),
                @"mode": @"song",
                @"playing": @YES,
                @"active": @YES,
            };
            _studioPrevWasActive = YES;
        } else if (shared->stemLen.load(std::memory_order_relaxed) > 0) {
            stateUpdate[@"studioPlayhead"] = @{
                @"pos": @(shared->stemPos.load(std::memory_order_relaxed) / 48000.0),
                @"len": @(shared->stemLen.load(std::memory_order_relaxed) / 48000.0),
                @"mode": @"stems",
                @"playing": @(shared->stemActive.load(std::memory_order_relaxed)),
                @"active": @YES,
            };
            _studioPrevWasActive = YES;
        } else if (_studioPrevWasActive) {
            _studioPrevWasActive = NO;
            stateUpdate[@"studioPlayhead"] = @{@"active": @NO};
        }
    }

    // Metrics every 5th tick (~5 Hz)
    if (_metricsTicks >= 5) {
        _metricsTicks = 0;
        EngineMetrics m = engine->get_metrics();

        stateUpdate[@"metrics"] = @{
            @"frameMs": @(m.transformer_ms),
            @"bufferAvail": @(m.buffer_available),
            @"bufferCap": @(m.buffer_capacity),
            @"textEncoderStatus": @(engine->get_text_encoder_status()),
            @"droppedFrames": @(m.dropped_frames)
        };
    }

    // Params — send only changed values
    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    for (int addr : kBridgedParamAddresses) {
        NSString* key = [MagentaSettings paramKeyForAddress:addr];
        if (!key) continue;
        float rawVal = [self readParamFromEngine:addr];
        NSNumber* val = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
        NSNumber* lastVal = _lastParams[key];
        if (!lastVal || ![lastVal isEqualToNumber:val]) {
            params[key] = val;
            _lastParams[key] = val;
        }
    }
    // cfgnotesuser: the user's chosen note-adherence slider value, unaffected
    // by the solo-mode ramp that animates the engine's internal cfg_notes.
    if (self.cfgNotesSliderValue) {
        NSNumber* sliderVal = @(self.cfgNotesSliderValue->load(std::memory_order_relaxed));
        NSNumber* lastSlider = _lastParams[@"cfgnotesuser"];
        if (!lastSlider || ![lastSlider isEqualToNumber:sliderVal]) {
            params[@"cfgnotesuser"] = sliderVal;
            _lastParams[@"cfgnotesuser"] = sliderVal;
        }
    }
    if (params.count > 0) stateUpdate[@"params"] = params;

    if (stateUpdate.count > 0) [self sendStateUpdate:stateUpdate];
}

// ─── Camera gesture control (mix circle / surface views) ────────────────────
// Poses bypass updateState: they arrive at camera rate (~30 Hz) and go through
// a dedicated lightweight callback the UI reads with refs.

- (void)setHandTrackingEnabled:(BOOL)on {
    if (!on) {
        [_handTracker stop];
        _handTracker = nil;
        [self sendStateUpdate:@{@"handTracking": @{@"active": @NO}}];
        return;
    }
    if (_handTracker.running) return;
    if (!_handTracker) {
        _handTracker = [[JamHandTracker alloc] init];
        __weak JamAppController* weakSelf = self;
        _handTracker.poseHandler = ^(float x, float y, BOOL pinching, BOOL visible) {
            JamAppController* s = weakSelf;
            if (!s || !s->_webView) return;
            NSString* js = [NSString stringWithFormat:
                @"if(window.updateHandPose)window.updateHandPose(%.4f,%.4f,%d,%d);",
                x, y, pinching ? 1 : 0, visible ? 1 : 0];
            [s->_webView evaluateJavaScript:js completionHandler:nil];
        };
        _handTracker.failureHandler = ^(NSString* reason) {
            JamAppController* s = weakSelf;
            if (!s) return;
            s->_handTracker = nil;
            [s sendStateUpdate:@{@"handTracking": @{@"active": @NO,
                                                    @"error": reason ?: @"camera unavailable"}}];
        };
    }
    [_handTracker start];
    [self sendStateUpdate:@{@"handTracking": @{@"active": @YES}}];
}

// ─── State push to React ─────────────────────────────────────────────────────

- (void)sendStateUpdate:(NSDictionary*)state {
    if (!_webView) return;
    NSError* error = nil;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:state options:0 error:&error];
    if (error) return;
    NSString* jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString* script = [NSString stringWithFormat:@"if (window.updateState) { window.updateState(%@); }", jsonString];
    [_webView evaluateJavaScript:script completionHandler:nil];
}

// ─── Calibration gate ─────────────────────────────────────────────────────
// On a device/channel change we mute program audio and play a standard
// 120 BPM reference click through the new output. The auto speed-compensation
// measures the device's true rate over ~2s and locks; the operator verifies
// the corrected click against their rig, then confirms to resume.
- (void)enterCalibration {
    if (!self.sharedState) return;
    self.sharedState->calibrating.store(true, std::memory_order_release);
    [self sendStateUpdate:@{@"calibration": @{@"active": @YES, @"measuring": @YES}}];

    __weak JamAppController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        JamAppController* s = weakSelf;
        if (!s || !s.sharedState) return;
        if (!s.sharedState->calibrating.load(std::memory_order_acquire)) return;
        float comp = s.sharedState->outSpeedComp.load(std::memory_order_acquire);
        if (comp < 0.0001f) comp = 1.0f;
        int ch = s.sharedState->outChannels.load(std::memory_order_relaxed);
        [s sendStateUpdate:@{@"calibration": @{
            @"active": @YES,
            @"measuring": @NO,
            @"comp": @(comp),
            @"effectiveRate": @((int)llround(48000.0 / comp)),
            @"channels": @(ch)
        }}];
    });
}

- (void)finishCalibration {
    if (self.sharedState)
        self.sharedState->calibrating.store(false, std::memory_order_release);
    [self sendStateUpdate:@{@"calibration": @{@"active": @NO}}];
}

// ─── Multi-track looper ───────────────────────────────────────────────────
- (void)ensureLoopTimer {
    if (_loopTimer) return;
    __weak JamAppController* w = self;
    _loopTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 12.0) repeats:YES
                                                   block:^(NSTimer* t) {
        JamAppController* s = w;
        if (!s) { [t invalidate]; return; }
        if (s.sharedState && s.sharedState->loopLen.load(std::memory_order_relaxed) > 0)
            [s pushLoopState];
    }];
}

// Push the modular sequencer's current step to the UI for the running-step
// highlight. Runs only while the Modular tab is active and the seq runs.
- (void)ensureModularTimer {
    if (_modularTimer) return;
    __weak JamAppController* w = self;
    _modularTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 15.0) repeats:YES
                                                      block:^(NSTimer* t) {
        JamAppController* s = w;
        if (!s) { [t invalidate]; return; }
        JamSharedState* sh = s.sharedState;
        if (!sh || !sh->modular.active.load(std::memory_order_relaxed)) {
            [t invalidate];
            if (s->_modularTimer == t) s->_modularTimer = nil;
            return;
        }
        const int step = sh->modular.seqRun.load(std::memory_order_relaxed)
            ? sh->modular.seqStepUi.load(std::memory_order_relaxed) : -1;
        [s sendStateUpdate:@{@"modular": @{@"step": @(step)}}];
    }];
}

- (void)handleLoopArm:(int)i {
    JamSharedState* sh = self.sharedState;
    if (!sh || i < 0 || i >= JamSharedState::kLoopTracks) return;
    [self ensureLoopTimer];
    const int s = sh->loopState[i].load(std::memory_order_relaxed);
    if (s == 2 || s == 5) return;   // already recording/overdubbing
    if (sh->loopLen.load(std::memory_order_relaxed) == 0) {
        // First loop defines the master grid from bars × current jam BPM.
        float bpm = sh->fxTempo.load(std::memory_order_relaxed);
        if (bpm < 40.0f || bpm > 300.0f) bpm = 120.0f;
        const int bars = sh->loopBars.load(std::memory_order_relaxed);
        const int bpb = sh->beatsPerBar.load(std::memory_order_relaxed);
        long len = (long)llround((double)bars * bpb * (60.0 / bpm) * 48000.0);
        len = MAX(4800L, MIN((long)JamSharedState::kLoopMaxFrames, len));
        sh->loopLen.store(len, std::memory_order_release);
        if (sh->loopCountInOn.load(std::memory_order_relaxed)) {
            // One bar of click count-in before recording starts.
            const long oneBar = MAX(1L, len / MAX(1, bars));
            sh->loopCountInTotal.store(oneBar, std::memory_order_relaxed);
            sh->loopCountInLeft.store(oneBar, std::memory_order_release);
        } else {
            sh->loopResetPhase.store(true, std::memory_order_release);  // start now
        }
    }
    sh->loopState[i].store(1, std::memory_order_relaxed);   // armed
    [self pushLoopState];
}

// Drop the master grid (and any count-in) once every track is empty.
- (void)loopResetGridIfEmpty {
    JamSharedState* sh = self.sharedState;
    for (int t = 0; t < JamSharedState::kLoopTracks; ++t)
        if (sh->loopState[t].load(std::memory_order_relaxed) != 0) return;
    sh->loopLen.store(0, std::memory_order_relaxed);
    sh->loopPhase.store(0, std::memory_order_relaxed);
    sh->loopCountInLeft.store(0, std::memory_order_relaxed);
}

// Universal pad tap: empty→(arm elsewhere) · armed→cancel · recording/overdub
// →finalize to playing · playing→stopped · stopped→playing.
- (void)handleLoopStop:(int)i {
    JamSharedState* sh = self.sharedState;
    if (!sh || i < 0 || i >= JamSharedState::kLoopTracks) return;
    const int s = sh->loopState[i].load(std::memory_order_relaxed);
    int n = s;
    switch (s) {
        case 1: n = 0; break;            // armed → cancel (empty)
        case 2: case 5: n = 3; break;    // recording/overdub → finalize to playing
        case 3: n = 6; break;            // playing → stopped
        case 4: n = 3; break;            // armed-overdub → playing
        case 6: n = 3; break;            // stopped → playing
        default: return;                 // empty
    }
    sh->loopState[i].store(n, std::memory_order_relaxed);
    if (n == 0) [self loopResetGridIfEmpty];
    [self pushLoopState];
}

- (void)handleLoopClear:(int)i {
    JamSharedState* sh = self.sharedState;
    if (!sh || i < 0 || i >= JamSharedState::kLoopTracks) return;
    sh->loopState[i].store(0, std::memory_order_relaxed);   // empty
    [self loopResetGridIfEmpty];
    [self pushLoopState];
}

- (void)handleLoopStopAll {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    for (int t = 0; t < JamSharedState::kLoopTracks; ++t) {
        const int s = sh->loopState[t].load(std::memory_order_relaxed);
        if (s != 0) sh->loopState[t].store(6, std::memory_order_relaxed);  // stopped
    }
    sh->loopCountInLeft.store(0, std::memory_order_relaxed);
    [self pushLoopState];
}

- (void)handleLoopClearAll {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    for (int t = 0; t < JamSharedState::kLoopTracks; ++t)
        sh->loopState[t].store(0, std::memory_order_relaxed);
    sh->loopLen.store(0, std::memory_order_relaxed);
    sh->loopPhase.store(0, std::memory_order_relaxed);
    sh->loopCountInLeft.store(0, std::memory_order_relaxed);
    [self pushLoopState];
}

- (void)handleLoopOverdub:(int)i {   // toggle from playing
    JamSharedState* sh = self.sharedState;
    if (!sh || i < 0 || i >= JamSharedState::kLoopTracks) return;
    const int s = sh->loopState[i].load(std::memory_order_relaxed);
    if (s == 3)               sh->loopState[i].store(4, std::memory_order_relaxed);  // → armed-overdub
    else if (s == 4 || s == 5) sh->loopState[i].store(3, std::memory_order_relaxed); // → playing (off)
    [self pushLoopState];
}

// Push loop track states (+ master phase fraction) to the UI for the pads.
- (void)pushLoopState {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    NSMutableArray* states = [NSMutableArray array];
    for (int t = 0; t < JamSharedState::kLoopTracks; ++t)
        [states addObject:@(sh->loopState[t].load(std::memory_order_relaxed))];
    const long len = sh->loopLen.load(std::memory_order_relaxed);
    const double frac = len > 0
        ? (double)sh->loopPhase.load(std::memory_order_relaxed) / (double)len : 0.0;
    // Count-in: beats remaining (0 = none) for the "preparation" display.
    const long ciLeft = sh->loopCountInLeft.load(std::memory_order_relaxed);
    const long ciTot  = sh->loopCountInTotal.load(std::memory_order_relaxed);
    const int  bpb    = sh->beatsPerBar.load(std::memory_order_relaxed);
    int ciBeats = 0;
    if (ciLeft > 0 && ciTot > 0 && bpb > 0)
        ciBeats = (int)ceil((double)ciLeft / ((double)ciTot / bpb));
    // Current beat within the bar (1..bpb) for the beat indicator.
    int beat = 0;
    if (len > 0 && bpb > 0) {
        const int bars = MAX(1, sh->loopBars.load(std::memory_order_relaxed));
        const long totalBeats = (long)bars * bpb;
        const long bi = (long)(frac * totalBeats);
        beat = (int)(bi % bpb) + 1;
    }
    [self sendStateUpdate:@{@"loop": @{
        @"states": states,
        @"phase": @(frac),
        @"bars": @(sh->loopBars.load(std::memory_order_relaxed)),
        @"beat": @(beat),
        @"bpb": @(bpb),
        @"countIn": @(ciBeats),
        @"auto": @(sh->loopAuto.load(std::memory_order_relaxed)),
        @"countInOn": @(sh->loopCountInOn.load(std::memory_order_relaxed)),
    }}];
}

// ─── Live (stage) mode: hold a power assertion so the machine never idle-
// sleeps and the screen never locks mid-performance. Released when off / quit.
- (void)setLiveMode:(BOOL)on {
    if (on) {
        if (_liveAssertionID == 0) {
            // Display-sleep prevention keeps the screen on (→ no idle lock) and
            // implicitly keeps the system awake while the display is up.
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep,
                kIOPMAssertionLevelOn,
                CFSTR("MRT2 - Jam live performance"),
                &_liveAssertionID);
        }
    } else if (_liveAssertionID != 0) {
        IOPMAssertionRelease(_liveAssertionID);
        _liveAssertionID = 0;
    }
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"Jam_LiveMode"];
    [self sendStateUpdate:@{@"liveMode": @(on)}];
}

- (void)sendPlayState:(BOOL)playing {
    _isPlaying = playing;
    [self sendStateUpdate:@{@"isPlaying": @(playing)}];
}

- (void)showReactSettings {
    [self sendStateUpdate:@{@"openSettings": @YES}];
}

- (void)connectToEngine {
    RealtimeRunner* engine = self.engine;
    if (!engine) return;

    NSMutableDictionary* initialParams = [NSMutableDictionary dictionary];
    for (int addr : kBridgedParamAddresses) {
        NSString* key = [MagentaSettings paramKeyForAddress:addr];
        if (!key) continue;
        float rawVal = [self readParamFromEngine:addr];
        NSNumber* val = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
        initialParams[key] = val;
        _lastParams[key] = val;
    }

    // Include stable slider value for note adherence
    if (self.cfgNotesSliderValue) {
        initialParams[@"cfgnotesuser"] = @(self.cfgNotesSliderValue->load(std::memory_order_relaxed));
    }

    NSMutableDictionary* state = [NSMutableDictionary dictionary];
    state[@"params"] = initialParams;
    state[@"isPlaying"] = @(_isPlaying);
    state[@"solomode"] = @(self.soloMode ? self.soloMode->load(std::memory_order_relaxed) : NO);
    if (_modelName) state[@"modelName"] = _modelName;

    // Restore saved prompt (always send, empty string if nothing saved)
    NSString* savedPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_Prompt"];
    state[@"prompt"] = savedPrompt ?: @"";

    // Restore saved rocker index
    NSNumber* savedRockerIndex = [[NSUserDefaults standardUserDefaults] objectForKey:@"Jam_RockerIndex"];
    if (savedRockerIndex) state[@"savedRockerIndex"] = savedRockerIndex;

    // Restore the unified mix chips (single source of truth for all modes)
    NSArray* savedMixPrompts = [[NSUserDefaults standardUserDefaults] arrayForKey:@"Jam_MixPrompts"];
    if (savedMixPrompts) state[@"savedMixPrompts"] = savedMixPrompts;

    // Restore performance-synth user presets
    NSArray* savedSynthPresets = [[NSUserDefaults standardUserDefaults] arrayForKey:@"Jam_SynthPresets"];
    if (savedSynthPresets) state[@"savedSynthPresets"] = savedSynthPresets;

    // PGM studio: neural separation model availability
    {
        NSString* sepPath = [self sepModelPath];
        const BOOL sepPresent = JamDemucsAvailable(sepPath);
        state[@"studioSepModel"] = @{
            @"present": @(sepPresent),
            @"sources": @(sepPresent ? ([sepPath containsString:@"-6s-"] ? 6 : 4) : 0),
            @"downloading": @NO,
            @"pct": @0,
        };
    }

    // Restore saved prompt history
    NSArray* savedHistory = [[NSUserDefaults standardUserDefaults] arrayForKey:@"Jam_PromptHistory"];
    if (savedHistory) {
        state[@"savedPromptHistory"] = savedHistory;
        state[@"savedHistoryIndex"] = [[NSUserDefaults standardUserDefaults] objectForKey:@"Jam_HistoryIndex"] ?: @0;
    }

    state[@"computerKeyboardMidi"] = @([[NSUserDefaults standardUserDefaults] boolForKey:@"Jam_ComputerKeyboardMidi"]);

    // Restore user preset overrides
    NSDictionary* savedSolo = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"Jam_UserPresetsSolo"];
    NSDictionary* savedJam = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"Jam_UserPresetsJam"];
    if (savedSolo || savedJam) {
        NSMutableDictionary* presets = [NSMutableDictionary dictionary];
        if (savedSolo) presets[@"solo"] = savedSolo;
        if (savedJam) presets[@"jam"] = savedJam;
        state[@"savedUserPresets"] = presets;
    }

    NSString* searchPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_ModelFolderPath"];
    if (!searchPath) {
        searchPath = [NSString stringWithUTF8String:magentart::paths::get_models_dir().c_str()];
    }
    state[@"downloadPath"] = searchPath;

    // Connect to the saved MIDI endpoint
    NSInteger savedEndpoint = [[NSUserDefaults standardUserDefaults] integerForKey:@"Jam_SelectedMidiEndpoint"];
    if (![[NSUserDefaults standardUserDefaults] objectForKey:@"Jam_SelectedMidiEndpoint"]) {
        // Default to Computer Keyboard (0) if nothing is saved
        savedEndpoint = 0;
    }
    [self selectMidiInput:(uint32_t)savedEndpoint];

    state[@"resourcesMissing"] = @(![MagentaModelDownloader areSharedResourcesValid]);

    [self sendStateUpdate:state];
    [self handleListLocalModels];
    [self handleMIDIStructureChanged];
}

- (void)setComputerKeyboardMidiEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"Jam_ComputerKeyboardMidi"];
    [self sendStateUpdate:@{@"computerKeyboardMidi": @(enabled)}];
}

- (void)notifyModelLoaded:(NSString*)modelName {
    _modelName = modelName;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary* state = [NSMutableDictionary dictionary];
        state[@"modelName"] = modelName;

        NSMutableDictionary* params = [NSMutableDictionary dictionary];
        for (int addr : kBridgedParamAddresses) {
            NSString* key = [MagentaSettings paramKeyForAddress:addr];
            if (!key) continue;
            float rawVal = [self readParamFromEngine:addr];
            params[key] = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
            self->_lastParams[key] = params[key];
        }
        if (self.cfgNotesSliderValue) {
            params[@"cfgnotesuser"] = @(self.cfgNotesSliderValue->load(std::memory_order_relaxed));
        }
        state[@"params"] = params;

        // Re-apply current prompt to the freshly loaded model.
        // _currentPromptText may have been set by the frontend via textPrompts IPC
        // before the model finished loading, or from a previous saved prompt.
        if (self.engine) {
            NSString* promptToUse = self->_currentPromptText.length > 0
                ? self->_currentPromptText
                : ([[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_Prompt"] ?: @"");
            BOOL isSolo = self.soloMode ? self.soloMode->load(std::memory_order_relaxed) : YES;
            NSString* cleanPrompt = [promptToUse stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString* engineText = @"";
            if (cleanPrompt.length == 0) {
                engineText = @"silence";
            } else {
                engineText = isSolo ? [NSString stringWithFormat:@"SOLO %@", cleanPrompt] : cleanPrompt;
            }
            std::vector<std::string> texts = {engineText.UTF8String, "", "", "", "", ""};
            std::vector<float> weights = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
            self.engine->set_text_prompts(texts, weights);
            self.engine->set_blend_weights(weights.data(), (int)weights.size());
            self->_currentPromptText = promptToUse;
            state[@"prompt"] = promptToUse;
        }

        [self sendStateUpdate:state];
    });
}

// ─── Navigation delegate ─────────────────────────────────────────────────────

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"Jam: WKWebView loaded");
}

// ─── Script message handler ──────────────────────────────────────────────────

// Apply one named SynthParams value to a synth instance (Instrument tab and
// the per-stem MIDI lane synths share the parameter schema).
static void JamSetSynthParam(JamSynth& sy, NSString* key, NSNumber* value) {
    const float v = value.floatValue;
    const int iv = value.intValue;
    if ([key isEqualToString:@"oscType"])          sy.oscType.store(MAX(0, MIN(4, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"wave"])        sy.wave.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"timbre"])      sy.timbre.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"shape"])       sy.shape.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"glide"])       sy.glide.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"attack"])      sy.attack.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"decay"])       sy.decay.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"sustain"])     sy.sustain.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"release"])     sy.release.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"filterType"])  sy.filterType.store(MAX(0, MIN(2, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"cutoff"])      sy.cutoff.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"resonance"])   sy.resonance.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"envFilter"])   sy.envFilter.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"lfoShape"])    sy.lfoShape.store(MAX(0, MIN(4, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"lfoRate"])     sy.lfoRate.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"lfoSync"])     sy.lfoSync.store(v > 0.5f, std::memory_order_relaxed);
    else if ([key isEqualToString:@"cycMode"])     sy.cycMode.store(MAX(0, MIN(2, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"cycRise"])     sy.cycRise.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"cycFall"])     sy.cycFall.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"cycHold"])     sy.cycHold.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"cycRiseShape"]) sy.cycRiseShape.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"cycFallShape"]) sy.cycFallShape.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"cycAmount"])   sy.cycAmount.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"arpMode"])     sy.arpMode.store(MAX(0, MIN(6, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"arpOct"])      sy.arpOct.store(MAX(1, MIN(4, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"arpDiv"])      sy.arpDiv.store(MAX(0, MIN(5, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"arpHold"])     sy.arpHold.store(v > 0.5f, std::memory_order_relaxed);
    else if ([key isEqualToString:@"arpSwing"])    sy.arpSwing.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"arpGate"])     sy.arpGate.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"arpSpice"])    sy.arpSpice.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"monoMode"])    sy.monoMode.store(v > 0.5f, std::memory_order_relaxed);
    else if ([key isEqualToString:@"chorus"])      sy.chorus.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"space"])       sy.space.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"volume"])      sy.volume.store(v, std::memory_order_relaxed);
}

// Apply one named param to the West-Coast modular voice (Modular tab).
static void JamSetModularParam(JamModular& md, NSString* key, NSNumber* value) {
    const float v = value.floatValue;
    const int iv = value.intValue;
    if      ([key isEqualToString:@"voiceMode"])  md.voiceMode.store(MAX(0, MIN(2, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"glide"])      md.glide.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"vcoWaveSel"]) md.vcoWaveSel.store(MAX(0, MIN(2, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"vcoPitch"])   md.vcoPitch.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"vcoWave"])    md.vcoWave.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"vcoScale"])   md.vcoScale.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"vcoFold"])    md.vcoFold.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"foldAmt"])    md.foldAmt.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"foldBias"])   md.foldBias.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn1Rise"])    md.fn1Rise.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn1Fall"])    md.fn1Fall.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn1Shape"])   md.fn1Shape.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn1Cycle"])   md.fn1Cycle.store(iv ? 1 : 0, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn2Rise"])    md.fn2Rise.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn2Fall"])    md.fn2Fall.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn2Shape"])   md.fn2Shape.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"fn2Cycle"])   md.fn2Cycle.store(iv ? 1 : 0, std::memory_order_relaxed);
    else if ([key isEqualToString:@"rndMode"])    md.rndMode.store(MAX(0, MIN(3, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"rndRate"])    md.rndRate.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"rndProb"])    md.rndProb.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"lpgCutoff"])  md.lpgCutoff.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"lpgReso"])    md.lpgReso.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"lpgDecay"])   md.lpgDecay.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"lpgDrive"])   md.lpgDrive.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"spaceType"])  md.spaceType.store(MAX(0, MIN(4, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"spaceSize"])  md.spaceSize.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"outVol"])     md.outVol.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"outWidth"])   md.outWidth.store(v, std::memory_order_relaxed);
    else if ([key isEqualToString:@"seqRun"])     md.seqRun.store(v > 0.5f, std::memory_order_relaxed);
    else if ([key isEqualToString:@"seqDiv"])     md.seqDiv.store(MAX(0, MIN(5, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"seqLen"])     md.seqLen.store(MAX(1, MIN(16, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"seqScale"])   md.seqScale.store(MAX(0, MIN(4, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"seqOctave"])  md.seqOctave.store(MAX(-2, MIN(2, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"seqRoot"])    md.seqRoot.store(MAX(24, MIN(84, iv)), std::memory_order_relaxed);
    else if ([key isEqualToString:@"seqSwing"])   md.seqSwing.store(v, std::memory_order_relaxed);
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"auHost"] || ![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary* body = message.body;
    NSString* type = body[@"type"];

    if ([type isEqualToString:@"param"]) {
        NSNumber* indexValue = body[@"index"];
        NSNumber* paramValue = body[@"value"];
        if (indexValue && paramValue) {
            [self applyParamToEngine:indexValue.intValue value:paramValue.floatValue];
        }
    }
    else if ([type isEqualToString:@"performance"]) {
        NSString* key = body[@"key"];
        NSNumber* value = body[@"value"];
        if ([key isKindOfClass:[NSString class]] &&
            [value isKindOfClass:[NSNumber class]] &&
            self.sharedState) {
            float v = value.floatValue;
            if (v < 0.0f) v = 0.0f;
            if (v > 1.0f) v = 1.0f;

            if ([key isEqualToString:@"filterX"]) {
                self.sharedState->filterX.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"filterY"]) {
                self.sharedState->filterY.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"drive"]) {
                self.sharedState->drive.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"delayMix"]) {
                self.sharedState->delayMix.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"delayFeedback"]) {
                self.sharedState->delayFeedback.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"reverbMix"]) {
                self.sharedState->reverbMix.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"limiter"]) {
                self.sharedState->limiter.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"stereoWidth"]) {
                self.sharedState->stereoWidth.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"tone"]) {
                self.sharedState->tone.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"outGain"]) {
                self.sharedState->outGain.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"crush"]) {
                self.sharedState->crush.store(v, std::memory_order_relaxed);
            } else if ([key isEqualToString:@"tremolo"]) {
                self.sharedState->tremolo.store(v, std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"fxTempo"]) {
        NSNumber* value = body[@"value"];
        if ([value isKindOfClass:[NSNumber class]] && self.sharedState) {
            self.sharedState->fxTempo.store(value.floatValue, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"instrumentFollowJam"]) {
        NSNumber* value = body[@"value"];
        if ([value isKindOfClass:[NSNumber class]] && self.sharedState) {
            self.sharedState->instrumentFollowsJam.store(
                value.boolValue, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"instrumentActive"]) {
        NSNumber* value = body[@"value"];
        if ([value isKindOfClass:[NSNumber class]] && self.sharedState) {
            const BOOL on = value.boolValue;
            // Gates note ROUTING only. The synth keeps sounding across tab
            // switches (latched arps, ringing releases) — note-offs always
            // reach it, so physical releases land even from the jam tab.
            self.sharedState->synth.active.store(on, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"synthParam"]) {
        NSString* key = body[@"key"];
        NSNumber* value = body[@"value"];
        if ([key isKindOfClass:[NSString class]] &&
            [value isKindOfClass:[NSNumber class]] && self.sharedState) {
            JamSetSynthParam(self.sharedState->synth, key, value);
        }
    }
    else if ([type isEqualToString:@"modularActive"]) {
        NSNumber* value = body[@"value"];
        if ([value isKindOfClass:[NSNumber class]] && self.sharedState) {
            const BOOL on = value.boolValue;
            self.sharedState->modular.active.store(on, std::memory_order_relaxed);
            if (on) [self ensureModularTimer];
        }
    }
    else if ([type isEqualToString:@"modularParam"]) {
        NSString* key = body[@"key"];
        NSNumber* value = body[@"value"];
        if ([key isKindOfClass:[NSString class]] &&
            [value isKindOfClass:[NSNumber class]] && self.sharedState) {
            JamSetModularParam(self.sharedState->modular, key, value);
        }
    }
    else if ([type isEqualToString:@"modularPatch"]) {
        // One matrix cell: { src, dst, value } (bipolar -1..1).
        NSNumber* srcN = body[@"src"];
        NSNumber* dstN = body[@"dst"];
        NSNumber* value = body[@"value"];
        if ([srcN isKindOfClass:[NSNumber class]] && [dstN isKindOfClass:[NSNumber class]] &&
            [value isKindOfClass:[NSNumber class]] && self.sharedState) {
            const int s = srcN.intValue, d = dstN.intValue;
            if (s >= 0 && s < JamModular::kSrc && d >= 0 && d < JamModular::kDst) {
                float v = value.floatValue;
                if (v < -1.0f) v = -1.0f; if (v > 1.0f) v = 1.0f;
                self.sharedState->modular.patch[s * JamModular::kDst + d].store(
                    v, std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"modularSeq"]) {
        // One sequencer cell: { lane, step, value }.
        //   lane: "gate" | "note" | "fn1" | "fn2" | "lpg" | "space"
        NSString* lane = body[@"lane"];
        NSNumber* stepN = body[@"step"];
        NSNumber* value = body[@"value"];
        if ([lane isKindOfClass:[NSString class]] && [stepN isKindOfClass:[NSNumber class]] &&
            [value isKindOfClass:[NSNumber class]] && self.sharedState) {
            const int st = stepN.intValue;
            if (st >= 0 && st < JamModular::kSteps) {
                JamModular& md = self.sharedState->modular;
                const int iv = value.intValue;
                const bool bv = value.boolValue;
                if      ([lane isEqualToString:@"gate"])  md.stepGate[st].store(bv, std::memory_order_relaxed);
                else if ([lane isEqualToString:@"note"])  md.stepNote[st].store(MAX(0, MIN(24, iv)), std::memory_order_relaxed);
                else if ([lane isEqualToString:@"fn1"])   md.laneFn1[st].store(bv, std::memory_order_relaxed);
                else if ([lane isEqualToString:@"fn2"])   md.laneFn2[st].store(bv, std::memory_order_relaxed);
                else if ([lane isEqualToString:@"lpg"])   md.laneLpg[st].store(bv, std::memory_order_relaxed);
                else if ([lane isEqualToString:@"space"]) md.laneSpace[st].store(bv, std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"modularDice"]) {
        if (self.sharedState) {
            self.sharedState->modular.diceSeed.fetch_add(
                0x9E3779B9u + 1u, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"detectBpm"]) {
        [self handleDetectBpm];
    }
    else if ([type isEqualToString:@"studioLoadSong"]) {
        [self handleStudioLoadSong];
    }
    else if ([type isEqualToString:@"studioSeparate"]) {
        [self handleStudioSeparate];
    }
    else if ([type isEqualToString:@"studioImportStem"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) [self handleStudioImportStem:idx.intValue];
    }
    else if ([type isEqualToString:@"studioTranscribe"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) [self handleStudioTranscribe:idx.intValue];
    }
    else if ([type isEqualToString:@"studioExtractStem"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) [self handleStudioExtractStem:idx.intValue];
    }
    else if ([type isEqualToString:@"studioStemAlign"]) {
        NSNumber* idx = body[@"index"];
        NSString* act = body[@"action"];   // 'left' | 'right' | 'auto' | 'reset'
        if ([idx isKindOfClass:[NSNumber class]] && [act isKindOfClass:[NSString class]])
            [self handleStudioStemAlign:idx.intValue action:act];
    }
    else if ([type isEqualToString:@"studioStemAlignSet"]) {
        NSNumber* idx = body[@"index"];
        NSNumber* ms = body[@"ms"];   // absolute offset in ms (+later / -earlier)
        if ([idx isKindOfClass:[NSNumber class]] && [ms isKindOfClass:[NSNumber class]] &&
            self.sharedState) {
            const int i = idx.intValue;
            if (i >= 0 && i < JamSharedState::kStems) {
                self.sharedState->stemOffset[i].store(
                    (long)llround(ms.doubleValue * 48.0), std::memory_order_relaxed);
                [self studioPushStemAlign:i];
            }
        }
    }
    else if ([type isEqualToString:@"studioStemDry"]) {
        NSNumber* idx = body[@"index"];
        NSNumber* val = body[@"value"];    // 0..0.5 dry-blend amount
        if ([idx isKindOfClass:[NSNumber class]] && [val isKindOfClass:[NSNumber class]] &&
            self.sharedState) {
            const int i = idx.intValue;
            if (i >= 0 && i < JamSharedState::kStems)
                self.sharedState->stemDry[i].store(
                    MAX(0.0f, MIN(0.5f, val.floatValue)), std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"studioDetectChords"]) {
        [self handleStudioDetectChords];
    }
    else if ([type isEqualToString:@"studioExportBacking"]) {
        // The audio engine + render block live in the app delegate; it owns the
        // offline bounce. Trigger it via notification.
        [[NSNotificationCenter defaultCenter] postNotificationName:@"JamExportBacking"
                                                            object:nil];
    }
    else if ([type isEqualToString:@"laneSource"]) {
        NSNumber* idx = body[@"index"];
        NSNumber* src = body[@"source"];
        if ([idx isKindOfClass:[NSNumber class]] && [src isKindOfClass:[NSNumber class]]) {
            [self handleLaneSource:idx.intValue midi:(src.intValue == 1)];
        }
    }
    else if ([type isEqualToString:@"lanePatch"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) {
            [self handleLanePatch:idx.intValue info:body];
        }
    }
    else if ([type isEqualToString:@"laneEngine"]) {
        NSNumber* idx = body[@"index"];
        NSNumber* eng = body[@"engine"];
        if ([idx isKindOfClass:[NSNumber class]] && [eng isKindOfClass:[NSNumber class]]) {
            [self handleLaneEngine:idx.intValue engine:eng.intValue];
        }
    }
    else if ([type isEqualToString:@"laneSfProgram"]) {
        NSNumber* idx = body[@"index"];
        NSNumber* prog = body[@"program"];
        if ([idx isKindOfClass:[NSNumber class]] && [prog isKindOfClass:[NSNumber class]] &&
            idx.intValue >= 1 && idx.intValue <= 7 && self.sharedState) {
            self.sharedState->laneSfProgram[idx.intValue - 1]
                .store(MAX(0, MIN(127, prog.intValue)), std::memory_order_relaxed);
            [self studioPushLanes];
        }
    }
    else if ([type isEqualToString:@"laneFx"]) {
        NSNumber* idx = body[@"index"];
        NSNumber* rev = body[@"reverb"];
        NSNumber* ech = body[@"echo"];
        if ([idx isKindOfClass:[NSNumber class]] &&
            idx.intValue >= 1 && idx.intValue <= 7 && self.sharedState) {
            JamLaneFx& fx = self.sharedState->laneFx[idx.intValue - 1];
            if ([rev isKindOfClass:[NSNumber class]]) {
                fx.reverb.store(MAX(0.0f, MIN(1.0f, rev.floatValue)),
                                std::memory_order_relaxed);
            }
            if ([ech isKindOfClass:[NSNumber class]]) {
                fx.echo.store(MAX(0.0f, MIN(1.0f, ech.floatValue)),
                              std::memory_order_relaxed);
            }
            [self studioPushLanes];
        }
    }
    else if ([type isEqualToString:@"laneRegen"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) {
            [self handleLaneRegen:idx.intValue];
        }
    }
    else if ([type isEqualToString:@"laneClear"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) {
            [self handleLaneClear:idx.intValue];
        }
    }
    else if ([type isEqualToString:@"laneClipGet"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) {
            [self handleLaneClipGet:idx.intValue];
        }
    }
    else if ([type isEqualToString:@"laneClipSet"]) {
        NSNumber* idx = body[@"index"];
        NSArray* notes = body[@"notes"];
        if ([idx isKindOfClass:[NSNumber class]] && [notes isKindOfClass:[NSArray class]]) {
            [self handleLaneClipSet:idx.intValue notes:notes];
        }
    }
    else if ([type isEqualToString:@"studioCover"]) {
        NSNumber* idx = body[@"index"];
        if ([idx isKindOfClass:[NSNumber class]]) [self handleStudioCover:idx.intValue];
    }
    else if ([type isEqualToString:@"studioTransport"]) {
        NSString* action = body[@"action"];
        JamSharedState* sh = self.sharedState;
        if ([action isKindOfClass:[NSString class]] && sh) {
            // Begin playback at `entry`, with a back-calculated count-in: the
            // transport actually rolls from `entry − N beats` (on the click
            // grid) with the click forced on until `entry`. It's continuous
            // playback — no freeze, no phase gap into the song — so any audio
            // in the pre-roll region (a pickup, the song's real start) plays.
            const auto startAt = ^(long entry) {
                const long len = sh->stemLen.load(std::memory_order_relaxed);
                if (len <= 0) return;
                entry = MAX(0L, MIN(entry, len - 1));
                const int beats = sh->countInBeats.load(std::memory_order_relaxed);
                if (beats > 0) {
                    const float bpm = sh->stemBpm.load(std::memory_order_relaxed);
                    const long B = (long)(60.0 / ((bpm < 40 || bpm > 300) ? 120.0 : bpm)
                                          * 48000.0);
                    const long total = (long)beats * B;
                    // Roll the transport back as far as there's room; the rest
                    // is a frozen click pre-roll (when the entry is near 0).
                    // Both halves click on the same grid → always N beats, no gap.
                    const long rollback = MIN(total, entry);
                    const long frozen = total - rollback;
                    sh->stemPos.store(entry - rollback, std::memory_order_relaxed);
                    sh->countInUntil.store(entry, std::memory_order_relaxed);
                    sh->countInVPos.store(entry - total, std::memory_order_relaxed);
                    sh->countInLeft.store(frozen, std::memory_order_release);
                } else {
                    sh->stemPos.store(entry, std::memory_order_relaxed);
                    sh->countInUntil.store(-1, std::memory_order_relaxed);
                    sh->countInLeft.store(0, std::memory_order_relaxed);
                }
                sh->prevActive.store(false, std::memory_order_relaxed);
                sh->stemActive.store(true, std::memory_order_release);
            };
            const long cue = sh->stemCue.load(std::memory_order_relaxed);
            if ([action isEqualToString:@"restart"]) {
                startAt(cue >= 0 ? cue : 0);     // ⟲ → the cue (song's real "1")
            } else if ([action isEqualToString:@"play"]) {
                const long len = sh->stemLen.load(std::memory_order_relaxed);
                long pos = sh->stemPos.load(std::memory_order_relaxed);
                if (pos >= len) pos = 0;
                // From the top with a cue set → enter at the cue (skip intro);
                // a scrubbed position past the cue is kept.
                if (cue >= 0 && pos < cue) pos = cue;
                startAt(pos);
            } else {   // pause
                sh->stemActive.store(false, std::memory_order_relaxed);
                sh->countInUntil.store(-1, std::memory_order_relaxed);
                sh->countInLeft.store(0, std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"audioRoute"]) {
        NSNumber* main = body[@"main"];
        NSNumber* click = body[@"click"];
        if (self.sharedState) {
            if ([main isKindOfClass:[NSNumber class]] && main.unsignedIntValue != 0) {
                self.sharedState->mainOutMask.store(main.unsignedIntValue,
                                                    std::memory_order_relaxed);
            }
            if ([click isKindOfClass:[NSNumber class]] && click.unsignedIntValue != 0) {
                self.sharedState->clickOutMask.store(click.unsignedIntValue,
                                                     std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"audioMultichannel"]) {
        NSNumber* on = body[@"on"];
        if ([on isKindOfClass:[NSNumber class]] && self.sharedState) {
            self.sharedState->multichannelOut.store(on.boolValue, std::memory_order_relaxed);
            [[NSUserDefaults standardUserDefaults] setBool:on.boolValue
                                                    forKey:@"Jam_MultichannelOut"];
            // Rebuild the audio graph for the new output mode.
            [[NSNotificationCenter defaultCenter] postNotificationName:@"JamRebuildAudioGraph"
                                                                object:nil];
        }
    }
    else if ([type isEqualToString:@"liveMode"]) {
        NSNumber* on = body[@"on"];
        if ([on isKindOfClass:[NSNumber class]]) [self setLiveMode:on.boolValue];
    }
    else if ([type isEqualToString:@"loopArm"]) {
        [self handleLoopArm:[body[@"index"] intValue]];
    }
    else if ([type isEqualToString:@"loopStop"]) {
        [self handleLoopStop:[body[@"index"] intValue]];
    }
    else if ([type isEqualToString:@"loopClear"]) {
        [self handleLoopClear:[body[@"index"] intValue]];
    }
    else if ([type isEqualToString:@"loopOverdub"]) {
        [self handleLoopOverdub:[body[@"index"] intValue]];
    }
    else if ([type isEqualToString:@"loopMute"]) {
        JamSharedState* sh = self.sharedState;
        const int i = [body[@"index"] intValue];
        if (sh && i >= 0 && i < JamSharedState::kLoopTracks)
            sh->loopMute[i].store([body[@"on"] boolValue], std::memory_order_relaxed);
    }
    else if ([type isEqualToString:@"loopGain"]) {
        JamSharedState* sh = self.sharedState;
        const int i = [body[@"index"] intValue];
        if (sh && i >= 0 && i < JamSharedState::kLoopTracks) {
            float g = [body[@"value"] floatValue];
            sh->loopGain[i].store(MAX(0.0f, MIN(1.5f, g)), std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"loopBars"]) {
        JamSharedState* sh = self.sharedState;
        if (sh) {
            int b = [body[@"value"] intValue];
            b = (b == 1 || b == 2 || b == 4 || b == 8) ? b : 4;
            sh->loopBars.store(b, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"loopStopAll"]) {
        [self handleLoopStopAll];
    }
    else if ([type isEqualToString:@"loopClearAll"]) {
        [self handleLoopClearAll];
    }
    else if ([type isEqualToString:@"loopAutoOverdub"]) {
        JamSharedState* sh = self.sharedState;
        if (sh) { sh->loopAuto.store([body[@"on"] boolValue], std::memory_order_relaxed);
                  [self pushLoopState]; }
    }
    else if ([type isEqualToString:@"loopCountIn"]) {
        JamSharedState* sh = self.sharedState;
        if (sh) { sh->loopCountInOn.store([body[@"on"] boolValue], std::memory_order_relaxed);
                  [self pushLoopState]; }
    }
    else if ([type isEqualToString:@"calibrationDone"]) {
        [self finishCalibration];
    }
    else if ([type isEqualToString:@"startCalibration"]) {
        [self enterCalibration];
    }
    else if ([type isEqualToString:@"studioCountIn"]) {
        NSNumber* beats = body[@"beats"];
        if ([beats isKindOfClass:[NSNumber class]] && self.sharedState) {
            const int b = beats.intValue;
            self.sharedState->countInBeats.store(
                (b == 4 || b == 8) ? b : 0, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"studioClick"]) {
        NSNumber* on = body[@"on"];
        if ([on isKindOfClass:[NSNumber class]] && self.sharedState) {
            self.sharedState->clickOn.store(on.boolValue, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"studioClickGain"]) {
        NSNumber* v = body[@"value"];
        if ([v isKindOfClass:[NSNumber class]] && self.sharedState) {
            const float g = MAX(0.0f, MIN(2.0f, v.floatValue));
            self.sharedState->clickGain.store(g, std::memory_order_relaxed);
            [[NSUserDefaults standardUserDefaults] setFloat:g forKey:@"Jam_ClickGain"];
        }
    }
    else if ([type isEqualToString:@"studioTimeSig"]) {
        NSNumber* beats = body[@"beats"];
        if ([beats isKindOfClass:[NSNumber class]] && self.sharedState) {
            self.sharedState->beatsPerBar.store(beats.intValue == 3 ? 3 : 4,
                                                std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"studioBpm"]) {
        NSNumber* bpm = body[@"bpm"];
        if ([bpm isKindOfClass:[NSNumber class]] && self.sharedState) {
            const double v = bpm.doubleValue;
            if (v >= 40.0 && v <= 300.0) {
                // Manual calibration: drives the click/count-in grid, MIDI
                // export tempo and chord voicing — keep them in sync.
                self->_songAnalysis.bpm = (float)v;
                self.sharedState->stemBpm.store((float)v, std::memory_order_relaxed);
                [self sendStateUpdate:@{@"studioBpm": @(v)}];
            }
        }
    }
    else if ([type isEqualToString:@"studioKey"]) {
        // Manual key label — a record the operator can correct. Persisted
        // per-song so reloading the song restores the edit.
        NSString* k = body[@"key"];
        if ([k isKindOfClass:[NSString class]]) {
            _keyOverride = [k length] ? k : nil;
            NSString* dk = [@"Jam_SongKey_" stringByAppendingString:(_songName ?: @"")];
            if ([k length]) [[NSUserDefaults standardUserDefaults] setObject:k forKey:dk];
            else            [[NSUserDefaults standardUserDefaults] removeObjectForKey:dk];
        }
    }
    else if ([type isEqualToString:@"studioMemo"]) {
        // Free-text notes panel. Persisted per-song.
        NSString* m = body[@"text"];
        if ([m isKindOfClass:[NSString class]]) {
            _songMemo = m;
            NSString* dk = [@"Jam_SongMemo_" stringByAppendingString:(_songName ?: @"")];
            if ([m length]) [[NSUserDefaults standardUserDefaults] setObject:m forKey:dk];
            else            [[NSUserDefaults standardUserDefaults] removeObjectForKey:dk];
        }
    }
    else if ([type isEqualToString:@"liveSource"]) {
        NSNumber* src = body[@"source"];
        NSNumber* prog = body[@"program"];
        NSNumber* gain = body[@"gain"];
        if (self.sharedState) {
            if ([prog isKindOfClass:[NSNumber class]]) {
                self.sharedState->liveSfProgram.store(MAX(0, MIN(127, prog.intValue)),
                                                      std::memory_order_relaxed);
            }
            if ([gain isKindOfClass:[NSNumber class]]) {
                const float g = MAX(0.0f, MIN(1.2f, gain.floatValue));
                self.sharedState->liveGain.store(g, std::memory_order_relaxed);
                // The built-in synth (the other live source) has no separate
                // gain stage — drive its master volume from the same control.
                self.sharedState->synth.volume.store(g, std::memory_order_relaxed);
            }
            NSNumber* rev = body[@"reverb"];
            NSNumber* ech = body[@"echo"];
            if ([rev isKindOfClass:[NSNumber class]]) {
                const float v = MAX(0.0f, MIN(1.0f, rev.floatValue));
                self.sharedState->liveFx.reverb.store(v, std::memory_order_relaxed);
                // Built-in synth has its own plate — mirror the reverb there.
                self.sharedState->synth.space.store(v, std::memory_order_relaxed);
            }
            if ([ech isKindOfClass:[NSNumber class]]) {
                self.sharedState->liveFx.echo.store(MAX(0.0f, MIN(1.0f, ech.floatValue)),
                                                    std::memory_order_relaxed);
            }
            if ([src isKindOfClass:[NSNumber class]]) {
                [self handleLiveSource:src.intValue];
            } else {
                [self studioPushLive];
            }
        }
    }
    else if ([type isEqualToString:@"studioCue"]) {
        NSString* action = body[@"action"];
        NSNumber* sec = body[@"sec"];
        if ([action isKindOfClass:[NSString class]]) {
            [self handleStudioCue:action
                              sec:([sec isKindOfClass:[NSNumber class]] ? sec.doubleValue : -1.0)];
        }
    }
    else if ([type isEqualToString:@"studioMix"]) {
        NSNumber* idx = body[@"index"];
        JamSharedState* sh = self.sharedState;
        if ([idx isKindOfClass:[NSNumber class]] && sh &&
            idx.intValue >= 0 && idx.intValue < 8) {
            const int i = idx.intValue;
            NSNumber* mute = body[@"mute"];
            NSNumber* solo = body[@"solo"];
            NSNumber* gain = body[@"gain"];
            if ([mute isKindOfClass:[NSNumber class]]) {
                int m = sh->stemMuteMask.load(std::memory_order_relaxed);
                m = mute.boolValue ? (m | (1 << i)) : (m & ~(1 << i));
                sh->stemMuteMask.store(m, std::memory_order_relaxed);
            }
            if ([solo isKindOfClass:[NSNumber class]]) {
                int m = sh->stemSoloMask.load(std::memory_order_relaxed);
                m = solo.boolValue ? (m | (1 << i)) : (m & ~(1 << i));
                sh->stemSoloMask.store(m, std::memory_order_relaxed);
            }
            if ([gain isKindOfClass:[NSNumber class]]) {
                float g = gain.floatValue;
                if (g < 0) g = 0;
                if (g > 1.5f) g = 1.5f;
                sh->stemGain[i].store(g, std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"studioLoadPgm"]) {
        [self handleStudioLoadPgm];
    }
    else if ([type isEqualToString:@"studioStemToggle"]) {
        NSNumber* idx = body[@"index"];
        NSNumber* on = body[@"on"];
        if ([idx isKindOfClass:[NSNumber class]] && [on isKindOfClass:[NSNumber class]]) {
            [self handleStudioStemToggle:idx.intValue on:on.boolValue];
        }
    }
    else if ([type isEqualToString:@"studioSeek"]) {
        NSNumber* sec = body[@"sec"];
        if ([sec isKindOfClass:[NSNumber class]] && self.sharedState) {
            const long p = (long)(MAX(0.0, sec.doubleValue) * 48000.0);
            JamSharedState* sh = self.sharedState;
            if (sh->prevActive.load(std::memory_order_relaxed)) {
                const long len = sh->prevLen.load(std::memory_order_relaxed);
                sh->prevPos.store(MIN(p, MAX(0L, len - 1)), std::memory_order_relaxed);
            } else if (sh->stemLen.load(std::memory_order_relaxed) > 0) {
                const long len = sh->stemLen.load(std::memory_order_relaxed);
                sh->stemPos.store(MIN(p, MAX(0L, len - 1)), std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"studioPreview"]) {
        NSNumber* idx = body[@"index"];
        NSString* src = body[@"source"];
        NSNumber* on = body[@"on"];
        if ([idx isKindOfClass:[NSNumber class]] && [on isKindOfClass:[NSNumber class]]) {
            [self handleStudioPreview:idx.intValue
                               source:([src isKindOfClass:[NSString class]] ? src : @"stem")
                                   on:on.boolValue];
        }
    }
    else if ([type isEqualToString:@"studioPackage"]) {
        [self handleStudioPackage];
    }
    else if ([type isEqualToString:@"studioSepDownload"]) {
        [self handleSepModelDownload];
    }
    else if ([type isEqualToString:@"studioSepPick"]) {
        [self handleSepModelPick];
    }
    else if ([type isEqualToString:@"synthDice"]) {
        // Re-roll the arp pattern (Dice).
        if (self.sharedState) {
            self.sharedState->synth.diceSeed.fetch_add(
                (uint32_t)(arc4random() | 1), std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"synthMatrix"]) {
        // One mod-matrix cell: index 0..24 (src*5+dest), value -1..1.
        NSNumber* idxVal = body[@"index"];
        NSNumber* value = body[@"value"];
        if ([idxVal isKindOfClass:[NSNumber class]] &&
            [value isKindOfClass:[NSNumber class]] && self.sharedState) {
            const int idx = idxVal.intValue;
            if (idx >= 0 && idx < 25) {
                float v = value.floatValue;
                if (v < -1.0f) v = -1.0f;
                if (v > 1.0f) v = 1.0f;
                self.sharedState->synth.matrix[idx].store(v, std::memory_order_relaxed);
            }
        }
    }
    else if ([type isEqualToString:@"saveSynthPresets"]) {
        NSArray* presets = body[@"value"];
        if ([presets isKindOfClass:[NSArray class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:presets forKey:@"Jam_SynthPresets"];
        }
    }
    else if ([type isEqualToString:@"aiPatch"]) {
        NSString* desc = body[@"value"];
        NSNumber* lane = body[@"lane"];
        if ([desc isKindOfClass:[NSString class]] && desc.length > 0) {
            [self handleAiPatch:desc
                           lane:([lane isKindOfClass:[NSNumber class]] ? lane.intValue : -1)];
        }
    }
    else if ([type isEqualToString:@"aiCompose"]) {
        NSString* desc = body[@"value"];
        NSNumber* lane = body[@"lane"];
        if ([desc isKindOfClass:[NSString class]] && desc.length > 0 &&
            [lane isKindOfClass:[NSNumber class]]) {
            [self handleAiCompose:desc lane:lane.intValue];
        }
    }
    else if ([type isEqualToString:@"punchFx"]) {
        // Punch-in pad: id >= 0 engages/updates (value = amount), id -1 releases.
        NSNumber* fxIdVal = body[@"id"];
        NSNumber* amtVal = body[@"value"];
        if (self.sharedState && [fxIdVal isKindOfClass:[NSNumber class]]) {
            const int fxId = fxIdVal.intValue;
            if ([amtVal isKindOfClass:[NSNumber class]]) {
                float v = amtVal.floatValue;
                if (v < 0.0f) v = 0.0f;
                if (v > 1.0f) v = 1.0f;
                self.sharedState->punchAmt.store(v, std::memory_order_relaxed);
            }
            const int prev = self.sharedState->punchFx.load(std::memory_order_relaxed);
            if (fxId >= 0 && fxId != prev) {
                // Fresh engage → reset the punch DSP state on the audio thread.
                self.sharedState->punchGen.fetch_add(1, std::memory_order_relaxed);
            }
            self.sharedState->punchFx.store(fxId, std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"setEngineMode"]) {
        NSString* mode = body[@"value"];
        if ([mode isKindOfClass:[NSString class]] && self.useLyria) {
            BOOL lyria = [mode isEqualToString:@"lyria"];
            if (self.useLyria->load(std::memory_order_relaxed) != lyria) {
                // Stop playback in the CURRENT mode first: pauses/bypasses the
                // local engine, or hard-cuts the Lyria socket.
                if (_isPlaying) {
                    [NSApp sendAction:@selector(menuTogglePlayStop:) to:nil from:self];
                }
                self.useLyria->store(lyria, std::memory_order_relaxed);
                // Safety: never leave a socket open when leaving Lyria mode.
                if (!lyria) [self.lyriaClient disconnect];
            }
        }
    }
    else if ([type isEqualToString:@"lyriaConfig"]) {
        if (!self.lyriaClient) return;
        NSMutableDictionary* cfg = [NSMutableDictionary dictionary];
        for (NSString* key in @[@"bpm", @"temperature", @"density",
                                @"brightness", @"scale", @"guidance",
                                @"muteBass", @"muteDrums", @"onlyBassAndDrums"]) {
            id v = body[key];
            if (v) cfg[key] = v;
        }
        if (cfg.count > 0) [self.lyriaClient setConfig:cfg];
    }
    else if ([type isEqualToString:@"copyText"]) {
        NSString* text = body[@"value"];
        if ([text isKindOfClass:[NSString class]] && text.length > 0) {
            NSPasteboard* pb = [NSPasteboard generalPasteboard];
            [pb clearContents];
            [pb setString:text forType:NSPasteboardTypeString];
        }
    }
    else if ([type isEqualToString:@"setLyriaKey"]) {
        NSString* key = body[@"value"];
        if ([key isKindOfClass:[NSString class]]) {
            NSString* trimmed = [key stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length)
                [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:@"Jam_LyriaApiKey"];
            else
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"Jam_LyriaApiKey"];
            [self sendStateUpdate:@{@"lyriaKeySet": @(trimmed.length > 0)}];
        }
    }
    else if ([type isEqualToString:@"aiPrompt"]) {
        NSString* idea = body[@"value"];
        NSArray* history = body[@"history"];
        if ([idea isKindOfClass:[NSString class]] && idea.length > 0) {
            [self handleAiPrompt:idea
                         history:([history isKindOfClass:[NSArray class]] ? history : @[])];
        }
    }
    else if ([type isEqualToString:@"exportSession"]) {
        NSString* json = body[@"value"];
        if ([json isKindOfClass:[NSString class]] && json.length > 0) {
            [self handleExportSession:json];
        }
    }
    else if ([type isEqualToString:@"importSession"]) {
        [self handleImportSession];
    }
    else if ([type isEqualToString:@"setSoloMode"]) {
        NSNumber* valueVal = body[@"value"];
        if (valueVal) {
            BOOL solo = valueVal.boolValue;
            if (self.soloMode) {
                self.soloMode->store(solo, std::memory_order_relaxed);
            }
            [[NSUserDefaults standardUserDefaults] setBool:solo forKey:@"Jam_SoloMode"];
        }
    }
    else if ([type isEqualToString:@"textPrompts"]) {
        NSArray* promptsArray = body[@"value"];

        // Cache/forward to the Lyria client (it only transmits while a
        // session is open). SOLO prefixes are local-engine concepts.
        if ([promptsArray isKindOfClass:[NSArray class]] && self.lyriaClient) {
            NSMutableArray* weighted = [NSMutableArray array];
            for (NSDictionary* p in promptsArray) {
                NSString* text = p[@"text"];
                NSNumber* weight = p[@"weight"];
                if (![text isKindOfClass:[NSString class]] ||
                    ![weight isKindOfClass:[NSNumber class]]) continue;
                if ([text hasPrefix:@"SOLO "]) text = [text substringFromIndex:5];
                NSString* trimmed = [text stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length == 0 || weight.floatValue <= 0.0f) continue;
                [weighted addObject:@{@"text" : trimmed, @"weight" : weight}];
            }
            if (weighted.count > 0) [self.lyriaClient setWeightedPrompts:weighted];
        }

        if ([promptsArray isKindOfClass:[NSArray class]] && self.engine) {
            std::vector<std::string> texts;
            std::vector<float> weights;
            for (NSDictionary* p in promptsArray) {
                NSString* text = p[@"text"];
                NSNumber* weight = p[@"weight"];
                if ([text isKindOfClass:[NSString class]] && [weight isKindOfClass:[NSNumber class]]) {
                    NSString* trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmed.length == 0 || [trimmed isEqualToString:@"SOLO"]) {
                        texts.push_back("silence");
                    } else {
                        texts.push_back(text.UTF8String);
                    }
                    weights.push_back(weight.floatValue);
                }
            }
            self.engine->set_text_prompts(texts, weights);
            self.engine->set_blend_weights(weights.data(), (int)weights.size());

            // Persist current prompt and history
            if (promptsArray.count > 0) {
                NSDictionary* p0 = promptsArray[0];
                NSString* prompt = p0[@"text"];
                if ([prompt isKindOfClass:[NSString class]]) {
                    if ([prompt hasPrefix:@"SOLO "]) {
                        prompt = [prompt substringFromIndex:5];
                    } else if ([prompt isEqualToString:@"SOLO"]) {
                        prompt = @"";
                    }
                    _currentPromptText = prompt;
                    [[NSUserDefaults standardUserDefaults] setObject:prompt forKey:@"Jam_Prompt"];
                }
            }
        }
    }
    else if ([type isEqualToString:@"loadModel"]) {
        [self handleLoadModel];
    }
    else if ([type isEqualToString:@"listLocalModels"]) {
        [self handleListLocalModels];
    }
    else if ([type isEqualToString:@"listRemoteModels"]) {
        [MagentaModelDownloader listRemoteModelsWithCompletion:^(NSArray<NSString *> *models, NSError *error) {
            if (error) {
                [self sendStateUpdate:@{@"remoteModelsError": error.localizedDescription}];
            } else {
                [self sendStateUpdate:@{@"remoteModels": models}];
            }
        }];
    }
    else if ([type isEqualToString:@"downloadModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [MagentaModelDownloader downloadModel:name progress:^(double progress, NSString *status) {
                [self sendStateUpdate:@{
                    @"downloadProgress": @{
                        @"status": @"downloading",
                        @"percent": @(progress),
                        @"text": status,
                        @"modelName": name
                    }
                }];
            } completion:^(BOOL success, NSError *error) {
                if (success) {
                    [self sendStateUpdate:@{
                        @"downloadProgress": @{
                            @"status": @"success",
                            @"percent": @(1.0),
                            @"text": @"Download Complete!",
                            @"modelName": name
                        }
                    }];
                    [self handleListLocalModels];
                } else {
                    [self sendStateUpdate:@{
                        @"downloadProgress": @{
                            @"status": @"error",
                            @"percent": @(0.0),
                            @"text": error.localizedDescription ?: @"Download Failed",
                            @"modelName": name
                        }
                    }];
                }
            }];
        }
    }
    else if ([type isEqualToString:@"selectDownloadFolder"]) {
        [self handleSelectDownloadFolder];
    }
    else if ([type isEqualToString:@"selectModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [self handleSelectModel:name];
        }
    }
    else if ([type isEqualToString:@"deleteModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [self handleDeleteModel:name];
        }
    }
    else if ([type isEqualToString:@"initResources"]) {
        NSString* modelName = body[@"modelName"];
        [self handleInitResources:modelName];
    }
    else if ([type isEqualToString:@"loadAudioPrompt"]) {
        [self handleLoadAudioPrompt:0];
    }
    else if ([type isEqualToString:@"startRecordAudioPrompt"]) {
        [self startRecordingAudioPrompt];
    }
    else if ([type isEqualToString:@"stopRecordAudioPrompt"]) {
        [self stopRecordingAudioPrompt];
    }
    else if ([type isEqualToString:@"loadVisualImage"]) {
        [self handleLoadVisualImage];
    }
    else if ([type isEqualToString:@"clearAudioPrompt"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RealtimeRunner* engine = self.engine;
            if (engine) {
                engine->set_audio_prompt(0, "");
            }
            [self sendStateUpdate:@{
                @"prompt": self->_currentPromptText ?: @"",
                @"isAudioPrompt": @NO,
            }];
        });
    }
    else if ([type isEqualToString:@"activeTab"]) {
        NSString* tab = body[@"tab"];
        if ([tab isKindOfClass:[NSString class]] && self.sharedState) {
            self.sharedState->jamTabActive.store(
                [tab isEqualToString:@"jam"], std::memory_order_relaxed);
        }
    }
    else if ([type isEqualToString:@"kbdNote"]) {
        NSNumber* noteVal = body[@"note"];
        NSNumber* onVal = body[@"on"];
        NSNumber* pulseVal = body[@"pulse"];
        if (!noteVal || !onVal || !self.engine) return;
        uint8_t note = (uint8_t)MIN(127, MAX(0, noteVal.intValue));
        BOOL on = onVal.boolValue;
        // BPM-lock metronome pulses condition the generative engine ONLY —
        // never the synth (they'd stomp the arp's held notes / hold latch).
        BOOL isPulse = [pulseVal isKindOfClass:[NSNumber class]] && pulseVal.boolValue;
        // Routing (see the MIDI port handler for the full rationale):
        //   synth   when the synth is active, or off the jam tab
        //   engine  when on the jam tab with synth inactive (pure jam), OR the
        //           instrument is set to follow the jam
        // Metronome pulses always condition the engine and never the synth.
        const BOOL jamActive = self.sharedState &&
            self.sharedState->jamTabActive.load(std::memory_order_relaxed);
        const BOOL synthActive = self.sharedState &&
            self.sharedState->synth.active.load(std::memory_order_relaxed);
        const BOOL follow = self.sharedState &&
            self.sharedState->instrumentFollowsJam.load(std::memory_order_relaxed);
        const BOOL toSynth = !isPulse && (synthActive || !jamActive);
        const BOOL toEngine = isPulse ||
            (jamActive && !synthActive) || (synthActive && follow);
        if (self.sharedState && (toSynth || !on)) {
            self.sharedState->routeLiveNote(note, on ? 100 : 0, on);
        }
        if (toEngine) {
            if (on) {
                self.engine->set_note_on(note);
                if (self.sharedState) self.sharedState->noteOn(note);
            } else {
                self.engine->set_note_off(note);
                if (self.sharedState) self.sharedState->noteOff(note);
            }
        }
    }
    else if ([type isEqualToString:@"togglePlay"]) {
        NSNumber* valueVal = body[@"value"];
        if (valueVal != nil) {
            BOOL target = valueVal.boolValue;
            if (target != _isPlaying) {
                [NSApp sendAction:@selector(menuTogglePlayStop:) to:nil from:self];
            }
        } else {
            [NSApp sendAction:@selector(menuTogglePlayStop:) to:nil from:self];
        }
    }
    else if ([type isEqualToString:@"openSettings"]) {
        [NSApp sendAction:@selector(menuShowSettings:) to:nil from:self];
    }
    else if ([type isEqualToString:@"setHandTracking"]) {
        [self setHandTrackingEnabled:[body[@"enabled"] boolValue]];
    }
    else if ([type isEqualToString:@"savePromptHistory"]) {
        NSArray* history = body[@"history"];
        NSNumber* index = body[@"index"];
        if (history) [[NSUserDefaults standardUserDefaults] setObject:history forKey:@"Jam_PromptHistory"];
        if (index) [[NSUserDefaults standardUserDefaults] setObject:index forKey:@"Jam_HistoryIndex"];
    }
    else if ([type isEqualToString:@"saveUserPresets"]) {
        NSDictionary* solo = body[@"solo"];
        NSDictionary* jam = body[@"jam"];
        if ([solo isKindOfClass:[NSDictionary class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:solo forKey:@"Jam_UserPresetsSolo"];
        }
        if ([jam isKindOfClass:[NSDictionary class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:jam forKey:@"Jam_UserPresetsJam"];
        }
    }
    else if ([type isEqualToString:@"saveRockerIndex"]) {
        NSNumber* value = body[@"value"];
        if (value) {
            [[NSUserDefaults standardUserDefaults] setObject:value forKey:@"Jam_RockerIndex"];
        }
    }
    else if ([type isEqualToString:@"saveMixPrompts"]) {
        NSArray* chips = body[@"value"];
        if ([chips isKindOfClass:[NSArray class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:chips forKey:@"Jam_MixPrompts"];
        }
    }
    else if ([type isEqualToString:@"log"]) {
        NSString* val = body[@"value"];
        if (val) NSLog(@"Jam UI: %@", val);
    }
    else if ([type isEqualToString:@"selectMidiSource"]) {
        NSNumber* endpointVal = body[@"endpoint"];
        if (endpointVal) {
            uint32_t endpoint = endpointVal.unsignedIntValue;
            [self selectMidiInput:endpoint];
        }
    }
    else if ([type isEqualToString:@"uiReady"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToEngine];
            [self studioPushSepPipeline];
            [self studioPushLive];
            [self sendStateUpdate:@{@"audioMultichannel":
                @([[NSUserDefaults standardUserDefaults] boolForKey:@"Jam_MultichannelOut"])}];
            [self sendStateUpdate:@{@"studioClickGain":
                @(self.sharedState->clickGain.load(std::memory_order_relaxed))}];
            // Re-apply persisted 现场模式 (creates the assertion + pushes state).
            [self setLiveMode:[[NSUserDefaults standardUserDefaults] boolForKey:@"Jam_LiveMode"]];
            // Whether a Lyria API key is configured (never send the key itself).
            NSString* lk = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_LyriaApiKey"];
            [self sendStateUpdate:@{@"lyriaKeySet": @(lk.length > 0)}];
        });
    }
    else if ([type isEqualToString:@"sepPipeline"]) {
        NSString* mode = body[@"mode"];
        if ([mode isKindOfClass:[NSString class]]) {
            [self handleSepPipeline:mode];
        }
    }
}

// ─── Model loading (shared core) ─────────────────────────────────────────────

- (void)loadModelAtPath:(NSString*)mlxfnPath {
    RealtimeRunner* engine = self.engine;
    if (!engine) return;

    NSLog(@"Jam: Loading model from %@", mlxfnPath);
    BOOL success = engine->load_model(mlxfnPath.UTF8String);

    if (success) {
        _modelName = mlxfnPath.lastPathComponent;

        // Auto-load corpus
        NSString* parentDir = [mlxfnPath stringByDeletingLastPathComponent];
        NSString* corpusPath = [parentDir stringByAppendingPathComponent:@"corpus.safetensors"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:corpusPath]) {
            engine->load_pca_file(corpusPath.UTF8String);
        }

        // Re-apply prompt to engine with proper SOLO prefix
        NSString* savedPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_Prompt"];
        NSString* promptToUse = _currentPromptText.length > 0 ? _currentPromptText
                                : (savedPrompt.length > 0 ? savedPrompt : @"");
        _currentPromptText = promptToUse;
        BOOL isSolo = self.soloMode ? self.soloMode->load(std::memory_order_relaxed) : YES;
        NSString* cleanPrompt = [promptToUse stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString* engineText = @"";
        if (cleanPrompt.length == 0) {
            engineText = @"silence";
        } else {
            engineText = isSolo ? [NSString stringWithFormat:@"SOLO %@", cleanPrompt] : cleanPrompt;
        }
        std::vector<std::string> texts = {engineText.UTF8String, "", "", "", "", ""};
        std::vector<float> weights = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        engine->set_text_prompts(texts, weights);
        engine->set_blend_weights(weights.data(), (int)weights.size());

        [self sendStateUpdate:@{
            @"modelName": mlxfnPath.lastPathComponent,
            @"prompt": promptToUse
        }];

        [[NSUserDefaults standardUserDefaults] setObject:mlxfnPath forKey:@"Jam_ModelPath"];
    } else {
        [self sendStateUpdate:@{@"modelName": [NSString stringWithFormat:@"Failed: %@", mlxfnPath.lastPathComponent]}];
    }
}

- (void)handleLoadModel {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:YES];
    [panel setMessage:@"Select the directory containing your model, or the .mlxfn file."];

    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString* path = url.path;
            BOOL isDir = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

            NSString* mlxfnPath = nil;
            if (isDir) {
                NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
                for (NSString *file in contents) {
                    if ([file hasSuffix:@".mlxfn"]) {
                        mlxfnPath = [path stringByAppendingPathComponent:file];
                        break;
                    }
                }
            } else if ([path hasSuffix:@".mlxfn"]) {
                mlxfnPath = path;
            }

            if (!mlxfnPath) {
                [self sendStateUpdate:@{@"modelName": @"No .mlxfn found"}];
                return;
            }

            [self loadModelAtPath:mlxfnPath];
        });
    };

    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

// ─── Audio prompt loading ────────────────────────────────────────────────────

- (void)loadAudioPromptFileAtPath:(NSString*)path index:(int)index {
    dispatch_async(dispatch_get_main_queue(), ^{
        RealtimeRunner* engine = self.engine;
        if (!engine) return;

        NSString* filename = path.lastPathComponent;
        BOOL readSuccess = NO;
        NSURL* url = [NSURL fileURLWithPath:path];

        ExtAudioFileRef extFile = nullptr;
        OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &extFile);
        if (status == noErr && extFile) {
            AudioStreamBasicDescription clientFormat = {};
            clientFormat.mSampleRate = 16000.0;
            clientFormat.mFormatID = kAudioFormatLinearPCM;
            clientFormat.mFormatFlags = kAudioFormatFlagIsFloat;
            clientFormat.mBitsPerChannel = 32;
            clientFormat.mChannelsPerFrame = 1;
            clientFormat.mBytesPerFrame = 4;
            clientFormat.mFramesPerPacket = 1;
            clientFormat.mBytesPerPacket = 4;

            status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                              sizeof(clientFormat), &clientFormat);
            if (status == noErr) {
                int maxFrames = 160000;
                std::vector<float> samples(maxFrames, 0.0f);
                AudioBufferList bufferList;
                bufferList.mNumberBuffers = 1;
                bufferList.mBuffers[0].mNumberChannels = 1;
                bufferList.mBuffers[0].mDataByteSize = maxFrames * sizeof(float);
                bufferList.mBuffers[0].mData = samples.data();

                UInt32 framesToRead = maxFrames;
                status = ExtAudioFileRead(extFile, &framesToRead, &bufferList);
                if (status == noErr && framesToRead > 0) {
                    if (framesToRead < (UInt32)maxFrames) {
                        for (UInt32 i = framesToRead; i < (UInt32)maxFrames; ++i)
                            samples[i] = samples[i % framesToRead];
                    }
                    engine->set_audio_prompt_samples(index, filename.UTF8String, samples.data(), maxFrames);
                    readSuccess = YES;
                }
            }
            ExtAudioFileDispose(extFile);
        }

        [self sendStateUpdate:@{
            @"prompt": readSuccess ? filename : @"Error: Load failed",
            @"isAudioPrompt": @(readSuccess),
        }];
    });
}

- (void)handleLoadAudioPrompt:(int)index {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.audio"]]];
    [panel setMessage:@"Select an audio file for the prompt"];

    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;

        [self loadAudioPromptFileAtPath:url.path index:index];
    };

    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

// ─── Audio-prompt recording (microphone) ────────────────────────────────────
// The engine consumes a fixed 160000-frame (10s @ 16kHz) mono buffer for an
// audio prompt. We capture from the default input device, resample to 16kHz
// mono, cap at 10s (auto-stop), and loop-fill if the take is shorter.

static const int kAudioPromptFrames = 160000; // 10s @ 16kHz

- (void)startRecordingAudioPrompt {
    if (_isRecording) return;
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (st == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) {
                    [self beginMicCapture];
                } else {
                    [self sendStateUpdate:@{@"recordingState": @"idle",
                                            @"sessionError": @"Microphone access denied"}];
                }
            });
        }];
        return;
    }
    if (st != AVAuthorizationStatusAuthorized) {
        [self sendStateUpdate:@{@"recordingState": @"idle",
                                @"sessionError": @"Microphone access denied — enable it in System Settings › Privacy"}];
        return;
    }
    [self beginMicCapture];
}

- (void)beginMicCapture {
    _recordSamples.clear();
    _recordSamples.reserve(kAudioPromptFrames);

    _recordEngine = [[AVAudioEngine alloc] init];
    AVAudioInputNode* input = _recordEngine.inputNode;
    AVAudioFormat* inFmt = [input outputFormatForBus:0];
    if (!inFmt || inFmt.sampleRate <= 0 || inFmt.channelCount == 0) {
        _recordEngine = nil;
        [self sendStateUpdate:@{@"recordingState": @"idle",
                                @"sessionError": @"No microphone input available"}];
        return;
    }
    AVAudioFormat* outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                            sampleRate:16000.0
                                                              channels:1
                                                           interleaved:NO];
    _recordConverter = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:outFmt];
    if (!_recordConverter) {
        _recordEngine = nil;
        [self sendStateUpdate:@{@"recordingState": @"idle",
                                @"sessionError": @"Audio converter init failed"}];
        return;
    }

    const double ratio = 16000.0 / inFmt.sampleRate;
    __weak JamAppController* weakSelf = self;
    [input installTapOnBus:0 bufferSize:4096 format:inFmt block:^(AVAudioPCMBuffer* buf, AVAudioTime* when) {
        JamAppController* s = weakSelf;
        if (!s || !s->_isRecording || buf.frameLength == 0) return;
        AVAudioFrameCount outCap = (AVAudioFrameCount)(buf.frameLength * ratio) + 64;
        AVAudioPCMBuffer* outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:outCap];
        if (!outBuf) return;
        __block BOOL fed = NO;
        AVAudioConverterInputBlock inputBlock = ^AVAudioBuffer*(AVAudioPacketCount need, AVAudioConverterInputStatus* status) {
            if (fed) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            fed = YES;
            *status = AVAudioConverterInputStatus_HaveData;
            return buf;
        };
        NSError* err = nil;
        [s->_recordConverter convertToBuffer:outBuf error:&err withInputFromBlock:inputBlock];
        const float* data = outBuf.floatChannelData ? outBuf.floatChannelData[0] : NULL;
        AVAudioFrameCount n = outBuf.frameLength;
        if (!data || n == 0) return;
        BOOL full = NO;
        @synchronized (s) {
            for (AVAudioFrameCount i = 0; i < n && (int)s->_recordSamples.size() < kAudioPromptFrames; ++i) {
                s->_recordSamples.push_back(data[i]);
            }
            full = ((int)s->_recordSamples.size() >= kAudioPromptFrames);
        }
        if (full) {
            dispatch_async(dispatch_get_main_queue(), ^{ [s stopRecordingAudioPrompt]; });
        }
    }];

    NSError* startErr = nil;
    _isRecording = YES;
    if (![_recordEngine startAndReturnError:&startErr]) {
        _isRecording = NO;
        [input removeTapOnBus:0];
        _recordEngine = nil;
        _recordConverter = nil;
        [self sendStateUpdate:@{@"recordingState": @"idle",
                                @"sessionError": @"Could not start microphone"}];
        return;
    }
    [self sendStateUpdate:@{@"recordingState": @"recording"}];
}

- (void)stopRecordingAudioPrompt {
    if (!_isRecording) return;
    _isRecording = NO;
    if (_recordEngine) {
        [_recordEngine.inputNode removeTapOnBus:0];
        [_recordEngine stop];
        _recordEngine = nil;
    }
    _recordConverter = nil;

    std::vector<float> samples;
    @synchronized (self) {
        samples.swap(_recordSamples);
    }
    if (samples.empty()) {
        [self sendStateUpdate:@{@"recordingState": @"idle",
                                @"sessionError": @"No audio recorded"}];
        return;
    }

    // Loop-fill to the fixed prompt length, matching the file-load path.
    std::vector<float> out(kAudioPromptFrames, 0.0f);
    const size_t srcLen = samples.size();
    for (int i = 0; i < kAudioPromptFrames; ++i) out[i] = samples[i % srcLen];

    RealtimeRunner* engine = self.engine;
    if (engine) {
        engine->set_audio_prompt_samples(0, "recording", out.data(), kAudioPromptFrames);
    }
    [self sendStateUpdate:@{
        @"recordingState": @"idle",
        @"prompt": @"recording",
        @"isAudioPrompt": @YES,
    }];
}

- (void)handleLoadVisualImage {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.image"]]];
    [panel setMessage:@"Select an image for the visual layer"];

    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData* data = [NSData dataWithContentsOfURL:url];
            if (!data) return;
            // Cap very large files so the data URL stays reasonable for IPC.
            if (data.length > 12 * 1024 * 1024) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self sendStateUpdate:@{@"visualImageError": @"Image too large (max 12 MB)"}];
                });
                return;
            }
            NSString* ext = url.pathExtension.lowercaseString;
            NSString* mime = @"image/png";
            if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) mime = @"image/jpeg";
            else if ([ext isEqualToString:@"gif"]) mime = @"image/gif";
            else if ([ext isEqualToString:@"webp"]) mime = @"image/webp";
            else if ([ext isEqualToString:@"bmp"]) mime = @"image/bmp";
            NSString* dataUrl = [NSString stringWithFormat:@"data:%@;base64,%@",
                mime, [data base64EncodedStringWithOptions:0]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self sendStateUpdate:@{@"visualImage": dataUrl}];
            });
        });
    };

    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

// ─── AI prompt assist (agentllm, model c-music-express) ─────────────────────
// Turns a free-form idea (any language) into a concise English music prompt
// tuned for this engine. Reuses the Lyria API key; runs off the main thread.

// ─── PGM studio ──────────────────────────────────────────────────────────────
// Upload a song → analyze (BPM/key/sections) + HPSS stem separation → cover
// each stem with the local model (stem slice as audio prompt, take recorded
// from the engine output) → A/B against the original → package as a PGM.

static NSArray* JamWaveThumb(const float* L, const float* R, long n, int points) {
    NSMutableArray* arr = [NSMutableArray arrayWithCapacity:points];
    if (n <= 0) { for (int i = 0; i < points; i++) [arr addObject:@0]; return arr; }
    const long step = MAX(1L, n / points);
    for (int p = 0; p < points; ++p) {
        const long s0 = p * step;
        float peak = 0;
        for (long i = s0; i < MIN(n, s0 + step); i += 16) {
            const float v = std::fabs(L[i]) + (R ? std::fabs(R[i]) : 0.0f);
            if (v > peak) peak = v;
        }
        [arr addObject:@(MIN(1.0f, peak * (R ? 0.55f : 1.0f)))];
    }
    return arr;
}

static NSArray* JamWaveThumbI16(const int16_t* interleaved, long frames, int points) {
    NSMutableArray* arr = [NSMutableArray arrayWithCapacity:points];
    if (frames <= 0) return @[];   // empty lane -> empty thumb (UI keys off length)
    const long step = MAX(1L, frames / points);
    for (int p = 0; p < points; ++p) {
        const long s0 = p * step;
        float peak = 0;
        for (long i = s0; i < MIN(frames, s0 + step); i += 16) {
            const float v = (std::fabs((float)interleaved[i * 2]) +
                             std::fabs((float)interleaved[i * 2 + 1])) / 65536.0f;
            if (v > peak) peak = v;
        }
        [arr addObject:@(MIN(1.0f, peak * 1.1f))];
    }
    return arr;
}

static NSString* const kJamKeyNames[12] = {@"C", @"C#", @"D", @"D#", @"E", @"F",
                                           @"F#", @"G", @"G#", @"A", @"A#", @"B"};

- (void)studioProgress:(NSString*)stage pct:(float)pct {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self sendStateUpdate:@{@"studioProgress": @{@"stage": stage, @"pct": @(pct)}}];
    });
}

- (void)handleStudioLoadSong {
    if (_studioBusy) return;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.audio"]]];
    [panel setMessage:@"Select a song to turn into a live PGM"];
    void (^completion)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;
        self->_studioBusy = YES;
        self->_songName = url.lastPathComponent;
        self->_songURL = url;
        [self studioUnpublishStems];
        self.sharedState->prevActive.store(false, std::memory_order_relaxed);
        [self studioProgress:@"decoding" pct:0.02f];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self studioDecodeAnalyzeSeparate:url];
        });
    };
    if (self.view.window) [panel beginSheetModalForWindow:self.view.window completionHandler:completion];
    else [panel beginWithCompletionHandler:completion];
}

- (void)studioDecodeAnalyzeSeparate:(NSURL*)url {
    // 1. Decode to 48 kHz stereo float (cap 8 minutes).
    ExtAudioFileRef f = nullptr;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &f) != noErr || !f) {
        [self studioFail:@"could not open the file"];
        return;
    }
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = 48000.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    fmt.mBitsPerChannel = 32;
    fmt.mChannelsPerFrame = 2;
    fmt.mBytesPerFrame = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = 4;
    ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(fmt), &fmt);
    const long maxFrames = 48000L * 60 * 8;
    _songL.clear(); _songR.clear();
    _songL.reserve(48000L * 240); _songR.reserve(48000L * 240);
    const UInt32 chunk = 1 << 16;
    std::vector<float> bufL(chunk), bufR(chunk);
    while ((long)_songL.size() < maxFrames) {
        // AudioBufferList has storage for ONE buffer; allocate room for two.
        struct { AudioBufferList list; AudioBuffer extra; } ablMem = {};
        AudioBufferList& abl = ablMem.list;
        abl.mNumberBuffers = 2;
        abl.mBuffers[0] = {1, chunk * 4, bufL.data()};
        abl.mBuffers[1] = {1, chunk * 4, bufR.data()};
        UInt32 n = chunk;
        if (ExtAudioFileRead(f, &n, &abl) != noErr || n == 0) break;
        _songL.insert(_songL.end(), bufL.begin(), bufL.begin() + n);
        _songR.insert(_songR.end(), bufR.begin(), bufR.begin() + n);
    }
    ExtAudioFileDispose(f);
    const long n = (long)_songL.size();
    if (n < 48000L * 10) {
        [self studioFail:@"song too short (need ≥10 s)"];
        return;
    }
    _songDur = n / 48000.0;

    // 2. Analysis on a mono mix.
    [self studioProgress:@"analyzing" pct:0.12f];
    std::vector<float> mono(n);
    for (long i = 0; i < n; ++i) mono[i] = (_songL[i] + _songR[i]) * 0.5f;
    _songAnalysis = jamstudio::analyze(mono.data(), n);
    {
        // Refine the beat grid (sub-BPM tempo + first-beat offset + downbeat)
        // so the click metronome and count-in actually line up with the song.
        jamstudio::BeatGrid bg =
            jamstudio::beatGrid(mono.data(), n, _songAnalysis.bpm);
        _songAnalysis.bpm = bg.bpm;
        self.sharedState->stemBpm.store(bg.bpm, std::memory_order_relaxed);
        self.sharedState->stemBeatOff.store((long)(bg.offsetSec * 48000.0),
                                            std::memory_order_relaxed);
        self.sharedState->stemBarPhase.store(bg.barPhase, std::memory_order_relaxed);
    }

    NSMutableArray* sections = [NSMutableArray array];
    static NSString* const labels[4] = {@"break", @"verse", @"drop", @"build"};
    for (const auto& s : _songAnalysis.sections) {
        [sections addObject:@{@"start": @(s.start), @"end": @(s.end),
                              @"label": labels[s.label & 3], @"energy": @(s.energy)}];
    }
    NSString* key = [NSString stringWithFormat:@"%@ %@",
                     kJamKeyNames[_songAnalysis.keyIdx],
                     _songAnalysis.minor ? @"minor" : @"major"];
    // Restore any per-song manual key / notes edits.
    NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
    NSString* savedKey = [defs stringForKey:[@"Jam_SongKey_" stringByAppendingString:(_songName ?: @"")]];
    _keyOverride = savedKey.length ? savedKey : nil;
    if (_keyOverride) key = _keyOverride;
    _songMemo = [defs stringForKey:[@"Jam_SongMemo_" stringByAppendingString:(_songName ?: @"")]] ?: @"";
    NSString* memo = _songMemo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self sendStateUpdate:@{@"studioSong": @{
            @"name": self->_songName ?: @"song",
            @"duration": @(self->_songDur),
            @"bpm": @((int)lroundf(self->_songAnalysis.bpm)),
            @"key": key,
            @"memo": memo,
            @"sections": sections,
            @"wave": JamWaveThumb(self->_songL.data(), self->_songR.data(),
                                  (long)self->_songL.size(), 480),
        }}];
    });

    // Decode + analysis done — separation is an explicit user action
    // (the ✂ Separate button), so a model downloaded later still applies.
    for (int i = 0; i < 8; ++i) {
        _stems[i].clear();
        _takeL[i].clear();
        _takeR[i].clear();
        _stemNotes[i].clear();
    }
    _chords.clear();
    _cueSec = -1.0;
    _clickAnchorSec = -1.0;
    self.sharedState->stemCue.store(-1, std::memory_order_relaxed);
    // Drop all MIDI lanes (the new song invalidates every clip).
    for (int t = 0; t < 8; ++t) {
        _laneClip[t].clear();
        if (t >= 1) {
            const int k = t - 1;
            self.sharedState->stemSource[t].store(0, std::memory_order_relaxed);
            self.sharedState->laneEv[k].store(nullptr, std::memory_order_relaxed);
            self.sharedState->laneCount[k].store(0, std::memory_order_relaxed);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // The render thread has dropped the old pointers by now (60 ms+).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            for (int t = 0; t < 8; ++t) self->_laneEvBuf[t].clear();
        });
        [self studioPushChords];
        [self studioPushSources];
        [self studioPushCue];
        self->_studioBusy = NO;
        [self studioProgress:@"ready" pct:1.0f];
    });
}

- (void)handleStudioSeparate {
    if (_studioBusy) return;
    if (_songL.empty() || !_songURL) {
        [self sendStateUpdate:@{@"studioError": @"load a song first"}];
        return;
    }
    _studioBusy = YES;
    [self studioUnpublishStems];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        usleep(60000);   // let the render thread drop any old stem pointers
        [self studioRunSeparation];
    });
}

// Stem separation: neural (htdemucs 4/6 stems) when weights are present,
// classic HPSS (3 stems) as the fallback. Background thread.
- (void)studioRunSeparation {
    const long n = (long)_songL.size();
    NSString* sepPath = [self sepModelPath];
    BOOL neural = NO;
    BOOL usedRf = NO;
    int nSources = 3;

    // Stage A (optional, model-gated): BS-RoFormer vocals — SOTA vocal
    // isolation. The instrumental (mix − vocals) then goes to htdemucs,
    // which separates the rest cleaner without vocal interference.
    NSString* pipeline = [self sepPipeline];
    NSString* rfPath = [self rfModelPath];
    const BOOL rfOnly = [pipeline isEqualToString:@"rf2"];
    const BOOL wantDemucs = !rfOnly && ![pipeline isEqualToString:@"hpss"];
    const BOOL wantRf = [pipeline isEqualToString:@"rf"] ||
        ([pipeline isEqualToString:@"auto"] &&
         [[NSFileManager defaultManager] fileExistsAtPath:rfPath]);

    // RF-only 2-stem pipeline: vocals + instrumental, no demucs pass.
    if (rfOnly) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:rfPath]) {
            [self studioFail:@"BS-RoFormer 模型未下载（在管线菜单重新选择以下载）"];
            return;
        }
        [self studioProgress:@"separating (BS-RoFormer 2-stem)" pct:0.01f];
        NSString* rfErr = nil;
        std::vector<float> vL, vR;
        if (!JamRoformerVocals(rfPath, _songL.data(), _songR.data(), n, vL, vR,
                               ^(float p) { [self studioProgress:@"separating (BS-RoFormer 2-stem)"
                                                             pct:0.01f + p * 0.95f]; },
                               &rfErr)) {
            [self studioFail:rfErr ?: @"BS-RoFormer separation failed"];
            return;
        }
        for (int i = 0; i < 8; ++i) {
            if (i < 6) _stems[i].clear();
            _takeL[i].clear();
            _takeR[i].clear();
            _stemNotes[i].clear();
        }
        _stems[3].assign(n * 2, 0);    // vocals
        _stems[2].assign(n * 2, 0);    // other = instrumental
        for (long i = 0; i < n; ++i) {
            const float vl = vL[i] * 32767.0f, vr = vR[i] * 32767.0f;
            const float ol = (_songL[i] - vL[i]) * 32767.0f;
            const float orr = (_songR[i] - vR[i]) * 32767.0f;
            _stems[3][i * 2] = (int16_t)MAX(-32768.0f, MIN(32767.0f, vl));
            _stems[3][i * 2 + 1] = (int16_t)MAX(-32768.0f, MIN(32767.0f, vr));
            _stems[2][i * 2] = (int16_t)MAX(-32768.0f, MIN(32767.0f, ol));
            _stems[2][i * 2 + 1] = (int16_t)MAX(-32768.0f, MIN(32767.0f, orr));
        }
        _stemSource[2] = _stemSource[3] = @"neural";
        for (int i : {0, 1, 4, 5}) _stemSource[i] = nil;
        [self studioRefineBeatGridFromDrums];   // no drums → keeps song grid
        dispatch_async(dispatch_get_main_queue(), ^{
            [self studioPushStemWaves];
            [self sendStateUpdate:@{@"studioSepEngine": @"BS-RoFormer"}];
            [self studioPublishStems];
            self->_studioBusy = NO;
            [self studioProgress:@"ready" pct:1.0f];
        });
        return;
    }
    std::vector<float> rfVocL, rfVocR;
    NSURL* demucsURL = _songURL;
    NSURL* rfTmpURL = nil;
    if (wantRf &&
        [[NSFileManager defaultManager] fileExistsAtPath:rfPath] &&
        JamDemucsAvailable(sepPath)) {
        [self studioProgress:@"separating vocals (BS-RoFormer)" pct:0.01f];
        NSString* rfErr = nil;
        if (JamRoformerVocals(rfPath, _songL.data(), _songR.data(), n,
                              rfVocL, rfVocR,
                              ^(float p) { [self studioProgress:@"separating vocals (BS-RoFormer)"
                                                            pct:0.01f + p * 0.55f]; },
                              &rfErr)) {
            // Write the instrumental to a temp wav for demucs.
            std::vector<int16_t> inst(n * 2);
            for (long i = 0; i < n; ++i) {
                const float l = (_songL[i] - rfVocL[i]) * 32767.0f;
                const float r = (_songR[i] - rfVocR[i]) * 32767.0f;
                inst[i * 2] = (int16_t)MAX(-32768.0f, MIN(32767.0f, l));
                inst[i * 2 + 1] = (int16_t)MAX(-32768.0f, MIN(32767.0f, r));
            }
            rfTmpURL = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"jam_rf_inst.wav"]];
            if (JamWriteWav(rfTmpURL, inst.data(), n)) {
                demucsURL = rfTmpURL;
                usedRf = YES;
            }
        } else {
            NSLog(@"Jam studio: BS-RoFormer failed (%@) — plain htdemucs", rfErr);
        }
    }

    if (wantDemucs && JamDemucsAvailable(sepPath)) {
        const float base = usedRf ? 0.56f : 0.02f;
        const float span = usedRf ? 0.42f : 0.96f;
        [self studioProgress:@"separating (neural htdemucs)" pct:base];
        NSString* err = nil;
        neural = JamDemucsSeparate(sepPath, demucsURL, _stems, &nSources,
                                   ^(float p) { [self studioProgress:@"separating (neural htdemucs)"
                                                                 pct:base + p * span]; },
                                   &err);
        if (!neural) NSLog(@"Jam studio: neural separation failed (%@) — falling back to HPSS", err);
        if (neural && usedRf) {
            // Replace the vocals stem with the RoFormer extraction.
            _stems[3].assign(n * 2, 0);
            for (long i = 0; i < n; ++i) {
                const float l = rfVocL[i] * 32767.0f, r = rfVocR[i] * 32767.0f;
                _stems[3][i * 2] = (int16_t)MAX(-32768.0f, MIN(32767.0f, l));
                _stems[3][i * 2 + 1] = (int16_t)MAX(-32768.0f, MIN(32767.0f, r));
            }
        }
        if (rfTmpURL) [[NSFileManager defaultManager] removeItemAtURL:rfTmpURL error:nil];
    }
    if (!neural) {
        [self studioProgress:@"separating (fast hpss)" pct:0.05f];
        jamstudio::separate(_songL.data(), _songR.data(), n,
                            _stems[0], _stems[1], _stems[2],
                            ^(float p) { [self studioProgress:@"separating (fast hpss)"
                                                          pct:0.05f + p * 0.9f]; });
        for (int i = 3; i < 6; ++i) _stems[i].clear();
        nSources = 3;
    }
    for (int i = 0; i < 8; ++i) {
        _takeL[i].clear();
        _takeR[i].clear();
        _stemNotes[i].clear();
        _stemSource[i] = _stems[i].empty() ? nil : (neural ? @"neural" : @"hpss");
    }

    [self studioRefineBeatGridFromDrums];

    const BOOL isNeural = neural;
    const BOOL isRf = usedRf && neural;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self studioPushStemWaves];
        [self sendStateUpdate:@{@"studioSepEngine":
            isRf ? @"htdemucs+RF" : (isNeural ? @"htdemucs" : @"hpss")}];
        [self studioPublishStems];
        self->_studioBusy = NO;
        [self studioProgress:@"ready" pct:1.0f];
    });
}

// Re-derive the beat grid from the DRUMS stem: percussion onsets give a far
// cleaner tempo/offset/downbeat than the full mix. No-op without drums.
- (void)studioRefineBeatGridFromDrums {
    if (_stems[0].empty() || !self.sharedState) return;
    const long nf = (long)_stems[0].size() / 2;
    std::vector<float> mono(nf);
    for (long i = 0; i < nf; ++i) {
        mono[i] = (_stems[0][i * 2] + _stems[0][i * 2 + 1]) * (0.5f / 32768.0f);
    }
    jamstudio::BeatGrid bg =
        jamstudio::beatGrid(mono.data(), nf, _songAnalysis.bpm);
    _songAnalysis.bpm = bg.bpm;
    self.sharedState->stemBpm.store(bg.bpm, std::memory_order_relaxed);
    self.sharedState->stemBeatOff.store((long)(bg.offsetSec * 48000.0),
                                        std::memory_order_relaxed);
    self.sharedState->stemBarPhase.store(bg.barPhase, std::memory_order_relaxed);
    NSLog(@"Jam studio: drum beat grid — %.3f bpm, offset %.3fs, bar phase %d",
          bg.bpm, bg.offsetSec, bg.barPhase);
}

// ── Cue point ──
// A live cue marks the song's real downbeat-"1" past an unmetered intro of
// uncontrollable length. Setting it re-anchors the click/count-in grid there
// (clicks start exactly at the cue) and makes ▶/⟲ enter at the cue.

// Find the musical start: first sustained onset (prefer the drums stem).
- (double)detectCueSec {
    const int16_t* src = !_stems[0].empty() ? _stems[0].data() : nullptr;
    long nf = src ? (long)_stems[0].size() / 2 : (long)_songL.size();
    if (nf < 48000) return 0.0;
    const int hop = 512;
    const long frames = nf / hop;
    std::vector<float> e(frames, 0.0f);
    float peak = 1e-9f;
    for (long f = 0; f < frames; ++f) {
        double acc = 0;
        for (int i = 0; i < hop; ++i) {
            const long k = f * hop + i;
            float s = src ? (src[k * 2] + src[k * 2 + 1]) * (0.5f / 32768.0f)
                          : (_songL[k] + _songR[k]) * 0.5f;
            acc += (double)s * s;
        }
        e[f] = (float)std::sqrt(acc / hop);
        peak = MAX(peak, e[f]);
    }
    const float thr = peak * 0.18f;        // 18% of the loudest = "music here"
    for (long f = 0; f < frames - 3; ++f) {
        if (e[f] > thr && e[f + 1] > thr && e[f + 2] > thr) {
            return (double)(f * hop) / 48000.0;
        }
    }
    return 0.0;
}

// Snap a time to the nearest beat of the detected grid (keeps the cue clean).
- (double)snapToBeatSec:(double)sec {
    const float bpm = _songAnalysis.bpm;
    if (bpm < 40 || bpm > 300) return MAX(0.0, sec);
    const double B = 60.0 / bpm;
    const double off = self.sharedState
        ? self.sharedState->stemBeatOff.load(std::memory_order_relaxed) / 48000.0 : 0.0;
    double k = std::round((sec - off) / B);
    return MAX(0.0, off + k * B);
}

// Apply the click beat-grid anchor (samples) — the reference from which the
// click's beats are back-derived. The anchor is treated as a downbeat.
- (void)applyClickAnchorSamples:(long)cs {
    JamSharedState* sh = self.sharedState;
    sh->stemBeatOff.store(cs, std::memory_order_relaxed);
    sh->stemBarPhase.store(0, std::memory_order_relaxed);
}

// PGM live MIDI-input instrument source: 0 = built-in synth, 1 = SF2.
- (void)handleLiveSource:(int)source {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    if (source == 1) {
        [self laneEnsureSf:^(BOOL ok) {
            if (!ok) return;
            sh->liveSource.store(1, std::memory_order_relaxed);
            [self studioPushLive];
        }];
        sh->liveSource.store(1, std::memory_order_relaxed);   // optimistic
        [self studioPushLive];
        return;
    }
    sh->liveSource.store(0, std::memory_order_relaxed);
    [self studioPushLive];
}

- (void)studioPushLive {
    JamSharedState* sh = self.sharedState;
    [self sendStateUpdate:@{@"studioLive": @{
        @"source": @(sh->liveSource.load(std::memory_order_relaxed)),
        @"program": @(sh->liveSfProgram.load(std::memory_order_relaxed)),
        @"gain": @(sh->liveGain.load(std::memory_order_relaxed)),
        @"reverb": @(sh->liveFx.reverb.load(std::memory_order_relaxed)),
        @"echo": @(sh->liveFx.echo.load(std::memory_order_relaxed)),
    }}];
}

- (void)handleStudioCue:(NSString*)action sec:(double)sec {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;

    // ── Click beat-grid anchor (计算点) ──
    if ([action isEqualToString:@"anchor"]) {
        // Manual on-beat reference; NOT snapped (it defines the grid phase).
        _clickAnchorSec = MAX(0.0, sec);
        [self applyClickAnchorSamples:(long)(_clickAnchorSec * 48000.0)];
        [self studioPushCue];
        [self sendStateUpdate:@{@"studioNotice":
            [NSString stringWithFormat:@"⊙ click 计算点 @ %.2fs（click 第一拍由此倒推）",
             _clickAnchorSec]}];
        return;
    }
    if ([action isEqualToString:@"anchorReset"]) {
        // Revert the anchor to the cue (the default), or the detected grid.
        _clickAnchorSec = -1.0;
        if (_cueSec >= 0) [self applyClickAnchorSamples:(long)(_cueSec * 48000.0)];
        else if (!_stems[0].empty()) [self studioRefineBeatGridFromDrums];
        [self studioPushCue];
        return;
    }

    // ── Cue (playback start) ──
    if ([action isEqualToString:@"clear"]) {
        _cueSec = -1.0;
        sh->stemCue.store(-1, std::memory_order_relaxed);
        if (_clickAnchorSec < 0) {   // anchor follows the cue → restore grid
            if (!_stems[0].empty()) [self studioRefineBeatGridFromDrums];
        }
        [self studioPushCue];
        return;
    }
    double cue = [action isEqualToString:@"auto"] ? [self detectCueSec] : MAX(0.0, sec);
    cue = [self snapToBeatSec:cue];
    _cueSec = cue;
    const long cs = (long)(cue * 48000.0);
    sh->stemCue.store(cs, std::memory_order_relaxed);
    // Default: the click anchor follows the cue (same position) unless the
    // user has pinned an independent计算点.
    if (_clickAnchorSec < 0) [self applyClickAnchorSamples:cs];
    [self studioPushCue];
    [self sendStateUpdate:@{@"studioNotice":
        [NSString stringWithFormat:@"◎ Cue @ %.2fs", cue]}];
}

- (void)studioPushCue {
    [self sendStateUpdate:@{@"studioCue": @{
        @"sec": @(_cueSec), @"has": @(_cueSec >= 0),
        @"anchor": @(_clickAnchorSec), @"hasAnchor": @(_clickAnchorSec >= 0),
        @"timeSig": @(self.sharedState->beatsPerBar.load(std::memory_order_relaxed))}}];
}

// Push all stem waveforms + per-stem sources to the UI (main thread).
- (void)studioPushStemWaves {
    NSMutableArray* waves = [NSMutableArray array];
    NSMutableArray* sources = [NSMutableArray array];
    for (int i = 0; i < 8; ++i) {
        const long frames = (long)_stems[i].size() / 2;
        [waves addObject:JamWaveThumbI16(_stems[i].data(), frames, 480)];
        [sources addObject:_stemSource[i] ?: @""];
    }
    [self sendStateUpdate:@{@"studioStems": waves, @"studioStemSources": sources}];
}

// ── Import / replace a stem from a third-party file ──
// Decoded at 48 kHz stereo and length-aligned to the loaded song so the
// multi-track mix player stays in sync.
- (void)handleStudioImportStem:(int)idx {
    if (idx < 0 || idx > 7 || _studioBusy) return;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.audio"]]];
    NSString* const* stemNames = kStemNames;
    [panel setMessage:[NSString stringWithFormat:@"Select an audio file for the %@ stem",
                       stemNames[idx]]];
    void (^completion)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSURL* url = panel.URL;
        self->_studioBusy = YES;
        [self studioUnpublishStems];
        [self studioProgress:@"importing stem" pct:0.3f];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            usleep(60000);   // render thread drops old stem pointers
            ExtAudioFileRef f = nullptr;
            std::vector<float> L, R;
            if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &f) == noErr && f) {
                AudioStreamBasicDescription fmt = {};
                fmt.mSampleRate = 48000.0;
                fmt.mFormatID = kAudioFormatLinearPCM;
                fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
                fmt.mBitsPerChannel = 32;
                fmt.mChannelsPerFrame = 2;
                fmt.mBytesPerFrame = 4;
                fmt.mFramesPerPacket = 1;
                fmt.mBytesPerPacket = 4;
                ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat,
                                        sizeof(fmt), &fmt);
                const UInt32 chunk = 1 << 16;
                std::vector<float> bufL(chunk), bufR(chunk);
                const long maxFrames = 48000L * 60 * 8;
                while ((long)L.size() < maxFrames) {
                    // AudioBufferList has storage for ONE buffer; allocate room for two.
                    struct { AudioBufferList list; AudioBuffer extra; } ablMem = {};
                    AudioBufferList& abl = ablMem.list;
                    abl.mNumberBuffers = 2;
                    abl.mBuffers[0] = {1, chunk * 4, bufL.data()};
                    abl.mBuffers[1] = {1, chunk * 4, bufR.data()};
                    UInt32 nf = chunk;
                    if (ExtAudioFileRead(f, &nf, &abl) != noErr || nf == 0) break;
                    L.insert(L.end(), bufL.begin(), bufL.begin() + nf);
                    R.insert(R.end(), bufR.begin(), bufR.begin() + nf);
                }
                ExtAudioFileDispose(f);
            }
            if (L.empty()) {
                [self studioFail:@"could not decode that file"];
                return;
            }
            // Length reference: the song if loaded, else the longest existing
            // stem, else the imported file itself defines the length.
            long target = (long)self->_songL.size();
            if (target == 0) {
                for (int k = 0; k < 8; ++k) {
                    target = MAX(target, (long)self->_stems[k].size() / 2);
                }
            }
            if (target == 0) target = (long)L.size();
            if (self->_songDur <= 0) self->_songDur = target / 48000.0;
            self->_stems[idx].assign(target * 2, 0);
            const long copyN = MIN(target, (long)L.size());
            for (long i = 0; i < copyN; ++i) {
                float l = L[i] * 32767.0f, r = R[i] * 32767.0f;
                l = MAX(-32768.0f, MIN(32767.0f, l));
                r = MAX(-32768.0f, MIN(32767.0f, r));
                self->_stems[idx][i * 2] = (int16_t)l;
                self->_stems[idx][i * 2 + 1] = (int16_t)r;
            }
            self->_stemSource[idx] = @"imported";
            self->_stemNotes[idx].clear();
            self.sharedState->stemOffset[idx].store(0, std::memory_order_relaxed);
            if (idx == 0) [self studioRefineBeatGridFromDrums];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self studioPushStemWaves];
                [self studioPublishStems];
                [self studioPushStemAlign:idx];
                self->_studioBusy = NO;
                [self studioProgress:@"ready" pct:1.0f];
            });
        });
    };
    if (self.view.window) [panel beginSheetModalForWindow:self.view.window completionHandler:completion];
    else [panel beginWithCompletionHandler:completion];
}

// Decode any audio file to 48 kHz stereo float (cap 8 min).
static BOOL JamDecode48k(NSURL* url, std::vector<float>& L, std::vector<float>& R) {
    ExtAudioFileRef f = nullptr;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &f) != noErr || !f) return NO;
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = 48000.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved;
    fmt.mBitsPerChannel = 32;
    fmt.mChannelsPerFrame = 2;
    fmt.mBytesPerFrame = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = 4;
    ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(fmt), &fmt);
    const UInt32 chunk = 1 << 16;
    std::vector<float> bufL(chunk), bufR(chunk);
    const long maxFrames = 48000L * 60 * 8;
    L.clear(); R.clear();
    while ((long)L.size() < maxFrames) {
        // AudioBufferList has storage for ONE buffer; allocate room for two.
        struct { AudioBufferList list; AudioBuffer extra; } ablMem = {};
        AudioBufferList& abl = ablMem.list;
        abl.mNumberBuffers = 2;
        abl.mBuffers[0] = {1, chunk * 4, bufL.data()};
        abl.mBuffers[1] = {1, chunk * 4, bufR.data()};
        UInt32 nf = chunk;
        if (ExtAudioFileRead(f, &nf, &abl) != noErr || nf == 0) break;
        L.insert(L.end(), bufL.begin(), bufL.begin() + nf);
        R.insert(R.end(), bufR.begin(), bufR.begin() + nf);
    }
    ExtAudioFileDispose(f);
    return !L.empty();
}

// ── Audio→MIDI transcription (Basic Pitch on ONNX Runtime) ──────────────────

static NSString* const kBpModelURL =
    @"https://github.com/spotify/basic-pitch/raw/main/basic_pitch/saved_models/icassp_2022/nmp.onnx";
static NSString* const kPianoModelURL =
    @"https://huggingface.co/stelee/piano-transcription-onnx/resolve/main/piano_crnn.onnx";

- (NSString*)bpModelPath {
    return [[self sepModelDir] stringByAppendingPathComponent:@"nmp.onnx"];
}

- (void)handleStudioTranscribe:(int)idx {
    if (idx < 0 || idx > 7 || _studioBusy || _stems[idx].empty()) return;
    NSString* model = [self bpModelPath];
    NSDictionary* attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:model error:nil];
    if (!attrs || [attrs fileSize] < 50 * 1024) {
        // Tiny model (~225 KB) — fetch inline, then transcribe.
        _studioBusy = YES;
        [self studioProgress:@"fetching basic-pitch model" pct:0.1f];
        NSURLSessionDataTask* task = [[NSURLSession sharedSession]
            dataTaskWithURL:[NSURL URLWithString:kBpModelURL]
          completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err || data.length < 50 * 1024) {
                    [self studioFail:@"could not download the transcription model"];
                    return;
                }
                [data writeToFile:model atomically:YES];
                self->_studioBusy = NO;
                [self handleStudioTranscribe:idx];
            });
        }];
        [task resume];
        return;
    }
    // Piano stem: use the piano-specialized high-resolution CRNN (ByteDance/
    // Kong 2020 — onset F1 96.7% on MAESTRO vs Basic Pitch's general model).
    // Fetch its ONNX (~154 MB) on first use, then transcribe.
    NSString* pianoModel =
        [[self sepModelDir] stringByAppendingPathComponent:@"piano_crnn.onnx"];
    if (idx == 5 &&
        ![[NSFileManager defaultManager] fileExistsAtPath:pianoModel]) {
        _studioBusy = YES;
        [self studioProgress:@"downloading piano model (154MB)" pct:0.01f];
        NSURLSessionDownloadTask* task = [[NSURLSession sharedSession]
            downloadTaskWithURL:[NSURL URLWithString:kPianoModelURL]
              completionHandler:^(NSURL* loc, NSURLResponse* resp, NSError* err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_studioBusy = NO;
                    if (err || !loc) {
                        // Fall back to Basic Pitch rather than failing outright.
                        NSLog(@"Jam: piano model download failed (%@) — Basic Pitch",
                              err.localizedDescription);
                    } else {
                        [[NSFileManager defaultManager] removeItemAtPath:pianoModel error:nil];
                        [[NSFileManager defaultManager]
                            moveItemAtURL:loc toURL:[NSURL fileURLWithPath:pianoModel] error:nil];
                    }
                    [self studioProgress:@"ready" pct:1.0f];
                    [self handleStudioTranscribe:idx];   // retry (uses model if present)
                });
            }];
        [task resume];
        __weak NSURLSessionDownloadTask* wTask = task;
        [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer* t) {
            NSURLSessionDownloadTask* st = wTask;
            if (!st || st.state != NSURLSessionTaskStateRunning) { [t invalidate]; return; }
            const int64_t got = st.countOfBytesReceived, want = st.countOfBytesExpectedToReceive;
            if (want > 0) [self studioProgress:@"downloading piano model (154MB)"
                                           pct:0.01f + 0.95f * (float)got / (float)want];
        }];
        return;
    }
    const BOOL usePiano = (idx == 5) &&
        [[NSFileManager defaultManager] fileExistsAtPath:pianoModel];

    _studioBusy = YES;
    [self studioProgress:(usePiano ? @"transcribing (piano hi-res)" : @"transcribing")
                     pct:0.02f];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString* err = nil;
        std::vector<JamNote> notes;
        BOOL ok;
        if (usePiano) {
            ok = JamTranscribePiano(pianoModel,
                                    self->_stems[idx].data(),
                                    (long)self->_stems[idx].size() / 2,
                                    notes,
                                    ^(float p) { [self studioProgress:@"transcribing (piano hi-res)"
                                                                  pct:0.02f + p * 0.95f]; },
                                    &err);
            if (!ok) {
                NSLog(@"Jam studio: piano model failed (%@) — falling back to Basic Pitch", err);
            }
        } else {
            ok = NO;
        }
        if (!ok) {
            err = nil;
            ok = JamTranscribe(model,
                               self->_stems[idx].data(),
                               (long)self->_stems[idx].size() / 2,
                               notes,
                               ^(float p) { [self studioProgress:@"transcribing"
                                                             pct:0.02f + p * 0.95f]; },
                               &err);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                [self studioFail:err ?: @"transcription failed"];
                return;
            }
            self->_stemNotes[idx] = std::move(notes);
            [self studioPushNotes:idx];
            if (usePiano) {
                [self sendStateUpdate:@{@"studioNotice":
                    [NSString stringWithFormat:@"✓ 钢琴高精度转写：%d 个音符",
                     (int)self->_stemNotes[idx].size()]}];
            }
            // If this lane already plays MIDI (e.g. a chord-voiced fallback),
            // swap in the fresh transcription.
            if (idx >= 1 && idx <= 7 && !self->_laneEvBuf[idx].empty()) {
                [self lanePublish:idx];
            }
            self->_studioBusy = NO;
            [self studioProgress:@"ready" pct:1.0f];
        });
    });
}

// Compact piano-roll ribbon for the UI: [startSec, endSec, pitch] triples.
- (void)studioPushNotes:(int)idx {
    const auto& notes = _stemNotes[idx];
    NSMutableArray* ribbon = [NSMutableArray array];
    const size_t step = MAX((size_t)1, notes.size() / 1000);
    for (size_t i = 0; i < notes.size(); i += step) {
        const auto& n = notes[i];
        [ribbon addObject:@[@(n.start), @(n.start + n.duration), @(n.pitch)]];
    }
    [self sendStateUpdate:@{@"studioNotes": @{
        @"index": @(idx),
        @"count": @((int)notes.size()),
        @"ribbon": ribbon,
    }}];
}

// ── Chord recognition + AUX re-voicing ───────────────────────────────────────

- (void)handleStudioDetectChords {
    if (_studioBusy) return;
    // Drums-free stem mix when available (much cleaner chroma), else the song.
    bool anyHarm = false;
    for (int i = 1; i < 8; ++i) anyHarm |= !_stems[i].empty();
    if (!anyHarm && _songL.empty()) {
        [self sendStateUpdate:@{@"studioError": @"load a song or stems first"}];
        return;
    }
    _studioBusy = YES;
    [self studioProgress:@"detecting chords" pct:0.1f];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        std::vector<float> mono;
        if (anyHarm) {
            long n = 0;
            for (int i = 1; i < 8; ++i) n = MAX(n, (long)self->_stems[i].size() / 2);
            mono.assign(n, 0.0f);
            for (int i = 1; i < 8; ++i) {     // skip drums (index 0)
                const auto& st = self->_stems[i];
                const long fn = (long)st.size() / 2;
                for (long k = 0; k < fn; ++k) {
                    mono[k] += (st[k * 2] + st[k * 2 + 1]) * (0.5f / 32768.0f);
                }
            }
        } else {
            const long n = (long)self->_songL.size();
            mono.resize(n);
            for (long k = 0; k < n; ++k) {
                mono[k] = (self->_songL[k] + self->_songR[k]) * 0.5f;
            }
        }
        [self studioProgress:@"detecting chords" pct:0.4f];
        auto chords = jamchords::detect(mono.data(), (long)mono.size(),
                                        self->_songAnalysis.bpm,
                                        self->_songAnalysis.keyIdx,
                                        self->_songAnalysis.minor);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_chords = std::move(chords);
            [self studioPushChords];
            self->_studioBusy = NO;
            [self studioProgress:@"ready" pct:1.0f];
            int named = 0;
            for (const auto& c : self->_chords) named += !c.none;
            [self sendStateUpdate:@{@"studioNotice":
                [NSString stringWithFormat:@"✓ 识别到 %d 段和弦（CHORDS 轨）", named]}];
        });
    });
}

- (void)studioPushChords {
    NSMutableArray* arr = [NSMutableArray array];
    for (const auto& c : _chords) {
        [arr addObject:@{@"start": @(c.start), @"end": @(c.end),
                         @"label": [NSString stringWithUTF8String:
                                    jamchords::chordName(c).c_str()],
                         @"minor": @(c.minor), @"none": @(c.none)}];
    }
    [self sendStateUpdate:@{@"studioChords": arr}];
}

// Build the AUX clip from the chord timeline in the given style and publish
// it to the render-thread sequencer.
// ── Per-stem MIDI lanes ──────────────────────────────────────────────────
// Lane k of JamSharedState ↔ stem k+1 (bass, other, vocals, guitar, piano).

// Stem-appropriate synth patch, applied once per lane.
static void JamApplyLanePatch(JamSynth& s, int stem) {
    s.arpMode.store(0);
    s.matrix[0].store(0);
    switch (stem) {
        case 1:   // BASS — mono lowpass saw with a little glide
            s.monoMode.store(true);
            s.oscType.store(0); s.wave.store(0.15f); s.timbre.store(0.4f);
            s.glide.store(0.06f);
            s.attack.store(0.01f); s.decay.store(0.35f);
            s.sustain.store(0.75f); s.release.store(0.12f);
            s.cutoff.store(0.38f); s.resonance.store(0.18f); s.envFilter.store(0.5f);
            s.chorus.store(0.0f); s.space.store(0.05f); s.volume.store(0.75f);
            break;
        case 2:   // OTHER — supersaw pad, slow swell, wide
            s.monoMode.store(false);
            s.oscType.store(1); s.wave.store(0.55f); s.timbre.store(0.6f);
            s.glide.store(0.0f);
            s.attack.store(0.3f); s.decay.store(0.5f);
            s.sustain.store(0.85f); s.release.store(0.45f);
            s.cutoff.store(0.55f); s.resonance.store(0.12f); s.envFilter.store(0.3f);
            s.chorus.store(0.45f); s.space.store(0.35f); s.volume.store(0.5f);
            break;
        case 3:   // VOCALS — mono portamento lead
            s.monoMode.store(true);
            s.oscType.store(0); s.wave.store(0.6f); s.timbre.store(0.5f);
            s.glide.store(0.1f);
            s.attack.store(0.02f); s.decay.store(0.4f);
            s.sustain.store(0.85f); s.release.store(0.2f);
            s.cutoff.store(0.62f); s.resonance.store(0.2f); s.envFilter.store(0.4f);
            s.chorus.store(0.2f); s.space.store(0.3f); s.volume.store(0.65f);
            break;
        case 4:   // GUITAR — plucked, fast decay, no sustain
            s.monoMode.store(false);
            s.oscType.store(2); s.wave.store(0.35f); s.timbre.store(0.45f);
            s.glide.store(0.0f);
            s.attack.store(0.0f); s.decay.store(0.28f);
            s.sustain.store(0.0f); s.release.store(0.2f);
            s.cutoff.store(0.6f); s.resonance.store(0.25f); s.envFilter.store(0.55f);
            s.chorus.store(0.25f); s.space.store(0.15f); s.volume.store(0.65f);
            break;
        default:  // PIANO — keys: snappy attack, medium decay
            s.monoMode.store(false);
            s.oscType.store(0); s.wave.store(0.4f); s.timbre.store(0.45f);
            s.glide.store(0.0f);
            s.attack.store(0.0f); s.decay.store(0.5f);
            s.sustain.store(0.35f); s.release.store(0.22f);
            s.cutoff.store(0.65f); s.resonance.store(0.15f); s.envFilter.store(0.45f);
            s.chorus.store(0.15f); s.space.store(0.2f); s.volume.store(0.6f);
            break;
    }
}

// Chord-voicing fallback style per stem (when no transcription exists).
static int JamLaneDefaultStyle(int stem) {
    switch (stem) {
        case 1: return 4;   // bass
        case 2: return 0;   // other → pad
        case 3: return 3;   // vocals → arp (a melodic placeholder)
        case 4: return 1;   // guitar → pluck
        case 5: return 2;   // piano → stab
        default: return 0;  // aux → pad
    }
}

// Build + publish the MIDI clip for a stem: its transcription when present,
// otherwise a chord-voiced phrase in the stem's default style.
- (BOOL)lanePublish:(int)stem {
    if (stem < 1 || stem > 7) return NO;
    std::vector<JamNote> notes = _stemNotes[stem];
    BOOL fromChords = NO;
    if (notes.empty()) {
        // Chord-voicing fallback applies to the separated stems only — AUX
        // lanes start empty by design (write in the piano roll / AI compose).
        if (stem >= 6 || _chords.empty()) return NO;
        notes = jamchords::voice(_chords, _songAnalysis.bpm,
                                 JamLaneDefaultStyle(stem));
        fromChords = YES;
    }
    if (notes.empty()) return NO;

    // Convert to sorted sample-time on/off events.
    std::vector<JamSharedState::AuxEv> evs;
    evs.reserve(notes.size() * 2);
    for (const auto& n : notes) {
        const long on = (long)(n.start * 48000.0);
        long off = (long)((n.start + n.duration) * 48000.0);
        if (off <= on) off = on + 2400;
        const uint8_t vel = (uint8_t)MAX(1, MIN(127, (int)lround(n.velocity * 127)));
        evs.push_back({on, (uint8_t)MAX(0, MIN(127, n.pitch)), vel, true});
        evs.push_back({off, (uint8_t)MAX(0, MIN(127, n.pitch)), 0, false});
    }
    std::sort(evs.begin(), evs.end(),
              [](const JamSharedState::AuxEv& a, const JamSharedState::AuxEv& b) {
                  return a.sample < b.sample || (a.sample == b.sample && !a.on && b.on);
              });

    JamSharedState* sh = self.sharedState;
    const int k = stem - 1;
    if (!_lanePatched[stem]) {
        JamApplyLanePatch(sh->laneSynth[k], stem);
        _lanePatched[stem] = YES;
    }
    // Swap-publish: point the render thread away, replace, re-point.
    sh->laneEv[k].store(nullptr, std::memory_order_release);
    sh->laneCount[k].store(0, std::memory_order_relaxed);
    usleep(20000);
    _laneEvBuf[stem] = std::move(evs);
    sh->laneCount[k].store((long)_laneEvBuf[stem].size(), std::memory_order_relaxed);
    sh->laneEv[k].store(_laneEvBuf[stem].data(), std::memory_order_release);
    sh->laneGen[k].fetch_add(1, std::memory_order_relaxed);
    _laneClip[stem] = std::move(notes);
    [self studioPublishStems];   // MIDI-only sessions get their timeline from clips

    // Show the clip on the lane's ribbon (chord-voiced clips have no
    // transcription ribbon yet).
    if (fromChords) [self studioPushNotes:stem fromClip:YES];
    return YES;
}

- (void)handleLaneSource:(int)stem midi:(BOOL)midi {
    if (stem < 1 || stem > 7) return;
    JamSharedState* sh = self.sharedState;
    if (midi && _laneEvBuf[stem].empty()) {
        if (![self lanePublish:stem]) {
            [self sendStateUpdate:@{@"studioError": stem >= 6
                ? @"空轨：先用 ✎ 打开钢琴卷写 MIDI（手写或 ✨ AI 生成）"
                : @"先 ♪ MIDI 转录该轨，或 ♪ Chords 识别和弦（自动生成乐句）"}];
            return;
        }
    }
    sh->stemSource[stem].store(midi ? 1 : 0, std::memory_order_relaxed);
    [self studioPushSources];
}

// Regenerate a lane's MIDI from its source: re-transcribe the stem audio,
// or re-voice from the chord chart (audio-less lanes). Overwrites the clip —
// the escape hatch after an over-aggressive ✨ 优化.
- (void)handleLaneRegen:(int)stem {
    if (stem < 1 || stem > 7) return;
    if (!_stems[stem].empty()) {
        [self handleStudioTranscribe:stem];   // async; UI refetches the clip
        return;
    }
    if (stem <= 5 && !_chords.empty()) {
        _stemNotes[stem].clear();
        if ([self lanePublish:stem]) {
            [self handleLaneClipGet:stem];
            return;
        }
    }
    [self sendStateUpdate:@{@"studioError":
        @"无音频也无和弦表，无法重新生成（AUX 轨可用 ✨ AI 重写）"}];
}

// Remove an AUX lane's content entirely (audio + MIDI + patch).
- (void)handleLaneClear:(int)stem {
    if (stem < 6 || stem > 7 || !self.sharedState) return;
    JamSharedState* sh = self.sharedState;
    const int k = stem - 1;
    sh->stemSource[stem].store(0, std::memory_order_relaxed);
    sh->stemBuf[stem].store(nullptr, std::memory_order_relaxed);
    sh->laneEv[k].store(nullptr, std::memory_order_relaxed);
    sh->laneCount[k].store(0, std::memory_order_relaxed);
    sh->laneFx[k].reverb.store(0, std::memory_order_relaxed);
    sh->laneFx[k].echo.store(0, std::memory_order_relaxed);
    _lanePatchInfo[stem] = nil;
    _stemSource[stem] = nil;
    // Free the buffers after the render thread has dropped the pointers.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_stems[stem].clear();
        self->_stemNotes[stem].clear();
        self->_laneClip[stem].clear();
        self->_laneEvBuf[stem].clear();
        [self studioPushStemWaves];
        [self studioPushNotes:stem];
        [self studioPushSources];
        [self studioPushPatches];
        [self studioPushLanes];
        [self studioPublishStems];
    });
}

- (void)studioPushSources {
    JamSharedState* sh = self.sharedState;
    NSMutableArray* arr = [NSMutableArray array];
    for (int t = 0; t < 8; ++t) {
        [arr addObject:@(sh->stemSource[t].load(std::memory_order_relaxed))];
    }
    [self sendStateUpdate:@{@"studioSources": arr}];
}

// Apply a full patch (Instrument-tab SynthParams numeric schema + 25-cell mod
// matrix) to a lane synth and remember it for PGM packaging.
// info: {index, name, origin: 'factory'|'user'|'ai', params: {...}, matrix: [25]}
- (void)handleLanePatch:(int)stem info:(NSDictionary*)info {
    if (stem < 1 || stem > 7 || !self.sharedState) return;
    JamSynth& sy = self.sharedState->laneSynth[stem - 1];
    NSDictionary* params = info[@"params"];
    if (![params isKindOfClass:[NSDictionary class]]) return;
    for (NSString* key in params) {
        NSNumber* v = params[key];
        if ([key isKindOfClass:[NSString class]] && [v isKindOfClass:[NSNumber class]]) {
            JamSetSynthParam(sy, key, v);
        }
    }
    NSArray* mx = info[@"matrix"];
    for (int i = 0; i < 25; ++i) {
        float v = 0;
        if ([mx isKindOfClass:[NSArray class]] && (NSUInteger)i < mx.count &&
            [mx[i] isKindOfClass:[NSNumber class]]) {
            v = MAX(-1.0f, MIN(1.0f, [mx[i] floatValue]));
        }
        sy.matrix[i].store(v, std::memory_order_relaxed);
    }
    NSString* pname = [info[@"name"] isKindOfClass:[NSString class]] ? info[@"name"] : @"patch";
    NSString* origin = [info[@"origin"] isKindOfClass:[NSString class]] ? info[@"origin"] : @"user";
    _lanePatchInfo[stem] = @{@"name": pname, @"origin": origin,
                             @"params": params,
                             @"matrix": [mx isKindOfClass:[NSArray class]] ? mx : @[]};
    _lanePatched[stem] = YES;   // don't overwrite with the built-in default later
    [self studioPushPatches];
}

- (void)studioPushPatches {
    NSMutableArray* arr = [NSMutableArray array];
    for (int t = 0; t < 8; ++t) {
        NSDictionary* p = _lanePatchInfo[t];
        [arr addObject:p ? @{@"name": p[@"name"] ?: @"patch",
                             @"origin": p[@"origin"] ?: @"user"}
                         : (id)[NSNull null]];
    }
    [self sendStateUpdate:@{@"studioPatches": arr}];
}

// ── SF2 sample engine (TinySoundFont) ──
// One master font; each lane gets a tsf_copy that shares the sample data.

static NSString* const kSf2URL =
    @"https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/main/GeneralUser-GS.sf2";

- (NSString*)sf2Path {
    return [[self sepModelDir] stringByAppendingPathComponent:@"GeneralUser-GS.sf2"];
}

// Default GM program per stem when SF2 is first enabled.
static int JamLaneDefaultProgram(int stem) {
    switch (stem) {
        case 1: return 33;   // Electric Bass (finger)
        case 2: return 48;   // String Ensemble
        case 3: return 52;   // Choir Aahs
        case 4: return 25;   // Steel Guitar
        case 5: return 0;    // Grand Piano
        default: return 40;  // Violin (aux lanes)
    }
}

// Load (downloading first if needed) and publish per-lane tsf instances.
// Calls done(YES) on the main queue once lanes can play SF2.
- (void)laneEnsureSf:(void (^)(BOOL))done {
    if (self.sharedState->laneSf[0].load(std::memory_order_relaxed)) { done(YES); return; }
    if (_sfBusy) { done(NO); return; }
    _sfBusy = YES;
    NSString* path = [self sf2Path];

    void (^loadIt)(void) = ^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            tsf* master = tsf_load_filename(path.fileSystemRepresentation);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!master) {
                    self->_sfBusy = NO;
                    [self sendStateUpdate:@{@"studioError": @"音色库加载失败"}];
                    [self studioProgress:@"ready" pct:1.0f];
                    done(NO);
                    return;
                }
                self->_sfMaster = master;
                for (int k = 0; k < JamSharedState::kMidiLanes; ++k) {
                    tsf* c = tsf_copy(master);
                    tsf_set_output(c, TSF_STEREO_UNWEAVED, 48000, 0.0f);
                    tsf_set_max_voices(c, 48);   // preallocate (audio-thread safety)
                    const int prog = self.sharedState->laneSfProgram[k]
                                         .load(std::memory_order_relaxed);
                    tsf_channel_set_presetnumber(c, 0, prog, 0);
                    self.sharedState->laneSfProgApplied[k] = prog;
                    self.sharedState->laneSf[k].store(c, std::memory_order_release);
                }
                // Live MIDI-input SF2 instance (PGM live source).
                if (!self.sharedState->liveSf.load(std::memory_order_relaxed)) {
                    tsf* lv = tsf_copy(master);
                    tsf_set_output(lv, TSF_STEREO_UNWEAVED, 48000, 0.0f);
                    tsf_set_max_voices(lv, 32);
                    tsf_channel_set_presetnumber(lv, 0,
                        self.sharedState->liveSfProgram.load(std::memory_order_relaxed), 0);
                    self.sharedState->liveSf.store(lv, std::memory_order_release);
                }
                self->_sfBusy = NO;
                [self studioProgress:@"ready" pct:1.0f];
                [self sendStateUpdate:@{@"studioNotice":
                    [NSString stringWithFormat:@"✓ 音色库就绪（%d 个预设）",
                     tsf_get_presetcount(master)]}];
                done(YES);
            });
        });
    };

    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self studioProgress:@"loading soundfont" pct:0.5f];
        loadIt();
        return;
    }
    // Download (~31 MB) then load.
    [self studioProgress:@"downloading soundfont" pct:0.02f];
    NSURLSessionDownloadTask* task = [[NSURLSession sharedSession]
        downloadTaskWithURL:[NSURL URLWithString:kSf2URL]
          completionHandler:^(NSURL* loc, NSURLResponse* resp, NSError* err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err || !loc) {
                    self->_sfBusy = NO;
                    [self sendStateUpdate:@{@"studioError":
                        [NSString stringWithFormat:@"音色库下载失败: %@",
                         err.localizedDescription ?: @"no data"]}];
                    [self studioProgress:@"ready" pct:1.0f];
                    done(NO);
                    return;
                }
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                NSError* mvErr = nil;
                [[NSFileManager defaultManager] moveItemAtURL:loc
                    toURL:[NSURL fileURLWithPath:path] error:&mvErr];
                if (mvErr) {
                    self->_sfBusy = NO;
                    [self sendStateUpdate:@{@"studioError": @"音色库保存失败"}];
                    done(NO);
                    return;
                }
                [self studioProgress:@"loading soundfont" pct:0.9f];
                loadIt();
            });
        }];
    [task resume];
    // Progress poll (NSURLSession download progress via KVO is overkill here).
    __weak NSURLSessionDownloadTask* wTask = task;
    NSTimer* timer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES
                                                       block:^(NSTimer* t) {
        NSURLSessionDownloadTask* st = wTask;
        if (!st || st.state != NSURLSessionTaskStateRunning) { [t invalidate]; return; }
        const int64_t got = st.countOfBytesReceived;
        const int64_t want = st.countOfBytesExpectedToReceive;
        if (want > 0) {
            [self studioProgress:@"downloading soundfont"
                             pct:0.02f + 0.85f * (float)got / (float)want];
        }
    }];
    (void)timer;
}

- (void)handleLaneEngine:(int)stem engine:(int)engine {
    if (stem < 1 || stem > 7 || !self.sharedState) return;
    JamSharedState* sh = self.sharedState;
    const int k = stem - 1;
    if (engine == 1) {
        // First time on this lane: give it a stem-appropriate GM program.
        if (sh->laneSf[k].load(std::memory_order_relaxed) == nullptr &&
            sh->laneSfProgram[k].load(std::memory_order_relaxed) == 0 &&
            JamLaneDefaultProgram(stem) != 0) {
            sh->laneSfProgram[k].store(JamLaneDefaultProgram(stem),
                                       std::memory_order_relaxed);
        }
        [self laneEnsureSf:^(BOOL ok) {
            if (!ok) return;
            sh->laneEngine[k].store(1, std::memory_order_relaxed);
            [self studioPushLanes];
        }];
        // Optimistic UI update (download may take a while).
        [self studioPushLanes];
        return;
    }
    sh->laneEngine[k].store(0, std::memory_order_relaxed);
    [self studioPushLanes];
}

- (void)studioPushLanes {
    JamSharedState* sh = self.sharedState;
    NSMutableArray* arr = [NSMutableArray array];
    for (int t = 0; t < 8; ++t) {
        if (t == 0) { [arr addObject:[NSNull null]]; continue; }
        const int k = t - 1;
        [arr addObject:@{
            @"engine": @(sh->laneEngine[k].load(std::memory_order_relaxed)),
            @"program": @(sh->laneSfProgram[k].load(std::memory_order_relaxed)),
            @"reverb": @(sh->laneFx[k].reverb.load(std::memory_order_relaxed)),
            @"echo": @(sh->laneFx[k].echo.load(std::memory_order_relaxed)),
        }];
    }
    [self sendStateUpdate:@{@"studioLanes": arr}];
}

// ── MIDI clip editor (piano roll) ──
// Full-resolution clip for the editor: what the lane actually plays.
- (void)handleLaneClipGet:(int)stem {
    if (stem < 1 || stem > 7) return;
    const auto& notes = !_laneClip[stem].empty() ? _laneClip[stem] : _stemNotes[stem];
    NSMutableArray* arr = [NSMutableArray arrayWithCapacity:notes.size()];
    for (const auto& n : notes) {
        [arr addObject:@[@(n.start), @(n.duration), @(n.pitch), @(n.velocity)]];
    }
    [self sendStateUpdate:@{@"studioClip": @{@"index": @(stem), @"notes": arr}}];
}

// Edited clip back from the piano roll: becomes the lane's notes, republished
// to the render thread immediately so changes are audible during playback.
- (void)handleLaneClipSet:(int)stem notes:(NSArray*)arr {
    if (stem < 1 || stem > 7) return;
    std::vector<JamNote> notes;
    notes.reserve(arr.count);
    for (NSArray* e in arr) {
        if (![e isKindOfClass:[NSArray class]] || e.count < 4) continue;
        JamNote n;
        n.start = MAX(0.0, [e[0] doubleValue]);
        n.duration = MAX(0.01, [e[1] doubleValue]);
        n.pitch = MAX(0, MIN(127, [e[2] intValue]));
        n.velocity = MAX(0.05f, MIN(1.0f, [e[3] floatValue]));
        notes.push_back(n);
    }
    std::sort(notes.begin(), notes.end(),
              [](const JamNote& a, const JamNote& b) { return a.start < b.start; });
    _stemNotes[stem] = std::move(notes);
    [self studioPushNotes:stem];
    // Republish when this lane is (or was) playing MIDI.
    if (!_laneEvBuf[stem].empty() ||
        self.sharedState->stemSource[stem].load(std::memory_order_relaxed) == 1) {
        [self lanePublish:stem];
    } else if (_stems[stem].empty() && !_stemNotes[stem].empty()) {
        // A lane with no audio (AUX) gets MIDI as its source automatically.
        if ([self lanePublish:stem]) {
            self.sharedState->stemSource[stem].store(1, std::memory_order_relaxed);
            [self studioPushSources];
        }
    }
}

// Push a stem lane's note ribbon (from transcription or the published clip).
- (void)studioPushNotes:(int)stem fromClip:(BOOL)fromClip {
    const auto& notes = fromClip ? _laneClip[stem] : _stemNotes[stem];
    NSMutableArray* ribbon = [NSMutableArray array];
    const size_t step = MAX((size_t)1, notes.size() / 1000);
    for (size_t i = 0; i < notes.size(); i += step) {
        const auto& n = notes[i];
        [ribbon addObject:@[@(n.start), @(n.start + n.duration), @(n.pitch)]];
    }
    [self sendStateUpdate:@{@"studioNotes": @{
        @"index": @(stem),
        @"count": @((int)notes.size()),
        @"ribbon": ribbon,
    }}];
}

// 16-bit stereo 48 kHz WAV writer (AudioToolbox).
static BOOL JamWriteWav(NSURL* url, const int16_t* interleaved, long frames) {
    AudioStreamBasicDescription fmt = {};
    fmt.mSampleRate = 48000.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    fmt.mBitsPerChannel = 16;
    fmt.mChannelsPerFrame = 2;
    fmt.mBytesPerFrame = 4;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = 4;
    AudioFileID file = nullptr;
    if (AudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileWAVEType, &fmt,
                               kAudioFileFlags_EraseFile, &file) != noErr || !file) {
        return NO;
    }
    UInt32 bytes = (UInt32)(frames * 4);
    const OSStatus st = AudioFileWriteBytes(file, false, 0, &bytes, interleaved);
    AudioFileClose(file);
    return st == noErr;
}

// ── Import a packaged PGM folder (program.json + stems/*.wav [+ song.wav]) ──
- (void)handleStudioLoadPgm {
    if (_studioBusy) return;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:NO];
    [panel setCanChooseDirectories:YES];
    [panel setMessage:@"Select a .pgm folder (program.json + stems)"];
    void (^completion)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSURL* root = panel.URL;
        NSData* jsonData = [NSData dataWithContentsOfURL:
                            [root URLByAppendingPathComponent:@"program.json"]];
        NSDictionary* pgm = jsonData
            ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
        if (![pgm isKindOfClass:[NSDictionary class]]) {
            [self sendStateUpdate:@{@"studioError": @"not a PGM folder (program.json missing)"}];
            return;
        }
        self->_studioBusy = YES;
        [self studioUnpublishStems];
        self.sharedState->prevActive.store(false, std::memory_order_relaxed);
        [self studioProgress:@"loading pgm" pct:0.05f];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Drop the MIDI lanes before touching their buffers.
            for (int t = 1; t <= 7; ++t) {
                self.sharedState->stemSource[t].store(0, std::memory_order_relaxed);
                self.sharedState->laneEv[t - 1].store(nullptr, std::memory_order_relaxed);
                self.sharedState->laneCount[t - 1].store(0, std::memory_order_relaxed);
            }
            usleep(60000);
            for (int t = 0; t < 8; ++t) {
                self->_laneEvBuf[t].clear();
                self->_laneClip[t].clear();
            }
            NSDictionary* song = pgm[@"song"];
            NSString* name = [song isKindOfClass:[NSDictionary class]] ? song[@"name"] : nil;
            self->_songName = [name isKindOfClass:[NSString class]] ? name : @"pgm";

            // Original song (optional in v1 packages).
            self->_songL.clear();
            self->_songR.clear();
            self->_songURL = nil;
            NSURL* songWav = [root URLByAppendingPathComponent:@"song.wav"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:songWav.path]) {
                [self studioProgress:@"loading song" pct:0.15f];
                if (JamDecode48k(songWav, self->_songL, self->_songR)) {
                    self->_songURL = songWav;
                }
            }

            // Stems by canonical name.
            NSString* const* names = kStemNames;
            // The packaged `stems` array skips empty stems (compacted), so it
            // must be matched by NAME, not by index — otherwise offset/dry get
            // restored to the wrong lane (notably aux when an earlier stem is
            // empty).
            NSArray* stemMeta = pgm[@"stems"];
            NSMutableDictionary* metaByName = [NSMutableDictionary dictionary];
            if ([stemMeta isKindOfClass:[NSArray class]]) {
                for (id e in stemMeta) {
                    if ([e isKindOfClass:[NSDictionary class]] &&
                        [e[@"name"] isKindOfClass:[NSString class]])
                        metaByName[e[@"name"]] = e;
                }
            }
            long maxFrames = (long)self->_songL.size();
            int loadMute = 0, loadSolo = 0;   // rebuilt from per-stem metadata
            for (int i = 0; i < 8; ++i) {
                self->_stems[i].clear();
                self->_stemSource[i] = nil;
                self.sharedState->stemOffset[i].store(0, std::memory_order_relaxed);
                self.sharedState->stemDry[i].store(0.0f, std::memory_order_relaxed);
                self.sharedState->stemGain[i].store(1.0f, std::memory_order_relaxed);
                // Mixer state is name-keyed in the package; restore even for stems
                // whose audio is absent (e.g. a muted lane).
                {
                    NSDictionary* m0 = metaByName[names[i]];
                    if ([m0[@"mute"] isKindOfClass:[NSNumber class]] && [m0[@"mute"] boolValue])
                        loadMute |= (1 << i);
                    if ([m0[@"solo"] isKindOfClass:[NSNumber class]] && [m0[@"solo"] boolValue])
                        loadSolo |= (1 << i);
                    if ([m0[@"gain"] isKindOfClass:[NSNumber class]]) {
                        float g = [m0[@"gain"] floatValue];
                        self.sharedState->stemGain[i].store(MAX(0.0f, MIN(1.5f, g)),
                                                            std::memory_order_relaxed);
                    }
                }
                self->_takeL[i].clear();
                self->_takeR[i].clear();
                NSURL* wav = [[root URLByAppendingPathComponent:@"stems"]
                              URLByAppendingPathComponent:
                              [names[i] stringByAppendingString:@".wav"]];
                if (![[NSFileManager defaultManager] fileExistsAtPath:wav.path]) continue;
                [self studioProgress:@"loading stems" pct:0.2f + 0.6f * (i / 6.0f)];
                std::vector<float> L, R;
                if (!JamDecode48k(wav, L, R)) continue;
                const long nf = (long)L.size();
                maxFrames = MAX(maxFrames, nf);
                self->_stems[i].assign(nf * 2, 0);
                for (long k = 0; k < nf; ++k) {
                    float l = L[k] * 32767.0f, r = R[k] * 32767.0f;
                    l = MAX(-32768.0f, MIN(32767.0f, l));
                    r = MAX(-32768.0f, MIN(32767.0f, r));
                    self->_stems[i][k * 2] = (int16_t)l;
                    self->_stems[i][k * 2 + 1] = (int16_t)r;
                }
                self->_stemSource[i] = @"imported";
                NSDictionary* sm = metaByName[names[i]];
                if ([sm[@"offset"] isKindOfClass:[NSNumber class]]) {
                    self.sharedState->stemOffset[i].store(
                        [sm[@"offset"] longValue], std::memory_order_relaxed);
                }
                if ([sm[@"dry"] isKindOfClass:[NSNumber class]]) {
                    self.sharedState->stemDry[i].store(
                        MAX(0.0f, MIN(0.5f, [sm[@"dry"] floatValue])), std::memory_order_relaxed);
                }
            }
            self.sharedState->stemMuteMask.store(loadMute, std::memory_order_relaxed);
            self.sharedState->stemSoloMask.store(loadSolo, std::memory_order_relaxed);
            if (maxFrames <= 0) {
                [self studioFail:@"PGM folder has no audio"];
                return;
            }
            // Length-align every loaded stem (mixer requires equal lengths).
            for (int i = 0; i < 8; ++i) {
                if (!self->_stems[i].empty()) {
                    self->_stems[i].resize(maxFrames * 2, 0);
                }
            }
            self->_songDur = maxFrames / 48000.0;

            // Metadata from program.json.
            NSNumber* bpm = [song isKindOfClass:[NSDictionary class]] ? song[@"bpm"] : nil;
            NSString* key = [song isKindOfClass:[NSDictionary class]] ? song[@"key"] : nil;
            self->_keyOverride = ([key isKindOfClass:[NSString class]] && [key length]) ? key : nil;
            NSString* pkgMemo = [song isKindOfClass:[NSDictionary class]] ? song[@"memo"] : nil;
            self->_songMemo = [pkgMemo isKindOfClass:[NSString class]] ? pkgMemo : @"";
            self->_songAnalysis.bpm = [bpm isKindOfClass:[NSNumber class]]
                ? bpm.floatValue : 120.0f;
            self.sharedState->stemBpm.store(self->_songAnalysis.bpm,
                                            std::memory_order_relaxed);
            if (!self->_stems[0].empty()) {
                // Drums give the cleanest beat grid.
                [self studioRefineBeatGridFromDrums];
            } else if (!self->_songL.empty()) {
                // Re-derive the precise beat grid from the imported song.
                std::vector<float> bgMono(self->_songL.size());
                for (size_t i = 0; i < bgMono.size(); ++i) {
                    bgMono[i] = (self->_songL[i] + self->_songR[i]) * 0.5f;
                }
                jamstudio::BeatGrid bg = jamstudio::beatGrid(
                    bgMono.data(), (long)bgMono.size(), self->_songAnalysis.bpm);
                self->_songAnalysis.bpm = bg.bpm;
                self.sharedState->stemBpm.store(bg.bpm, std::memory_order_relaxed);
                self.sharedState->stemBeatOff.store((long)(bg.offsetSec * 48000.0),
                                                    std::memory_order_relaxed);
                self.sharedState->stemBarPhase.store(bg.barPhase,
                                                     std::memory_order_relaxed);
            }
            // Cue point: re-anchors the grid to the packaged "1" if present.
            self->_cueSec = -1.0;
            self.sharedState->stemCue.store(-1, std::memory_order_relaxed);
            NSNumber* cue = [song isKindOfClass:[NSDictionary class]] ? song[@"cue"] : nil;
            if ([cue isKindOfClass:[NSNumber class]] && cue.doubleValue >= 0) {
                self->_cueSec = cue.doubleValue;
                self.sharedState->stemCue.store((long)(self->_cueSec * 48000.0),
                                                std::memory_order_relaxed);
            }
            // Click anchor (计算点): explicit value wins, else follows the cue.
            self->_clickAnchorSec = -1.0;
            NSNumber* anc = [song isKindOfClass:[NSDictionary class]] ? song[@"clickAnchor"] : nil;
            if ([anc isKindOfClass:[NSNumber class]] && anc.doubleValue >= 0) {
                self->_clickAnchorSec = anc.doubleValue;
                self.sharedState->stemBeatOff.store((long)(self->_clickAnchorSec * 48000.0),
                                                    std::memory_order_relaxed);
                self.sharedState->stemBarPhase.store(0, std::memory_order_relaxed);
            } else if (self->_cueSec >= 0) {
                self.sharedState->stemBeatOff.store((long)(self->_cueSec * 48000.0),
                                                    std::memory_order_relaxed);
                self.sharedState->stemBarPhase.store(0, std::memory_order_relaxed);
            }
            NSNumber* tsig = [song isKindOfClass:[NSDictionary class]] ? song[@"timeSig"] : nil;
            self.sharedState->beatsPerBar.store(
                ([tsig isKindOfClass:[NSNumber class]] && tsig.intValue == 3) ? 3 : 4,
                std::memory_order_relaxed);
            self->_songAnalysis.sections.clear();
            NSArray* sections = pgm[@"sections"];
            if ([sections isKindOfClass:[NSArray class]]) {
                for (NSDictionary* sec in sections) {
                    if (![sec isKindOfClass:[NSDictionary class]]) continue;
                    jamstudio::Section js;
                    js.start = [sec[@"start"] doubleValue];
                    js.end = [sec[@"end"] doubleValue];
                    js.energy = [sec[@"energy"] floatValue];
                    NSString* lbl = sec[@"label"];
                    js.label = [@"verse" isEqualToString:lbl] ? 1
                             : [@"drop" isEqualToString:lbl] ? 2
                             : [@"build" isEqualToString:lbl] ? 3 : 0;
                    self->_songAnalysis.sections.push_back(js);
                }
            }

            // MIDI clips back from midi/<stem>.mid (exact round-trip of what
            // the lanes played at package time — transcription or voicing).
            for (int i = 0; i < 8; ++i) {
                self->_stemNotes[i].clear();
                NSURL* mid = [[root URLByAppendingPathComponent:@"midi"]
                              URLByAppendingPathComponent:
                              [names[i] stringByAppendingString:@".mid"]];
                if ([[NSFileManager defaultManager] fileExistsAtPath:mid.path]) {
                    JamReadMidi(mid, self->_stemNotes[i]);
                }
            }

            // Chord chart from program.json (label → root/minor/none).
            self->_chords.clear();
            NSArray* chordArr = pgm[@"chords"];
            if ([chordArr isKindOfClass:[NSArray class]]) {
                for (NSDictionary* cd in chordArr) {
                    if (![cd isKindOfClass:[NSDictionary class]]) continue;
                    jamchords::Chord c;
                    c.start = [cd[@"start"] doubleValue];
                    c.end = [cd[@"end"] doubleValue];
                    NSString* lbl = [cd[@"label"] isKindOfClass:[NSString class]]
                        ? cd[@"label"] : @"";
                    c.none = YES;
                    for (int pc = 11; pc >= 0; --pc) {   // longest match first (C# over C)
                        NSString* nm = [NSString stringWithUTF8String:jamchords::kPcNames[pc]];
                        if ([lbl hasPrefix:nm] &&
                            (lbl.length == nm.length ||
                             [lbl isEqualToString:[nm stringByAppendingString:@"m"]])) {
                            c.root = pc;
                            c.minor = (lbl.length > nm.length);
                            c.none = NO;
                            break;
                        }
                    }
                    self->_chords.push_back(c);
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [self sendStateUpdate:@{@"studioSong": @{
                    @"name": self->_songName ?: @"pgm",
                    @"duration": @(self->_songDur),
                    @"bpm": @((int)lroundf(self->_songAnalysis.bpm)),
                    @"key": [key isKindOfClass:[NSString class]] ? key : @"",
                    @"memo": self->_songMemo ?: @"",
                    @"sections": [sections isKindOfClass:[NSArray class]] ? sections : @[],
                    @"wave": self->_songL.empty()
                        ? @[]
                        : JamWaveThumb(self->_songL.data(), self->_songR.data(),
                                       (long)self->_songL.size(), 480),
                }}];
                [self studioPushStemWaves];
                [self studioPublishStems];
                [self studioPushChords];
                [self studioPushCue];
                for (int i = 0; i < 8; ++i) {
                    if (!self->_stemNotes[i].empty()) [self studioPushNotes:i];
                }
                // Lane patches (incl. AI-designed ones) + playback sources.
                NSArray* patches = pgm[@"patches"];
                for (int t = 1; t <= 7; ++t) {
                    self->_lanePatchInfo[t] = nil;
                    self->_lanePatched[t] = NO;
                    if ([patches isKindOfClass:[NSArray class]] &&
                        (NSUInteger)t < patches.count &&
                        [patches[t] isKindOfClass:[NSDictionary class]]) {
                        [self handleLanePatch:t info:patches[t]];
                    }
                }
                // Lane engines (synth/SF2), GM programs + insert FX.
                NSArray* lanes = pgm[@"lanes"];
                BOOL wantSf = NO;
                if ([lanes isKindOfClass:[NSArray class]]) {
                    for (int t = 1; t <= 7 && (NSUInteger)t < lanes.count; ++t) {
                        NSDictionary* ld = lanes[t];
                        if (![ld isKindOfClass:[NSDictionary class]]) continue;
                        const int k = t - 1;
                        self.sharedState->laneSfProgram[k].store(
                            MAX(0, MIN(127, [ld[@"program"] intValue])),
                            std::memory_order_relaxed);
                        self.sharedState->laneFx[k].reverb.store(
                            MAX(0.0f, MIN(1.0f, [ld[@"reverb"] floatValue])),
                            std::memory_order_relaxed);
                        self.sharedState->laneFx[k].echo.store(
                            MAX(0.0f, MIN(1.0f, [ld[@"echo"] floatValue])),
                            std::memory_order_relaxed);
                        if ([ld[@"engine"] intValue] == 1) {
                            wantSf = YES;
                            [self handleLaneEngine:t engine:1];
                        } else {
                            self.sharedState->laneEngine[k].store(0,
                                std::memory_order_relaxed);
                        }
                    }
                }
                (void)wantSf;
                NSArray* sources = pgm[@"sources"];
                if ([sources isKindOfClass:[NSArray class]]) {
                    for (int t = 1; t <= 7 && (NSUInteger)t < sources.count; ++t) {
                        if ([sources[t] intValue] == 1) {
                            [self handleLaneSource:t midi:YES];
                        }
                    }
                }
                // PGM live-play source console (SOURCE / VOL / R / E).
                NSDictionary* live = pgm[@"live"];
                if ([live isKindOfClass:[NSDictionary class]]) {
                    if ([live[@"program"] isKindOfClass:[NSNumber class]])
                        self.sharedState->liveSfProgram.store(
                            MAX(0, MIN(127, [live[@"program"] intValue])), std::memory_order_relaxed);
                    if ([live[@"gain"] isKindOfClass:[NSNumber class]]) {
                        const float g = MAX(0.0f, MIN(1.2f, [live[@"gain"] floatValue]));
                        self.sharedState->liveGain.store(g, std::memory_order_relaxed);
                        self.sharedState->synth.volume.store(g, std::memory_order_relaxed);
                    }
                    if ([live[@"reverb"] isKindOfClass:[NSNumber class]]) {
                        const float v = MAX(0.0f, MIN(1.0f, [live[@"reverb"] floatValue]));
                        self.sharedState->liveFx.reverb.store(v, std::memory_order_relaxed);
                        self.sharedState->synth.space.store(v, std::memory_order_relaxed);
                    }
                    if ([live[@"echo"] isKindOfClass:[NSNumber class]])
                        self.sharedState->liveFx.echo.store(
                            MAX(0.0f, MIN(1.0f, [live[@"echo"] floatValue])), std::memory_order_relaxed);
                    if ([live[@"source"] isKindOfClass:[NSNumber class]])
                        [self handleLiveSource:[live[@"source"] intValue]];
                }
                [self studioPushPatches];
                [self studioPushSources];
                [self studioPushLanes];
                [self studioPushLive];
                for (int i = 0; i < 8; ++i) { [self studioPushStemAlign:i]; [self studioPushStemDry:i]; }
                [self studioPushMixer];
                self->_studioBusy = NO;
                [self studioProgress:@"ready" pct:1.0f];
            });
        });
    };
    if (self.view.window) [panel beginSheetModalForWindow:self.view.window completionHandler:completion];
    else [panel beginWithCompletionHandler:completion];
}

// ── Separation model management ──
// htdemucs ggml weights (~81 MB) live in Application Support; downloadable
// from Hugging Face or hand-picked from disk.

static NSString* const kSepModelURL =
    @"https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/ggml-model-htdemucs-6s-f16.bin";

- (NSString*)sepModelDir {
    NSString* dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"MagentaRT"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// Preferred weights: hand-picked file → 6-source → 4-source.
- (NSString*)sepModelPath {
    NSString* custom = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_SepModelPath"];
    if (custom.length > 0 && JamDemucsAvailable(custom)) return custom;
    NSString* six = [[self sepModelDir] stringByAppendingPathComponent:@"ggml-model-htdemucs-6s-f16.bin"];
    if (JamDemucsAvailable(six)) return six;
    return [[self sepModelDir] stringByAppendingPathComponent:@"ggml-model-htdemucs-4s-f16.bin"];
}

- (void)pushSepModelState:(BOOL)downloading pct:(float)pct {
    [self pushSepModelState:downloading pct:pct mb:0];
}

- (void)pushSepModelState:(BOOL)downloading pct:(float)pct mb:(float)mb {
    NSString* path = [self sepModelPath];
    const BOOL present = JamDemucsAvailable(path);
    int sources = 0;
    if (present) sources = [path containsString:@"-6s-"] ? 6 : 4;
    [self sendStateUpdate:@{@"studioSepModel": @{
        @"present": @(present),
        @"sources": @(sources),
        @"downloading": @(downloading),
        @"pct": @(pct),
        @"mb": @(mb),
    }}];
}

- (void)handleSepModelDownload {
    if (_sepDownload) return;
    if (JamDemucsAvailable([self sepModelPath])) { [self pushSepModelState:NO pct:1]; return; }
    _sepRetries = 0;
    _sepResumeData = nil;
    [self sepStartDownload];
}

// ── Separation pipeline selection (auto / hpss / demucs / rf) ──

static NSString* const kRfModelURL =
    @"https://huggingface.co/bgkb/bs_polarformer/resolve/main/bs_polarformer.onnx";

- (NSString*)rfModelPath {
    return [[self sepModelDir] stringByAppendingPathComponent:@"bs_polarformer.onnx"];
}

- (NSString*)sepPipeline {
    NSString* m = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_SepPipeline"];
    return ([@[@"auto", @"hpss", @"demucs", @"rf", @"rf2"] containsObject:m]) ? m : @"auto";
}

- (void)handleSepPipeline:(NSString*)mode {
    if (![@[@"auto", @"hpss", @"demucs", @"rf", @"rf2"] containsObject:mode]) return;
    [[NSUserDefaults standardUserDefaults] setObject:mode forKey:@"Jam_SepPipeline"];
    [self studioPushSepPipeline];
    // Selecting RF with no model on disk: fetch it (~201 MB).
    if (([mode isEqualToString:@"rf"] || [mode isEqualToString:@"rf2"]) &&
        ![[NSFileManager defaultManager] fileExistsAtPath:[self rfModelPath]] &&
        !_sfBusy) {
        [self rfModelDownload];
    }
}

- (void)studioPushSepPipeline {
    [self sendStateUpdate:@{@"studioSepPipeline": @{
        @"mode": [self sepPipeline],
        @"rfPresent": @([[NSFileManager defaultManager]
                            fileExistsAtPath:[self rfModelPath]]),
    }}];
}

- (void)rfModelDownload {
    NSString* path = [self rfModelPath];
    [self studioProgress:@"downloading BS-RoFormer (201MB)" pct:0.02f];
    NSURLSessionDownloadTask* task = [[NSURLSession sharedSession]
        downloadTaskWithURL:[NSURL URLWithString:kRfModelURL]
          completionHandler:^(NSURL* loc, NSURLResponse* resp, NSError* err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (err || !loc) {
                    [self sendStateUpdate:@{@"studioError":
                        [NSString stringWithFormat:@"BS-RoFormer 下载失败: %@",
                         err.localizedDescription ?: @"no data"]}];
                    [self studioProgress:@"ready" pct:1.0f];
                    return;
                }
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                [[NSFileManager defaultManager]
                    moveItemAtURL:loc toURL:[NSURL fileURLWithPath:path] error:nil];
                [self studioProgress:@"ready" pct:1.0f];
                [self sendStateUpdate:@{@"studioNotice": @"✓ BS-RoFormer 模型就绪"}];
                [self studioPushSepPipeline];
            });
        }];
    [task resume];
    __weak NSURLSessionDownloadTask* wTask = task;
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer* t) {
        NSURLSessionDownloadTask* st = wTask;
        if (!st || st.state != NSURLSessionTaskStateRunning) { [t invalidate]; return; }
        const int64_t got = st.countOfBytesReceived;
        const int64_t want = st.countOfBytesExpectedToReceive;
        if (want > 0) {
            [self studioProgress:@"downloading BS-RoFormer (201MB)"
                             pct:0.02f + 0.95f * (float)got / (float)want];
        }
    }];
}

// ── On-demand HQ single-stem re-separation (BS-Roformer-SW 6-stem) ──
// The user runs this per stem (currently piano) when the htdemucs split isn't
// clean enough; it overwrites just that stem with the dedicated model.

static NSString* const kSwModelURL =
    @"https://huggingface.co/elicwhite/bs-roformer-sw-6stem-onnx/resolve/main/bs_roformer_sw_6stem_fp16.onnx";

- (NSString*)swModelPath {
    return [[self sepModelDir] stringByAppendingPathComponent:@"bs_roformer_sw_6stem_fp16.onnx"];
}

- (void)handleStudioExtractStem:(int)idx {
    if (_studioBusy) return;
    if (idx < 0 || idx > 5) return;            // app stem index (vocals via RF2)
    if (_songL.empty()) {
        [self sendStateUpdate:@{@"studioError": @"load a song first"}];
        return;
    }
    // App stems are [drums,bass,other,vocals,guitar,piano]; the SW model emits
    // [bass,drums,other,vocals,guitar,piano] — map the requested app stem to
    // the model's output channel.
    static const int kAppToSw[6] = {1, 0, 2, 3, 4, 5};
    const int swIdx = kAppToSw[idx];
    NSString* path = [self swModelPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // Fetch the 336 MB model once, then retry the extraction.
        _studioBusy = YES;
        [self studioProgress:@"downloading 钢琴HQ model (336MB)" pct:0.01f];
        NSURLSessionDownloadTask* task = [[NSURLSession sharedSession]
            downloadTaskWithURL:[NSURL URLWithString:kSwModelURL]
              completionHandler:^(NSURL* loc, NSURLResponse* resp, NSError* err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_studioBusy = NO;
                    if (err || !loc) {
                        [self studioFail:[NSString stringWithFormat:@"模型下载失败: %@",
                                          err.localizedDescription ?: @"no data"]];
                        return;
                    }
                    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                    [[NSFileManager defaultManager]
                        moveItemAtURL:loc toURL:[NSURL fileURLWithPath:path] error:nil];
                    [self studioProgress:@"ready" pct:1.0f];
                    [self handleStudioExtractStem:idx];   // retry
                });
            }];
        [task resume];
        __weak NSURLSessionDownloadTask* wTask = task;
        [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer* t) {
            NSURLSessionDownloadTask* st = wTask;
            if (!st || st.state != NSURLSessionTaskStateRunning) { [t invalidate]; return; }
            const int64_t got = st.countOfBytesReceived, want = st.countOfBytesExpectedToReceive;
            if (want > 0) [self studioProgress:@"downloading 钢琴HQ model (336MB)"
                                           pct:0.01f + 0.95f * (float)got / (float)want];
        }];
        return;
    }

    static NSString* const kAppNames[6] = {@"drums", @"bass", @"other", @"vocals",
                                           @"guitar", @"piano"};
    _studioBusy = YES;
    [self studioProgress:[NSString stringWithFormat:@"%@ HQ 分离中 (BS-Roformer-SW)",
                          kAppNames[idx]] pct:0.02f];
    const long n = (long)_songL.size();
    std::vector<float> songL = _songL, songR = _songR;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        std::vector<float> oL, oR;
        NSString* err = nil;
        const BOOL ok = JamRoformerSWStem(path, swIdx, songL.data(), songR.data(), n, oL, oR,
            ^(float p) { [self studioProgress:[NSString stringWithFormat:
                @"%@ HQ 分离中", kAppNames[idx]] pct:0.02f + p * 0.95f]; }, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) { [self studioFail:err ?: @"HQ 分离失败"]; return; }
            // Overwrite the stem, length-aligned to the existing stems (the
            // mixer requires equal lengths). Fall back to the song length.
            long frames = 0;
            for (int t = 0; t < 8; ++t) frames = MAX(frames, (long)self->_stems[t].size() / 2);
            if (frames == 0) frames = n;
            self->_stems[idx].assign(frames * 2, 0);
            const long copyN = MIN(frames, (long)oL.size());
            for (long i = 0; i < copyN; ++i) {
                float l = oL[i] * 32767.0f, r = oR[i] * 32767.0f;
                self->_stems[idx][i * 2]     = (int16_t)MAX(-32768.0f, MIN(32767.0f, l));
                self->_stems[idx][i * 2 + 1] = (int16_t)MAX(-32768.0f, MIN(32767.0f, r));
            }
            self->_stemSource[idx] = @"neural";
            self->_stemNotes[idx].clear();    // transcription is now stale
            [self studioPushStemWaves];
            [self studioPushNotes:idx];
            [self studioPublishStems];
            self->_studioBusy = NO;
            [self studioProgress:@"ready" pct:1.0f];
            [self sendStateUpdate:@{@"studioNotice":
                [NSString stringWithFormat:@"✓ %@ HQ 重分离完成", kAppNames[idx]]}];
        });
    });
}

// Push a stem's current alignment offset (ms) to the UI.
- (void)studioPushStemAlign:(int)idx {
    if (idx < 0 || idx >= JamSharedState::kStems || !self.sharedState) return;
    const long off = self.sharedState->stemOffset[idx].load(std::memory_order_relaxed);
    [self sendStateUpdate:@{@"studioStemAlign": @{
        @"index": @(idx),
        @"ms": @((int)llroundf(off / 48.0f)),
    }}];
}

// Push the per-stem mixer state (mute / solo / gain) to the UI.
- (void)studioPushMixer {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    const int mute = sh->stemMuteMask.load(std::memory_order_relaxed);
    const int solo = sh->stemSoloMask.load(std::memory_order_relaxed);
    NSMutableArray* arr = [NSMutableArray array];
    for (int i = 0; i < 8; ++i) {
        [arr addObject:@{
            @"mute": @(((mute >> i) & 1) != 0),
            @"solo": @(((solo >> i) & 1) != 0),
            @"gain": @(sh->stemGain[i].load(std::memory_order_relaxed)),
        }];
    }
    [self sendStateUpdate:@{@"studioMixer": arr}];
}

// Push a stem's current dry-blend amount (0..0.5) to the UI.
- (void)studioPushStemDry:(int)idx {
    if (idx < 0 || idx >= JamSharedState::kStems || !self.sharedState) return;
    [self sendStateUpdate:@{@"studioStemDry": @{
        @"index": @(idx),
        @"value": @(self.sharedState->stemDry[idx].load(std::memory_order_relaxed)),
    }}];
}

// Manual nudge / auto-align / reset of an imported/replaced stem against the
// base song. Offset is applied at playback read time (stemOffset, samples).
- (void)handleStudioStemAlign:(int)idx action:(NSString*)action {
    JamSharedState* sh = self.sharedState;
    if (idx < 0 || idx >= JamSharedState::kStems || !sh) return;
    const long kNudge = 480;  // 10 ms per click @ 48 kHz

    if ([action isEqualToString:@"reset"]) {
        sh->stemOffset[idx].store(0, std::memory_order_relaxed);
        [self studioPushStemAlign:idx];
        return;
    }
    if ([action isEqualToString:@"left"]) {       // play earlier
        sh->stemOffset[idx].fetch_sub(kNudge, std::memory_order_relaxed);
        [self studioPushStemAlign:idx];
        return;
    }
    if ([action isEqualToString:@"right"]) {      // play later
        sh->stemOffset[idx].fetch_add(kNudge, std::memory_order_relaxed);
        [self studioPushStemAlign:idx];
        return;
    }
    if (![action isEqualToString:@"auto"]) return;

    // ── Auto-align: cross-correlate the stem's onset envelope against the
    //    original mix and pick the lag that lines them up. ──
    if (_stems[idx].empty() || _songL.empty() || _studioBusy) {
        [self studioPushStemAlign:idx];
        return;
    }
    _studioBusy = YES;
    [self studioProgress:@"自动对齐分析中…" pct:0.15f];
    // Snapshot the audio for the background thread.
    std::vector<int16_t> stem = _stems[idx];
    std::vector<float> songL = _songL, songR = _songR;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        const int H = 256;                       // envelope hop (~187 Hz)
        const long stemFrames = (long)stem.size() / 2;
        const long songFrames = (long)songL.size();
        const long N = MIN(stemFrames, songFrames);
        const long cap = MIN(N, (long)(120.0 * 48000.0));  // analyse ≤120 s
        const long E = cap / H;                  // envelope length
        if (E < 16) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_studioBusy = NO;
                [self studioProgress:@"ready" pct:1.0f];
                [self studioPushStemAlign:idx];
            });
            return;
        }
        std::vector<float> eStem(E, 0.0f), eRef(E, 0.0f);
        for (long m = 0; m < E; ++m) {
            float ss = 0.0f, rr = 0.0f;
            const long base = m * H;
            for (int j = 0; j < H; ++j) {
                const long s = base + j;
                ss += fabsf((float)(stem[s * 2] + stem[s * 2 + 1])) * (0.5f / 32768.0f);
                rr += fabsf(songL[s] + songR[s]) * 0.5f;
            }
            eStem[m] = ss; eRef[m] = rr;
        }
        // Mean-subtract for a covariance-style match.
        double mS = 0, mR = 0;
        for (long m = 0; m < E; ++m) { mS += eStem[m]; mR += eRef[m]; }
        mS /= E; mR /= E;
        for (long m = 0; m < E; ++m) { eStem[m] -= (float)mS; eRef[m] -= (float)mR; }
        const long L = MIN(E / 2, (long)(3.0 * 48000.0 / H));  // ±3 s search
        double best = -1e30; long bestD = 0;
        for (long d = -L; d <= L; ++d) {
            double acc = 0.0;
            const long m0 = MAX(0L, -d), m1 = MIN(E, E - d);
            for (long m = m0; m < m1; ++m) acc += (double)eStem[m] * eRef[m + d];
            if (acc > best) { best = acc; bestD = d; }
        }
        const long offset = bestD * H;           // stemOffset (samples)
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_studioBusy = NO;
            sh->stemOffset[idx].store(offset, std::memory_order_relaxed);
            [self studioProgress:@"ready" pct:1.0f];
            [self sendStateUpdate:@{@"studioNotice":
                [NSString stringWithFormat:@"✓ 自动对齐：%+d ms",
                 (int)llroundf(offset / 48.0f)]}];
            [self studioPushStemAlign:idx];
        });
    });
}

// Resume-capable download with a stall watchdog: if no bytes arrive for 20 s
// (flaky CDN / proxy), cancel-with-resume-data and continue from where it
// stopped. Network errors that carry resume data also continue in place.
- (void)sepStartDownload {
    __weak JamAppController* weakSelf = self;
    void (^completion)(NSURL*, NSURLResponse*, NSError*) =
        ^(NSURL* location, NSURLResponse* response, NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                JamAppController* s = weakSelf;
                if (!s) return;
                [s->_sepDownloadTimer invalidate];
                s->_sepDownloadTimer = nil;
                s->_sepDownload = nil;
                if (error || !location) {
                    NSData* rd = error.userInfo[NSURLSessionDownloadTaskResumeData];
                    if (s->_sepRetries < 12) {
                        s->_sepRetries++;
                        s->_sepResumeData = rd;   // nil → restart from scratch
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                     (int64_t)(2.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            [weakSelf sepStartDownload];
                        });
                        return;
                    }
                    [s sendStateUpdate:@{@"studioError":
                        [NSString stringWithFormat:@"model download failed: %@",
                         error.localizedDescription ?: @"unknown"]}];
                    [s pushSepModelState:NO pct:0];
                    return;
                }
                NSString* dest = [[s sepModelDir]
                    stringByAppendingPathComponent:@"ggml-model-htdemucs-6s-f16.bin"];
                [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
                NSError* mvErr = nil;
                [[NSFileManager defaultManager] moveItemAtURL:location
                                                        toURL:[NSURL fileURLWithPath:dest]
                                                        error:&mvErr];
                [s pushSepModelState:NO pct:1];
                [s sendStateUpdate:@{@"studioNotice":
                    mvErr ? @"download finished but could not save" : @"separation model ready"}];
            });
        };

    if (_sepResumeData) {
        _sepDownload = [[NSURLSession sharedSession]
            downloadTaskWithResumeData:_sepResumeData completionHandler:completion];
        _sepResumeData = nil;
    } else {
        _sepDownload = [[NSURLSession sharedSession]
            downloadTaskWithURL:[NSURL URLWithString:kSepModelURL]
              completionHandler:completion];
    }
    [_sepDownload resume];
    _sepLastBytes = -1;
    _sepLastChange = CFAbsoluteTimeGetCurrent();
    [self pushSepModelState:YES pct:0];

    _sepDownloadTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer* t) {
        JamAppController* s = weakSelf;
        if (!s || !s->_sepDownload) { [t invalidate]; return; }
        const int64_t got = s->_sepDownload.countOfBytesReceived;
        const int64_t want = s->_sepDownload.countOfBytesExpectedToReceive;
        const float pct = want > 0 ? (float)((double)got / want) : 0;
        [s pushSepModelState:YES pct:pct mb:(float)(got / 1048576.0)];
        // Stall watchdog.
        if (got != s->_sepLastBytes) {
            s->_sepLastBytes = got;
            s->_sepLastChange = CFAbsoluteTimeGetCurrent();
        } else if (CFAbsoluteTimeGetCurrent() - s->_sepLastChange > 20.0 &&
                   s->_sepRetries < 12) {
            s->_sepRetries++;
            [t invalidate];
            s->_sepDownloadTimer = nil;
            NSURLSessionDownloadTask* task = s->_sepDownload;
            s->_sepDownload = nil;
            [task cancelByProducingResumeData:^(NSData* rd) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    JamAppController* s2 = weakSelf;
                    if (!s2) return;
                    s2->_sepResumeData = rd;
                    [s2 sepStartDownload];
                });
            }];
        }
    }];
}

- (void)handleSepModelPick {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setMessage:@"Select the htdemucs ggml weights (ggml-model-htdemucs-4s-f16.bin)"];
    void (^completion)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        [[NSUserDefaults standardUserDefaults] setObject:panel.URL.path
                                                  forKey:@"Jam_SepModelPath"];
        [self pushSepModelState:NO pct:1];
    };
    if (self.view.window) [panel beginSheetModalForWindow:self.view.window completionHandler:completion];
    else [panel beginWithCompletionHandler:completion];
}

- (void)studioFail:(NSString*)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_studioBusy = NO;
        [self sendStateUpdate:@{@"studioError": msg}];
    });
}

// Find the loudest 10 s window of a stem and resample it to the engine's
// 160000-frame (16 kHz mono) audio-prompt buffer.
- (BOOL)studioSetAudioPromptFromStem:(int)idx {
    const std::vector<int16_t>& stem = _stems[idx];
    const long frames = (long)stem.size() / 2;
    const long win = 48000L * 10;
    if (frames < win) return NO;
    const long hop = 48000L / 2;
    long bestAt = 0;
    double bestE = -1;
    for (long s = 0; s + win <= frames; s += hop) {
        double e = 0;
        for (long i = s; i < s + win; i += 64) {
            const float v = (stem[i * 2] + stem[i * 2 + 1]) / 65536.0f;
            e += v * v;
        }
        if (e > bestE) { bestE = e; bestAt = s; }
    }
    std::vector<float> prompt(160000);
    for (long o = 0; o < 160000; ++o) {
        const long s = bestAt + o * 3;
        float acc = 0;
        for (int k = 0; k < 3; ++k) {
            acc += (stem[(s + k) * 2] + stem[(s + k) * 2 + 1]) / 65536.0f;
        }
        prompt[o] = acc / 3.0f;
    }
    self.engine->set_audio_prompt_samples(0, "stem", prompt.data(), 160000);
    return YES;
}

- (void)handleStudioCover:(int)idx {
    if (idx < 0 || idx > 5 || _studioBusy || _stems[idx].empty()) return;
    if (!self.engine || !self.engine->is_loaded()) {
        [self sendStateUpdate:@{@"studioError": @"load a local model first"}];
        return;
    }
    if (self.useLyria && self.useLyria->load(std::memory_order_relaxed)) {
        [self sendStateUpdate:@{@"studioError": @"covers use the local engine — switch to local"}];
        return;
    }
    _studioBusy = YES;
    [self studioProgress:@"covering" pct:0.05f];

    // 1. Style DNA: the stem's loudest 10 s into audio slot 0. Audio slots
    //    take priority over text at the SAME index, so the steering text must
    //    live in slot 1 — blended ~70% audio DNA / 30% text guidance.
    if (![self studioSetAudioPromptFromStem:idx]) {
        [self studioFail:@"stem too short"];
        return;
    }
    static NSString* const tmpl[6] = {
        @"solo drums, drum kit only, no melody no bass",
        @"solo bass line, deep round bass, no drums",
        @"melodic instruments, chords and lead, no drums",
        @"expressive lead melody, vocal-like phrasing, no drums",
        @"solo electric guitar, expressive riffs, no drums",
        @"solo piano, expressive chords and melody, no drums",
    };
    const int bpm = (int)lroundf(_songAnalysis.bpm);
    NSString* text = [NSString stringWithFormat:@"%@, %d bpm", tmpl[idx], bpm];
    std::vector<std::string> texts = {"", text.UTF8String};   // slot 0 = audio
    std::vector<float> weights = {0.7f, 0.3f};
    self.engine->set_text_prompts(texts, weights);
    self.engine->set_blend_weights(weights.data(), 2);

    // 2. Stem discipline: suppress drums for bass/melodic takes.
    [self applyParamToEngine:39 value:(idx == 0 ? 0.0f : 1.0f)];   // drumless

    // 3. Clean slate: reset the model context so the take doesn't inherit
    //    whatever was playing before.
    [self applyParamToEngine:31 value:1.0f];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self applyParamToEngine:31 value:0.0f];
    });

    // 4. Roll: start playback if needed, settle 8 bars (encode + steering +
    //    buffering), record 8 bars.
    BOOL started = NO;
    if (!_isPlaying) {
        [NSApp sendAction:@selector(menuTogglePlayStop:) to:nil from:self];
        started = YES;
    }
    _coverStartedPlayback = started;
    const double beat = 60.0 / MAX(70, bpm);
    const double settleSec = 32.0 * beat;   // 8 bars
    const double recSec = 32.0 * beat;      // 8 bars
    const long recFrames = (long)(recSec * 48000.0);
    _recBufL.assign(recFrames, 0.0f);
    _recBufR.assign(recFrames, 0.0f);

    JamSharedState* shared = self.sharedState;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settleSec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self studioProgress:@"recording take" pct:0.4f];
        shared->recWritten.store(0, std::memory_order_relaxed);
        shared->recL.store(self->_recBufL.data(), std::memory_order_relaxed);
        shared->recR.store(self->_recBufR.data(), std::memory_order_relaxed);
        shared->recCap.store(recFrames, std::memory_order_relaxed);
        shared->recArmed.store(true, std::memory_order_release);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((settleSec + recSec + 0.3) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        shared->recArmed.store(false, std::memory_order_relaxed);
        shared->recL.store(nullptr, std::memory_order_relaxed);
        shared->recR.store(nullptr, std::memory_order_relaxed);
        self->_takeL[idx] = self->_recBufL;
        self->_takeR[idx] = self->_recBufR;
        if (self->_coverStartedPlayback && self->_isPlaying) {
            [NSApp sendAction:@selector(menuTogglePlayStop:) to:nil from:self];
        }
        // Restore: clear the audio slot, drumless off, back to the user's prompt.
        self.engine->set_audio_prompt_samples(0, "", nullptr, 0);
        [self applyParamToEngine:39 value:0.0f];
        if (self->_currentPromptText.length > 0) {
            std::vector<std::string> t = {self->_currentPromptText.UTF8String};
            std::vector<float> w = {1.0f};
            self.engine->set_text_prompts(t, w);
            self.engine->set_blend_weights(w.data(), 1);
        }
        self->_studioBusy = NO;
        [self sendStateUpdate:@{@"studioTake": @{
            @"index": @(idx),
            @"wave": JamWaveThumb(self->_takeL[idx].data(), self->_takeR[idx].data(),
                                  (long)self->_takeL[idx].size(), 480),
        }}];
        [self studioProgress:@"ready" pct:1.0f];
    });
}

// Publish the controller-owned stem buffers to the render thread (call on
// main, only when the vectors are stable).
- (void)studioPublishStems {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    long len = LONG_MAX;
    bool any = false;
    for (int i = 0; i < 8; ++i) {
        if (_stems[i].empty()) {
            sh->stemBuf[i].store(nullptr, std::memory_order_relaxed);
        } else {
            sh->stemBuf[i].store(_stems[i].data(), std::memory_order_relaxed);
            len = MIN(len, (long)_stems[i].size() / 2);
            any = true;
        }
    }
    if (!any) {
        // MIDI-only session: the transport timeline falls back to the song
        // length, or the longest published MIDI clip (+1 s of tail).
        len = (long)_songL.size();
        for (int t = 1; t < 8; ++t) {
            if (!_laneEvBuf[t].empty()) {
                len = MAX(len, _laneEvBuf[t].back().sample + 48000);
            }
        }
        if (len > 0) any = true;
    }
    sh->stemLen.store(any ? len : 0, std::memory_order_release);
    // Publish the original mix for the per-stem dry blend.
    if (!_songL.empty()) {
        sh->songMixL.store(_songL.data(), std::memory_order_relaxed);
        sh->songMixR.store(_songR.empty() ? _songL.data() : _songR.data(),
                           std::memory_order_relaxed);
        sh->songMixLen.store((long)_songL.size(), std::memory_order_release);
    } else {
        sh->songMixLen.store(0, std::memory_order_release);
        sh->songMixL.store(nullptr, std::memory_order_relaxed);
        sh->songMixR.store(nullptr, std::memory_order_relaxed);
    }
}

- (void)studioUnpublishStems {
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    sh->stemActive.store(false, std::memory_order_relaxed);
    sh->stemMask.store(0, std::memory_order_relaxed);
    sh->stemLen.store(0, std::memory_order_relaxed);
    for (int i = 0; i < 8; ++i) sh->stemBuf[i].store(nullptr, std::memory_order_relaxed);
    sh->songMixLen.store(0, std::memory_order_release);
    sh->songMixL.store(nullptr, std::memory_order_relaxed);
    sh->songMixR.store(nullptr, std::memory_order_relaxed);
}

- (void)handleStudioStemToggle:(int)idx on:(BOOL)on {
    if (idx < 0 || idx > 7) return;
    JamSharedState* sh = self.sharedState;
    if (!sh) return;
    // Stems and the song preview are mutually exclusive.
    sh->prevActive.store(false, std::memory_order_relaxed);
    int mask = sh->stemMask.load(std::memory_order_relaxed);
    if (on) {
        if (_stems[idx].empty()) return;
        mask |= (1 << idx);
    } else {
        mask &= ~(1 << idx);
    }
    sh->stemMask.store(mask, std::memory_order_relaxed);
    if (mask) {
        const long len = sh->stemLen.load(std::memory_order_relaxed);
        if (sh->stemPos.load(std::memory_order_relaxed) >= len) {
            sh->stemPos.store(0, std::memory_order_relaxed);
        }
        sh->stemActive.store(true, std::memory_order_release);
    } else {
        sh->stemActive.store(false, std::memory_order_relaxed);
    }
}

- (void)handleStudioPreview:(int)idx source:(NSString*)source on:(BOOL)on {
    JamSharedState* shared = self.sharedState;
    if (!shared) return;
    shared->prevActive.store(false, std::memory_order_relaxed);
    shared->stemActive.store(false, std::memory_order_relaxed);
    shared->stemMask.store(0, std::memory_order_relaxed);
    if (!on) return;
    if ([source isEqualToString:@"take"]) {
        if (idx < 0 || idx > 7 || _takeL[idx].empty()) return;
        _prevBufL = _takeL[idx];
        _prevBufR = _takeR[idx];
    } else if ([source isEqualToString:@"song"]) {
        if (_songL.empty()) return;
        _prevBufL = _songL;
        _prevBufR = _songR;
    } else {
        if (idx < 0 || idx > 7 || _stems[idx].empty()) return;
        const long frames = (long)_stems[idx].size() / 2;
        _prevBufL.resize(frames);
        _prevBufR.resize(frames);
        for (long i = 0; i < frames; ++i) {
            _prevBufL[i] = _stems[idx][i * 2] / 32768.0f;
            _prevBufR[i] = _stems[idx][i * 2 + 1] / 32768.0f;
        }
    }
    shared->prevPos.store(0, std::memory_order_relaxed);
    shared->prevLen.store((long)_prevBufL.size(), std::memory_order_relaxed);
    shared->prevL.store(_prevBufL.data(), std::memory_order_relaxed);
    shared->prevR.store(_prevBufR.data(), std::memory_order_relaxed);
    shared->prevActive.store(true, std::memory_order_release);
}

- (void)handleStudioPackage {
    if (_songL.empty()) {
        [self sendStateUpdate:@{@"studioError": @"load a song first"}];
        return;
    }
    bool anyStem = false;
    for (int i = 0; i < 8; ++i) anyStem |= !_stems[i].empty();
    if (!anyStem) {
        [self sendStateUpdate:@{@"studioError": @"separate or import stems first"}];
        return;
    }
    NSMutableArray* sections = [NSMutableArray array];
    static NSString* const labels[4] = {@"break", @"verse", @"drop", @"build"};
    for (const auto& s : _songAnalysis.sections) {
        [sections addObject:@{@"start": @(s.start), @"end": @(s.end),
                              @"label": labels[s.label & 3], @"energy": @(s.energy)}];
    }
    NSString* const* stemNames = kStemNames;
    static NSString* const tmpl[8] = {
        @"solo drums, drum kit only, no melody no bass",
        @"solo bass line, deep round bass, no drums",
        @"melodic instruments, chords and lead, no drums",
        @"expressive lead melody, vocal-like phrasing, no drums",
        @"solo electric guitar, expressive riffs, no drums",
        @"solo piano, expressive chords and melody, no drums",
        @"auxiliary melodic part, no drums",
        @"auxiliary melodic part, no drums",
    };
    const int bpm = (int)lroundf(_songAnalysis.bpm);
    NSMutableArray* stems = [NSMutableArray array];
    for (int i = 0; i < 8; ++i) {
        if (_stems[i].empty() && _stemNotes[i].empty() && _laneClip[i].empty()) continue;
        NSMutableDictionary* st = [@{
            @"name": stemNames[i],
            @"prompt": [NSString stringWithFormat:@"%@, %d bpm", tmpl[i], bpm],
            @"file": [NSString stringWithFormat:@"stems/%@.wav", stemNames[i]],
            @"source": _stemSource[i] ?: @"",
            @"offset": @(self.sharedState->stemOffset[i].load(std::memory_order_relaxed)),
            @"dry": @(self.sharedState->stemDry[i].load(std::memory_order_relaxed)),
            @"mute": @(((self.sharedState->stemMuteMask.load(std::memory_order_relaxed) >> i) & 1) != 0),
            @"solo": @(((self.sharedState->stemSoloMask.load(std::memory_order_relaxed) >> i) & 1) != 0),
            @"gain": @(self.sharedState->stemGain[i].load(std::memory_order_relaxed)),
        } mutableCopy];
        if (!_stemNotes[i].empty()) {
            st[@"midi"] = [NSString stringWithFormat:@"midi/%@.mid", stemNames[i]];
            st[@"notes"] = @((int)_stemNotes[i].size());
        }
        [stems addObject:st];
    }
    NSDictionary* pgm = @{
        @"app": @"megenta-jam",
        @"type": @"pgm",
        @"version": @2,
        @"song": @{@"name": _songName ?: @"song",
                   @"duration": @(_songDur),
                   @"bpm": @(bpm),
                   @"key": _keyOverride.length ? _keyOverride :
                           [NSString stringWithFormat:@"%@ %@",
                            kJamKeyNames[_songAnalysis.keyIdx],
                            _songAnalysis.minor ? @"minor" : @"major"],
                   @"memo": _songMemo ?: @"",
                   @"cue": @(_cueSec),
                   @"clickAnchor": @(_clickAnchorSec),
                   @"timeSig": @(self.sharedState->beatsPerBar.load(std::memory_order_relaxed)),
                   @"file": _songL.empty() ? @"" : @"song.wav"},
        @"sections": sections,
        @"stems": stems,
        @"chords": ({
            NSMutableArray* arr = [NSMutableArray array];
            for (const auto& c : _chords) {
                [arr addObject:@{@"start": @(c.start), @"end": @(c.end),
                                 @"label": [NSString stringWithUTF8String:
                                            jamchords::chordName(c).c_str()]}];
            }
            arr;
        }),
        @"sources": ({
            // Per-stem playback source at package time (0 = audio, 1 = MIDI).
            NSMutableArray* arr = [NSMutableArray array];
            for (int t = 0; t < 8; ++t) {
                [arr addObject:@(self.sharedState->stemSource[t]
                                     .load(std::memory_order_relaxed))];
            }
            arr;
        }),
        @"patches": ({
            // Per-stem lane synth patches (full parameter values, so
            // AI-designed sounds reload exactly on import).
            NSMutableArray* arr = [NSMutableArray array];
            for (int t = 0; t < 8; ++t) {
                [arr addObject:_lanePatchInfo[t] ?: (id)[NSNull null]];
            }
            arr;
        }),
        @"lanes": ({
            // Per-stem lane engine (synth/SF2), GM program and insert FX.
            NSMutableArray* arr = [NSMutableArray array];
            for (int t = 0; t < 8; ++t) {
                if (t == 0) { [arr addObject:[NSNull null]]; continue; }
                const int k = t - 1;
                [arr addObject:@{
                    @"engine": @(self.sharedState->laneEngine[k]
                                     .load(std::memory_order_relaxed)),
                    @"program": @(self.sharedState->laneSfProgram[k]
                                      .load(std::memory_order_relaxed)),
                    @"reverb": @(self.sharedState->laneFx[k].reverb
                                     .load(std::memory_order_relaxed)),
                    @"echo": @(self.sharedState->laneFx[k].echo
                                   .load(std::memory_order_relaxed)),
                }];
            }
            arr;
        }),
        @"live": @{
            // PGM live-play source (the SOURCE / VOL / R / E console).
            @"source":  @(self.sharedState->liveSource.load(std::memory_order_relaxed)),
            @"program": @(self.sharedState->liveSfProgram.load(std::memory_order_relaxed)),
            @"gain":    @(self.sharedState->liveGain.load(std::memory_order_relaxed)),
            @"reverb":  @(self.sharedState->liveFx.reverb.load(std::memory_order_relaxed)),
            @"echo":    @(self.sharedState->liveFx.echo.load(std::memory_order_relaxed)),
        },
    };
    NSData* data = [NSJSONSerialization dataWithJSONObject:pgm
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return;
    // The PGM is a folder: program.json + stems/<name>.wav (48 kHz 16-bit).
    NSSavePanel* panel = [NSSavePanel savePanel];
    NSString* base = [_songName stringByDeletingPathExtension] ?: @"show";
    [panel setNameFieldStringValue:[base stringByAppendingString:@".pgm"]];
    [panel setMessage:@"Package the live performance program (folder with stems + program.json)"];
    void (^completion)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSURL* root = panel.URL;
        self->_studioBusy = YES;
        [self studioProgress:@"packaging" pct:0.05f];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSFileManager* fm = [NSFileManager defaultManager];
            [fm removeItemAtURL:root error:nil];
            NSURL* stemsDir = [root URLByAppendingPathComponent:@"stems"];
            NSError* dirErr = nil;
            [fm createDirectoryAtURL:stemsDir withIntermediateDirectories:YES
                          attributes:nil error:&dirErr];
            if (dirErr) {
                [self studioFail:@"could not create the PGM folder"];
                return;
            }
            [data writeToURL:[root URLByAppendingPathComponent:@"program.json"]
                  atomically:YES];
            NSString* const* names = kStemNames;
            BOOL ok = YES;
            int written = 0;
            for (int i = 0; i < 8; ++i) {
                if (self->_stems[i].empty()) continue;
                [self studioProgress:@"packaging stems" pct:0.1f + 0.75f * (written / 8.0f)];
                NSURL* wav = [stemsDir URLByAppendingPathComponent:
                              [names[i] stringByAppendingString:@".wav"]];
                ok &= JamWriteWav(wav, self->_stems[i].data(),
                                  (long)self->_stems[i].size() / 2);
                written++;
            }
            // MIDI transcriptions + chords + AUX clip.
            {
                BOOL anyMidi = !self->_chords.empty();
                for (int i = 0; i < 8; ++i) {
                    anyMidi |= !self->_stemNotes[i].empty() ||
                               !self->_laneClip[i].empty();
                }
                if (anyMidi) {
                    NSURL* midiDir = [root URLByAppendingPathComponent:@"midi"];
                    [fm createDirectoryAtURL:midiDir withIntermediateDirectories:YES
                                  attributes:nil error:nil];
                    for (int i = 0; i < 8; ++i) {
                        // Prefer the published lane clip (what actually plays
                        // when the lane is on MIDI); fall back to the raw
                        // transcription.
                        const auto& notes = !self->_laneClip[i].empty()
                            ? self->_laneClip[i] : self->_stemNotes[i];
                        if (notes.empty()) continue;
                        JamWriteMidi([midiDir URLByAppendingPathComponent:
                                      [names[i] stringByAppendingString:@".mid"]],
                                     notes, self->_songAnalysis.bpm);
                    }
                    if (!self->_chords.empty()) {
                        // Block-triad chart for DAW reference.
                        std::vector<JamNote> chordNotes;
                        for (const auto& c : self->_chords) {
                            if (c.none) continue;
                            const int third = c.minor ? 3 : 4;
                            const double dur = MAX(0.1, c.end - c.start - 0.05);
                            chordNotes.push_back({c.start, dur, 60 + c.root, 0.7f});
                            chordNotes.push_back({c.start, dur, 60 + c.root + third, 0.7f});
                            chordNotes.push_back({c.start, dur, 67 + c.root, 0.7f});
                        }
                        JamWriteMidi([midiDir URLByAppendingPathComponent:@"chords.mid"],
                                     chordNotes, self->_songAnalysis.bpm);
                    }
                }
            }
            // Original song (enables full PGM re-import).
            if (!self->_songL.empty()) {
                [self studioProgress:@"packaging song" pct:0.88f];
                const long nf = (long)self->_songL.size();
                std::vector<int16_t> songI16(nf * 2);
                for (long i = 0; i < nf; ++i) {
                    float l = self->_songL[i] * 32767.0f, r = self->_songR[i] * 32767.0f;
                    l = MAX(-32768.0f, MIN(32767.0f, l));
                    r = MAX(-32768.0f, MIN(32767.0f, r));
                    songI16[i * 2] = (int16_t)l;
                    songI16[i * 2 + 1] = (int16_t)r;
                }
                ok &= JamWriteWav([root URLByAppendingPathComponent:@"song.wav"],
                                  songI16.data(), nf);
            }
            const BOOL allOk = ok;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_studioBusy = NO;
                [self studioProgress:@"ready" pct:1.0f];
                [self sendStateUpdate:@{@"studioNotice":
                    allOk ? [NSString stringWithFormat:@"PGM packaged → %@", root.lastPathComponent]
                          : @"PGM packaged with errors (some stems failed)"}];
            });
        });
    };
    if (self.view.window) [panel beginSheetModalForWindow:self.view.window completionHandler:completion];
    else [panel beginWithCompletionHandler:completion];
}

// ─── BPM detection ───────────────────────────────────────────────────────────
// One-click tempo detection from the master output: autocorrelate the recent
// onset-strength envelope (written by the audio thread), pick the strongest
// beat period in the 50–200 BPM range with a harmonic bonus, refine the peak
// parabolically, and fold the result into the 70–180 dance range.

- (void)handleDetectBpm {
    JamSharedState* shared = self.sharedState;
    if (!shared) return;
    if (!_isPlaying) {
        [self sendStateUpdate:@{@"detectedBpm": @0,
                                @"bpmDetectError": @"start playback first"}];
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        const float fps = 48000.0f / (float)JamSharedState::BPM_HOP;   // ≈ 93.75
        const int total = shared->bpmWrite.load(std::memory_order_acquire);
        const int n = MIN(total, JamSharedState::BPM_RING);
        if (n < (int)(fps * 6.0f)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self sendStateUpdate:@{@"detectedBpm": @0,
                                        @"bpmDetectError": @"let it play a few more seconds"}];
            });
            return;
        }
        // Copy the most recent window in time order (relaxed reads are fine
        // for analysis) and remove the mean.
        std::vector<float> x(n);
        const int start = total - n;
        double mean = 0.0;
        for (int i = 0; i < n; ++i) {
            x[i] = shared->bpmOnset[(start + i) % JamSharedState::BPM_RING];
            mean += x[i];
        }
        mean /= n;
        double energy = 0.0;
        for (int i = 0; i < n; ++i) { x[i] -= (float)mean; energy += x[i] * x[i]; }
        if (energy < 1e-12) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self sendStateUpdate:@{@"detectedBpm": @0,
                                        @"bpmDetectError": @"no beat found"}];
            });
            return;
        }

        // Autocorrelation over beat periods for 50–200 BPM.
        const int minLag = (int)(60.0f * fps / 200.0f);                // ≈ 28
        const int maxLag = MIN((int)(60.0f * fps / 50.0f), n / 2);     // ≈ 112
        std::vector<float> r(maxLag + 1, 0.0f);
        for (int lag = minLag; lag <= maxLag; ++lag) {
            double acc = 0.0;
            for (int i = 0; i + lag < n; ++i) acc += x[i] * x[i + lag];
            r[lag] = (float)(acc / (n - lag));
        }
        int bestLag = -1;
        float bestScore = 0.0f;
        for (int lag = minLag; lag <= maxLag; ++lag) {
            float score = r[lag];
            if (lag * 2 <= maxLag) score += 0.5f * r[lag * 2];         // harmonic bonus
            if (score > bestScore) { bestScore = score; bestLag = lag; }
        }
        if (bestLag < 0 || bestScore <= 0.0f) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self sendStateUpdate:@{@"detectedBpm": @0,
                                        @"bpmDetectError": @"no beat found"}];
            });
            return;
        }
        // Parabolic peak refinement for sub-block accuracy.
        float lagF = (float)bestLag;
        if (bestLag > minLag && bestLag < maxLag) {
            const float y0 = r[bestLag - 1], y1 = r[bestLag], y2 = r[bestLag + 1];
            const float den = y0 - 2.0f * y1 + y2;
            if (std::fabs(den) > 1e-12f) lagF += 0.5f * (y0 - y2) / den;
        }
        float bpm = 60.0f * fps / lagF;
        while (bpm < 70.0f) bpm *= 2.0f;
        while (bpm > 180.0f) bpm *= 0.5f;
        const int bpmInt = (int)std::lround(bpm);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendStateUpdate:@{@"detectedBpm": @(bpmInt)}];
        });
    });
}

// ─── AI patch design (Instrument tab) ────────────────────────────────────────
// Turns a free-form sound description (any language) into a synth patch JSON
// for the MicroFreak-style performance synth. Reuses the agentllm key.

// Parse a (possibly truncated) JSON object. If a straight parse fails, trim to
// the last complete '}' and balance any unclosed brackets with a small stack.
static NSDictionary* JamParsePatchJson(NSString* jsonStr) {
    id parsed = [NSJSONSerialization JSONObjectWithData:
        [jsonStr dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([parsed isKindOfClass:[NSDictionary class]]) return parsed;

    // Truncated output (finish_reason == length): cut at the last '}' or ']'
    // so we are not inside a string/number, then close whatever is still open.
    NSRange lastBrace = [jsonStr rangeOfString:@"}" options:NSBackwardsSearch];
    NSRange lastBracket = [jsonStr rangeOfString:@"]" options:NSBackwardsSearch];
    NSUInteger cutAt = lastBrace.location;
    if (lastBracket.location != NSNotFound &&
        (cutAt == NSNotFound || lastBracket.location > cutAt)) {
        cutAt = lastBracket.location;
    }
    if (cutAt == NSNotFound) return nil;
    NSString* cut = [jsonStr substringToIndex:cutAt + 1];

    NSMutableString* closers = [NSMutableString string];
    {
        char stack[64];
        int sp = 0;
        BOOL inStr = NO, esc = NO;
        for (NSUInteger i = 0; i < cut.length; ++i) {
            const unichar c = [cut characterAtIndex:i];
            if (esc) { esc = NO; continue; }
            if (inStr) {
                if (c == '\\') esc = YES;
                else if (c == '"') inStr = NO;
                continue;
            }
            if (c == '"') inStr = YES;
            else if ((c == '{' || c == '[') && sp < 63) stack[sp++] = (char)c;
            else if ((c == '}' || c == ']') && sp > 0) sp--;
        }
        while (sp > 0) [closers appendString:(stack[--sp] == '{' ? @"}" : @"]")];
    }
    NSString* repaired = [cut stringByAppendingString:closers];
    parsed = [NSJSONSerialization JSONObjectWithData:
        [repaired dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
}

// ── AI MIDI composition (piano-roll ✨ 写MIDI) ──
// Turns a musical request + song context (key/BPM/sections/chords, assembled
// by the UI) into a JSON note list, in beats from song start.
- (void)handleAiCompose:(NSString*)desc lane:(int)lane {
    NSString* apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_LyriaApiKey"];
    if (apiKey.length == 0) {
        [self sendStateUpdate:@{@"aiComposeError": @"No API key — set your agentLLM API Key in Settings"}];
        return;
    }
    NSURL* url = [NSURL URLWithString:@"https://agentllm.linkyun.co/v1/chat/completions"];
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 90.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSString* sys =
        @"You are a MIDI composer/editor for one part of a live show backing track (4/4). "
         "Reply with STRICT JSON only, no code fences, no prose: "
         "{\"notes\": [[start_beat, duration_beats, midi_pitch, velocity], ...]} "
         "where start_beat is a float counted from the song start at the given BPM, "
         "duration_beats is a float > 0, midi_pitch is an int 0-127, velocity is a float 0..1. "
         "COMPOSE MUSICALLY: follow the provided chord timeline exactly (chord tones on strong "
         "beats, scale passing tones on weak beats), stay in the song key, write idiomatic "
         "phrases for the requested instrument with breathing rests between phrases, vary the "
         "rhythm, prefer stepwise motion with occasional expressive leaps, and stay in a "
         "practical register for the instrument. MATCH THE SONG'S STYLE: respect the section "
         "energies and fit the existing arrangement (similar density, register and rhythmic "
         "feel as the other listed parts) - do not overplay quiet sections. "
         "If the user names a song section (e.g. intro), write ONLY inside that section's beat "
         "range and leave everything else empty. "
         "WHEN 'EXISTING NOTES to IMPROVE' ARE GIVEN: revise THOSE notes, do not compose anew - "
         "keep the same musical intent, register and phrase contour. Quantize sloppy timing, "
         "snap dissonant pitches to chord tones, and turn broken/staccato transcription "
         "fragments into smooth SUSTAINED LEGATO lines: extend or merge held notes so they ring "
         "until the chord changes or the pitch is re-struck, closing unnatural gaps. "
         "Use at most 300 notes.";

    NSDictionary* payload = @{
        @"model": @"c-music-express",
        @"max_tokens": @8000,
        @"temperature": @0.7,
        @"stream": @NO,
        @"messages": @[
            @{@"role": @"system", @"content": sys},
            @{@"role": @"user", @"content": desc},
        ],
    };
    NSData* bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!bodyData) {
        [self sendStateUpdate:@{@"aiComposeError": @"Could not encode request"}];
        return;
    }
    req.HTTPBody = bodyData;

    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            NSArray* notes = nil;
            NSString* errMsg = nil;
            if (error) {
                errMsg = error.localizedDescription;
            } else if (data) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString* content = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray* choices = json[@"choices"];
                    if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                        NSDictionary* msg = choices[0][@"message"];
                        if ([msg isKindOfClass:[NSDictionary class]] &&
                            [msg[@"content"] isKindOfClass:[NSString class]]) {
                            content = msg[@"content"];
                        }
                    }
                }
                if (content.length > 0) {
                    NSRange open = [content rangeOfString:@"{"];
                    if (open.location != NSNotFound) {
                        NSDictionary* obj =
                            JamParsePatchJson([content substringFromIndex:open.location]);
                        if ([obj[@"notes"] isKindOfClass:[NSArray class]]) {
                            notes = obj[@"notes"];
                        }
                    }
                }
                if (!notes) errMsg = @"AI returned unreadable notes";
            } else {
                errMsg = @"No response data";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (notes) {
                    [self sendStateUpdate:@{@"aiComposeResult":
                        @{@"lane": @(lane), @"notes": notes}}];
                } else {
                    [self sendStateUpdate:@{@"aiComposeError":
                        errMsg ?: @"Compose request failed"}];
                }
            });
        }];
    [task resume];
}

- (void)handleAiPatch:(NSString*)desc lane:(int)lane {
    NSString* apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_LyriaApiKey"];
    if (apiKey.length == 0) {
        [self sendStateUpdate:@{@"aiPatchError": @"No API key — set your agentLLM API Key in Settings"}];
        return;
    }

    NSURL* url = [NSURL URLWithString:@"https://agentllm.linkyun.co/v1/chat/completions"];
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 45.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSString* sys =
        @"You are a sound designer for a MicroFreak-style synthesizer. Convert the user's "
         "description (any language) into ONE patch as STRICT JSON, no code fences, no extra text. "
         "Schema (floats 0..1 unless noted): {\"name\": short english patch name, "
         "\"oscType\": \"analog\"|\"supersaw\"|\"wavetable\"|\"fm\"|\"harmonic\", "
         "\"wave\": float (analog: sub level / supersaw: unison / wavetable: position / fm: ratio / harmonic: partials), "
         "\"timbre\": float (saw-pulse blend / detune / wavefold / fm index / rolloff), "
         "\"shape\": float (pulse width / side mix / phase distortion / fm feedback / odd-even), "
         "\"cutoff\": float, \"resonance\": float, \"filterType\": \"lp\"|\"bp\"|\"hp\", "
         "\"envFilter\": float -1..1 (filter env amount), "
         "\"attack\": float, \"decay\": float, \"sustain\": float, \"release\": float, "
         "\"lfoShape\": \"sine\"|\"tri\"|\"saw\"|\"square\"|\"sh\", \"lfoRate\": float, \"lfoSync\": bool, "
         "\"cycMode\": \"env\"|\"run\"|\"loop\", \"cycRise\": float, \"cycFall\": float, "
         "\"cycHold\": float (env: sustain level, run/loop: hold time), "
         "\"cycRiseShape\": float (0 log, 0.5 lin, 1 exp), \"cycFallShape\": float, "
         "\"cycAmount\": float (cycling-env output level, default 1), "
         "\"arp\": \"off\"|\"up\"|\"down\"|\"updown\"|\"random\"|\"order\"|\"pattern\", \"arpOct\": int 1-4, "
         "\"arpDiv\": \"1/4\"|\"1/8\"|\"1/8T\"|\"1/16\"|\"1/16T\"|\"1/32\", "
         "\"arpSwing\": float, \"arpGate\": float, \"arpSpice\": float (variation probability), "
         "\"mono\": bool, \"glide\": float, \"chorus\": float, \"space\": float (reverb), "
         "\"volume\": float (default 0.6), "
         "\"matrix\": up to 6 of {\"src\": \"cycenv\"|\"env\"|\"lfo\"|\"velo\"|\"key\", "
         "\"dest\": \"pitch\"|\"wave\"|\"timbre\"|\"shape\"|\"cutoff\", \"amt\": float -1..1}}. "
         "SOUND-DESIGN RULES (stage quality): always give chorus 0.15-0.5 and space 0.1-0.5 "
         "unless the user asks for dry; vibrato = lfo→pitch amt 0.02-0.06 with lfoRate ~0.45; "
         "wobble = lfoSync true + lfo→cutoff 0.3-0.6; movement = cycenv run mode → wave/timbre. "
         "Basses: mono true, envFilter +0.3..0.6, cutoff 0.25-0.45, space ≤0.15. "
         "Pads: attack 0.4-0.7, release 0.6-0.8, chorus 0.4+, space 0.4+, supersaw or wavetable. "
         "Plucks/keys: attack 0, decay 0.25-0.45, sustain 0-0.2, envFilter +0.3. "
         "Leads: mono true, glide 0.05-0.15, vibrato. Arp only if rhythm implied. "
         "EXAMPLE (lush trance pad): {\"name\":\"Crystal Dawn\",\"oscType\":\"supersaw\","
         "\"wave\":0.95,\"timbre\":0.5,\"shape\":0.75,\"cutoff\":0.62,\"resonance\":0.12,"
         "\"filterType\":\"lp\",\"envFilter\":0.15,\"attack\":0.55,\"decay\":0.6,\"sustain\":0.75,"
         "\"release\":0.7,\"lfoShape\":\"tri\",\"lfoRate\":0.35,\"lfoSync\":false,"
         "\"cycMode\":\"run\",\"cycRise\":0.7,\"cycFall\":0.7,\"cycHold\":0.3,\"cycAmount\":0.8,"
         "\"arp\":\"off\",\"mono\":false,\"glide\":0,\"chorus\":0.45,\"space\":0.5,\"volume\":0.6,"
         "\"matrix\":[{\"src\":\"cycenv\",\"dest\":\"timbre\",\"amt\":0.18},"
         "{\"src\":\"lfo\",\"dest\":\"cutoff\",\"amt\":0.08}]}";

    NSDictionary* payload = @{
        @"model": @"c-music-express",
        @"max_tokens": @4000,   // the backend spends tokens on hidden reasoning
        @"temperature": @0.6,
        @"stream": @NO,
        @"messages": @[
            @{@"role": @"system", @"content": sys},
            @{@"role": @"user", @"content": desc},
        ],
    };
    NSError* jsonErr = nil;
    NSData* bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonErr];
    if (!bodyData) {
        [self sendStateUpdate:@{@"aiPatchError": @"Could not encode request"}];
        return;
    }
    req.HTTPBody = bodyData;

    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            NSDictionary* patch = nil;
            NSString* errMsg = nil;
            if (error) {
                errMsg = error.localizedDescription;
            } else if (data) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString* content = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray* choices = json[@"choices"];
                    if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                        NSDictionary* msg = choices[0][@"message"];
                        if ([msg isKindOfClass:[NSDictionary class]] &&
                            [msg[@"content"] isKindOfClass:[NSString class]]) {
                            content = msg[@"content"];
                        }
                    }
                }
                if (content.length > 0) {
                    // Extract the JSON object (the model may wrap it in fences/prose),
                    // repairing truncated output if the token cap was hit.
                    NSRange open = [content rangeOfString:@"{"];
                    if (open.location != NSNotFound) {
                        patch = JamParsePatchJson([content substringFromIndex:open.location]);
                    }
                }
                if (!patch) errMsg = @"AI returned an unreadable patch";
            } else {
                errMsg = @"No response data";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (patch) {
                    NSMutableDictionary* result = [patch mutableCopy];
                    if (lane >= 1 && lane <= 7) result[@"_lane"] = @(lane);
                    [self sendStateUpdate:@{@"aiPatchResult": result}];
                } else {
                    [self sendStateUpdate:@{@"aiPatchError": errMsg ?: @"Patch request failed"}];
                }
            });
        }];
    [task resume];
}

- (void)handleAiPrompt:(NSString*)idea history:(NSArray*)history {
    NSString* apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_LyriaApiKey"];
    if (apiKey.length == 0) {
        [self sendStateUpdate:@{@"aiPromptError": @"No API key — set your agentLLM API Key in Settings"}];
        return;
    }

    NSURL* url = [NSURL URLWithString:@"https://agentllm.linkyun.co/v1/chat/completions"];
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 45.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSString* sys = @"You are a prompt engineer for a real-time music generation model. "
                     "Convert the user idea (any language) into ONE concise English music prompt. "
                     "The chat is multi-turn: if the user asks for an adjustment (e.g. 'make it "
                     "darker', 'add drums'), refine your PREVIOUS prompt rather than starting over. "
                     "Stack concrete descriptors: genre + instrument/texture + production/mood, "
                     "comma-separated. No tempo or key. Output ONLY the prompt text, lowercase, "
                     "no quotes, no explanation.";

    // Build the messages: system + recent conversation history + the new idea.
    NSMutableArray* messages = [NSMutableArray array];
    [messages addObject:@{@"role": @"system", @"content": sys}];
    for (NSDictionary* m in history) {
        if (![m isKindOfClass:[NSDictionary class]]) continue;
        NSString* role = m[@"role"];
        NSString* text = m[@"text"];
        if (![text isKindOfClass:[NSString class]] || text.length == 0) continue;
        if ([role isEqualToString:@"user"]) {
            [messages addObject:@{@"role": @"user", @"content": text}];
        } else if ([role isEqualToString:@"ai"]) {
            [messages addObject:@{@"role": @"assistant", @"content": text}];
        }
        // 'error' turns are skipped.
    }
    [messages addObject:@{@"role": @"user", @"content": idea}];

    NSDictionary* payload = @{
        @"model": @"c-music-express",
        @"max_tokens": @1200,
        @"temperature": @0.8,
        @"stream": @NO,
        @"messages": messages,
    };
    NSError* jsonErr = nil;
    NSData* bodyData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonErr];
    if (!bodyData) {
        [self sendStateUpdate:@{@"aiPromptError": @"Could not encode request"}];
        return;
    }
    req.HTTPBody = bodyData;

    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            NSString* result = nil;
            NSString* errMsg = nil;
            if (error) {
                errMsg = error.localizedDescription;
            } else if (data) {
                NSError* parseErr = nil;
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseErr];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray* choices = json[@"choices"];
                    if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                        NSDictionary* msg = choices[0][@"message"];
                        NSString* content = [msg isKindOfClass:[NSDictionary class]] ? msg[@"content"] : nil;
                        if ([content isKindOfClass:[NSString class]]) {
                            NSCharacterSet* trimSet = [NSCharacterSet characterSetWithCharactersInString:@" \n\r\t\"'`"];
                            result = [content stringByTrimmingCharactersInSet:trimSet];
                        }
                    }
                    if (result.length == 0) {
                        NSDictionary* apiErr = json[@"error"];
                        if ([apiErr isKindOfClass:[NSDictionary class]] && [apiErr[@"message"] isKindOfClass:[NSString class]]) {
                            errMsg = apiErr[@"message"];
                        }
                    }
                }
                if (result.length == 0 && !errMsg) errMsg = @"Empty response from AI";
            } else {
                errMsg = @"No response data";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (result.length > 0) {
                    [self sendStateUpdate:@{@"aiPromptResult": result}];
                } else {
                    [self sendStateUpdate:@{@"aiPromptError": errMsg ?: @"AI request failed"}];
                }
            });
        }];
    [task resume];
}

- (void)handleExportSession:(NSString*)json {
    NSSavePanel* panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:@"jam-session.json"];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.json"]]];
    [panel setMessage:@"Export the current jam session"];
    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;
        NSError* err = nil;
        BOOL ok = [json writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&err];
        if (!ok) {
            [self sendStateUpdate:@{@"sessionError":
                [NSString stringWithFormat:@"Export failed: %@", err.localizedDescription ?: @"unknown"]}];
        } else {
            [self sendStateUpdate:@{@"sessionNotice": @"Session exported"}];
        }
    };
    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

- (void)handleImportSession {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setAllowedContentTypes:@[[UTType typeWithIdentifier:@"public.json"]]];
    [panel setMessage:@"Import a jam session"];
    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;
        NSError* err = nil;
        NSString* json = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:&err];
        if (!json) {
            [self sendStateUpdate:@{@"sessionError":
                [NSString stringWithFormat:@"Import failed: %@", err.localizedDescription ?: @"unreadable file"]}];
            return;
        }
        [self sendStateUpdate:@{@"importedSession": json}];
    };
    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

- (void)handleSelectDownloadFolder {
    [MagentaModelManager selectDownloadFolderWithParentWindow:self.view.window
                                                  completion:^(NSString *selectedPath, NSData *bookmarkData, NSError *error) {
        if (selectedPath) {
            dispatch_async(dispatch_get_main_queue(), ^{
                // Save custom path bookmarks
                [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:@"MagentaRT_ModelFolderBookmark"];
                [[NSUserDefaults standardUserDefaults] setObject:selectedPath forKey:@"MagentaRT_ModelFolderPath"];

                // Determine if custom resources folder exists inside the selected path
                NSString *customResourcesPath = [selectedPath stringByAppendingPathComponent:@"resources"];
                BOOL hasCustomResources = [[NSFileManager defaultManager] fileExistsAtPath:customResourcesPath];

                NSString *resourcesPathToLoad = hasCustomResources ? customResourcesPath : [NSString stringWithUTF8String:magentart::paths::get_resources_dir().c_str()];

                // Re-initialize the C++ engine with this selected resources folder!
                if (!self.engine->init_assets(resourcesPathToLoad.UTF8String)) {
                    NSLog(@"Jam: Failed to initialize C++ assets from custom path: %@", resourcesPathToLoad);
                } else {
                    NSLog(@"Jam: Successfully initialized C++ assets from path: %@", resourcesPathToLoad);
                    // Save custom resources path for subsequent launches!
                    [[NSUserDefaults standardUserDefaults] setObject:resourcesPathToLoad forKey:@"MagentaRT_CustomResourcesPath"];
                }
                // Force close the onboarding modal!
                [self sendStateUpdate:@{
                    @"downloadPath": selectedPath,
                    @"resourcesMissing": @NO // Close onboarding modal instantly!
                }];

                [self handleListLocalModels];

                // Programmatically auto-load the first available model in the newly selected folder if present!
                NSArray<NSString *> *modelFiles = [MagentaModelManager listLocalModelsInDirectory:[NSURL fileURLWithPath:selectedPath]];
                if (modelFiles.count > 0) {
                    [self handleSelectModel:modelFiles[0]];
                }
            });
        } else if (error) {
            NSLog(@"Jam: Failed to create folder bookmark: %@", error.localizedDescription);
        }
    }];
}

- (void)handleListLocalModels {
    NSData* bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_ModelFolderBookmark"];
    NSURL* modelsDir = nil;
    BOOL accessGranted = NO;

    if (bookmark) {
        BOOL stale = NO;
        modelsDir = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
        if (modelsDir) {
            accessGranted = [modelsDir startAccessingSecurityScopedResource];
        }
    }

    if (!modelsDir) {
        std::string defaultPath = magentart::paths::get_models_dir();
        modelsDir = [NSURL fileURLWithPath:[NSString stringWithUTF8String:defaultPath.c_str()]];
    }

    [[NSFileManager defaultManager] createDirectoryAtURL:modelsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *modelFiles = [MagentaModelManager listLocalModelsInDirectory:modelsDir];

    if (accessGranted) {
        [modelsDir stopAccessingSecurityScopedResource];
    }

    [self sendStateUpdate:@{@"localModels": modelFiles}];
}

- (void)handleSelectModel:(NSString*)modelName {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.engine) return;

        NSData* bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_ModelFolderBookmark"];
        NSURL* modelsDir = nil;
        BOOL accessGranted = NO;

        if (bookmark) {
            BOOL stale = NO;
            modelsDir = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
            if (modelsDir) {
                accessGranted = [modelsDir startAccessingSecurityScopedResource];
            }
        }

        if (!modelsDir) {
            std::string defaultPath = magentart::paths::get_models_dir();
            modelsDir = [NSURL fileURLWithPath:[NSString stringWithUTF8String:defaultPath.c_str()]];
        }

        NSURL* modelURL = [modelsDir URLByAppendingPathComponent:modelName];
        NSString* path = modelURL.path;
        BOOL isDir = NO;
        [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

        NSString* mlxfnPath = nil;
        if ([path hasSuffix:@".mlxfn"]) {
            mlxfnPath = path;
        } else if (isDir) {
            std::string dirPathStr = path.UTF8String;
            std::string foundMlxfn = magentart::paths::find_mlxfn_in_dir(dirPathStr);
            if (!foundMlxfn.empty()) {
                mlxfnPath = [NSString stringWithUTF8String:foundMlxfn.c_str()];
            }
        }

        if (!mlxfnPath) {
            [self sendStateUpdate:@{@"modelName": @"No .mlxfn found"}];
            if (accessGranted) [modelsDir stopAccessingSecurityScopedResource];
            return;
        }

        [self loadModelAtPath:mlxfnPath];
        [[NSUserDefaults standardUserDefaults] setObject:modelName forKey:@"Jam_LoadedModelName"];

        if (accessGranted) {
            [modelsDir stopAccessingSecurityScopedResource];
        }
    });
}

- (void)handleDeleteModel:(NSString *)modelName {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData* bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"Jam_ModelSearchBookmark"];
        NSURL* modelsDir = nil;
        BOOL accessGranted = NO;

        if (bookmark) {
            BOOL stale = NO;
            modelsDir = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
            if (modelsDir) {
                accessGranted = [modelsDir startAccessingSecurityScopedResource];
            }
        }

        if (!modelsDir) {
            std::string defaultPath = magentart::paths::get_models_dir();
            modelsDir = [NSURL fileURLWithPath:[NSString stringWithUTF8String:defaultPath.c_str()]];
        }

        NSURL* modelURL = [modelsDir URLByAppendingPathComponent:modelName];
        NSString* path = modelURL.path;

        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        if (error) {
            NSLog(@"Jam: Failed to delete model %@: %@", modelName, error.localizedDescription);
        } else {
            NSLog(@"Jam: Successfully deleted model %@", modelName);
            [self handleListLocalModels];
        }

        if (accessGranted) {
            [modelsDir stopAccessingSecurityScopedResource];
        }
    });
}

- (void)handleInitResources:(NSString *)modelName {
    BOOL hasModel = modelName && modelName.length > 0;

    [MagentaModelDownloader initializeSharedResourcesWithProgress:^(double progress, NSString *status) {
        double scaledPercent = hasModel ? progress * 0.5 : progress;
        NSString *statusWithProgress = [NSString stringWithFormat:@"[1/2] Shared assets: %@", status];
        if (!hasModel) statusWithProgress = status;

        [self sendStateUpdate:@{
            @"resourcesProgress": @{
                @"status": @"downloading",
                @"percent": @(scaledPercent),
                @"text": statusWithProgress
            }
        }];
    } completion:^(BOOL success, NSError *error) {
        if (!success) {
            [self sendStateUpdate:@{
                @"resourcesProgress": @{
                    @"status": @"error",
                    @"percent": @(0.0),
                    @"text": error.localizedDescription ?: @"Initialization Failed"
                }
            }];
            return;
        }

        if (hasModel) {
            // Start downloading the selected model
            [MagentaModelDownloader downloadModel:modelName progress:^(double progress, NSString *status) {
                double scaledPercent = 0.5 + (progress * 0.5);
                [self sendStateUpdate:@{
                    @"resourcesProgress": @{
                        @"status": @"downloading",
                        @"percent": @(scaledPercent),
                        @"text": [NSString stringWithFormat:@"[2/2] Model: %@", status]
                    }
                }];
            } completion:^(BOOL success, NSError *error) {
                if (success) {
                    // Re-initialize the C++ engine assets with the newly downloaded resources!
                    std::string resources = magentart::paths::get_resources_dir();
                    if (!self.engine->init_assets(resources.c_str())) {
                        NSLog(@"Jam: Failed to re-initialize C++ assets after onboarding download");
                    } else {
                        NSLog(@"Jam: Successfully initialized C++ assets after onboarding download");
                    }

                    [self sendStateUpdate:@{
                        @"resourcesProgress": @{
                            @"status": @"success",
                            @"percent": @(1.0),
                            @"text": @"Onboarding Completed!"
                        },
                        @"resourcesMissing": @NO
                    }];
                    // Re-list local models so it immediately appears in local list
                    [self handleListLocalModels];

                    // Programmatically select and load the newly downloaded model into the C++ engine
                    [self handleSelectModel:modelName];
                } else {
                    [self sendStateUpdate:@{
                        @"resourcesProgress": @{
                            @"status": @"error",
                            @"percent": @(0.5),
                            @"text": error.localizedDescription ?: @"Model download failed"
                        }
                    }];
                }
            }];
        } else {
            // Finished resources download only
            // Re-initialize the C++ engine assets with the newly downloaded resources!
            std::string resources = magentart::paths::get_resources_dir();
            if (!self.engine->init_assets(resources.c_str())) {
                NSLog(@"Jam: Failed to re-initialize C++ assets after onboarding download");
            } else {
                NSLog(@"Jam: Successfully initialized C++ assets after onboarding download");
            }

            [self sendStateUpdate:@{
                @"resourcesProgress": @{
                    @"status": @"success",
                    @"percent": @(1.0),
                    @"text": @"Initialization Completed!"
                },
                @"resourcesMissing": @NO
            }];
        }
    }];
}

- (void)dealloc {
    [_metricsTimer invalidate];
}

// ─── MIDI management ──────────────────────────────────────────────────────────

- (NSArray<NSDictionary*>*)getMIDISourcesList {
    NSMutableArray* sources = [NSMutableArray array];
    ItemCount sourceCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < sourceCount; ++i) {
        MIDIEndpointRef src = MIDIGetSource(i);
        CFStringRef cfName = NULL;
        MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cfName);
        NSString* name = cfName ? (__bridge_transfer NSString*)cfName : @"Unknown MIDI Source";
        BOOL connected = [self.connectedSources containsObject:@((uint32_t)src)];
        [sources addObject:@{
            @"name": name,
            @"endpoint": @((uint32_t)src),
            @"connected": @(connected)
        }];
    }
    return sources;
}

- (void)handleMIDIStructureChanged {
    NSArray* sources = [self getMIDISourcesList];

    BOOL connectedSourceStillExists = NO;
    for (NSNumber* srcNum in [self.connectedSources allObjects]) {
        uint32_t endpoint = [srcNum unsignedIntValue];
        for (NSDictionary* srcInfo in sources) {
            if ([srcInfo[@"endpoint"] unsignedIntValue] == endpoint) {
                connectedSourceStillExists = YES;
                break;
            }
        }
    }

    if (self.connectedSources.count > 0 && !connectedSourceStillExists) {
        [self selectMidiInput:0];
        return;
    }

    [self sendStateUpdate:@{@"midiSources": sources}];
}

- (void)selectMidiInput:(uint32_t)selectedEndpoint {
    if (!self.midiInputPort || !self.connectedSources) return;

    // 1. Disconnect all currently connected physical MIDI sources
    for (NSNumber* srcNum in [self.connectedSources allObjects]) {
        MIDIEndpointRef endpoint = (MIDIEndpointRef)[srcNum unsignedIntValue];
        MIDIPortDisconnectSource(self.midiInputPort, endpoint);
    }
    [self.connectedSources removeAllObjects];

    if (selectedEndpoint == 0) {
        // "Computer Keyboard" selected
        [self setComputerKeyboardMidiEnabled:YES];
    } else {
        // Physical MIDI input selected
        [self setComputerKeyboardMidiEnabled:NO];
        BOOL success = NO;
        if (selectedEndpoint != 0xFFFFFFFF) { // 0xFFFFFFFF can mean "None"
            MIDIEndpointRef endpoint = (MIDIEndpointRef)selectedEndpoint;
            if (MIDIPortConnectSource(self.midiInputPort, endpoint, NULL) == noErr) {
                [self.connectedSources addObject:@(selectedEndpoint)];
                success = YES;
            }
        }
        if (!success) {
            [self setComputerKeyboardMidiEnabled:YES];
            selectedEndpoint = 0;
        }
    }

    [[NSUserDefaults standardUserDefaults] setInteger:selectedEndpoint forKey:@"Jam_SelectedMidiEndpoint"];
    [self handleMIDIStructureChanged];
}

@end
