#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>
#include <assert.h>
#include <string.h>
#define AVAudioSession FixtureAudioSession
#define AVCaptureDevice FixtureCaptureDevice
#define UIApplication FixtureApplication
#import "UIKit/UIKit.h"
#import "AVFoundation/AVFoundation.h"

static int audioInitialized, captureInitialized, applicationInitialized;
static BOOL gameCaller;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }

@implementation AVAudioSession
+ (void)initialize { audioInitialized++; }
+ (instancetype)sharedInstance { return [self new]; }
- (NSInteger)recordPermission { return AVAudioSessionRecordPermissionGranted; }
- (void)requestRecordPermission:(void (^)(BOOL))response { response(YES); }
@end
@implementation AVCaptureDevice
+ (void)initialize { captureInitialized++; }
+ (NSInteger)authorizationStatusForMediaType:(NSString *)media { return 3; }
+ (void)requestAccessForMediaType:(NSString *)media completionHandler:(void (^)(BOOL))response { response(YES); }
@end
@implementation UIApplication
+ (void)initialize { applicationInitialized++; }
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler { return 1; }
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler { return 2; }
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)task {}
@end

#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
// CoreAudio loads a native AudioSession class even in a macOS fixture. Substitute
// just the metadata lookup, using distinct fake classes so registration never clashes.
static const void *fixture_class(const char *name) {
    if (strcmp(name, "AVAudioSession") == 0) name = "FixtureAudioSession";
    if (strcmp(name, "AVCaptureDevice") == 0) name = "FixtureCaptureDevice";
    if (strcmp(name, "UIApplication") == 0) name = "FixtureApplication";
    return (__bridge const void *)objc_lookUpClass(name);
}
#define objc_lookUpClass(name) ((__bridge Class)fixture_class(name))
#include "../../Sources/MulgEngineHooks/MulgCompatHooks.m"

int main(void) {
    @autoreleasepool {
        MulgEngineCompatHook hooks = mulg_engine_install_compat_hooks(NO, NO);
        assert(hooks & MulgEngineCompatHookMicrophone);
        assert(hooks & MulgEngineCompatHookBackgroundTasks);
        assert(audioInitialized == 0 && captureInitialized == 0 && applicationInitialized == 0);
        mulg_engine_install_compat_hooks(NO, NO);
        assert(audioInitialized == 0 && captureInitialized == 0 && applicationInitialized == 0);
        // Hook installation preserves native initialization and permission answers.
        gameCaller = NO;
        assert([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == 3);
        assert(captureInitialized == 1);
        assert([AVAudioSession sharedInstance].recordPermission == AVAudioSessionRecordPermissionGranted);
        assert(audioInitialized == 1);
        // Game-only denied privacy still takes effect; no permission is widened.
        mulg_engine_configure_privacy(NO, NO, NO, NO);
        gameCaller = YES;
        assert([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusDenied);
        assert([AVAudioSession sharedInstance].recordPermission == AVAudioSessionRecordPermissionDenied);
        dispatch_semaphore_t replied = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL allowed) {
            assert(!allowed); dispatch_semaphore_signal(replied);
        }];
        assert(dispatch_semaphore_wait(replied, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0);
        gameCaller = NO;
        UIApplication *application = [UIApplication new];
        UIBackgroundTaskIdentifier task = [application beginBackgroundTaskWithExpirationHandler:^{}];
        assert(applicationInitialized == 1 && mulg_engine_background_task_count() == 1);
        [application endBackgroundTask:task];
        assert(mulg_engine_background_task_count() == 0);
        puts("PASS: constructor privacy hooks avoid device initialization and preserve permission/background behavior");
    }
}
