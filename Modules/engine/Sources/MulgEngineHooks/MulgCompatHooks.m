//
//  MulgCompatHooks.m
//  engine module: general compatibility fixes ported from upstream NSObject+Swizzle.m.
//
//  - VSSubscriptionRegistrationCenter.setCurrentSubscription: does nothing on a Mac and some
//    games crash calling it (upstream always did this);
//  - Unreal Engine games crash in NSString's regular-expression replacement on empty strings
//    when the system encoding is Chinese (upstream: Unreal only, Chinese encodings only);
//  - checkMicPermissionSync: answer microphone permission requests at once when already
//    granted, for games that wait on the answer on the main thread.
//

#import "MulgEngineHooks.h"
#import <objc/message.h>
#include <TargetConditionals.h>
#include <stdatomic.h>
#include <time.h>

#if TARGET_OS_IPHONE
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <UIKit/UIKit.h>
#endif

typedef id (*ReplaceRegex)(id, SEL, NSString *, NSString *, NSRegularExpressionOptions, NSRange);
typedef void (*RequestPermission)(id, SEL, void (^)(BOOL));

static IMP previous_regex_replace;
static IMP previous_request_record_permission;
static IMP previous_begin_background_task;
static IMP previous_begin_named_background_task;
static IMP previous_end_background_task;
static NSMutableSet<NSNumber *> *background_tasks;
static NSUInteger ending_background_tasks;
// A partial install can miss already-running tasks; later retries cannot recover that history.
static atomic_int background_tracking_state; // 0 = not attempted, 1 = complete, -1 = incomplete

/// Mulg's own lock for the task set. `@synchronized ([NSProcessInfo class])` shared its lock with any
/// code synchronizing on Foundation's class object, on a path every background task passes.
static id background_tasks_lock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

BOOL mulg_engine_background_tracking_available(void) {
    return atomic_load(&background_tracking_state) == 1;
}

NSUInteger mulg_engine_background_task_count(void) {
    @synchronized (background_tasks_lock()) { return background_tasks.count + ending_background_tasks; }
}

#if TARGET_OS_IPHONE
typedef UIBackgroundTaskIdentifier (*BeginTask)(id, SEL, void (^)(void));
typedef UIBackgroundTaskIdentifier (*BeginNamedTask)(id, SEL, NSString *, void (^)(void));
typedef void (*EndTask)(id, SEL, UIBackgroundTaskIdentifier);

static void remember_task(UIBackgroundTaskIdentifier task) {
    if (task == UIBackgroundTaskInvalid) return;
    @synchronized (background_tasks_lock()) {
        if (!background_tasks) background_tasks = [NSMutableSet set];
        [background_tasks addObject:@(task)];
    }
}

static UIBackgroundTaskIdentifier mulg_begin_task(id self, SEL cmd, void (^handler)(void)) {
    UIBackgroundTaskIdentifier task = ((BeginTask)previous_begin_background_task)(self, cmd, handler);
    remember_task(task);
    return task;
}

static UIBackgroundTaskIdentifier mulg_begin_named_task(id self, SEL cmd, NSString *name, void (^handler)(void)) {
    UIBackgroundTaskIdentifier task = ((BeginNamedTask)previous_begin_named_background_task)(self, cmd, name, handler);
    remember_task(task);
    return task;
}

static void mulg_end_task(id self, SEL cmd, UIBackgroundTaskIdentifier task) {
    BOOL tracked;
    @synchronized (background_tasks_lock()) {
        tracked = [background_tasks containsObject:@(task)];
        [background_tasks removeObject:@(task)];
        if (tracked) ending_background_tasks++;
    }
    // Native completion may synchronously start another task or let another thread
    // reuse this identifier. Remove the old task before that new task is registered.
    // Keep shutdown conservative until native cleanup returns, without retaining
    // the identifier: a new task can reuse it during this native call.
    @try { ((EndTask)previous_end_background_task)(self, cmd, task); }
    @finally {
        if (tracked) { @synchronized (background_tasks_lock()) { ending_background_tasks--; } }
    }
}
#endif

static void mulg_set_current_subscription(id self, SEL _cmd, id subscription) {
    // Intentionally empty.
}

static id mulg_regex_replace(NSString *self, SEL _cmd, NSString *pattern, NSString *template,
                             NSRegularExpressionOptions options, NSRange range) {
    if (self.length == 0) {
        return @"";
    }
    return ((ReplaceRegex)previous_regex_replace)(self, _cmd, pattern, template, options, range);
}

