//
//  MulgDeviceStateHooks.m
//  identity module: battery and volume, as a device reports them (upstream BatteryLevel.m and
//  MediaVolume.m).
//
//  Upstream added its replacement methods to NSObject through a category, so every object in
//  the game gained pm_* methods, and installed them from +load whether the identity was
//  wanted or not. Here the replacement implementations go straight onto the target classes,
//  once, from the identity module.
//

#import "MulgIdentityHooks.h"
#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>

const float mulg_identity_reported_volume = 0.3f;

// MARK: - Battery

static BOOL mulg_battery_monitoring(id self, SEL _cmd) {
    return YES;
}

static NSInteger mulg_battery_state(id self, SEL _cmd) {
    return 3; // UIDeviceBatteryStateFull
}

static float mulg_battery_level(id self, SEL _cmd) {
    return 1.0f;
}

int mulg_identity_install_battery_hooks(void) {
#if TARGET_OS_IPHONE
    static int installed = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class device = NSClassFromString(@"UIDevice");
        int count = 0;
        count += mulg_swizzle_instance_owned("identity", device, NSSelectorFromString(@"isBatteryMonitoringEnabled"),
                                       (IMP)mulg_battery_monitoring, NULL) == MulgSwizzleResultReplaced;
        count += mulg_swizzle_instance_owned("identity", device, NSSelectorFromString(@"batteryState"),
                                       (IMP)mulg_battery_state, NULL) == MulgSwizzleResultReplaced;
        count += mulg_swizzle_instance_owned("identity", device, NSSelectorFromString(@"batteryLevel"),
                                       (IMP)mulg_battery_level, NULL) == MulgSwizzleResultReplaced;
        installed = count;
    });
    return installed;
#else
    return 0;
#endif
}

// MARK: - Volume

static float mulg_volume(id self, SEL _cmd) {
    return mulg_identity_reported_volume;
}

static void mulg_set_volume(id self, SEL _cmd, float value) {
    // The game may not change the Mac's volume.
}

static void mulg_set_volume_animated(id self, SEL _cmd, float value, BOOL animated) {
}

typedef struct {
    const char *className;
    const char *selector;
    IMP replacement;
    BOOL installed;
} MulgVolumeHook;

static MulgVolumeHook volume_hooks[] = {
    { "AVAudioSession", "outputVolume", (IMP)mulg_volume, NO },
    { "MPVolumeSlider", "value", (IMP)mulg_volume, NO },
    { "MPVolumeSlider", "setValue:", (IMP)mulg_set_volume, NO },
    { "MPVolumeSlider", "setValue:animated:", (IMP)mulg_set_volume_animated, NO },
    { "MPMusicPlayerController", "volume", (IMP)mulg_volume, NO },
    { "MPMusicPlayerController", "setVolume:", (IMP)mulg_set_volume, NO },
};

int mulg_identity_install_volume_hooks(void) {
    // Called from the main thread only (prepare, then again once the scene is active).
    int count = 0;
    for (size_t index = 0; index < sizeof(volume_hooks) / sizeof(volume_hooks[0]); index++) {
        MulgVolumeHook *hook = &volume_hooks[index];
        if (!hook->installed) {
            Class cls = objc_getClass(hook->className);
            hook->installed = cls != Nil
                && mulg_swizzle_instance_owned("identity", cls, sel_registerName(hook->selector), hook->replacement, NULL)
                       == MulgSwizzleResultReplaced;
        }
        count += hook->installed ? 1 : 0;
    }
    return count;
}

// MARK: - Compatibility answers (the compatibility part of upstream's device-compatibility file)
//
// Answers for APIs that don't work for an iOS app on a Mac, always on as upstream had them.
// Upstream's jailbreak-detection bypass is in MulgJailbreakBypassHooks.m, per game.

static void mulg_request_tracking(id self, SEL _cmd, void (^completion)(NSUInteger)) {
    // ATTrackingManagerAuthorizationStatusDenied without showing the prompt (it can hang on a Mac, and
    // "denied" is what a player who never sees it would want). Answered later on another queue, as iOS
    // does: answering inside the call deadlocked a game that requests while holding a lock its handler
    // takes, or that waits on the main thread for the answer (the engine's permission answers do the same).
    if (completion != nil) {
        void (^handler)(NSUInteger) = [completion copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ handler(2); });
    }
}

static NSUInteger mulg_tracking_status(id self, SEL _cmd) {
    return 2;
}

static BOOL mulg_return_no(id self, SEL _cmd) {
    return NO;
}

int mulg_identity_install_compat_answers(void) {
    // Main thread only; called at prepare and again once the scene is active, for frameworks
    // the game loads late.
    static BOOL tracking = NO;
    static BOOL trackingStatus = NO;
    static BOOL ageRange = NO;
    Class trackingManager = objc_getClass("ATTrackingManager");
    if (!tracking && trackingManager != Nil) {
        tracking = mulg_swizzle_class_owned("identity", trackingManager, NSSelectorFromString(@"requestTrackingAuthorizationWithCompletionHandler:"),
                                      (IMP)mulg_request_tracking, NULL) == MulgSwizzleResultReplaced;
    }
    if (!trackingStatus && trackingManager != Nil) {
        trackingStatus = mulg_swizzle_class_owned("identity", trackingManager, NSSelectorFromString(@"trackingAuthorizationStatus"),
                                            (IMP)mulg_tracking_status, NULL) == MulgSwizzleResultReplaced;
    }
    // Wuthering Waves asks for the declared age range, which a Mac can't provide; the game
    // then waits forever.
    Class ageRangeService = objc_getClass("KRDeclaredAgeRangeService");
    if (!ageRange && ageRangeService != Nil) {
        ageRange = mulg_swizzle_instance_owned("identity", ageRangeService, NSSelectorFromString(@"isAgeRangeRequestAvailable"),
                                         (IMP)mulg_return_no, NULL) == MulgSwizzleResultReplaced;
    }
    return (tracking ? 1 : 0) + (trackingStatus ? 1 : 0) + (ageRange ? 1 : 0);
}
