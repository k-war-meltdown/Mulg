//
//  MulgFrameRateHooks.m
//  display module: how fast the game may draw (PLAN.md §4.2, §6.1, §13.1).
//
//  - Uncap: a display link or MetalKit view asking for 60 FPS is raised to the display's
//    rate when the user turned "uncap frame rate" on. Several engines hard-set 60 unless they
//    detect ProMotion, and MTKView defaults to 60.
//  - Cap below refresh: "as fast as possible" becomes the target (for example 116 at 120 Hz),
//    which keeps the frame queue empty and the game inside the variable-refresh range.
//  - Background throttle: every live display link is capped at a low rate while the window is
//    hidden, then restored to what the game asked for.
//  - Just-in-time frame start: display-link callbacks go through a small target that lets the
//    engine wait before the game reads input for the next frame.
//
//  What the game asked for is remembered per display link, so the rules can change at run
//  time without losing the game's own request.
//

#import "MulgDisplayInternal.h"
#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <MulgEngineHooks.h>
#include <limits.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <stdatomic.h>
#include <string.h>

typedef void (*SetFrameRateRange)(id, SEL, CAFrameRateRange);
typedef void (*SetInteger)(id, SEL, NSInteger);
typedef id (*DisplayLinkFactory)(id, SEL, id, SEL);
typedef id (*InitWithFrameDevice)(id, SEL, CGRect, id);
typedef id (*InitWithCoder)(id, SEL, NSCoder *);

static IMP previous_set_range;
static IMP previous_set_fps;
static IMP previous_factory;
static IMP previous_mtk_set_fps;
static IMP previous_mtk_init_frame;
static IMP previous_mtk_init_coder;

static char kRequestedRangeKey;
static NSHashTable<CADisplayLink *> *mulg_links;
static NSHashTable *mulg_mtk_views;
static char kRequestedMTKRateKey;
static os_unfair_lock mulg_links_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic(int) mulg_throttle_fps = 0;

// MARK: - Remembering the game's request

// Requests are atomic associated objects: a game may set a rate on its render thread while the main
// thread reapplies every link (throttle, settings); a non-atomic read could get a value being released.

static void remember(CADisplayLink *link, CAFrameRateRange range) {
    NSValue *value = [NSValue valueWithBytes:&range objCType:@encode(CAFrameRateRange)];
    objc_setAssociatedObject(link, &kRequestedRangeKey, value, OBJC_ASSOCIATION_RETAIN);
}

static CAFrameRateRange requested(CADisplayLink *link) {
    NSValue *value = objc_getAssociatedObject(link, &kRequestedRangeKey);
    CAFrameRateRange range = CAFrameRateRangeDefault;
    if (value != nil) {
        [value getValue:&range size:sizeof(range)];
    }
    return range;
}

/// Set while this thread is inside the original setter, so that if one setter calls the
/// other internally, the inner call goes straight to the original instead of recursing.
static __thread int mulg_applying = 0;
static CAFrameRateRange effective(CADisplayLink *link);

static void apply(CADisplayLink *link, CAFrameRateRange range) {
    // A native setter may finish after a newer game request or visibility update.
    // Reconcile outside shared locks so the last native write cannot leave stale rules.
    while (true) {
        mulg_applying += 1;
        @try { ((SetFrameRateRange)previous_set_range)(link, @selector(setPreferredFrameRateRange:), range); }
        @finally { mulg_applying -= 1; }
        CAFrameRateRange latest = effective(link);
        if (CAFrameRateRangeIsEqualToRange(latest, range)) return;
        range = latest;
    }
}

/// What the link should run at now: the throttle while hidden, otherwise the game's request
/// with the uncap and cap rules applied.
static CAFrameRateRange effective(CADisplayLink *link) {
    int throttle = atomic_load(&mulg_throttle_fps);
    if (throttle > 0) {
        return CAFrameRateRangeMake(1, (float)throttle, (float)throttle);
    }
    return mulg_display_apply_rules(requested(link), mulg_display_current_config());
}

// MARK: - CADisplayLink

