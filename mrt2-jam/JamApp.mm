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

// Jam — standalone app entry point.
// Reuses RealtimeRunner, AVAudioEngine, CoreMIDI from Magenta RT standalone.
// Adds shared state for MIDI note visualization and audio waveform display.

#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMIDI/CoreMIDI.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <mach/mach_time.h>
#include <vector>

// Minimal 48 kHz 16-bit stereo WAV writer (little-endian, as on x86/ARM).
static BOOL JamAppWriteWav(NSURL* url, const int16_t* interleaved, long frames) {
    const uint32_t sr = 48000, ch = 2, bits = 16;
    const uint32_t dataBytes = (uint32_t)(frames * ch * (bits / 8));
    NSMutableData* d = [NSMutableData data];
    auto u32 = [&](uint32_t v) { [d appendBytes:&v length:4]; };
    auto u16 = [&](uint16_t v) { [d appendBytes:&v length:2]; };
    [d appendBytes:"RIFF" length:4]; u32(36 + dataBytes); [d appendBytes:"WAVE" length:4];
    [d appendBytes:"fmt " length:4]; u32(16); u16(1); u16((uint16_t)ch);
    u32(sr); u32(sr * ch * (bits / 8)); u16((uint16_t)(ch * (bits / 8))); u16((uint16_t)bits);
    [d appendBytes:"data" length:4]; u32(dataBytes);
    [d appendBytes:interleaved length:dataBytes];
    return [d writeToURL:url atomically:YES];
}

// Encode 48 kHz stereo int16 PCM to AAC in an .m4a (native; ~1/10 the size of
// WAV). macOS can't encode MP3, so AAC/m4a is the compressed option.
static BOOL JamAppWriteM4A(NSURL* url, const int16_t* interleaved, long frames) {
    AudioStreamBasicDescription dst = {};
    dst.mSampleRate = 48000;
    dst.mFormatID = kAudioFormatMPEG4AAC;
    dst.mChannelsPerFrame = 2;
    ExtAudioFileRef ext = nullptr;
    if (ExtAudioFileCreateWithURL((__bridge CFURLRef)url, kAudioFileM4AType, &dst, nullptr,
                                  kAudioFileFlags_EraseFile, &ext) != noErr || !ext)
        return NO;
    AudioStreamBasicDescription client = {};
    client.mSampleRate = 48000;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    client.mChannelsPerFrame = 2;
    client.mBitsPerChannel = 16;
    client.mBytesPerFrame = 4;
    client.mFramesPerPacket = 1;
    client.mBytesPerPacket = 4;
    OSStatus st = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                          sizeof(client), &client);
    if (st == noErr) {
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = 2;
        abl.mBuffers[0].mDataByteSize = (UInt32)(frames * 4);
        abl.mBuffers[0].mData = (void*)interleaved;
        st = ExtAudioFileWrite(ext, (UInt32)frames, &abl);
    }
    ExtAudioFileDispose(ext);
    return st == noErr;
}
#import "JamAppController.h"
#import "LyriaClient.h"
#import "LyriaConductor.h"
#import "common/objc/MagentaSettings.h"
#include <magentart/realtime_runner.h>
#include "common/cpp/magenta_paths.h"
#include "vendor/tsf/tsf.h"

using magentart::core::RealtimeRunner;

// ─── Settings Window Controller ─────────────────────────────────────────────
// Full settings panel: Model, Generation params, Audio I/O, MIDI sources.
// Accessible from app menu (Cmd+,) or from the gear icon in the React UI.

@interface JamSettingsController : NSWindowController <NSWindowDelegate>
@property (nonatomic, strong) AVAudioEngine* audioEngine;
@property (nonatomic, weak) JamAppController* appController;
- (void)refreshAll;
@end

@implementation JamSettingsController {
    // Generation
    NSSlider* _temperatureSlider;   NSTextField* _temperatureValue;
    NSSlider* _topkSlider;          NSTextField* _topkValue;

    NSSlider* _cfgMusicCoCaSlider;  NSTextField* _cfgMusicCoCaValue;
    NSSlider* _cfgNotesSlider;      NSTextField* _cfgNotesValue;
    NSSlider* _cfgDrumsSlider;      NSTextField* _cfgDrumsValue;
    NSSlider* _unmaskWidthSlider;   NSTextField* _unmaskWidthValue;
    NSSlider* _volumeSlider;        NSTextField* _volumeValue;
    NSPopUpButton* _bufferSizePopup;
    NSButton* _muteCheckbox;
    NSButton* _drumModeCheckbox;
    // Audio
    NSTextField* _audioDeviceLabel;
    NSTextField* _audioSampleRateLabel;
    NSTextField* _audioBufferSizeLabel;
}

// ── Helpers for building UI ──

static NSTextField* makeLabel(NSString* text, CGFloat x, CGFloat y, CGFloat w) {
    NSTextField* label = [NSTextField labelWithString:text];
    label.frame = NSMakeRect(x, y, w, 16);
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

static NSTextField* makeValue(CGFloat x, CGFloat y) {
    NSTextField* label = [NSTextField labelWithString:@"—"];
    label.frame = NSMakeRect(x, y, 50, 16);
    label.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    label.alignment = NSTextAlignmentRight;
    return label;
}

static NSSlider* makeSlider(CGFloat x, CGFloat y, CGFloat w, double min, double max, double val, id target, SEL action) {
    NSSlider* slider = [[NSSlider alloc] initWithFrame:NSMakeRect(x, y, w, 20)];
    slider.minValue = min;
    slider.maxValue = max;
    slider.doubleValue = val;
    slider.continuous = YES;
    slider.target = target;
    slider.action = action;
    return slider;
}

- (instancetype)init {
    CGFloat W = 480, H = 420;
    NSRect frame = NSMakeRect(0, 0, W, H);
    NSWindow* window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Settings";
    window.releasedWhenClosed = NO;

    self = [super initWithWindow:window];
    if (!self) return nil;
    window.delegate = self;

    NSView* c = window.contentView;
    CGFloat pad = 20, col2 = 110, sliderW = 280, valX = W - 70;
    CGFloat y = H - 40;

    // ── Generation ──
    NSTextField* genHeader = [NSTextField labelWithString:@"Generation"];
    genHeader.font = [NSFont boldSystemFontOfSize:13];
    genHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:genHeader];
    y -= 26;

    // Volume
    [c addSubview:makeLabel(@"Volume (dB)", pad, y, 90)];
    _volumeSlider = makeSlider(col2, y - 2, sliderW, -60, 12, 0, self, @selector(volumeChanged:));
    [c addSubview:_volumeSlider];
    _volumeValue = makeValue(valX, y); [c addSubview:_volumeValue];
    y -= 26;

    // Temperature
    [c addSubview:makeLabel(@"Temperature", pad, y, 90)];
    _temperatureSlider = makeSlider(col2, y - 2, sliderW, 0, 3, kMagentaDefaultTemperature, self, @selector(temperatureChanged:));
    [c addSubview:_temperatureSlider];
    _temperatureValue = makeValue(valX, y); [c addSubview:_temperatureValue];
    y -= 26;

    // Top-K
    [c addSubview:makeLabel(@"Top-K", pad, y, 90)];
    _topkSlider = makeSlider(col2, y - 2, sliderW, 1, 1024, kMagentaDefaultTopK, self, @selector(topkChanged:));
    [c addSubview:_topkSlider];
    _topkValue = makeValue(valX, y); [c addSubview:_topkValue];
    y -= 26;



    // CFG-MusicCoCa
    [c addSubview:makeLabel(@"CFG-MusicCoCa", pad, y, 90)];
    _cfgMusicCoCaSlider = makeSlider(col2, y - 2, sliderW, 0, 5, kMagentaDefaultCfgMusicCoCa, self, @selector(cfgMusicCoCaChanged:));
    [c addSubview:_cfgMusicCoCaSlider];
    _cfgMusicCoCaValue = makeValue(valX, y); [c addSubview:_cfgMusicCoCaValue];
    y -= 26;

    // CFG-Notes
    [c addSubview:makeLabel(@"CFG-Notes", pad, y, 90)];
    _cfgNotesSlider = makeSlider(col2, y - 2, sliderW, 0, 5, kMagentaDefaultCfgNotes, self, @selector(cfgNotesChanged:));
    [c addSubview:_cfgNotesSlider];
    _cfgNotesValue = makeValue(valX, y); [c addSubview:_cfgNotesValue];
    y -= 26;

    // CFG-Drums
    [c addSubview:makeLabel(@"CFG-Drums", pad, y, 90)];
    _cfgDrumsSlider = makeSlider(col2, y - 2, sliderW, 0, 5, 1, self, @selector(cfgDrumsChanged:));
    [c addSubview:_cfgDrumsSlider];
    _cfgDrumsValue = makeValue(valX, y); [c addSubview:_cfgDrumsValue];
    y -= 26;

    // Unmask width
    [c addSubview:makeLabel(@"Unmask width", pad, y, 90)];
    _unmaskWidthSlider = makeSlider(col2, y - 2, sliderW, 0, 127, 0, self, @selector(unmaskWidthChanged:));
    [c addSubview:_unmaskWidthSlider];
    _unmaskWidthValue = makeValue(valX, y); [c addSubview:_unmaskWidthValue];
    y -= 30;

    // Buffer size
    [c addSubview:makeLabel(@"Buffer Size", pad, y + 2, 90)];
    _bufferSizePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(col2, y, 100, 22) pullsDown:NO];
    [_bufferSizePopup addItemsWithTitles:@[@"2048", @"4096", @"8192"]];
    _bufferSizePopup.font = [NSFont systemFontOfSize:11];
    _bufferSizePopup.target = self;
    _bufferSizePopup.action = @selector(bufferSizeChanged:);
    [c addSubview:_bufferSizePopup];

    _muteCheckbox = [NSButton checkboxWithTitle:@"Mute" target:self action:@selector(muteChanged:)];
    _muteCheckbox.frame = NSMakeRect(col2 + 120, y + 1, 60, 18);
    _muteCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_muteCheckbox];

    _drumModeCheckbox = [NSButton checkboxWithTitle:@"Drum Mode" target:self action:@selector(drumModeChanged:)];
    _drumModeCheckbox.frame = NSMakeRect(col2 + 190, y + 1, 100, 18);
    _drumModeCheckbox.font = [NSFont systemFontOfSize:11];
    [c addSubview:_drumModeCheckbox];
    y -= 20;

    // Reset defaults
    NSButton* resetBtn = [NSButton buttonWithTitle:@"Reset Defaults" target:self action:@selector(resetDefaults:)];
    resetBtn.frame = NSMakeRect(pad, y, 120, 20);
    resetBtn.bezelStyle = NSBezelStyleInline;
    resetBtn.font = [NSFont systemFontOfSize:11];
    [c addSubview:resetBtn];
    y -= 16;

    NSBox* sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - 2 * pad, 1)];
    sep1.boxType = NSBoxSeparator;
    [c addSubview:sep1];
    y -= 24;

    // ── Audio Output ──
    NSTextField* audioHeader = [NSTextField labelWithString:@"Audio Output"];
    audioHeader.font = [NSFont boldSystemFontOfSize:13];
    audioHeader.frame = NSMakeRect(pad, y, 200, 18);
    [c addSubview:audioHeader];
    y -= 22;

    [c addSubview:makeLabel(@"Device:", pad, y, 55)];
    _audioDeviceLabel = [NSTextField labelWithString:@"—"];
    _audioDeviceLabel.frame = NSMakeRect(pad + 60, y, 350, 16);
    _audioDeviceLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioDeviceLabel];
    y -= 18;

    [c addSubview:makeLabel(@"Sample Rate:", pad, y, 80)];
    _audioSampleRateLabel = [NSTextField labelWithString:@"—"];
    _audioSampleRateLabel.frame = NSMakeRect(pad + 85, y, 200, 16);
    _audioSampleRateLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioSampleRateLabel];
    y -= 18;

    [c addSubview:makeLabel(@"Buffer Size:", pad, y, 80)];
    _audioBufferSizeLabel = [NSTextField labelWithString:@"—"];
    _audioBufferSizeLabel.frame = NSMakeRect(pad + 85, y, 200, 16);
    _audioBufferSizeLabel.font = [NSFont systemFontOfSize:11];
    [c addSubview:_audioBufferSizeLabel];

    return self;
}

