#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>
#include <assert.h>
#include <string.h>
#define UIApplication FixtureApplication
#define AVAudioSession FixtureAudioSession
#import "UIKit/UIKit.h"
#import "AVFoundation/AVFoundation.h"

static BOOL recycleIdentifier;
@implementation UIApplication
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler { return 1; }
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler { return 2; }
- (void)endBackgroundTask:(UIBackgroundTaskIdentifier)task {
    if (recycleIdentifier && task == 1) {
        recycleIdentifier = NO;
        [self beginBackgroundTaskWithExpirationHandler:^{}];
    }
}
@end
@implementation AVAudioSession
+ (instancetype)sharedInstance { return [self new]; }
- (NSInteger)recordPermission { return AVAudioSessionRecordPermissionGranted; }
- (void)requestRecordPermission:(void (^)(BOOL))response { response(YES); }
@end

static SEL rejected;
MulgSwizzleResult mulg_swizzle_instance_owned(const char *owner, Class cls, SEL selector, IMP replacement, IMP *previous) {
    if (selector == rejected) return MulgSwizzleResultConflict;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return MulgSwizzleResultMethodMissing;
    if (method_getImplementation(method) != replacement) {
        if (previous) *previous = method_getImplementation(method);
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    }
    return MulgSwizzleResultReplaced;
}
MulgSwizzleResult mulg_swizzle_instance_named_owned(const char *owner, const char *name, SEL selector, IMP replacement, IMP *previous) {
    return mulg_swizzle_instance_owned(owner, objc_getClass(name), selector, replacement, previous);
}
MulgSwizzleResult mulg_swizzle_class_owned(const char *owner, Class cls, SEL selector, IMP replacement, IMP *previous) {
    return mulg_swizzle_instance_owned(owner, cls ? object_getClass(cls) : Nil, selector, replacement, previous);
}
BOOL mulg_engine_is_game_caller(const void *caller) { return NO; }

#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
static const void *fixture_class(const char *name) {
    if (strcmp(name, "AVAudioSession") == 0) name = "FixtureAudioSession";
    if (strcmp(name, "UIApplication") == 0) name = "FixtureApplication";
    return (__bridge const void *)objc_lookUpClass(name);
}
#define objc_lookUpClass(name) ((__bridge Class)fixture_class(name))
#include "../../Sources/MulgEngineHooks/MulgCompatHooks.m"

int main(int argc, const char **argv) {
    @autoreleasepool {
        rejected = argc > 1 ? NSSelectorFromString(@(argv[1])) : NULL;
        MulgEngineCompatHook hooks = mulg_engine_install_compat_hooks(NO, NO);
        assert(mulg_engine_background_tracking_available() == (rejected == NULL));
        assert(!!(hooks & MulgEngineCompatHookBackgroundTasks) == (rejected == NULL));
        UIApplication *app = [UIApplication new];
        NSUInteger first = [app beginBackgroundTaskWithExpirationHandler:^{}];
        NSUInteger second = [app beginBackgroundTaskWithName:@"sync" expirationHandler:^{}];
        assert(mulg_engine_background_task_count() == (rejected == @selector(beginBackgroundTaskWithExpirationHandler:)
            || rejected == @selector(beginBackgroundTaskWithName:expirationHandler:) ? 1 : 2));
        [app endBackgroundTask:first]; [app endBackgroundTask:second];
        if (rejected != @selector(endBackgroundTask:)) assert(mulg_engine_background_task_count() == 0);
        rejected = NULL;
        assert(mulg_engine_install_compat_hooks(NO, NO) & MulgEngineCompatHookBackgroundTasks);
        assert(mulg_engine_background_tracking_available() == (argc == 1));
        [app endBackgroundTask:first]; [app endBackgroundTask:second];
        assert(mulg_engine_background_task_count() == 0);
        [app beginBackgroundTaskWithExpirationHandler:^{}];
        recycleIdentifier = YES;
        [app endBackgroundTask:1];
        assert(mulg_engine_background_task_count() == 1); // The new task with the reused ID remains live.
        [app endBackgroundTask:1];
        assert(mulg_engine_background_task_count() == 0);
        puts("PASS: partial background tracking remains conservative after retries that cannot recover old tasks");
    }
}