static void mulg_set_range(CADisplayLink *self, SEL _cmd, CAFrameRateRange range) {
    if (mulg_applying) {
        ((SetFrameRateRange)previous_set_range)(self, _cmd, range);
        return;
    }
    remember(self, range);
    apply(self, effective(self));
}

static void mulg_set_fps(CADisplayLink *self, SEL _cmd, NSInteger fps) {
    if (mulg_applying) {
        ((SetInteger)previous_set_fps)(self, _cmd, fps);
        return;
    }
    // Treat the old API as a range request so both paths follow the same rules.
    float rate = (float)fps;
    // Zero is the default range only when all three fields are zero. A positive
    // legacy FPS request needs a positive minimum for QuartzCore's range setter.
    remember(self, fps > 0 ? CAFrameRateRangeMake(1, rate, rate) : CAFrameRateRangeDefault);
    apply(self, effective(self));
}

/// Stands between a display link and the game's target so the engine can hold the callback
/// back until just before the frame is needed (just-in-time frame start, §6.1). The link retains
/// its target, so this retains the game's, as the link would.
@interface MulgFrameStartTarget : NSObject {
@public
    id _target;
    SEL _selector;
    BOOL _drivesFrames;
}
@end

@implementation MulgFrameStartTarget
// Build 864's frame start, which Genshin played with: input is delivered at every main-thread
// tick before the game's frame. Build 865 required proof that this link presented the frame;
// Unity presents on its render thread, so that proof never came for Genshin.
- (void)tick:(CADisplayLink *)link {
    id target = _target;
    SEL selector = _selector;
    _drivesFrames = mulg_engine_display_link_callback(_drivesFrames, ^{
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, link);
    });
}
@end

static id mulg_display_link_factory(id cls, SEL _cmd, id target, SEL selector) {
    // Build 864: every link with a target goes through the proxy, which sends the selector with
    // objc_msgSend exactly as CADisplayLink does (forwarding targets included). Build 871 only
    // proxied one-argument callbacks; Unity's takes none, so Genshin's frames lost the proxy.
    if (target != nil && selector != NULL) {
        MulgFrameStartTarget *proxy = [MulgFrameStartTarget new];
        proxy->_target = target;
        proxy->_selector = selector;
        target = proxy;
        selector = @selector(tick:);
    }
    CADisplayLink *link = ((DisplayLinkFactory)previous_factory)(cls, _cmd, target, selector);
    if (link != nil) {
        os_unfair_lock_lock(&mulg_links_lock);
        [mulg_links addObject:link];
        os_unfair_lock_unlock(&mulg_links_lock);
        // A new link asks for "as fast as possible" until the game says otherwise.
        CAFrameRateRange rules = effective(link);
        if (rules.maximum != 0 || rules.preferred != 0) {
            apply(link, rules);
        }
    }
    return link;
}

// MARK: - MTKView

static CAFrameRateRange mtk_rules(NSInteger fps) {
    int throttle = atomic_load(&mulg_throttle_fps);
    if (throttle > 0) {
        // MetalKit's own display link is tracked and throttled separately.
        return CAFrameRateRangeMake(0, (float)fps, (float)fps);
    }
    return mulg_display_apply_rules(CAFrameRateRangeMake(0, (float)fps, (float)fps), mulg_display_current_config());
}

static void apply_mtk_rate(id view, NSInteger fps) {
    while (true) {
        CAFrameRateRange range = mtk_rules(fps);
        NSInteger applied = (NSInteger)(range.preferred > 0 ? range.preferred : fps);
        ((SetInteger)previous_mtk_set_fps)(view, @selector(setPreferredFramesPerSecond:), applied);
        NSNumber *requested = objc_getAssociatedObject(view, &kRequestedMTKRateKey);
        NSInteger latest = requested ? requested.integerValue : fps;
        range = mtk_rules(latest);
        if ((NSInteger)(range.preferred > 0 ? range.preferred : latest) == applied) return;
        fps = latest;
    }
}