// ── Show / refresh ──

- (void)showWindow:(id)sender {
    [self refreshAll];
    [super showWindow:sender];
    [self.window center];
}

- (void)refreshAll {
    [self refreshParams];
    [self refreshAudioInfo];
}

- (void)refreshParams {
    JamAppController* ctrl = _appController;
    if (!ctrl) return;

    _temperatureSlider.doubleValue = [ctrl readParamFromEngine:0];
    _temperatureValue.stringValue = [NSString stringWithFormat:@"%.2f", _temperatureSlider.doubleValue];

    _topkSlider.doubleValue = [ctrl readParamFromEngine:1];
    _topkValue.stringValue = [NSString stringWithFormat:@"%d", (int)_topkSlider.doubleValue];



    _cfgMusicCoCaSlider.doubleValue = [ctrl readParamFromEngine:3];
    _cfgMusicCoCaValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgMusicCoCaSlider.doubleValue];

    _cfgNotesSlider.doubleValue = [ctrl readParamFromEngine:4];
    _cfgNotesValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgNotesSlider.doubleValue];

    _cfgDrumsSlider.doubleValue = [ctrl readParamFromEngine:48];
    _cfgDrumsValue.stringValue = [NSString stringWithFormat:@"%.2f", _cfgDrumsSlider.doubleValue];

    _unmaskWidthSlider.doubleValue = [ctrl readParamFromEngine:7];
    _unmaskWidthValue.stringValue = [NSString stringWithFormat:@"%d", (int)_unmaskWidthSlider.doubleValue];

    _volumeSlider.doubleValue = [ctrl readParamFromEngine:5];
    _volumeValue.stringValue = [NSString stringWithFormat:@"%.1f", _volumeSlider.doubleValue];

    float bufVal = [ctrl readParamFromEngine:8];
    [_bufferSizePopup selectItemAtIndex:(bufVal < 0.5 ? 0 : (bufVal < 1.5 ? 1 : 2))];

    _muteCheckbox.state = ([ctrl readParamFromEngine:6] > 0.5) ? NSControlStateValueOn : NSControlStateValueOff;
    _drumModeCheckbox.state = ([ctrl readParamFromEngine:39] > 0.5) ? NSControlStateValueOn : NSControlStateValueOff;
}

// ── Slider / control actions ──

- (void)temperatureChanged:(NSSlider*)sender {
    _temperatureValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:0 value:(float)sender.doubleValue];
}
- (void)topkChanged:(NSSlider*)sender {
    int v = (int)sender.doubleValue;
    _topkValue.stringValue = [NSString stringWithFormat:@"%d", v];
    [_appController applyParamToEngine:1 value:(float)v];
}

- (void)cfgMusicCoCaChanged:(NSSlider*)sender {
    _cfgMusicCoCaValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:3 value:(float)sender.doubleValue];
}
- (void)cfgNotesChanged:(NSSlider*)sender {
    _cfgNotesValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:4 value:(float)sender.doubleValue];
}
- (void)cfgDrumsChanged:(NSSlider*)sender {
    _cfgDrumsValue.stringValue = [NSString stringWithFormat:@"%.2f", sender.doubleValue];
    [_appController applyParamToEngine:48 value:(float)sender.doubleValue];
}
- (void)unmaskWidthChanged:(NSSlider*)sender {
    int v = (int)sender.doubleValue;
    _unmaskWidthValue.stringValue = [NSString stringWithFormat:@"%d", v];
    [_appController applyParamToEngine:7 value:(float)v];
}
- (void)volumeChanged:(NSSlider*)sender {
    _volumeValue.stringValue = [NSString stringWithFormat:@"%.1f", sender.doubleValue];
    [_appController applyParamToEngine:5 value:(float)sender.doubleValue];
}
- (void)bufferSizeChanged:(NSPopUpButton*)sender {
    [_appController applyParamToEngine:8 value:(float)sender.indexOfSelectedItem];
}
- (void)muteChanged:(NSButton*)sender {
    [_appController applyParamToEngine:6 value:(sender.state == NSControlStateValueOn) ? 1.0f : 0.0f];
}
- (void)drumModeChanged:(NSButton*)sender {
    [_appController applyParamToEngine:39 value:(sender.state == NSControlStateValueOn) ? 1.0f : 0.0f];
}

- (void)resetDefaults:(id)sender {
    [MagentaSettings resetDefaultsOnEngine:_appController.engine
                              prefixString:@"Jam"];
    [self refreshParams];
}

// ── Audio info ──

- (void)refreshAudioInfo {
    if (!_audioEngine) return;
    AVAudioFormat* outputFormat = [_audioEngine.outputNode outputFormatForBus:0];
    double sampleRate = outputFormat.sampleRate;

    AudioDeviceID deviceID = 0;
    UInt32 propSize = sizeof(deviceID);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &propSize, &deviceID);

    NSString* deviceName = @"Unknown";
    if (deviceID != 0) {
        CFStringRef cfName = NULL;
        propSize = sizeof(cfName);
        AudioObjectPropertyAddress nameAddr = {
            kAudioDevicePropertyDeviceNameCFString,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(deviceID, &nameAddr, 0, NULL, &propSize, &cfName) == noErr && cfName) {
            deviceName = (__bridge_transfer NSString*)cfName;
        }
    }

    UInt32 bufferFrames = 0;
    propSize = sizeof(bufferFrames);
    AudioObjectPropertyAddress bufAddr = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (deviceID != 0) {
        AudioObjectGetPropertyData(deviceID, &bufAddr, 0, NULL, &propSize, &bufferFrames);
    }

    _audioDeviceLabel.stringValue = deviceName;
    _audioSampleRateLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz (engine: 48000 Hz)", sampleRate];
    _audioBufferSizeLabel.stringValue = [NSString stringWithFormat:@"%u frames", (unsigned)bufferFrames];
}
@end

