#import "MulgEngineHooks.h"
#import <objc/message.h>
#include <pthread.h>
#include <stdatomic.h>

static char kLifecycleState;
static void (^layout_handler)(id);
static _Atomic(_Bool) keep_active;

void mulg_engine_set_keep_active(BOOL enabled) {
    atomic_store_explicit(&keep_active, enabled, memory_order_release);
}

BOOL mulg_engine_keeps_game_active(void) {
    return atomic_load_explicit(&keep_active, memory_order_acquire);
}

// The state is an atomic associated object: reading it retains what it returns, so a reader never sees a
// value released by a concurrent write. `@synchronized (UIApplication/UIScene)` did that before, sharing its
// lock with any code that synchronizes on UIKit's own objects, on a getter games call every frame.
void mulg_engine_set_lifecycle_state(id object, NSInteger state) {
    objc_setAssociatedObject(object, &kLifecycleState, @(state), OBJC_ASSOCIATION_RETAIN);
}

void mulg_engine_clear_lifecycle_state(id object) {
    objc_setAssociatedObject(object, &kLifecycleState, nil, OBJC_ASSOCIATION_RETAIN);
}

NSInteger mulg_engine_effective_lifecycle_state(id object, SEL selector) {
    if (atomic_load_explicit(&keep_active, memory_order_acquire)) return 0;
    NSNumber *state = objc_getAssociatedObject(object, &kLifecycleState);
    return state ? state.integerValue : ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger lifecycle_state(id self, SEL selector) {
    if (mulg_engine_is_game_caller(__builtin_return_address(0))) {
        if (atomic_load_explicit(&keep_active, memory_order_acquire)) return 0;
        NSNumber *state = objc_getAssociatedObject(self, &kLifecycleState);
        if (state) return state.integerValue;
    }
    IMP original = mulg_swizzle_original(object_getClass(self), selector, (IMP)lifecycle_state);
    return ((NSInteger (*)(id, SEL))original)(self, selector);
}

static void view_layout(id self, SEL selector) {
    IMP original = mulg_swizzle_original(object_getClass(self), selector, (IMP)view_layout);
    ((void (*)(id, SEL))original)(self, selector);
    // UIKit layout is main-thread work. Never enter main-actor Swift from a game's worker.
    if (pthread_main_np() && layout_handler) layout_handler(self);
}

MulgEngineUIKitHook mulg_engine_install_uikit_hooks(void (^handler)(id)) {
    layout_handler = [handler copy]; // Startup/main thread only; reads above are also main only.
    MulgEngineUIKitHook installed = 0;
    if (mulg_swizzle_checked_owned("engine", objc_getClass("UIApplication"), sel_registerName("applicationState"),
        (IMP)lifecycle_state, NULL, @encode(NSInteger), @[]) == MulgSwizzleResultReplaced)
        installed |= MulgEngineUIKitHookApplicationState;
    if (mulg_swizzle_checked_owned("engine", objc_getClass("UIScene"), sel_registerName("activationState"),
        (IMP)lifecycle_state, NULL, @encode(NSInteger), @[]) == MulgSwizzleResultReplaced)
        installed |= MulgEngineUIKitHookSceneState;
    if (mulg_swizzle_checked_owned("engine", objc_getClass("UIView"), sel_registerName("layoutSubviews"),
        (IMP)view_layout, NULL, @encode(void), @[]) == MulgSwizzleResultReplaced)
        installed |= MulgEngineUIKitHookViewLayout;
    return installed;
}