static void mulg_mtk_set_fps(id self, SEL _cmd, NSInteger fps) {
    objc_setAssociatedObject(self, &kRequestedMTKRateKey, @(fps), OBJC_ASSOCIATION_RETAIN);
    os_unfair_lock_lock(&mulg_links_lock);
    [mulg_mtk_views addObject:self];
    os_unfair_lock_unlock(&mulg_links_lock);
    apply_mtk_rate(self, fps);
}

/// MTKView starts at 60 FPS without calling its setter, so apply the rules after init.
static void reapply_mtk_rate(id view) {
    if (view == nil || previous_mtk_set_fps == NULL) {
        return;
    }
    NSNumber *requested = objc_getAssociatedObject(view, &kRequestedMTKRateKey);
    if (requested == nil) {
        NSInteger current = ((NSInteger (*)(id, SEL))objc_msgSend)(view, @selector(preferredFramesPerSecond));
        mulg_mtk_set_fps(view, @selector(setPreferredFramesPerSecond:), current);
    } else {
        apply_mtk_rate(view, requested.integerValue);
    }
}

static id mulg_mtk_init_frame(id self, SEL _cmd, CGRect frame, id device) {
    id view = ((InitWithFrameDevice)previous_mtk_init_frame)(self, _cmd, frame, device);
    reapply_mtk_rate(view);
    return view;
}

static id mulg_mtk_init_coder(id self, SEL _cmd, NSCoder *coder) {
    id view = ((InitWithCoder)previous_mtk_init_coder)(self, _cmd, coder);
    reapply_mtk_rate(view);
    return view;
}

// MARK: - Throttle

void mulg_display_set_background_throttle(int framesPerSecond) {
    atomic_store(&mulg_throttle_fps, framesPerSecond > 0 ? framesPerSecond : 0);
    os_unfair_lock_lock(&mulg_links_lock);
    NSArray<CADisplayLink *> *links = mulg_links.allObjects;
    NSArray *views = mulg_mtk_views.allObjects;
    os_unfair_lock_unlock(&mulg_links_lock);
    // MTKView may recreate/update its display link here. Its original request wins over a
    // previously forced rate; then the link throttle is applied below.
    for (id view in views) reapply_mtk_rate(view);
    for (CADisplayLink *link in links) {
        apply(link, effective(link));
    }
}

NSUInteger mulg_display_tracked_display_links(void) {
    os_unfair_lock_lock(&mulg_links_lock);
    NSUInteger count = mulg_links.allObjects.count;
    os_unfair_lock_unlock(&mulg_links_lock);
    return count;
}

// MARK: - Installation

MulgDisplayHook mulg_display_install_frame_rate_hooks(MulgDisplayHook *attempted) {
    MulgDisplayHook installed = 0;
    os_unfair_lock_lock(&mulg_links_lock);
    if (mulg_links == nil) mulg_links = [NSHashTable weakObjectsHashTable];
    if (mulg_mtk_views == nil) mulg_mtk_views = [NSHashTable weakObjectsHashTable];
    os_unfair_lock_unlock(&mulg_links_lock);

    Class link = [CADisplayLink class];
    *attempted |= MulgDisplayHookDisplayLinkRate | MulgDisplayHookDisplayLinkCreation;
    BOOL rangeHooked = mulg_swizzle_checked_owned("display", link, @selector(setPreferredFrameRateRange:),
                                             (IMP)mulg_set_range, &previous_set_range, "v", @[@(@encode(CAFrameRateRange))]) == MulgSwizzleResultReplaced;
    // The integer replacement applies its request through the original range setter.
    // Never publish it when that prerequisite failed ABI/ownership validation.
    BOOL fpsHooked = rangeHooked && mulg_swizzle_checked_owned("display", link, @selector(setPreferredFramesPerSecond:),
                                           (IMP)mulg_set_fps, &previous_set_fps, "v", @[@(@encode(NSInteger))]) == MulgSwizzleResultReplaced;
    if (rangeHooked && fpsHooked) {
        installed |= MulgDisplayHookDisplayLinkRate;
        if (mulg_swizzle_checked_owned("display", object_getClass(link), @selector(displayLinkWithTarget:selector:),
                               (IMP)mulg_display_link_factory, &previous_factory, "@", @[@"@", @":"]) == MulgSwizzleResultReplaced) {
            installed |= MulgDisplayHookDisplayLinkCreation;
        }
    }

    // MetalKit is only present when the game links it.
    Class metalKitView = objc_getClass("MTKView");
    if (metalKitView != Nil) {
        *attempted |= MulgDisplayHookMetalKitViewRate;
        BOOL setter = mulg_swizzle_checked_owned("display", metalKitView, @selector(setPreferredFramesPerSecond:),
                                            (IMP)mulg_mtk_set_fps, &previous_mtk_set_fps, "v", @[@(@encode(NSInteger))]) == MulgSwizzleResultReplaced;
        BOOL initFrame = setter && mulg_swizzle_checked_owned("display", metalKitView, @selector(initWithFrame:device:),
                                               (IMP)mulg_mtk_init_frame, &previous_mtk_init_frame, "@", @[@(@encode(CGRect)), @"@"]) == MulgSwizzleResultReplaced;
        BOOL initCoder = setter && mulg_swizzle_checked_owned("display", metalKitView, @selector(initWithCoder:),
                                               (IMP)mulg_mtk_init_coder, &previous_mtk_init_coder, "@", @[@"@"]) == MulgSwizzleResultReplaced;
        if (setter && initFrame && initCoder) {
            installed |= MulgDisplayHookMetalKitViewRate;
        }
    }
    return installed;
}

