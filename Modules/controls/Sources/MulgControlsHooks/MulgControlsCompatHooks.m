//
//  MulgControlsCompatHooks.m
//  controls module: input compatibility fixes ported from upstream NSObject+Swizzle.m.
//
//  - disableBuiltinMouse: hide the Mac mouse from GCMouse, for games that switch to
//    mouse-and-keyboard mode and ignore keymapped touches when they see a mouse;
//  - limitMotionUpdateFrequency: a new CMMotionManager starts at 100 updates per second
//    instead of "as fast as possible", which wastes CPU;
//  - game-owned pointer locking is handled by MulgPointerLockHooks, independently of
//    touch injection and engine-specific controller names;
//  - ignoreUnityKeyboardInitializationError: Unity's KeyboardDelegate.Initialize can throw on
//    a Mac; the exception is caught and logged.
//

#import "MulgControlsHooks.h"
#import <objc/runtime.h>
#include <string.h>
#include <stdatomic.h>

BOOL mulg_controls_responder_is_editable(id responder) {
    // WKContentView exposes isEditable for its focused element, even with a hardware keyboard:
    // https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/ios/WKContentViewInteraction.mm
    SEL selector = sel_registerName("isEditable");
    Method method = class_getInstanceMethod(object_getClass(responder), selector);
    if (!method) return NO;
    const char *types = method_getTypeEncoding(method);
    if (types == NULL) return NO;
    // NSMethodSignature throws on encodings it cannot parse; uncaught, that ran into the game's key
    // handling (typing into a web login form, for one). An unreadable signature is "not editable".
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
        if (signature == nil || signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, @encode(BOOL)) != 0) return NO;
    } @catch (NSException *exception) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))method_getImplementation(method))(responder, selector);
}
#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>
#import <MulgEngineHooks.h>
#import <os/log.h>

typedef id (*ClassGetter)(id, SEL);
typedef id (*Initializer)(id, SEL);
typedef void (*ClassAction)(id, SEL);

static IMP previous_mouse_current;
static IMP previous_mouse_mice;
static IMP previous_keyboard_coalesced;
static BOOL hide_mice_policy;
static _Atomic(BOOL) isolate_touch_gameplay;
static IMP previous_motion_init;
static IMP previous_unity_keyboard_initialize;

static id mulg_mouse_current(id cls, SEL _cmd) {
    if (mulg_engine_is_game_caller(__builtin_return_address(0))) {
        id virtualMouse = mulg_controls_virtual_mouse_device();
        if (virtualMouse) return virtualMouse;
        if (hide_mice_policy || isolate_touch_gameplay) return nil;
    }
    return ((ClassGetter)previous_mouse_current)(cls, _cmd);
}

static id mulg_mouse_mice(id cls, SEL _cmd) {
    if (mulg_engine_is_game_caller(__builtin_return_address(0))) {
        id virtualMouse = mulg_controls_virtual_mouse_device();
        if (virtualMouse) return @[virtualMouse];
        if (hide_mice_policy || isolate_touch_gameplay) return @[];
    }
    return ((ClassGetter)previous_mouse_mice)(cls, _cmd);
}

static id mulg_keyboard_coalesced(id cls, SEL _cmd) {
    return isolate_touch_gameplay && mulg_engine_is_game_caller(__builtin_return_address(0)) ? nil
        : ((ClassGetter)previous_keyboard_coalesced)(cls, _cmd);
}

void mulg_controls_set_touch_isolation(BOOL enabled) { isolate_touch_gameplay = enabled; }

int mulg_controls_install_mouse_device_hooks(void) {
    Class mouse = objc_getClass("GCMouse");
    int count = 0;
    count += mulg_swizzle_checked_owned("controls", object_getClass(mouse), @selector(current),
        (IMP)mulg_mouse_current, &previous_mouse_current, "@", @[]) == MulgSwizzleResultReplaced;
    count += mulg_swizzle_checked_owned("controls", object_getClass(mouse), @selector(mice),
        (IMP)mulg_mouse_mice, &previous_mouse_mice, "@", @[]) == MulgSwizzleResultReplaced;
    return count;
}