// ─── AppDelegate ─────────────────────────────────────────────────────────────

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    RealtimeRunner _engine;
    JamSharedState _sharedState;
    AVAudioEngine* _audioEngine;
    AVAudioSourceNode* _sourceNode;
    AVAudioSourceNodeRenderBlock _renderBlock;
    MIDIClientRef _midiClient;
    MIDIPortRef _midiInputPort;
    MIDIEndpointRef _midiVirtualDest;
    NSWindow* _window;
    JamAppController* _controller;
    JamSettingsController* _settingsController;
    BOOL _isPlaying;
    NSMenuItem* _playStopMenuItem;
    std::atomic<float> _gateLevel;
    std::atomic<float> _gateDecaySeconds;
    std::atomic<bool> _soloMode;
    std::atomic<float> _cfgNotesSliderValue;
    std::atomic<float> _cfgNotesCurrentLevel;
    // Lyria cloud engine — sockets only exist while playing in Lyria mode.
    // The conductor runs two LyriaClient channels and crossfades between them
    // to survive the gateway's 10-minute per-connection limit.
    LyriaConductor* _lyriaClient;
    std::atomic<bool> _useLyria;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // Initialize ML assets from ~/Documents/Magenta/magenta-rt-v2/resources (centralized path) or saved custom folder.
    // Model files should be placed in ~/Documents/Magenta/magenta-rt-v2/models/.
    NSString *customResources = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_CustomResourcesPath"];
    std::string resources = customResources ? customResources.UTF8String : magentart::paths::get_resources_dir();
    if (!_engine.init_assets(resources.c_str())) {
        NSLog(@"Jam: Failed to load static assets from %s", resources.c_str());
    }

    _gateLevel.store(1.0f);
    _gateDecaySeconds.store(2.0f);

    BOOL savedSoloMode = NO;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"Jam_SoloMode"]) {
        savedSoloMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"Jam_SoloMode"];
    }
    _soloMode.store(savedSoloMode);
    _cfgNotesCurrentLevel.store(50.0f);

    float savedCfgNotes = [[NSUserDefaults standardUserDefaults] floatForKey:@"Jam_Param_cfgnotes"];
    _cfgNotesSliderValue.store(savedCfgNotes > 0.0f ? savedCfgNotes : kMagentaDefaultCfgNotes);

    _useLyria.store(false);
    _lyriaClient = [[LyriaConductor alloc] init];

    _controller = [[JamAppController alloc] init];
    _controller.engine = &_engine;
    _controller.sharedState = &_sharedState;
    _controller.soloMode = &_soloMode;
    _controller.cfgNotesSliderValue = &_cfgNotesSliderValue;
    _controller.gateDecaySeconds = &_gateDecaySeconds;
    _controller.lyriaClient = _lyriaClient;
    _controller.useLyria = &_useLyria;

    __weak JamAppController* weakCtrl = _controller;
    [_lyriaClient setStatusHandler:^(NSString* status) {
        [weakCtrl sendStateUpdate:@{@"lyriaStatus" : status}];
    }];
    [_lyriaClient setChannelStateHandler:^(NSArray<NSString*>* states) {
        [weakCtrl sendStateUpdate:@{@"lyriaChannels" : states}];
    }];

    // Restore saved parameters immediately so the engine has them from start
    [_controller restoreSavedParams];

    _isPlaying = NO;
    _engine.set_bypass(true);

    NSRect frame = NSMakeRect(0, 0, 850, 605);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                           styleMask:NSWindowStyleMaskTitled |
                                                     NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable |
                                                     NSWindowStyleMaskResizable
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    _window.title = @"VerveFlow";
    _window.minSize = NSMakeSize(850, 605);
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _window.contentViewController = _controller;
    [_window center];
    [_window makeKeyAndOrderFront:nil];

    // Open in fullscreen by default.
    if (!(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        [_window toggleFullScreen:nil];
    }

    [self setupAudioEngine];
    [self setupMIDI];
    [self setupMenuBar];

    _controller.midiInputPort = _midiInputPort;
    _controller.connectedSources = [NSMutableSet set];

    _settingsController = [[JamSettingsController alloc] init];
    _settingsController.audioEngine = _audioEngine;
    _settingsController.appController = _controller;

    [self autoLoadModel];
}

// ─── AVAudioEngine ───────────────────────────────────────────────────────────