// MARK: - Unity player frame rate

// Every Unity iOS player, also one with stripped or obfuscated IL2CPP names, hands the game's
// Application.targetFrameRate to -[UnityAppController callbackFramerateChange:], which sets its display
// link. With the uncap on, a request below the target (or the default, 0 or less) asks for the target.
// UnityFramework can load after the startup hooks, so this installs from the display module's poll.

typedef void (*SetUnityRate)(id, SEL, int);
static IMP previous_unity_rate;
static _Atomic(bool) unity_rate_hooked;
static _Atomic(int) unity_requested = INT_MIN;

static void mulg_unity_rate(id self, SEL _cmd, int fps) {
    atomic_store(&unity_requested, fps);
    ((SetUnityRate)previous_unity_rate)(self, _cmd, mulg_display_unity_player_rate(fps, mulg_display_current_config()));
}

/// Main thread. Hooks the player once it is loaded, then asks it again with the current rule (the game
/// asked before the hook, or the target changed). Its own request comes back when the uncap is off.
BOOL mulg_display_apply_unity_player_rate(void) {
    __unsafe_unretained Class controller = objc_lookUpClass("UnityAppController");
    if (!controller) return NO;
    if (!atomic_load(&unity_rate_hooked)) {
        if (mulg_swizzle_checked_owned("display", controller, @selector(callbackFramerateChange:), (IMP)mulg_unity_rate,
                &previous_unity_rate, "v", @[@(@encode(int))]) != MulgSwizzleResultReplaced) return NO;
        atomic_store(&unity_rate_hooked, true);
    }
    // Through the runtime: this file builds without UIKit in the hook fixtures.
    __unsafe_unretained Class application = objc_lookUpClass("UIApplication");
    id shared = application ? ((id (*)(id, SEL))objc_msgSend)(application, sel_registerName("sharedApplication")) : nil;
    id delegate = shared ? ((id (*)(id, SEL))objc_msgSend)(shared, sel_registerName("delegate")) : nil;
    if (![delegate isKindOfClass:controller]) return NO;
    int requested = atomic_load(&unity_requested);
    if (requested == INT_MIN) requested = 0;
    ((SetUnityRate)previous_unity_rate)(delegate, @selector(callbackFramerateChange:),
        mulg_display_unity_player_rate(requested, mulg_display_current_config()));
    return YES;
}

#else

BOOL mulg_display_apply_unity_player_rate(void) { return NO; }

MulgDisplayHook mulg_display_install_frame_rate_hooks(MulgDisplayHook *attempted) {
    return 0;
}

void mulg_display_set_background_throttle(int framesPerSecond) {}

NSUInteger mulg_display_tracked_display_links(void) {
    return 0;
}

#endif
