#import "JamHandTracker.h"

#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

#include <cmath>

// Pinch hysteresis: thumb–index distance relative to hand size (wrist→middle
// MCP). Engage below kPinchOn, release above kPinchOff so the grab doesn't
// flicker at the threshold.
static const float kPinchOn  = 0.42f;
static const float kPinchOff = 0.58f;
// One-pole smoothing on the palm position (per ~30 Hz frame).
static const float kSmooth = 0.45f;
// Landmark confidence floor below which a joint is treated as unseen.
static const float kMinConfidence = 0.3f;

@interface JamHandTracker () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation JamHandTracker {
    AVCaptureSession* _session;
    dispatch_queue_t _queue;
    VNDetectHumanHandPoseRequest* _request;
    BOOL _running;
    // Tracking state, only touched on _queue.
    float _smoothX, _smoothY;
    BOOL _haveSmooth;
    BOOL _pinching;
    BOOL _wasVisible;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("co.linkyun.vervflow.handtracker",
                                       DISPATCH_QUEUE_SERIAL);
        _request = [[VNDetectHumanHandPoseRequest alloc] init];
        _request.maximumHandCount = 1;
    }
    return self;
}

- (BOOL)running { return _running; }

- (void)start {
    if (_running) return;
    _running = YES;

    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (st == AVAuthorizationStatusAuthorized) {
        [self startSession];
    } else if (st == AVAuthorizationStatusNotDetermined) {
        __weak JamHandTracker* weakSelf = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                JamHandTracker* s = weakSelf;
                if (!s || !s->_running) return;
                if (granted) [s startSession];
                else [s failWithReason:@"camera access denied"];
            });
        }];
    } else {
        [self failWithReason:@"camera access denied — enable it in System Settings › Privacy › Camera"];
    }
}

- (void)startSession {
    AVCaptureDevice* device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (!device) { [self failWithReason:@"no camera found"]; return; }

    NSError* err = nil;
    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
    if (!input) {
        [self failWithReason:err.localizedDescription ?: @"camera unavailable"];
        return;
    }

    AVCaptureSession* session = [[AVCaptureSession alloc] init];
    [session beginConfiguration];
    // Hand pose doesn't need resolution; a small frame keeps Vision cheap.
    if ([session canSetSessionPreset:AVCaptureSessionPreset640x480])
        session.sessionPreset = AVCaptureSessionPreset640x480;
    if (![session canAddInput:input]) {
        [session commitConfiguration];
        [self failWithReason:@"camera is in use by another app"];
        return;
    }
    [session addInput:input];

    AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
    [output setSampleBufferDelegate:self queue:_queue];
    if (![session canAddOutput:output]) {
        [session commitConfiguration];
        [self failWithReason:@"camera output unavailable"];
        return;
    }
    [session addOutput:output];
    [session commitConfiguration];

    _session = session;
    _haveSmooth = NO;
    _pinching = NO;
    _wasVisible = NO;
    // -startRunning blocks; keep it off the main thread.
    dispatch_async(_queue, ^{ [session startRunning]; });
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    AVCaptureSession* session = _session;
    _session = nil;
    if (session) dispatch_async(_queue, ^{ [session stopRunning]; });
}

- (void)failWithReason:(NSString*)reason {
    _running = NO;
    void (^handler)(NSString*) = self.failureHandler;
    if (!handler) return;
    if ([NSThread isMainThread]) handler(reason);
    else dispatch_async(dispatch_get_main_queue(), ^{ handler(reason); });
}

// ─── Frame processing (capture queue) ───────────────────────────────────────

static inline BOOL pointOK(VNRecognizedPoint* p) {
    return p != nil && p.confidence >= kMinConfidence;
}