- (void)setupAudioEngine {
    _audioEngine = [[AVAudioEngine alloc] init];
    AVAudioFormat* format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:2];

    RealtimeRunner* engine = &_engine;
    JamSharedState* shared = &_sharedState;
    auto* gateLevel = &_gateLevel;
    auto* gateDecaySec = &_gateDecaySeconds;
    auto* soloMode = &_soloMode;
    auto* cfgNotesSliderVal = &_cfgNotesSliderValue;
    auto* cfgNotesLevel = &_cfgNotesCurrentLevel;
    auto* useLyria = &_useLyria;
    __unsafe_unretained LyriaConductor* lyriaConductor = _lyriaClient;

    // Request 64 frame buffer size on default output device
    AudioDeviceID deviceID = 0;
    UInt32 propSize = sizeof(deviceID);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &propSize, &deviceID) == noErr && deviceID != 0) {
        UInt32 bufferFrames = 64;
        AudioObjectPropertyAddress bufAddr = {
            kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        OSStatus status = AudioObjectSetPropertyData(deviceID, &bufAddr, 0, NULL, sizeof(bufferFrames), &bufferFrames);
        if (status != noErr) {
            NSLog(@"Jam: Failed to set buffer size to 64, error %d", (int)status);
        } else {
            NSLog(@"Jam: Requested buffer size of 64 frames");
        }
    }

    _renderBlock = ^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp,
                             AVAudioFrameCount frameCount, AudioBufferList* outputData) {
        if (frameCount > (AVAudioFrameCount)JamSharedState::kBusMax ||
            outputData->mNumberBuffers == 0) {
            *isSilence = YES;
            return noErr;
        }
        // Everything renders into internal busses; the tail of this block
        // distributes them onto the device channels per the routing masks.
        float* outL = shared->busL;
        float* outR = shared->busR;

        // ── Auto speed compensation ──────────────────────────────────────
        // Some output paths (e.g. SP-404 over USB, or a multichannel graph)
        // consume our 48 kHz content slower than 48000 frames/sec, stretching
        // playback and dragging the tempo off the original BPM. We measure the
        // *effective content rate* C = (frames requested) / (wall-clock) from
        // the callback clock, then derive comp = 48000 / C. This corrects speed
        // back to the true original BPM automatically — no ear-tuning — which
        // matters for playing in time with other live instruments.
        if (timestamp && (timestamp->mFlags & kAudioTimeStampHostTimeValid) &&
            shared->hostTicksToSec > 0.0) {
            if (shared->rateMeasReset.exchange(false, std::memory_order_acquire)) {
                shared->rateMeasStartHost = timestamp->mHostTime;
                shared->rateMeasFrames = 0.0;
                shared->rateMeasLocked = false;
                shared->outSpeedComp.store(1.0f, std::memory_order_release);
                shared->calibSamplePos = 0;
            }
            if (!shared->rateMeasLocked && shared->rateMeasStartHost != 0) {
                double elapsed = (double)(timestamp->mHostTime - shared->rateMeasStartHost)
                                 * shared->hostTicksToSec;
                if (elapsed >= 2.0 && shared->rateMeasFrames > 0.0) {
                    double C = shared->rateMeasFrames / elapsed;     // content frames/sec
                    double comp = 48000.0 / C;
                    if (comp < 1.005 && comp > 0.995) comp = 1.0;    // deadzone: genuine 48k
                    if (comp < 1.0) comp = 1.0;                      // only fix slowdowns
                    if (comp > 1.5) comp = 1.5;
                    shared->outSpeedComp.store((float)comp, std::memory_order_release);
                    shared->rateMeasLocked = true;
                    NSLog(@"[SpeedComp] measured device content rate %.1f Hz -> comp %.4f",
                          C, comp);
                }
                shared->rateMeasFrames += (double)frameCount;
            }
        }

        // Output speed compensation. We generate `genFrames` of 48 kHz content
        // and resample it down to the `frameCount` frames the device asked for,
        // so playback speed (and therefore tempo) is corrected.
        // comp == 1.0 → genFrames == frameCount → passthrough (no extra work).
        float _comp = shared->outSpeedComp.load(std::memory_order_relaxed);
        if (_comp < 1.0f) _comp = 1.0f;
        if (_comp > 1.5f) _comp = 1.5f;
        AVAudioFrameCount genFrames = frameCount;
        if (_comp > 1.0001f) {
            genFrames = (AVAudioFrameCount)lround((double)frameCount * (double)_comp);
            if (genFrames > (AVAudioFrameCount)JamSharedState::kBusMax)
                genFrames = (AVAudioFrameCount)JamSharedState::kBusMax;
            if (genFrames < 1) genFrames = 1;
        }
        memset(shared->clickBus, 0, genFrames * sizeof(float));

        const bool _calib = shared->calibrating.load(std::memory_order_relaxed);
        if (_calib) {
            // ── Calibration: emit ONLY a standard 120 BPM reference click ──
            // It runs through the same speed-compensation/resample path as real
            // audio, so the operator verifies the CORRECTED click is exactly
            // 120 BPM on the new device before performing. Accent on beat 1.
            const uint64_t base = shared->calibSamplePos;
            const uint64_t beatLen  = 24000;   // 120 BPM @ 48k → 0.5s per beat
            const uint64_t clickLen = 1200;    // ~25ms tick
            for (AVAudioFrameCount i = 0; i < genFrames; ++i) {
                const uint64_t pos = base + i;
                const uint64_t inBeat = pos % beatLen;
                float s = 0.0f;
                if (inBeat < clickLen) {
                    const uint64_t beat = pos / beatLen;
                    const bool accent = (beat % 4) == 0;
                    const float t = (float)inBeat / 48000.0f;
                    const float freq = accent ? 2000.0f : 1000.0f;
                    const float env = expf(-t * 90.0f);
                    s = sinf(6.2831853f * freq * t) * env * (accent ? 0.95f : 0.6f);
                }
                outL[i] = s;
                outR[i] = s;
            }
            shared->calibSamplePos = base + genFrames;
        } else {

        if (useLyria->load(std::memory_order_relaxed)) {
            // Cloud engine: the conductor mixes its two channels (crossfading
            // near the 10-min limit) into the output; silence until primed.
            // The local engine stays bypassed, but FX/meters below still apply.
            [lyriaConductor readStereoLeft:outL right:outR frames:genFrames];
        } else if (!engine->is_loaded()) {
            // No model yet — keep the buffers zeroed but fall through so the
            // performance synth (Instrument tab) can still play.
            memset(outL, 0, genFrames * sizeof(float));
            if (outputData->mNumberBuffers > 1) memset(outR, 0, genFrames * sizeof(float));
        } else {
            engine->read_audio_stereo(outL, outR, genFrames, false);
        }

        // PGM studio take recorder: capture the raw engine output (pre-FX)
        // while armed so cover takes can be A/B'd against the original stem.
        if (shared->recArmed.load(std::memory_order_relaxed)) {
            float* rl = shared->recL.load(std::memory_order_relaxed);
            float* rr = shared->recR.load(std::memory_order_relaxed);
            const long cap = shared->recCap.load(std::memory_order_relaxed);
            long w = shared->recWritten.load(std::memory_order_relaxed);
            if (rl && rr) {
                for (AVAudioFrameCount i = 0; i < genFrames && w < cap; ++i, ++w) {
                    rl[w] = outL[i];
                    rr[w] = outR[i];
                }
                shared->recWritten.store(w, std::memory_order_release);
                if (w >= cap) shared->recArmed.store(false, std::memory_order_relaxed);
            }
        }

        // Check if any MIDI note is currently held
        bool anyNoteHeld = false;
        for (int n = 0; n < 128 && !anyNoteHeld; ++n) {
            anyNoteHeld = shared->midiNotes[n].load(std::memory_order_relaxed);
        }

        // Solo's note-gated envelope only applies to the local engine — Lyria
        // has no MIDI conditioning, so never gate its stream to silence.
        bool isSolo = !useLyria->load(std::memory_order_relaxed) &&
                      soloMode->load(std::memory_order_relaxed);

        if (isSolo) {
            const float sliderVal = cfgNotesSliderVal->load(std::memory_order_relaxed);
            const float decaySec = gateDecaySec->load(std::memory_order_relaxed);

            // Volume gate: open instantly when any note is held, decay to 0 when released
            float gate = gateLevel->load(std::memory_order_relaxed);
            const float decayPerSample = (decaySec > 0.0f) ? (1.0f / (48000.0f * decaySec)) : 1.0f;

            for (AVAudioFrameCount i = 0; i < genFrames; ++i) {
                if (anyNoteHeld) {
                    gate = 1.0f;
                } else {
                    gate -= decayPerSample;
                    if (gate < 0.0f) gate = 0.0f;
                }
                outL[i] *= gate;
                outR[i] *= gate;
            }
            gateLevel->store(gate, std::memory_order_relaxed);

            // CFG Notes ramp: snap to slider value when note held, ramp to 50.0f over decaySec when released
            float cfgNotes = cfgNotesLevel->load(std::memory_order_relaxed);
            const float targetVal = 50.0f;
            const float rampPerFrame = (decaySec > 0.0f) ? ((targetVal - sliderVal) / (48000.0f * decaySec)) : targetVal;

            if (anyNoteHeld) {
                cfgNotes = sliderVal;
            } else if (cfgNotes < targetVal) {
                cfgNotes += rampPerFrame * (float)genFrames;
                if (cfgNotes > targetVal) cfgNotes = targetVal;
            }
            cfgNotesLevel->store(cfgNotes, std::memory_order_relaxed);
            engine->set_cfg_notes(cfgNotes);

            // DEBUG: throttled log (~1Hz)
            static int _dbgCounter = 0;
            if (++_dbgCounter >= (int)(48000.0f / genFrames)) {
                _dbgCounter = 0;
                NSLog(@"[Solo ramp] noteHeld=%d slider=%.2f cfgNotes=%.2f gate=%.3f",
                      anyNoteHeld, sliderVal, cfgNotes, gate);
            }
        } else {
            // Accompany mode: reset gate/cfg notes level to slider value, bypass gate
            cfgNotesLevel->store(cfgNotesSliderVal->load(std::memory_order_relaxed), std::memory_order_relaxed);
            gateLevel->store(1.0f, std::memory_order_relaxed);
            engine->set_cfg_notes(cfgNotesSliderVal->load(std::memory_order_relaxed));
        }

        // Live-performance synth (Instrument tab): mixed in before the FX chain
        // so it shares the filter/delay/reverb/punch pads with the music.
        shared->synth.render(outL, outR, genFrames,
                             shared->fxTempo.load(std::memory_order_relaxed));

        // PGM live MIDI-input SF2 source: drain queued note events into the
        // live tsf instance and mix its render in. (Built-in synth source uses
        // the path above.)
        {
            tsf* lsf = (tsf*)shared->liveSf.load(std::memory_order_acquire);
            const int src = shared->liveSource.load(std::memory_order_relaxed);
            if (lsf) {
                // Flush held SF2 notes when switching away from the SF2 source.
                if (src != shared->liveSourceSeen) {
                    if (src != 1) {
                        for (int nn = 0; nn < 128; ++nn)
                            if (shared->liveHeld[nn]) { tsf_channel_note_off(lsf, 0, nn);
                                                        shared->liveHeld[nn] = false; }
                    }
                    shared->liveSourceSeen = src;
                }
                int r = shared->liveEvR.load(std::memory_order_relaxed);
                while (r != shared->liveEvW.load(std::memory_order_acquire)) {
                    const auto ev = shared->liveEv[r];
                    r = (r + 1) & 255;
                    if (ev.on) { tsf_channel_note_on(lsf, 0, ev.note, ev.vel / 127.0f);
                                 shared->liveHeld[ev.note] = true; }
                    else { tsf_channel_note_off(lsf, 0, ev.note);
                           shared->liveHeld[ev.note] = false; }
                }
                shared->liveEvR.store(r, std::memory_order_release);
                if (src == 1 && genFrames <= (AVAudioFrameCount)JamSharedState::kLaneBlockMax) {
                    const int prog = shared->liveSfProgram.load(std::memory_order_relaxed);
                    if (prog != shared->liveSfProgApplied) {
                        tsf_channel_set_presetnumber(lsf, 0, prog, 0);
                        shared->liveSfProgApplied = prog;
                    }
                    tsf_render_float(lsf, shared->laneSfTmp, (int)genFrames, 0);
                    // Per-source reverb + echo on the unweaved [L..][R..] halves.
                    shared->liveFx.process(shared->laneSfTmp,
                                           shared->laneSfTmp + genFrames, (int)genFrames,
                                           shared->stemBpm.load(std::memory_order_relaxed));
                    const float g = shared->liveGain.load(std::memory_order_relaxed) * 1.8f;
                    for (AVAudioFrameCount i = 0; i < genFrames; ++i) {
                        outL[i] += shared->laneSfTmp[i] * g;
                        outR[i] += shared->laneSfTmp[genFrames + i] * g;
                    }
                }
            }
        }

        shared->processPerformanceFX(outL, outR, genFrames);

        // PGM studio preview player: dry one-shot playback (post-FX) of an
        // original stem or a recorded cover take.
        if (shared->prevActive.load(std::memory_order_relaxed)) {
            const float* pl = shared->prevL.load(std::memory_order_relaxed);
            const float* pr = shared->prevR.load(std::memory_order_relaxed);
            const long len = shared->prevLen.load(std::memory_order_relaxed);
            long pos = shared->prevPos.load(std::memory_order_relaxed);
            if (pl && pr) {
                for (AVAudioFrameCount i = 0; i < genFrames && pos < len; ++i, ++pos) {
                    outL[i] += pl[pos] * 0.9f;
                    outR[i] += pr[pos] * 0.9f;
                }
                shared->prevPos.store(pos, std::memory_order_relaxed);
                if (pos >= len) shared->prevActive.store(false, std::memory_order_relaxed);
            }
        }

        // Count-in (预备拍): back-calculated pre-roll on the click grid. The
        // transport rolls back as far as there's room (continuous playback,
        // plays any pickup audio); the remaining beats with no room before the
        // entry are a FROZEN click pre-roll, swept on the same grid so it flows
        // seamlessly into the rolled-back/real clicks. Always N beats.
        {
            long left = shared->countInLeft.load(std::memory_order_relaxed);
            if (left > 0 && shared->stemActive.load(std::memory_order_relaxed)) {
                const float bpm = shared->stemBpm.load(std::memory_order_relaxed);
                const long B = (long)(60.0 / ((bpm < 40 || bpm > 300) ? 120.0 : bpm)
                                      * 48000.0);
                const long beatOff = shared->stemBeatOff.load(std::memory_order_relaxed);
                const int barPh = shared->stemBarPhase.load(std::memory_order_relaxed);
                const int bpb = shared->beatsPerBar.load(std::memory_order_relaxed);
                long v = shared->countInVPos.load(std::memory_order_relaxed);
                for (AVAudioFrameCount i = 0; i < genFrames && left > 0; ++i, --left, ++v) {
                    const long rel = v - beatOff;
                    const long m = ((rel % B) + B) % B;
                    if (m == 0) {
                        const long bi = (rel - m) / B;
                        const int phase = (int)(((bi % bpb) + bpb) % bpb);
                        shared->clickEnv = 1.0f;
                        shared->clickPhase = 0.0f;
                        shared->clickFreq = (phase == barPh) ? 1760.0f : 1175.0f;
                    }
                    if (shared->clickEnv > 0.0005f) {
                        shared->clickPhase += shared->clickFreq / 48000.0f;
                        if (shared->clickPhase >= 1.0f) shared->clickPhase -= 1.0f;
                        shared->clickBus[i] += sinf(shared->clickPhase * 2.0f * (float)M_PI)
                                               * shared->clickEnv * 0.5f
                                               * shared->clickGain.load(std::memory_order_relaxed);
                        shared->clickEnv *= 0.9988f;
                    }
                }
                shared->countInVPos.store(v, std::memory_order_relaxed);
                shared->countInLeft.store(left, std::memory_order_relaxed);
            }
        }

        // Per-stem MIDI lane sequencers: fire each lane's clip events against
        // the stem transport into that lane's synth instance. Flush hanging
        // notes on stop/seek/clip-swap/source-switch.
        {
            const bool act = shared->stemActive.load(std::memory_order_relaxed) &&
                             shared->countInLeft.load(std::memory_order_relaxed) <= 0;
            const long pos = shared->stemPos.load(std::memory_order_relaxed);
            const long len = shared->stemLen.load(std::memory_order_relaxed);
            const bool moved = (pos != shared->laneLastPos);
            const float bpm = shared->fxTempo.load(std::memory_order_relaxed);
            for (int k = 0; k < JamSharedState::kMidiLanes; ++k) {
                const int t = k + 1;                       // lane k ↔ stem t
                JamSynth& syn = shared->laneSynth[k];
                const int engine = shared->laneEngine[k].load(std::memory_order_relaxed);
                tsf* sf = (tsf*)shared->laneSf[k].load(std::memory_order_acquire);
                const bool sfMode = (engine == 1) && sf;
                const bool midiMode =
                    shared->stemSource[t].load(std::memory_order_relaxed) == 1;
                const JamSharedState::AuxEv* evs =
                    shared->laneEv[k].load(std::memory_order_acquire);
                const long cnt = shared->laneCount[k].load(std::memory_order_relaxed);
                const bool playing = act && midiMode && evs && cnt > 0;
                const uint32_t gen = shared->laneGen[k].load(std::memory_order_relaxed);
                const bool jumped = moved || (gen != shared->laneGenSeen[k]);
                const bool engineSwitched = engine != shared->laneEngineSeen[k];
                if (!playing || jumped || engineSwitched) {
                    // Release everything on BOTH engines (cheap when empty).
                    for (int nn = 0; nn < 128; ++nn) {
                        if (shared->laneHeld[k][nn]) {
                            syn.pushNote((uint8_t)nn, 0, false);
                            if (sf) tsf_channel_note_off(sf, 0, nn);
                            shared->laneHeld[k][nn] = false;
                        }
                    }
                    shared->laneEngineSeen[k] = engine;
                }
                // Re-locate the cursor after a seek / new clip — ALSO while
                // paused: the jump is consumed by the flush above, so waiting
                // for `playing` would resume with a stale cursor (silence
                // until the old position is reached again).
                if (jumped && evs && cnt > 0) {
                    shared->laneGenSeen[k] = gen;
                    long lo = 0, hi = cnt;
                    while (lo < hi) {
                        const long mid = (lo + hi) / 2;
                        if (evs[mid].sample < pos) lo = mid + 1;
                        else hi = mid;
                    }
                    shared->laneCursor[k] = lo;
                }
                if (playing) {
                    const long blockEnd = pos + (long)genFrames;
                    long cur = shared->laneCursor[k];
                    while (cur < cnt && evs[cur].sample < blockEnd) {
                        const uint8_t note = evs[cur].note;
                        if (evs[cur].on) {
                            if (sfMode) tsf_channel_note_on(sf, 0, note, evs[cur].vel / 127.0f);
                            else syn.pushNote(note, evs[cur].vel, true);
                            shared->laneHeld[k][note] = true;
                        } else {
                            if (sfMode) tsf_channel_note_off(sf, 0, note);
                            else syn.pushNote(note, 0, false);
                            shared->laneHeld[k][note] = false;
                        }
                        cur++;
                    }
                    shared->laneCursor[k] = cur;
                }
                // Render this lane's instrument into its scratch buffer.
                // Keep rendering ~4 s after leaving MIDI mode so releases and
                // FX tails decay instead of cutting.
                if (midiMode) shared->laneTail[k] = 4L * 48000;
                const bool wantRender =
                    shared->laneTail[k] > 0 &&
                    genFrames <= (AVAudioFrameCount)JamSharedState::kLaneBlockMax;
                if (wantRender) {
                    if (sfMode) {
                        const int prog =
                            shared->laneSfProgram[k].load(std::memory_order_relaxed);
                        if (prog != shared->laneSfProgApplied[k]) {
                            tsf_channel_set_presetnumber(sf, 0, prog, 0);
                            shared->laneSfProgApplied[k] = prog;
                        }
                        tsf_render_float(sf, shared->laneSfTmp, (int)genFrames, 0);
                        memcpy(shared->laneBufL[k], shared->laneSfTmp,
                               sizeof(float) * genFrames);
                        memcpy(shared->laneBufR[k], shared->laneSfTmp + genFrames,
                               sizeof(float) * genFrames);
                    } else {
                        memset(shared->laneBufL[k], 0, sizeof(float) * genFrames);
                        memset(shared->laneBufR[k], 0, sizeof(float) * genFrames);
                        syn.render(shared->laneBufL[k], shared->laneBufR[k],
                                   (int)genFrames, bpm);
                    }
                    shared->laneFx[k].process(shared->laneBufL[k], shared->laneBufR[k],
                                              (int)genFrames, bpm);
                    if (!midiMode) shared->laneTail[k] -= (long)genFrames;
                } else {
                    shared->laneTail[k] = 0;
                }
            }
            // Predict next block's start for jump detection.
            long next = pos;
            if (act) next = MIN(len, pos + (long)genFrames);
            shared->laneLastPos = next;
        }

        // PGM console stem mixer: master transport + per-stem gain/mute/solo.
        // Stems in MIDI mode contribute their lane synth instead of audio,
        // through the same audibility/gain (one fader rules both sources).
        {
            // Backing bounce: snapshot outL/R before the stem section so we can
            // capture only what the stems + MIDI lanes add (the backing),
            // isolated from any engine/synth output already in the bus.
            const bool _bounce = shared->bounceArmed.load(std::memory_order_relaxed);
            if (_bounce) {
                memcpy(shared->bounceSnapL, outL, genFrames * sizeof(float));
                memcpy(shared->bounceSnapR, outR, genFrames * sizeof(float));
            }
            const long len = shared->stemLen.load(std::memory_order_relaxed);
            const int mute = shared->stemMuteMask.load(std::memory_order_relaxed);
            const int solo = shared->stemSoloMask.load(std::memory_order_relaxed);
            const int16_t* bufs[JamSharedState::kStems];
            bool midiSrc[JamSharedState::kStems] = {};
            float target[JamSharedState::kStems];
            for (int t = 0; t < JamSharedState::kStems; ++t) {
                bufs[t] = shared->stemBuf[t].load(std::memory_order_relaxed);
                midiSrc[t] = t > 0 &&
                    shared->stemSource[t].load(std::memory_order_relaxed) == 1;
                const bool audible = (bufs[t] || midiSrc[t]) &&
                    (solo ? ((solo >> t) & 1) : !((mute >> t) & 1));
                target[t] = audible
                    ? shared->stemGain[t].load(std::memory_order_relaxed) : 0.0f;
            }
            if (len > 0 && shared->stemActive.load(std::memory_order_relaxed) &&
                shared->countInLeft.load(std::memory_order_relaxed) <= 0) {
                // Click during normal playback (clickOn) OR through the rolled-
                // back count-in region (pos before the cue), on the same grid.
                const long ciUntil = shared->countInUntil.load(std::memory_order_relaxed);
                const bool clickToggle = shared->clickOn.load(std::memory_order_relaxed);
                const float bpmC = shared->stemBpm.load(std::memory_order_relaxed);
                const long B = (long)(60.0 / ((bpmC < 40 || bpmC > 300) ? 120.0 : bpmC)
                                      * 48000.0);
                const long beatOff = shared->stemBeatOff.load(std::memory_order_relaxed);
                const int barPh = shared->stemBarPhase.load(std::memory_order_relaxed);
                const int bpb = shared->beatsPerBar.load(std::memory_order_relaxed);
                const float* mixL = shared->songMixL.load(std::memory_order_relaxed);
                const float* mixR = shared->songMixR.load(std::memory_order_relaxed);
                const long mixLen = shared->songMixLen.load(std::memory_order_relaxed);
                long pos = shared->stemPos.load(std::memory_order_relaxed);
                for (AVAudioFrameCount i = 0; i < genFrames && pos < len; ++i, ++pos) {
                    float l = 0.0f, r = 0.0f;
                    for (int t = 0; t < JamSharedState::kStems; ++t) {
                        if (midiSrc[t]) continue;          // handled below
                        float& g = shared->stemSmoothG[t];
                        g += (target[t] - g) * 0.002f;     // ~10 ms de-click
                        if (bufs[t] && g > 0.0005f) {
                            // Per-stem alignment offset: read from pos - offset,
                            // silent outside the stem buffer.
                            const long sp = pos - shared->stemOffset[t].load(std::memory_order_relaxed);
                            float sl = 0.0f, sr = 0.0f;
                            if (sp >= 0 && sp < len) {
                                sl = bufs[t][sp * 2]     * (1.0f / 32768.0f);
                                sr = bufs[t][sp * 2 + 1] * (1.0f / 32768.0f);
                            }
                            // Dry blend: fold a little of the original mix back in
                            // (fills hard-mask gaps / masks separation artifacts).
                            const float d = shared->stemDry[t].load(std::memory_order_relaxed);
                            if (d > 0.0001f && mixL && pos < mixLen) {
                                sl = (1.0f - d) * sl + d * mixL[pos];
                                sr = (1.0f - d) * sr + d * mixR[pos];
                            }
                            l += sl * g * 0.9f;
                            r += sr * g * 0.9f;
                        }
                    }
                    const bool click = clickToggle || (ciUntil >= 0 && pos < ciUntil);
                    if (click) {
                        // Beats are derived from the anchor (cue/first-beat) in
                        // BOTH directions, so the metronome ticks through the
                        // lead-in and the downbeat "1" lands exactly on it.
                        const long rel = pos - beatOff;
                        const long m = ((rel % B) + B) % B;
                        if (m == 0) {
                            const long bi = (rel - m) / B;     // beat index (may be <0)
                            const int phase = (int)(((bi % bpb) + bpb) % bpb);
                            shared->clickEnv = 1.0f;
                            shared->clickPhase = 0.0f;
                            shared->clickFreq = (phase == barPh) ? 1760.0f : 1175.0f;
                        }
                        if (shared->clickEnv > 0.0005f) {
                            shared->clickPhase += shared->clickFreq / 48000.0f;
                            if (shared->clickPhase >= 1.0f) shared->clickPhase -= 1.0f;
                            const float c = sinf(shared->clickPhase * 2.0f * (float)M_PI)
                                            * shared->clickEnv * 0.4f
                                            * shared->clickGain.load(std::memory_order_relaxed);
                            shared->clickEnv *= 0.9988f;
                            shared->clickBus[i] += c;
                        }
                    }
                    outL[i] += l;
                    outR[i] += r;
                }
                shared->stemPos.store(pos, std::memory_order_relaxed);
                if (pos >= len) shared->stemActive.store(false, std::memory_order_relaxed);
            }
            // MIDI lanes mix in even when the transport is stopped (FX tails).
            for (int k = 0; k < JamSharedState::kMidiLanes; ++k) {
                if (shared->laneTail[k] <= 0) continue;
                const int t = k + 1;
                const float tgt = midiSrc[t] ? target[t] : 0.0f;
                float& g = shared->laneSmoothG[k];
                if (tgt <= 0.0005f && g <= 0.0005f) { g = tgt; continue; }
                for (AVAudioFrameCount i = 0; i < genFrames; ++i) {
                    g += (tgt - g) * 0.002f;
                    outL[i] += shared->laneBufL[k][i] * g * 1.8f;
                    outR[i] += shared->laneBufR[k][i] * g * 1.8f;
                }
            }

            // Backing bounce capture: (post-stem − pre-stem) = the backing mix,
            // plus the click bus if requested.
            if (_bounce) {
                float* bl = shared->bounceL.load(std::memory_order_relaxed);
                float* br = shared->bounceR.load(std::memory_order_relaxed);
                const long cap = shared->bounceCap.load(std::memory_order_relaxed);
                const bool wc = shared->bounceClick.load(std::memory_order_relaxed);
                long w = shared->bounceWritten.load(std::memory_order_relaxed);
                if (bl && br) {
                    for (AVAudioFrameCount i = 0; i < genFrames && w < cap; ++i, ++w) {
                        float cl = outL[i] - shared->bounceSnapL[i];
                        float cr = outR[i] - shared->bounceSnapR[i];
                        if (wc) { cl += shared->clickBus[i]; cr += shared->clickBus[i]; }
                        bl[w] = cl; br[w] = cr;
                    }
                    shared->bounceWritten.store(w, std::memory_order_relaxed);
                    if (w >= cap) shared->bounceArmed.store(false, std::memory_order_relaxed);
                }
            }
        }

        }  // end program-audio generation (else of calibration)

        shared->pushAudioSamples(outL, outR, genFrames);

        // Resample the generated genFrames of 48k content down to the frameCount
        // output frames the device asked for (speed compensation). Linear interp,
        // done in place: when genFrames > frameCount the source read index is
        // always >= the write index, so overwriting is safe.
        if (genFrames != frameCount && frameCount > 1) {
            const double rstep = (double)(genFrames - 1) / (double)(frameCount - 1);
            float* clk = shared->clickBus;
            for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                double sp = (double)i * rstep;
                AVAudioFrameCount i0 = (AVAudioFrameCount)sp;
                AVAudioFrameCount i1 = i0 + 1;
                if (i1 >= genFrames) i1 = genFrames - 1;
                float fr = (float)(sp - (double)i0);
                outL[i] = outL[i0] + (outL[i1] - outL[i0]) * fr;
                outR[i] = outR[i0] + (outR[i1] - outR[i0]) * fr;
                clk[i]  = clk[i0]  + (clk[i1]  - clk[i0])  * fr;
            }
        }

        // ── Distribute busses → device channels per the routing masks ──
        {
            const int nch = (int)outputData->mNumberBuffers;
            const uint32_t mMask = shared->mainOutMask.load(std::memory_order_relaxed);
            const uint32_t cMask = shared->clickOutMask.load(std::memory_order_relaxed);
            int sel[32];
            int nSel = 0;
            for (int c = 0; c < nch && c < 32; ++c) {
                float* dst = (float*)outputData->mBuffers[c].mData;
                if (dst) memset(dst, 0, frameCount * sizeof(float));
                if (mMask & (1u << c)) sel[nSel++] = c;
            }
            // Main: selected channels alternate L/R in ascending order;
            // a single selected channel gets the mono sum.
            for (int k = 0; k < nSel; ++k) {
                float* dst = (float*)outputData->mBuffers[sel[k]].mData;
                if (!dst) continue;
                if (nSel == 1) {
                    for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                        dst[i] += (outL[i] + outR[i]) * 0.5f;
                    }
                } else {
                    const float* src = (k % 2 == 0) ? outL : outR;
                    for (AVAudioFrameCount i = 0; i < frameCount; ++i) dst[i] += src[i];
                }
            }
            // Click: mono, added to every selected channel.
            for (int c = 0; c < nch && c < 32; ++c) {
                if (!(cMask & (1u << c))) continue;
                float* dst = (float*)outputData->mBuffers[c].mData;
                if (!dst) continue;
                for (AVAudioFrameCount i = 0; i < frameCount; ++i) {
                    dst[i] += shared->clickBus[i];
                }
            }
        }
        return noErr;
    };

    // Mach timebase → seconds, for the speed-compensation rate measurement.
    {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        _sharedState.hostTicksToSec = (double)tb.numer / (double)tb.denom * 1e-9;
    }

    // Apply the persisted multichannel-output preference before connecting.
    _sharedState.multichannelOut.store(
        [[NSUserDefaults standardUserDefaults] boolForKey:@"Jam_MultichannelOut"],
        std::memory_order_relaxed);

    // Persisted click volume (default 1.0 when never set).
    {
        NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
        const float g = [d objectForKey:@"Jam_ClickGain"] ? [d floatForKey:@"Jam_ClickGain"] : 1.0f;
        _sharedState.clickGain.store(MAX(0.0f, MIN(2.0f, g)), std::memory_order_relaxed);
    }

    [self connectSourceNodeForCurrentDevice];

    // When the output device changes (plug in headphones, switch speakers,
    // (dis)connect Bluetooth), AVAudioEngine stops itself and posts this
    // notification. Nothing restarts it automatically → silence. Re-establish
    // the graph and restart so audio follows the new device.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAudioEngineConfigChange:)
                                                 name:AVAudioEngineConfigurationChangeNotification
                                               object:_audioEngine];
    // The UI toggles multichannel output / routing → rebuild the graph.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"JamRebuildAudioGraph"
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* n) {
        [self rebuildAudioGraph];
    }];
    // Export the current backing mix (honoring mute/solo) to a WAV file.
    [[NSNotificationCenter defaultCenter] addObserverForName:@"JamExportBacking"
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification* n) {
        [self exportBacking];
    }];

    NSError* error = nil;
    if (![_audioEngine startAndReturnError:&error]) {
        NSLog(@"Jam: AVAudioEngine failed to start: %@", error);
    }
}