#if TARGET_OS_IPHONE
// A Mac without any audio input (a Mac mini with a DAC, no microphone) gives the game a
// 0-channel input: voice-chat engines then fail to start and retry, and some games wait on them
// forever (Ragnarok: The New World sat on its loading screen, 2026-10-09). An iPad always has a
// microphone, so games never see that; they do handle the iOS answer "permission denied".
// While the Mac has no input, game callers get that answer; with a microphone, nothing changes.
static atomic_bool mic_permission_sync;
static IMP previous_record_permission;
static IMP previous_app_record_permission;
static IMP previous_app_request_permission;
static IMP previous_capture_status;
static IMP previous_capture_request;

/// Core Audio is asked at most once a second: voice SDKs poll the permission (some every frame),
/// and each answer is a round trip to the audio daemon on the game's thread. A plugged-in
/// microphone is still noticed within a second.
static BOOL audio_input_missing_now(void);
BOOL mulg_engine_audio_input_missing(void) {
    static _Atomic(uint64_t) checked_at;
    static atomic_bool missing;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    uint64_t at = atomic_load_explicit(&checked_at, memory_order_acquire);
    if (at != 0 && now - at < 1000000000ULL) return atomic_load_explicit(&missing, memory_order_relaxed);
    BOOL answer = audio_input_missing_now();
    atomic_store_explicit(&missing, answer, memory_order_relaxed);
    atomic_store_explicit(&checked_at, now, memory_order_release);
    return answer;
}

static BOOL audio_input_missing_now(void) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) return NO;
    if (device == kAudioObjectUnknown) return YES;
    AudioObjectPropertyAddress streams = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain };
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &bytes) != noErr) return NO;
    return bytes == 0;
}

// What the game may use (PrivacySettings): bits 1 microphone, 2 camera, 4 photos, 8 location.
static atomic_int privacy_allowed;

void mulg_engine_configure_privacy(BOOL microphone, BOOL camera, BOOL photos, BOOL location) {
    atomic_store(&privacy_allowed, (microphone ? 1 : 0) | (camera ? 2 : 0) | (photos ? 4 : 0) | (location ? 8 : 0));
}

static BOOL denied(const void *caller, int bit) {
    return mulg_engine_is_game_caller(caller) && !(atomic_load(&privacy_allowed) & bit);
}

static BOOL deny_microphone(const void *caller) {
    return mulg_engine_is_game_caller(caller) && (!(atomic_load(&privacy_allowed) & 1) || mulg_engine_audio_input_missing());
}

/// A denied request answers as iOS does: later, on another queue. Answering inside the call
/// deadlocks a game that requests while holding a lock its handler takes, or waits on the main
/// thread for the answer.
static void answer_denied(void (^response)(BOOL)) {
    if (!response) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ response(NO); });
}
static void answer_denied_status(void (^handler)(NSInteger)) {
    if (!handler) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ handler(2); });
}

static void mulg_request_record_permission(id self, SEL _cmd, void (^response)(BOOL)) {
    if (deny_microphone(__builtin_return_address(0))) { answer_denied(response); return; }
    if (atomic_load(&mic_permission_sync)
        && AVAudioSession.sharedInstance.recordPermission == AVAudioSessionRecordPermissionGranted) {
        response(YES);
        return;
    }
    ((RequestPermission)previous_request_record_permission)(self, _cmd, response);
}

static NSUInteger mulg_record_permission(id self, SEL _cmd) {
    if (deny_microphone(__builtin_return_address(0))) return AVAudioSessionRecordPermissionDenied;
    return ((NSUInteger (*)(id, SEL))previous_record_permission)(self, _cmd);
}

// AVAudioApplication (iOS 17): the same answers through the newer API. 0x64656e79 = 'deny'.
static NSInteger mulg_app_record_permission(id self, SEL _cmd) {
    if (deny_microphone(__builtin_return_address(0))) return 0x64656e79;
    return ((NSInteger (*)(id, SEL))previous_app_record_permission)(self, _cmd);
}

static void mulg_app_request_permission(id self, SEL _cmd, void (^response)(BOOL)) {
    if (deny_microphone(__builtin_return_address(0))) { answer_denied(response); return; }
    ((void (*)(id, SEL, void (^)(BOOL)))previous_app_request_permission)(self, _cmd, response);
}

static NSInteger mulg_capture_status(id self, SEL _cmd, NSString *media) {
    const void *caller = __builtin_return_address(0);
    if ([media isEqualToString:AVMediaTypeAudio] && deny_microphone(caller)) return AVAuthorizationStatusDenied;
    if ([media isEqualToString:AVMediaTypeVideo] && denied(caller, 2)) return AVAuthorizationStatusDenied;
    return ((NSInteger (*)(id, SEL, NSString *))previous_capture_status)(self, _cmd, media);
}