int mulg_controls_install_touch_isolation(void) {
    int count = mulg_controls_install_mouse_device_hooks();
    Class keyboard = objc_getClass("GCKeyboard");
    count += mulg_swizzle_checked_owned("controls", object_getClass(keyboard), @selector(coalescedKeyboard),
        (IMP)mulg_keyboard_coalesced, &previous_keyboard_coalesced, "@", @[]) == MulgSwizzleResultReplaced;
    return count;
}

static id mulg_motion_manager_init(id self, SEL _cmd) {
    CMMotionManager *manager = ((Initializer)previous_motion_init)(self, _cmd);
    manager.accelerometerUpdateInterval = 0.01;
    manager.deviceMotionUpdateInterval = 0.01;
    manager.gyroUpdateInterval = 0.01;
    return manager;
}

static void mulg_unity_keyboard_initialize(id cls, SEL _cmd) {
    @try {
        ((ClassAction)previous_unity_keyboard_initialize)(cls, _cmd);
    } @catch (NSException *exception) {
        os_log(OS_LOG_DEFAULT, "[Mulg] Unity keyboard initialisation failed: %{public}@ %{public}@",
               exception.name, exception.reason);
    }
}

int mulg_controls_install_compat_hooks(BOOL hideMice, BOOL limitMotionRate) {
    int count = 0;
    if (hideMice) {
        hide_mice_policy = YES;
        count += mulg_controls_install_mouse_device_hooks();
    }
    if (limitMotionRate) {
        count += mulg_swizzle_instance_owned("controls", [CMMotionManager class], @selector(init),
                                       (IMP)mulg_motion_manager_init, &previous_motion_init) == MulgSwizzleResultReplaced;
    }
    return count;
}

static IMP previous_web_view_did_move_to_window;
static NSHashTable<UIView *> *tracked_web_views;  // main thread only

void mulg_controls_note_web_view(id view) {
    if (!tracked_web_views) tracked_web_views = [NSHashTable weakObjectsHashTable];
    [tracked_web_views addObject:view];
}

static void mulg_web_view_did_move_to_window(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))previous_web_view_did_move_to_window)(self, _cmd);
    if (self.window) mulg_controls_note_web_view(self);
    else [tracked_web_views removeObject:self];
}

int mulg_controls_track_web_views(void) {
    Class webView = objc_getClass("WKWebView");
    if (!webView) return 0;
    return mulg_swizzle_checked_owned("controls", webView, @selector(didMoveToWindow),
                                      (IMP)mulg_web_view_did_move_to_window, &previous_web_view_did_move_to_window,
                                      "v", @[]) == MulgSwizzleResultReplaced;
}

NSArray *mulg_controls_web_views(void) {
    NSMutableArray *views = [NSMutableArray array];
    for (UIView *view in tracked_web_views) {
        if (view.window) [views addObject:view];
    }
    return views;
}

int mulg_controls_install_unity_keyboard_fix(void) {
    // UnityFramework may load after the runtime starts; the caller retries a moment later.
    return mulg_swizzle_class_owned("controls", objc_getClass("KeyboardDelegate"), NSSelectorFromString(@"Initialize"),
                              (IMP)mulg_unity_keyboard_initialize, &previous_unity_keyboard_initialize)
           == MulgSwizzleResultReplaced;
}

#else

int mulg_controls_install_mouse_device_hooks(void) { return 0; }
int mulg_controls_install_touch_isolation(void) { return 0; }
void mulg_controls_set_touch_isolation(BOOL enabled) {}

int mulg_controls_install_compat_hooks(BOOL hideMice, BOOL limitMotionRate) {
    return 0;
}

int mulg_controls_install_unity_keyboard_fix(void) {
    return 0;
}

int mulg_controls_track_web_views(void) { return 0; }
void mulg_controls_note_web_view(id view) {}
NSArray *mulg_controls_web_views(void) { return @[]; }

#endif
