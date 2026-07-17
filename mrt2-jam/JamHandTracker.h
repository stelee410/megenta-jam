// Camera hand tracking for gesture control of the mix surfaces.
// AVFoundation capture + Vision hand-pose detection, entirely on a private
// background queue — never touches the audio graph or render thread.
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pose sample, delivered on the main queue at camera rate (~30 Hz) while a
/// hand is visible. Coordinates are normalized [0,1], mirrored (selfie-style)
/// with a top-left origin so they map 1:1 onto UI surfaces.
typedef void (^JamHandPoseHandler)(float x, float y, BOOL pinching, BOOL visible);

@interface JamHandTracker : NSObject

/// Pose callback (main queue). When the hand leaves the frame this fires once
/// with visible == NO, then stays quiet until the hand reappears.
@property (nonatomic, copy, nullable) JamHandPoseHandler poseHandler;

/// Fires once on the main queue if capture can't start (permission denied,
/// no camera). The string is a short user-facing reason.
@property (nonatomic, copy, nullable) void (^failureHandler)(NSString *reason);

@property (nonatomic, readonly) BOOL running;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