// (Re)create the source node sized to the CURRENT output device's channel
// count, so multichannel interfaces expose every output to the router.
- (void)connectSourceNodeForCurrentDevice {
    AVAudioFormat* devFmt = [_audioEngine.outputNode outputFormatForBus:0];
    const UInt32 devCh = devFmt.channelCount;
    const double hwRate = devFmt.sampleRate;

    if (_sourceNode) [_audioEngine detachNode:_sourceNode];

    // Default: source(48 kHz stereo) → mainMixerNode with the engine
    // auto-managing mixer→output. That auto-negotiation is the ONLY path that
    // gets the real device clock right — forcing any output format plays slow
    // on devices that misreport their rate (raw SP-404). So per-channel click
    // routing (which needs a forced multichannel output) is OPT-IN and only
    // safe with a true 48 kHz device / aggregate device.
    const bool wantMC = _sharedState.multichannelOut.load(std::memory_order_relaxed) &&
                        devCh > 2 && devCh <= 16;
    if (wantMC) {
        // Multichannel source → mainMixer, but DO NOT force the mixer→output
        // format. Forcing any output sample-rate is what plays slow on these
        // devices; letting the engine auto-negotiate mixer→output keeps the
        // real device clock, and the multichannel source carries the extra
        // channels through for click routing.
        AVAudioFormat* srcFmt = [[AVAudioFormat alloc]
            initStandardFormatWithSampleRate:48000.0 channels:devCh];
        _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:srcFmt
                                                    renderBlock:_renderBlock];
        [_audioEngine attachNode:_sourceNode];
        [_audioEngine connect:_sourceNode to:_audioEngine.mainMixerNode format:srcFmt];
        _sharedState.outChannels.store((int)devCh, std::memory_order_relaxed);
    } else {
        AVAudioFormat* srcFmt = [[AVAudioFormat alloc]
            initStandardFormatWithSampleRate:48000.0 channels:2];
        _sourceNode = [[AVAudioSourceNode alloc] initWithFormat:srcFmt
                                                    renderBlock:_renderBlock];
        [_audioEngine attachNode:_sourceNode];
        [_audioEngine connect:_sourceNode to:_audioEngine.mainMixerNode format:srcFmt];
        _sharedState.outChannels.store(2, std::memory_order_relaxed);
    }
    // Restart the speed-compensation measurement for the new graph/device.
    _sharedState.rateMeasReset.store(true, std::memory_order_release);
    NSLog(@"Jam: source node connected — %s; device %u ch @ %.0f Hz",
          wantMC ? "multichannel" : "stereo", (unsigned)devCh, hwRate);
}

