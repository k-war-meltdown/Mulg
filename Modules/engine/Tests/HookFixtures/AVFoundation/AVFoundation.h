#pragma once
// Minimal AVFoundation declarations for the native compatibility-hook fixtures.
#import <Foundation/Foundation.h>
static const NSInteger AVAudioSessionRecordPermissionGranted = 1;
static const NSInteger AVAudioSessionRecordPermissionDenied = 2;
static const NSInteger AVAuthorizationStatusDenied = 2;
static NSString *const AVMediaTypeAudio = @"audio";
static NSString *const AVMediaTypeVideo = @"video";
@interface AVAudioSession : NSObject
+ (instancetype)sharedInstance;
@property(nonatomic, readonly) NSInteger recordPermission;
- (void)requestRecordPermission:(void (^)(BOOL))response;
@end
@interface AVCaptureDevice : NSObject
+ (NSInteger)authorizationStatusForMediaType:(NSString *)media;
+ (void)requestAccessForMediaType:(NSString *)media completionHandler:(void (^)(BOOL))response;
@end
