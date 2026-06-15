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

#import "LyriaClient.h"

static NSString* const kLyriaWsBase =
    @"wss://agentllm.linkyun.co/v1beta/google/lyria/ws";
static NSString* const kLyriaModel = @"models/lyria-realtime-exp";

@interface LyriaClient () <NSURLSessionWebSocketDelegate>
@end

@implementation LyriaClient {
    LyriaAudioRing _ring;
    NSURLSession* _session;
    NSURLSessionWebSocketTask* _task;
    // Epoch guards: callbacks from a cancelled socket are ignored.
    std::atomic<uint64_t> _epoch;
    BOOL _connected;          // setupComplete received (main-queue confined)
    BOOL _connecting;
    NSArray<NSDictionary*>* _cachedPrompts;
    NSMutableDictionary* _cachedConfig;
    void (^_statusHandler)(NSString*);
    BOOL _announcedStreaming;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cachedConfig = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration* cfg =
            [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 15;
        _session = [NSURLSession sessionWithConfiguration:cfg
                                                 delegate:self
                                            delegateQueue:[NSOperationQueue mainQueue]];
    }
    return self;
}

- (LyriaAudioRing*)ring {
    return &_ring;
}

- (void)setStatusHandler:(void (^)(NSString*))handler {
    _statusHandler = [handler copy];
}

- (void)emitStatus:(NSString*)status {
    NSLog(@"Lyria: %@", status);
    if (_statusHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_statusHandler) self->_statusHandler(status);
        });
    }
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

- (void)connectWithApiKey:(NSString*)apiKey {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_task) return; // already connecting/connected
        if (apiKey.length == 0) {
            [self emitStatus:@"error: no api key (defaults: Jam_LyriaApiKey)"];
            return;
        }
        self->_connecting = YES;
        self->_connected = NO;
        self->_announcedStreaming = NO;
        self->_ring.clear();
        [self emitStatus:@"connecting"];

        NSString* urlStr =
            [NSString stringWithFormat:@"%@?api_key=%@", kLyriaWsBase, apiKey];
        NSURL* url = [NSURL URLWithString:urlStr];
        self->_task = [self->_session webSocketTaskWithURL:url];
        [self->_task resume];
        [self receiveLoopForEpoch:self->_epoch.load(std::memory_order_relaxed)];
    });
}

- (void)disconnect {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_epoch.fetch_add(1, std::memory_order_relaxed);
        if (self->_task) {
            // Best-effort STOP so the server stops billing immediately, then
            // hard-cancel the socket.
            NSURLSessionWebSocketTask* task = self->_task;
            self->_task = nil;
            [self sendJson:@{@"playbackControl" : @"STOP"} onTask:task];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [task cancel];
            });
        }
        self->_connected = NO;
        self->_connecting = NO;
        self->_ring.clear();
        [self emitStatus:@"idle"];
    });
}

// ─── Outbound messages ───────────────────────────────────────────────────────

- (void)sendJson:(NSDictionary*)obj onTask:(NSURLSessionWebSocketTask*)task {
    if (!task) return;
    NSError* err = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
    if (!data) return;
    NSString* str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage* msg =
        [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    [task sendMessage:msg completionHandler:^(NSError* sendErr) {
        if (sendErr) NSLog(@"Lyria: send failed: %@", sendErr.localizedDescription);
    }];
}

- (void)sendJson:(NSDictionary*)obj {
    [self sendJson:obj onTask:_task];
}

- (void)setWeightedPrompts:(NSArray<NSDictionary*>*)prompts {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (prompts.count == 0) return; // Lyria rejects empty prompt lists
        self->_cachedPrompts = [prompts copy];
        if (self->_connected) {
            [self sendJson:@{@"clientContent" : @{@"weightedPrompts" : prompts}}];
        }
    });
}

- (void)setConfig:(NSDictionary*)config {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Per the Lyria RealTime docs, bpm and scale changes only take
        // effect after a context reset; other knobs apply live.
        BOOL needsReset = NO;
        for (NSString* key in @[ @"bpm", @"scale" ]) {
            id v = config[key];
            if (v && ![v isEqual:self->_cachedConfig[key]]) needsReset = YES;
        }
        [self->_cachedConfig addEntriesFromDictionary:config];
        if (self->_connected) {
            [self sendJson:@{@"musicGenerationConfig" : self->_cachedConfig}];
            if (needsReset) {
                [self sendJson:@{@"playbackControl" : @"RESET_CONTEXT"}];
            }
        }
    });
}