// Tear down and rebuild the graph for the current device / routing mode.
- (void)rebuildAudioGraph {
    if (!_audioEngine) return;
    [_audioEngine stop];
    @try {
        [self connectSourceNodeForCurrentDevice];
    } @catch (NSException* e) {
        NSLog(@"Jam: graph rebuild threw: %@", e);
    }
    NSError* err = nil;
    if (![_audioEngine startAndReturnError:&err]) {
        NSLog(@"Jam: AVAudioEngine restart failed: %@", err);
    }
    // Device / channel changed → gate playback behind a 120 BPM calibration
    // pass so timing is verified on the new output before performing.
    [_controller enterCalibration];
}

- (void)handleAudioEngineConfigChange:(NSNotification*)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"Jam: output device changed — rebuilding graph for the new device");
        [self rebuildAudioGraph];
    });
}

// Export the current backing mix (per mute/solo, with audio + MIDI lanes +
// offset + dry) to a WAV. The render block is pumped offline (engine paused)
// faster than real time, capturing the isolated stem-mix delta. The operator
// chooses whether to bake the metronome click in.
- (void)exportBacking {
    JamSharedState* sh = &_sharedState;
    const long len = sh->stemLen.load(std::memory_order_relaxed);
    if (len <= 0) {
        [_controller sendStateUpdate:@{@"studioNotice": @"先载入并分离一首歌再导出伴奏"}];
        return;
    }

    // 1) Format.
    NSAlert* fmtAlert = [[NSAlert alloc] init];
    fmtAlert.messageText = @"导出伴奏 — 格式";
    fmtAlert.informativeText = @"M4A/AAC 体积小(约 WAV 的 1/10),通用可播;WAV 无损但很大。";
    [fmtAlert addButtonWithTitle:@"M4A (小)"];
    [fmtAlert addButtonWithTitle:@"WAV (无损)"];
    [fmtAlert addButtonWithTitle:@"取消"];
    const NSModalResponse fr = [fmtAlert runModal];
    if (fr == NSAlertThirdButtonReturn) return;
    const BOOL asM4A = (fr == NSAlertFirstButtonReturn);

    // 2) Click.
    NSAlert* clkAlert = [[NSAlert alloc] init];
    clkAlert.messageText = @"导出伴奏 — 节拍器";
    clkAlert.informativeText = @"按当前 mute / solo 设置导出。是否包含节拍器 click?";
    [clkAlert addButtonWithTitle:@"含 click"];
    [clkAlert addButtonWithTitle:@"不含 click"];
    [clkAlert addButtonWithTitle:@"取消"];
    const NSModalResponse cr = [clkAlert runModal];
    if (cr == NSAlertThirdButtonReturn) return;
    const BOOL withClick = (cr == NSAlertFirstButtonReturn);

    NSString* ext = asM4A ? @"m4a" : @"wav";
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:ext]];
    panel.nameFieldStringValue =
        [NSString stringWithFormat:@"伴奏%@.%@", withClick ? @" (含click)" : @"", ext];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSURL* url = panel.URL;

    // Save live transport/audio state to restore after the bounce.
    const bool  sClickOn   = sh->clickOn.load(std::memory_order_relaxed);
    const int   sCountIn   = sh->countInBeats.load(std::memory_order_relaxed);
    const float sComp      = sh->outSpeedComp.load(std::memory_order_relaxed);
    const long  sPos       = sh->stemPos.load(std::memory_order_relaxed);
    const bool  sActive    = sh->stemActive.load(std::memory_order_relaxed);
    const bool  sCalib     = sh->calibrating.load(std::memory_order_relaxed);

    float* capL = (float*)calloc((size_t)len, sizeof(float));
    float* capR = (float*)calloc((size_t)len, sizeof(float));
    if (!capL || !capR) { free(capL); free(capR); return; }

    // Configure the bounce: clean 1:1 rate, no count-in, click per choice,
    // transport from the start, capture armed.
    sh->outSpeedComp.store(1.0f, std::memory_order_relaxed);
    sh->calibrating.store(false, std::memory_order_relaxed);
    sh->countInBeats.store(0, std::memory_order_relaxed);
    sh->countInLeft.store(0, std::memory_order_relaxed);
    sh->clickOn.store(withClick, std::memory_order_relaxed);
    sh->stemPos.store(0, std::memory_order_relaxed);
    sh->stemActive.store(true, std::memory_order_relaxed);
    sh->bounceClick.store(withClick, std::memory_order_relaxed);
    sh->bounceL.store(capL, std::memory_order_relaxed);
    sh->bounceR.store(capR, std::memory_order_relaxed);
    sh->bounceCap.store(len, std::memory_order_relaxed);
    sh->bounceWritten.store(0, std::memory_order_relaxed);
    sh->bounceArmed.store(true, std::memory_order_release);

    [_audioEngine pause];   // no device callback → safe to drive the block offline
    [_controller sendStateUpdate:@{@"studioNotice": @"导出伴奏中…"}];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        const AVAudioFrameCount BS = 1024;
        float* tL = (float*)calloc(BS, sizeof(float));
        float* tR = (float*)calloc(BS, sizeof(float));
        AudioBufferList* abl =
            (AudioBufferList*)malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer));
        abl->mNumberBuffers = 2;
        abl->mBuffers[0].mNumberChannels = 1;
        abl->mBuffers[0].mDataByteSize = BS * sizeof(float);
        abl->mBuffers[0].mData = tL;
        abl->mBuffers[1].mNumberChannels = 1;
        abl->mBuffers[1].mDataByteSize = BS * sizeof(float);
        abl->mBuffers[1].mData = tR;
        AudioTimeStamp ts; memset(&ts, 0, sizeof(ts));  // mFlags=0 → skip rate measure
        BOOL silence = NO;
        const long maxIters = len / BS + 256;
        long guard = 0;
        while (sh->bounceArmed.load(std::memory_order_relaxed) && guard++ < maxIters) {
            memset(tL, 0, BS * sizeof(float));
            memset(tR, 0, BS * sizeof(float));
            self->_renderBlock(&silence, &ts, BS, abl);
        }
        free(tL); free(tR); free(abl);

        // Float → int16 interleaved (clipped).
        std::vector<int16_t> pcm((size_t)len * 2);
        for (long i = 0; i < len; ++i) {
            float l = capL[i], r = capR[i];
            l = l < -1.0f ? -1.0f : (l > 1.0f ? 1.0f : l);
            r = r < -1.0f ? -1.0f : (r > 1.0f ? 1.0f : r);
            pcm[i * 2]     = (int16_t)lrintf(l * 32767.0f);
            pcm[i * 2 + 1] = (int16_t)lrintf(r * 32767.0f);
        }
        free(capL); free(capR);
        const BOOL ok = asM4A ? JamAppWriteM4A(url, pcm.data(), len)
                              : JamAppWriteWav(url, pcm.data(), len);

        dispatch_async(dispatch_get_main_queue(), ^{
            // Disarm + restore live state.
            sh->bounceArmed.store(false, std::memory_order_relaxed);
            sh->bounceL.store(nullptr, std::memory_order_relaxed);
            sh->bounceR.store(nullptr, std::memory_order_relaxed);
            sh->clickOn.store(sClickOn, std::memory_order_relaxed);
            sh->countInBeats.store(sCountIn, std::memory_order_relaxed);
            sh->outSpeedComp.store(sComp, std::memory_order_relaxed);
            sh->stemPos.store(sPos, std::memory_order_relaxed);
            sh->stemActive.store(sActive, std::memory_order_relaxed);
            sh->calibrating.store(sCalib, std::memory_order_relaxed);
            NSError* err = nil;
            if (![self->_audioEngine startAndReturnError:&err])
                NSLog(@"Jam: engine restart after bounce failed: %@", err);
            [self->_controller sendStateUpdate:@{@"studioNotice":
                ok ? [NSString stringWithFormat:@"✓ 已导出伴奏:%@", url.lastPathComponent]
                   : @"导出失败"}];
        });
    });
}