- (void)captureOutput:(AVCaptureOutput*)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection*)connection {
    if (!_running) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixels) return;

    VNImageRequestHandler* handler =
        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixels
                                                 orientation:kCGImagePropertyOrientationUp
                                                     options:@{}];
    NSError* err = nil;
    if (![handler performRequests:@[ _request ] error:&err]) {
        [self pushVisible:NO x:0 y:0 pinch:NO];
        return;
    }

    VNHumanHandPoseObservation* hand = _request.results.firstObject;
    if (!hand) { [self pushVisible:NO x:0 y:0 pinch:NO]; return; }

    NSDictionary<VNHumanHandPoseObservationJointName, VNRecognizedPoint*>* joints =
        [hand recognizedPointsForJointsGroupName:VNHumanHandPoseObservationJointsGroupNameAll
                                           error:nil];
    VNRecognizedPoint* wrist     = joints[VNHumanHandPoseObservationJointNameWrist];
    VNRecognizedPoint* indexMCP  = joints[VNHumanHandPoseObservationJointNameIndexMCP];
    VNRecognizedPoint* middleMCP = joints[VNHumanHandPoseObservationJointNameMiddleMCP];
    VNRecognizedPoint* littleMCP = joints[VNHumanHandPoseObservationJointNameLittleMCP];
    VNRecognizedPoint* thumbTip  = joints[VNHumanHandPoseObservationJointNameThumbTip];
    VNRecognizedPoint* indexTip  = joints[VNHumanHandPoseObservationJointNameIndexTip];

    // Palm center: average of the trusted base joints.
    float px = 0, py = 0; int n = 0;
    for (VNRecognizedPoint* p in @[ wrist ?: (id)NSNull.null,
                                    indexMCP ?: (id)NSNull.null,
                                    middleMCP ?: (id)NSNull.null,
                                    littleMCP ?: (id)NSNull.null ]) {
        if (![p isKindOfClass:[VNRecognizedPoint class]] || !pointOK((VNRecognizedPoint*)p)) continue;
        px += ((VNRecognizedPoint*)p).location.x;
        py += ((VNRecognizedPoint*)p).location.y;
        n++;
    }
    if (n < 2) { [self pushVisible:NO x:0 y:0 pinch:NO]; return; }
    px /= n; py /= n;

    // Vision: origin bottom-left, unmirrored. UI wants selfie-mirrored, top-left.
    float uiX = 1.0f - px;
    float uiY = 1.0f - py;

    if (_haveSmooth) {
        _smoothX += (uiX - _smoothX) * kSmooth;
        _smoothY += (uiY - _smoothY) * kSmooth;
    } else {
        _smoothX = uiX; _smoothY = uiY; _haveSmooth = YES;
    }

    // Pinch: thumb-tip↔index-tip distance relative to hand size, so it works
    // at any distance from the camera. Hysteresis avoids flicker.
    if (pointOK(thumbTip) && pointOK(indexTip) && pointOK(wrist) && pointOK(middleMCP)) {
        const float dx = (float)(thumbTip.location.x - indexTip.location.x);
        const float dy = (float)(thumbTip.location.y - indexTip.location.y);
        const float hx = (float)(wrist.location.x - middleMCP.location.x);
        const float hy = (float)(wrist.location.y - middleMCP.location.y);
        const float handSize = std::sqrt(hx * hx + hy * hy);
        if (handSize > 1e-4f) {
            const float ratio = std::sqrt(dx * dx + dy * dy) / handSize;
            if (_pinching) { if (ratio > kPinchOff) _pinching = NO; }
            else           { if (ratio < kPinchOn)  _pinching = YES; }
        }
    } else if (_pinching && !(pointOK(thumbTip) && pointOK(indexTip))) {
        // Lost the fingertips mid-pinch: hold the grab rather than dropping it.
    }

    [self pushVisible:YES x:_smoothX y:_smoothY pinch:_pinching];
}

- (void)pushVisible:(BOOL)visible x:(float)x y:(float)y pinch:(BOOL)pinch {
    if (!visible) {
        _haveSmooth = NO;
        _pinching = NO;
        if (!_wasVisible) return;   // only announce the hand leaving once
    }
    _wasVisible = visible;
    JamHandPoseHandler handler = self.poseHandler;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(x, y, pinch, visible); });
}

@end