// ─── Inbound messages ────────────────────────────────────────────────────────

- (void)receiveLoopForEpoch:(uint64_t)epoch {
    NSURLSessionWebSocketTask* task = _task;
    if (!task) return;
    __weak LyriaClient* weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage* msg,
                                                NSError* error) {
        LyriaClient* self2 = weakSelf;
        if (!self2) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self2->_epoch.load(std::memory_order_relaxed) != epoch) return;
            if (error) {
                [self2 emitStatus:[NSString stringWithFormat:@"error: %@",
                                                             error.localizedDescription]];
                self2->_task = nil;
                self2->_connected = NO;
                self2->_connecting = NO;
                // Invalidate stale receive/ping loops before the reconnect.
                self2->_epoch.fetch_add(1, std::memory_order_relaxed);
                return;
            }
            [self2 handleMessage:msg];
            [self2 receiveLoopForEpoch:epoch];
        });
    }];
}

- (void)handleMessage:(NSURLSessionWebSocketMessage*)msg {
    NSData* data = nil;
    if (msg.type == NSURLSessionWebSocketMessageTypeString) {
        data = [msg.string dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        data = msg.data;
    }
    if (!data) return;
    NSDictionary* obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return;

    if (obj[@"setupComplete"]) {
        _connected = YES;
        _connecting = NO;
        if (_cachedPrompts.count > 0) {
            [self sendJson:@{@"clientContent" : @{@"weightedPrompts" : _cachedPrompts}}];
        }
        if (_cachedConfig.count > 0) {
            [self sendJson:@{@"musicGenerationConfig" : _cachedConfig}];
        }
        [self sendJson:@{@"playbackControl" : @"PLAY"}];
        [self emitStatus:@"buffering"];
        return;
    }

    NSArray* chunks = obj[@"serverContent"][@"audioChunks"];
    if ([chunks isKindOfClass:[NSArray class]]) {
        for (NSDictionary* chunk in chunks) {
            NSString* b64 = chunk[@"data"];
            if (![b64 isKindOfClass:[NSString class]]) continue;
            NSData* pcm = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
            if (!pcm) continue;
            const size_t frames = pcm.length / 4; // 2 ch × int16
            _ring.writeInt16Stereo((const int16_t*)pcm.bytes, frames);
        }
        if (!_announcedStreaming && _ring.primed.load(std::memory_order_relaxed)) {
            _announcedStreaming = YES;
            [self emitStatus:@"streaming"];
        }
    }
}

// ─── NSURLSessionWebSocketDelegate ──────────────────────────────────────────

- (void)URLSession:(NSURLSession*)session
          webSocketTask:(NSURLSessionWebSocketTask*)task
    didOpenWithProtocol:(NSString*)protocol {
    if (task != _task) return;
    [self sendJson:@{@"setup" : @{@"model" : kLyriaModel}} onTask:task];
    // Keepalive: proxies/gateways drop a socket that sends no client→server
    // traffic (we mostly just receive audio). Periodic WS pings keep the
    // connection (and NAT/proxy state) alive — without them the gateway here
    // resets the socket every ~40-145 s, forcing an audible emergency handover.
    [self pingLoopForEpoch:_epoch.load(std::memory_order_relaxed)];
}

// Send a WebSocket ping every 15 s while this epoch's socket is live.
- (void)pingLoopForEpoch:(uint64_t)epoch {
    if (_epoch.load(std::memory_order_relaxed) != epoch) return;
    NSURLSessionWebSocketTask* task = _task;
    if (!task) return;
    [task sendPingWithPongReceiveHandler:^(NSError* err) {
        if (err) NSLog(@"Lyria: ping failed: %@", err.localizedDescription);
    }];
    __weak LyriaClient* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LyriaClient* s = weakSelf;
        if (s) [s pingLoopForEpoch:epoch];
    });
}

- (void)URLSession:(NSURLSession*)session
        webSocketTask:(NSURLSessionWebSocketTask*)task
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)code
              reason:(NSData*)reason {
    if (task != _task) return;
    _task = nil;
    _connected = NO;
    _connecting = NO;
    NSString* why = reason.length
        ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding]
        : @"";
    [self emitStatus:[NSString stringWithFormat:@"error: closed (%ld) %@",
                                                (long)code, why]];
}

@end