// ─── CoreMIDI ────────────────────────────────────────────────────────────────

- (void)setupMIDI {
    RealtimeRunner* engine = &_engine;
    JamSharedState* shared = &_sharedState;

    __weak JamAppController* weakController = _controller;
    OSStatus status = MIDIClientCreateWithBlock(
        CFSTR("MRT2 - Jam"),
        &_midiClient,
        ^(const MIDINotification* notification) {
            if (notification->messageID == kMIDIMsgSetupChanged) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakController handleMIDIStructureChanged];
                });
            }
        }
    );
    if (status != noErr) { NSLog(@"Jam: MIDIClientCreate failed: %d", (int)status); return; }

    status = MIDIInputPortCreateWithProtocol(
        _midiClient, CFSTR("MRT2 - Jam In"), kMIDIProtocol_1_0, &_midiInputPort,
        ^(const MIDIEventList* evtList, void* srcConnRefCon) {
            const MIDIEventPacket* pkt = &evtList->packet[0];
            for (UInt32 i = 0; i < evtList->numPackets; ++i) {
                for (UInt32 w = 0; w < pkt->wordCount; ++w) {
                    uint32_t word = pkt->words[w];
                    uint8_t msgType = (word >> 28) & 0xF;
                    if (msgType == 0x2) {
                        uint8_t statusByte = (word >> 16) & 0xFF;
                        uint8_t statusNibble = statusByte & 0xF0;
                        uint8_t note = (word >> 8) & 0x7F;
                        uint8_t velocity = word & 0x7F;
                        // Routing:
                        //   synth   when the synth is active, or off the jam tab
                        //   engine  on the jam tab with synth inactive (pure
                        //           jam), OR when the instrument follows the jam
                        // (both can fire: instrument + follow plays the synth
                        //  AND conditions the engine).
                        const bool synthActive =
                            shared->synth.active.load(std::memory_order_relaxed);
                        const bool jamActive =
                            shared->jamTabActive.load(std::memory_order_relaxed);
                        const bool follow =
                            shared->instrumentFollowsJam.load(std::memory_order_relaxed);
                        const bool toSynth = synthActive || !jamActive;
                        const bool toEngine =
                            (jamActive && !synthActive) || (synthActive && follow);
                        if (statusNibble == 0x90 && velocity > 0) {
                            if (toSynth) shared->routeLiveNote(note, velocity, true);
                            if (toEngine) { engine->set_note_on(note); shared->noteOn(note); }
                        } else if (statusNibble == 0x80 || (statusNibble == 0x90 && velocity == 0)) {
                            // Note-offs always reach the synth too, so keys
                            // released after a tab switch never leave stale
                            // held notes (harmless when the note is unknown).
                            shared->routeLiveNote(note, 0, false);
                            if (toEngine) {
                                engine->set_note_off(note);
                                shared->noteOff(note);
                            }
                        }
                    }
                }
                pkt = MIDIEventPacketNext(pkt);
            }
        }
    );
    if (status != noErr) { NSLog(@"Jam: MIDIInputPortCreate failed: %d", (int)status); return; }

    status = MIDIDestinationCreateWithProtocol(
        _midiClient, CFSTR("MRT2 - Jam Input"), kMIDIProtocol_1_0, &_midiVirtualDest,
        ^(const MIDIEventList* evtList, void* srcConnRefCon) {
            const MIDIEventPacket* pkt = &evtList->packet[0];
            for (UInt32 i = 0; i < evtList->numPackets; ++i) {
                for (UInt32 w = 0; w < pkt->wordCount; ++w) {
                    uint32_t word = pkt->words[w];
                    uint8_t msgType = (word >> 28) & 0xF;
                    if (msgType == 0x2) {
                        uint8_t statusByte = (word >> 16) & 0xFF;
                        uint8_t statusNibble = statusByte & 0xF0;
                        uint8_t note = (word >> 8) & 0x7F;
                        uint8_t velocity = word & 0x7F;
                        // Routing:
                        //   synth   when the synth is active, or off the jam tab
                        //   engine  on the jam tab with synth inactive (pure
                        //           jam), OR when the instrument follows the jam
                        // (both can fire: instrument + follow plays the synth
                        //  AND conditions the engine).
                        const bool synthActive =
                            shared->synth.active.load(std::memory_order_relaxed);
                        const bool jamActive =
                            shared->jamTabActive.load(std::memory_order_relaxed);
                        const bool follow =
                            shared->instrumentFollowsJam.load(std::memory_order_relaxed);
                        const bool toSynth = synthActive || !jamActive;
                        const bool toEngine =
                            (jamActive && !synthActive) || (synthActive && follow);
                        if (statusNibble == 0x90 && velocity > 0) {
                            if (toSynth) shared->routeLiveNote(note, velocity, true);
                            if (toEngine) { engine->set_note_on(note); shared->noteOn(note); }
                        } else if (statusNibble == 0x80 || (statusNibble == 0x90 && velocity == 0)) {
                            // Note-offs always reach the synth too, so keys
                            // released after a tab switch never leave stale
                            // held notes (harmless when the note is unknown).
                            shared->routeLiveNote(note, 0, false);
                            if (toEngine) {
                                engine->set_note_off(note);
                                shared->noteOff(note);
                            }
                        }
                    }
                }
                pkt = MIDIEventPacketNext(pkt);
            }
        }
    );
    if (status != noErr) {
        NSLog(@"Jam: MIDIDestinationCreate failed: %d", (int)status);
    }
}