static void mulg_capture_request(id self, SEL _cmd, NSString *media, void (^response)(BOOL)) {
    const void *caller = __builtin_return_address(0);
    if (([media isEqualToString:AVMediaTypeAudio] && deny_microphone(caller))
        || ([media isEqualToString:AVMediaTypeVideo] && denied(caller, 2))) { answer_denied(response); return; }
    ((void (*)(id, SEL, NSString *, void (^)(BOOL)))previous_capture_request)(self, _cmd, media, response);
}
// Photos (PHPhotoLibrary) and location (CLLocationManager): 2 = denied for both enums.
static IMP previous_photo_status, previous_photo_level_status, previous_photo_request, previous_photo_level_request;
static IMP previous_location_class_status, previous_location_status, previous_location_when_in_use, previous_location_always;

static NSInteger mulg_photo_status(id self, SEL _cmd) {
    if (denied(__builtin_return_address(0), 4)) return 2;
    return ((NSInteger (*)(id, SEL))previous_photo_status)(self, _cmd);
}
static NSInteger mulg_photo_level_status(id self, SEL _cmd, NSInteger level) {
    if (denied(__builtin_return_address(0), 4)) return 2;
    return ((NSInteger (*)(id, SEL, NSInteger))previous_photo_level_status)(self, _cmd, level);
}
static void mulg_photo_request(id self, SEL _cmd, void (^handler)(NSInteger)) {
    if (denied(__builtin_return_address(0), 4)) { answer_denied_status(handler); return; }
    ((void (*)(id, SEL, void (^)(NSInteger)))previous_photo_request)(self, _cmd, handler);
}
static void mulg_photo_level_request(id self, SEL _cmd, NSInteger level, void (^handler)(NSInteger)) {
    if (denied(__builtin_return_address(0), 4)) { answer_denied_status(handler); return; }
    ((void (*)(id, SEL, NSInteger, void (^)(NSInteger)))previous_photo_level_request)(self, _cmd, level, handler);
}

static int mulg_location_class_status(id self, SEL _cmd) {
    if (denied(__builtin_return_address(0), 8)) return 2;
    return ((int (*)(id, SEL))previous_location_class_status)(self, _cmd);
}
static int mulg_location_status(id self, SEL _cmd) {
    if (denied(__builtin_return_address(0), 8)) return 2;
    return ((int (*)(id, SEL))previous_location_status)(self, _cmd);
}
/// A denied request still answers the delegate, as iOS does, so a game waiting for it goes on.
static void tell_location_delegate(id manager) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id delegate = [manager valueForKey:@"delegate"];
        SEL modern = NSSelectorFromString(@"locationManagerDidChangeAuthorization:");
        SEL legacy = NSSelectorFromString(@"locationManager:didChangeAuthorizationStatus:");
        if ([delegate respondsToSelector:modern]) ((void (*)(id, SEL, id))objc_msgSend)(delegate, modern, manager);
        else if ([delegate respondsToSelector:legacy]) ((void (*)(id, SEL, id, int))objc_msgSend)(delegate, legacy, manager, 2);
    });
}
static void mulg_location_when_in_use(id self, SEL _cmd) {
    if (denied(__builtin_return_address(0), 8)) { tell_location_delegate(self); return; }
    ((void (*)(id, SEL))previous_location_when_in_use)(self, _cmd);
}
static void mulg_location_always(id self, SEL _cmd) {
    if (denied(__builtin_return_address(0), 8)) { tell_location_delegate(self); return; }
    ((void (*)(id, SEL))previous_location_always)(self, _cmd);
}
#else
BOOL mulg_engine_audio_input_missing(void) { return NO; }
#endif
#if !TARGET_OS_IPHONE
void mulg_engine_configure_privacy(BOOL microphone, BOOL camera, BOOL photos, BOOL location) {}
#endif

MulgEngineCompatHook mulg_engine_install_compat_hooks(BOOL unrealEngine, BOOL micPermissionSync) {
    MulgEngineCompatHook installed = 0;
    if (mulg_swizzle_instance_named_owned("engine", "VSSubscriptionRegistrationCenter", @selector(setCurrentSubscription:),
                                         (IMP)mulg_set_current_subscription, NULL) == MulgSwizzleResultReplaced)
        installed |= MulgEngineCompatHookSubscription;
    if (unrealEngine) {
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL selector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            if (mulg_swizzle_instance_owned("engine", objc_lookUpClass("NSString"), selector, (IMP)mulg_regex_replace,
                                           &previous_regex_replace) == MulgSwizzleResultReplaced)
                installed |= MulgEngineCompatHookRegex;
        }
    }
#if TARGET_OS_IPHONE
    // Always installed: it answers "denied" while the Mac has no audio input, and answers at once
    // when permission is already granted only if the game asks for that (micPermissionSync).
    atomic_store(&mic_permission_sync, micPermissionSync);
    // Objective-C messages such as +class trigger +initialize. AVCaptureDevice's
    // initializer discovers camera extensions with synchronous XPC, which can block
    // while dyld still owns the loader lock. Install metadata-only hooks now;
    // the system initializes these classes when the game actually uses them.
    // ARC retains of a Class can also send messages and invoke +initialize.
    // Runtime-registered classes stay alive without strong local ownership.
    __unsafe_unretained Class audioSession = objc_lookUpClass("AVAudioSession");
    __unsafe_unretained Class captureDevice = objc_lookUpClass("AVCaptureDevice");
    __unsafe_unretained Class uiApplication = objc_lookUpClass("UIApplication");
    if (mulg_swizzle_instance_owned("engine", audioSession, @selector(requestRecordPermission:),
                                   (IMP)mulg_request_record_permission,
                                   &previous_request_record_permission) == MulgSwizzleResultReplaced)
        installed |= MulgEngineCompatHookMicrophone;
    BOOL missingInput = mulg_swizzle_instance_owned("engine", audioSession, @selector(recordPermission),
                                                   (IMP)mulg_record_permission, &previous_record_permission) == MulgSwizzleResultReplaced;
    __unsafe_unretained Class application = objc_lookUpClass("AVAudioApplication");
    if (application) {
        mulg_swizzle_instance_owned("engine", application, @selector(recordPermission),
                                    (IMP)mulg_app_record_permission, &previous_app_record_permission);
        mulg_swizzle_class_owned("engine", application, NSSelectorFromString(@"requestRecordPermissionWithCompletionHandler:"),
                                 (IMP)mulg_app_request_permission, &previous_app_request_permission);
    }
    mulg_swizzle_class_owned("engine", captureDevice, @selector(authorizationStatusForMediaType:),
                             (IMP)mulg_capture_status, &previous_capture_status);
    mulg_swizzle_class_owned("engine", captureDevice, @selector(requestAccessForMediaType:completionHandler:),
                             (IMP)mulg_capture_request, &previous_capture_request);
    if (missingInput) installed |= MulgEngineCompatHookMissingMicrophone;
    // Photos and location load with their frameworks; imagesChanged installs these later if needed.
    __unsafe_unretained Class photos = objc_lookUpClass("PHPhotoLibrary");
    __unsafe_unretained Class location = objc_lookUpClass("CLLocationManager");
    BOOL privacy = NO;
    if (photos) {
        privacy |= mulg_swizzle_class_owned("engine", photos, @selector(authorizationStatus), (IMP)mulg_photo_status, &previous_photo_status) == MulgSwizzleResultReplaced;
        mulg_swizzle_class_owned("engine", photos, NSSelectorFromString(@"authorizationStatusForAccessLevel:"), (IMP)mulg_photo_level_status, &previous_photo_level_status);
        mulg_swizzle_class_owned("engine", photos, NSSelectorFromString(@"requestAuthorization:"), (IMP)mulg_photo_request, &previous_photo_request);
        mulg_swizzle_class_owned("engine", photos, NSSelectorFromString(@"requestAuthorizationForAccessLevel:handler:"), (IMP)mulg_photo_level_request, &previous_photo_level_request);
    }
    if (location) {
        privacy |= mulg_swizzle_class_owned("engine", location, @selector(authorizationStatus), (IMP)mulg_location_class_status, &previous_location_class_status) == MulgSwizzleResultReplaced;
        mulg_swizzle_instance_owned("engine", location, @selector(authorizationStatus), (IMP)mulg_location_status, &previous_location_status);
        mulg_swizzle_instance_owned("engine", location, NSSelectorFromString(@"requestWhenInUseAuthorization"), (IMP)mulg_location_when_in_use, &previous_location_when_in_use);
        mulg_swizzle_instance_owned("engine", location, NSSelectorFromString(@"requestAlwaysAuthorization"), (IMP)mulg_location_always, &previous_location_always);
    }
    if (privacy) installed |= MulgEngineCompatHookPrivacy;
    BOOL began = mulg_swizzle_instance_owned("engine", uiApplication, @selector(beginBackgroundTaskWithExpirationHandler:),
                                            (IMP)mulg_begin_task, &previous_begin_background_task) == MulgSwizzleResultReplaced;
    BOOL named = mulg_swizzle_instance_owned("engine", uiApplication, @selector(beginBackgroundTaskWithName:expirationHandler:),
                                            (IMP)mulg_begin_named_task, &previous_begin_named_background_task) == MulgSwizzleResultReplaced;
    BOOL ended = mulg_swizzle_instance_owned("engine", uiApplication, @selector(endBackgroundTask:),
                                            (IMP)mulg_end_task, &previous_end_background_task) == MulgSwizzleResultReplaced;
    if (began && named && ended) installed |= MulgEngineCompatHookBackgroundTasks;
    if (!(began && named && ended)) {
        atomic_store(&background_tracking_state, -1);
    } else {
        int initial = 0;
        atomic_compare_exchange_strong(&background_tracking_state, &initial, 1);
    }
#endif
    return installed;
}