// ─── Menu bar ────────────────────────────────────────────────────────────────

- (void)setupMenuBar {
    NSMenu* menuBar = [[NSMenu alloc] init];

    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About VerveFlow" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Settings..." action:@selector(menuShowSettings:) keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit VerveFlow" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    [menuBar addItem:appMenuItem];

    NSMenuItem* fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"Load Model..." action:@selector(menuLoadModel:) keyEquivalent:@"o"];
    fileMenuItem.submenu = fileMenu;
    [menuBar addItem:fileMenuItem];

    NSMenuItem* editMenuItem = [[NSMenuItem alloc] init];
    NSMenu* editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editMenuItem.submenu = editMenu;
    [menuBar addItem:editMenuItem];

    NSMenuItem* transportMenuItem = [[NSMenuItem alloc] init];
    NSMenu* transportMenu = [[NSMenu alloc] initWithTitle:@"Transport"];
    _playStopMenuItem = [transportMenu addItemWithTitle:@"Play"
                                                  action:@selector(menuTogglePlayStop:)
                                           keyEquivalent:@" "];
    _isPlaying = NO;
    transportMenuItem.submenu = transportMenu;
    [menuBar addItem:transportMenuItem];

    [NSApp setMainMenu:menuBar];
}

- (void)menuTogglePlayStop:(id)sender {
    if (_useLyria.load(std::memory_order_relaxed)) {
        // Cloud engine: the websocket only exists while playing. Pause is a
        // hard cutoff (STOP + cancel) so no idle session keeps billing.
        if (_isPlaying) {
            [_lyriaClient disconnect];
            _isPlaying = NO;
            _playStopMenuItem.title = @"Play";
        } else {
            NSString* key =
                [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_LyriaApiKey"];
            [_lyriaClient connectWithApiKey:key];
            _isPlaying = YES;
            _playStopMenuItem.title = @"Pause";
        }
        [_controller sendPlayState:_isPlaying];
        return;
    }

    if (_isPlaying) {
        _engine.set_bypass(true);
        _isPlaying = NO;
        _playStopMenuItem.title = @"Play";
    } else {
        _engine.set_bypass(false);
        _engine.trigger_reset();
        _isPlaying = YES;
        _playStopMenuItem.title = @"Pause";
    }
    [_controller sendPlayState:_isPlaying];
}

- (void)menuShowSettings:(id)sender {
    if (_controller) {
        [_controller showReactSettings];
    }
}

- (void)menuLoadModel:(id)sender {
    [_controller handleLoadModel];
}

// ─── Auto-load model ─────────────────────────────────────────────────────────

- (void)autoLoadModel {
    NSString* modelPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jam_ModelPath"];
    if (!modelPath) return;

    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) return;

    NSLog(@"Jam: Auto-loading model from %@", modelPath);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = self->_engine.load_model(modelPath.UTF8String);
        if (success) {
            NSLog(@"Jam: Model loaded successfully.");

            NSString* parentDir = [modelPath stringByDeletingLastPathComponent];
            NSString* corpusPath = [parentDir stringByAppendingPathComponent:@"corpus.safetensors"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:corpusPath]) {
                self->_engine.load_pca_file(corpusPath.UTF8String);
            }

            [self->_controller restoreSavedParams];

            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_controller notifyModelLoaded:modelPath.lastPathComponent];
            });
        } else {
            NSLog(@"Jam: Failed to auto-load model from %@", modelPath);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_controller sendStateUpdate:@{@"modelName": @"No model loaded"}];
            });
        }
    });
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)applicationWillTerminate:(NSNotification*)notification {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVAudioEngineConfigurationChangeNotification
                                                  object:_audioEngine];
    [_lyriaClient disconnect];
    _engine.stop();
    _engine.unload();
    [_audioEngine stop];
    if (_midiVirtualDest) MIDIEndpointDispose(_midiVirtualDest);
    if (_midiInputPort) MIDIPortDispose(_midiInputPort);
    if (_midiClient) MIDIClientDispose(_midiClient);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender { return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

@end

// ─── main ────────────────────────────────────────────────────────────────────

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
