//
//  MulgForcedResolution.m
//  graphics module: the game renders at the window's pixel size whatever its own resolution
//  option says (graphics.forceRenderResolution, per game, off by default).
//
//  Games pick their own render size below the surface Mulg gives them (Bleach: "resolution 1080"
//  on a 5K surface). Two ways around it:
//   - Unity IL2CPP games that keep il2cpp_resolve_icall: Screen.SetResolution is Unity's own way to
//     set the size, so Mulg replaces that internal call with one that keeps the game's mode and
//     refresh rate but asks for the target size, and applies the target once in case the game
//     already set its size. Unity then builds every attachment at that size itself.
//   - MetalKit uses its owning view's resize entry point. Other renderers use their normal
//     view-scale/layout path; their raw layer sizes must match the engine's own attachments.
//  Off again, the game's own last request is restored.
//

#import "MulgGraphicsHooks.h"
#import <MulgEngineHooks.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <os/lock.h>
#include <os/log.h>

static _Atomic(bool) forced_enabled;
/// Target pixel size, packed width << 32 | height; 0 while unknown.
static _Atomic(uint64_t) forced_target;

static uint64_t pack(int32_t width, int32_t height) {
    return width > 0 && height > 0 ? ((uint64_t)(uint32_t)width << 32) | (uint32_t)height : 0;
}

MulgForcedSize mulg_graphics_forced_target(void) {
    uint64_t value = atomic_load_explicit(&forced_target, memory_order_acquire);
    return (MulgForcedSize){ (int32_t)(value >> 32), (int32_t)(value & 0xffffffff) };
}

MulgForcedSize mulg_graphics_forced_size(MulgForcedSize requested, MulgForcedSize target) {
    if (target.width <= 0 || target.height <= 0 || requested.width <= 0 || requested.height <= 0) return requested;
    // Exactly the player's chosen resolution, lower as well as higher than the game's own request.
    return target;
}

// MARK: - Unity

typedef struct { uint32_t numerator, denominator; } MulgUnityRefreshRate;
typedef enum { UnityNone = 0, UnityInjected, UnityModeHz, UnityFullscreenHz } UnityVariant;

typedef void (*SetInjected)(int32_t, int32_t, int32_t, MulgUnityRefreshRate *);
typedef void (*SetModeHz)(int32_t, int32_t, int32_t, int32_t);
typedef void (*SetFullscreenHz)(int32_t, int32_t, bool, int32_t);
typedef void *(*ResolveCall)(const char *);
typedef void (*AddCall)(const char *, const void *);

/// Unity 2022.2+, 2019.1–2022.1, and 2017–2018.
static const char *const kInjected = "UnityEngine.Screen::SetResolution_Injected(System.Int32,System.Int32,UnityEngine.FullScreenMode,UnityEngine.RefreshRate&)";
static const char *const kModeHz = "UnityEngine.Screen::SetResolution(System.Int32,System.Int32,UnityEngine.FullScreenMode,System.Int32)";
static const char *const kFullscreenHz = "UnityEngine.Screen::SetResolution(System.Int32,System.Int32,System.Boolean,System.Int32)";

static os_unfair_lock unity_lock = OS_UNFAIR_LOCK_INIT;
static UnityVariant variant;
static void *original;
/// The game's last request; its mode/fullscreen and refresh rate are kept when the size is replaced.
static bool game_requested;
static int32_t game_width, game_height, game_mode = 1;
static MulgUnityRefreshRate game_rate = { 0, 1 };
/// The size Mulg last asked Unity for, 0 when the game's own size applies.
static int32_t applied_width, applied_height;
static _Atomic(int) unity_overrides;

static void call_original(int32_t width, int32_t height, int32_t mode, MulgUnityRefreshRate rate) {
    switch (variant) {
        case UnityInjected: ((SetInjected)original)(width, height, mode, &rate); break;
        case UnityModeHz: ((SetModeHz)original)(width, height, mode, (int32_t)rate.numerator); break;
        case UnityFullscreenHz: ((SetFullscreenHz)original)(width, height, mode != 3, (int32_t)rate.numerator); break;
        case UnityNone: break;
    }
}

/// Every game call: remember it, then pass it on or replace its size.
static void game_set(int32_t width, int32_t height, int32_t mode, MulgUnityRefreshRate rate) {
    os_unfair_lock_lock(&unity_lock);
    game_requested = true;
    game_width = width; game_height = height; game_mode = mode; game_rate = rate;
    MulgForcedSize size = { width, height };
    if (atomic_load(&forced_enabled)) size = mulg_graphics_forced_size(size, mulg_graphics_forced_target());
    bool replaced = size.width != width || size.height != height;
    applied_width = replaced ? size.width : 0;
    applied_height = replaced ? size.height : 0;
    os_unfair_lock_unlock(&unity_lock);
    if (replaced && atomic_fetch_add(&unity_overrides, 1) == 0) {
        os_log(os_log_create("io.mulg", "graphics"), "Unity asked for %dx%d, rendering %dx%d (forced resolution)",
               width, height, size.width, size.height);
    }
    call_original(size.width, size.height, mode, rate);
}

static void mulg_set_injected(int32_t width, int32_t height, int32_t mode, MulgUnityRefreshRate *rate) {
    game_set(width, height, mode, rate ? *rate : (MulgUnityRefreshRate){ 0, 1 });
}
static void mulg_set_mode_hz(int32_t width, int32_t height, int32_t mode, int32_t hz) {
    game_set(width, height, mode, (MulgUnityRefreshRate){ (uint32_t)MAX(hz, 0), 1 });
}
static void mulg_set_fullscreen_hz(int32_t width, int32_t height, bool fullscreen, int32_t hz) {
    // FullScreenMode: 1 FullScreenWindow, 3 Windowed.
    game_set(width, height, fullscreen ? 1 : 3, (MulgUnityRefreshRate){ (uint32_t)MAX(hz, 0), 1 });
}

MulgUnityResolutionState mulg_graphics_unity_resolution_install(void) {
    os_unfair_lock_lock(&unity_lock);
    UnityVariant current = variant;
    os_unfair_lock_unlock(&unity_lock);
    if (current != UnityNone) return MulgUnityResolutionInstalled;
    ResolveCall resolve = (ResolveCall)dlsym(RTLD_DEFAULT, "il2cpp_resolve_icall");
    AddCall add = (AddCall)dlsym(RTLD_DEFAULT, "il2cpp_add_internal_call");
    if (!resolve || !add) return MulgUnityResolutionUnavailable;
    const struct { const char *name; UnityVariant variant; const void *replacement; } candidates[] = {
        { kInjected, UnityInjected, (const void *)mulg_set_injected },
        { kModeHz, UnityModeHz, (const void *)mulg_set_mode_hz },
        { kFullscreenHz, UnityFullscreenHz, (const void *)mulg_set_fullscreen_hz },
    };
    for (size_t i = 0; i < sizeof candidates / sizeof *candidates; i++) {
        // NULL until Unity registered its internal calls (the caller tries again), or another version.
        void *found = resolve(candidates[i].name);
        if (!found || found == candidates[i].replacement) continue;
        os_unfair_lock_lock(&unity_lock);
        original = found;
        variant = candidates[i].variant;
        os_unfair_lock_unlock(&unity_lock);
        // Call sites the game has not run yet resolve to this; ones already run are corrected by
        // mulg_graphics_unity_apply_resolution.
        add(candidates[i].name, candidates[i].replacement);
        return MulgUnityResolutionInstalled;
    }
    return MulgUnityResolutionWaiting;
}

BOOL mulg_graphics_unity_apply_resolution(void) {
    os_unfair_lock_lock(&unity_lock);
    if (variant == UnityNone) { os_unfair_lock_unlock(&unity_lock); return NO; }
    MulgForcedSize target = mulg_graphics_forced_target();
    bool enabled = atomic_load(&forced_enabled);
    int32_t width = 0, height = 0;
    if (enabled && target.width > 0 && target.height > 0) {
        MulgForcedSize size = game_requested
            ? mulg_graphics_forced_size((MulgForcedSize){ game_width, game_height }, target) : target;
        // The game's own request already reaches the target: nothing to replace.
        if (game_requested && size.width == game_width && size.height == game_height) size = (MulgForcedSize){ 0, 0 };
        width = size.width; height = size.height;
    }
    int32_t call_width = 0, call_height = 0;
    if (width > 0 && (width != applied_width || height != applied_height)) {
        call_width = width; call_height = height;
    } else if (width == 0 && applied_width > 0 && game_requested) {
        // Off again (or no longer needed): the game's own last request.
        call_width = game_width; call_height = game_height;
    }
    applied_width = width; applied_height = height;
    int32_t mode = game_mode;
    MulgUnityRefreshRate rate = game_rate;
    os_unfair_lock_unlock(&unity_lock);
    if (call_width <= 0 || call_height <= 0) return NO;
    call_original(call_width, call_height, mode, rate);
    return YES;
}

// MARK: - Unity player rendering size

// Every Unity iOS player, also one with stripped or obfuscated IL2CPP names (Honkai: Star Rail has
// no Screen:: names at all), hands the game's Screen.SetResolution size to its trampoline's
// -[DisplayConnection requestRenderingResolution:]. Unity then renders at that size and stretches
// it onto the full drawable. Raising the request makes Unity build its own surface at the target.

static void (*previous_request_rendering)(id, SEL, CGSize);
static _Atomic(bool) display_hooked;
/// Under unity_lock. The main display's connection, the game's last request and what Mulg passed
/// instead (zero while the game's own size applies).
static __weak id unity_display;
static bool display_requested;
static CGSize display_request, display_applied;
/// A typed zero-size snapshot means Unity's natural surface, not an unknown request.
static bool display_default_adopted;
static NSString *display_snapshot_source = @"none";
static _Atomic(int) display_overrides;

static CGSize display_size(CGSize requested) {
    MulgForcedSize target = mulg_graphics_forced_target();
    if (!atomic_load(&forced_enabled) || !isfinite(requested.width) || !isfinite(requested.height) ||
        requested.width < 1 || requested.height < 1 || requested.width > 16384 || requested.height > 16384)
        return requested;
    MulgForcedSize size = mulg_graphics_forced_size(
        (MulgForcedSize){ (int32_t)lround(requested.width), (int32_t)lround(requested.height) }, target);
    if (size.width == (int32_t)lround(requested.width) && size.height == (int32_t)lround(requested.height))
        return requested;
    return CGSizeMake(size.width, size.height);
}

static void mulg_request_rendering(id self, SEL _cmd, CGSize size) {
    CGSize forced = display_size(size);
    BOOL raised = !CGSizeEqualToSize(forced, size);
    os_unfair_lock_lock(&unity_lock);
    unity_display = self;
    display_requested = true;
    display_request = size;
    display_applied = raised ? forced : (CGSize){ 0, 0 };
    display_default_adopted = false;
    display_snapshot_source = @"game request";
    os_unfair_lock_unlock(&unity_lock);
    if (raised) {
        atomic_fetch_add(&display_overrides, 1);
        os_log(os_log_create("io.mulg", "graphics"), "Unity player asked for %.0fx%.0f, rendering %.0fx%.0f (forced resolution)",
               size.width, size.height, forced.width, forced.height);
    }
    previous_request_rendering(self, _cmd, forced);
}

BOOL mulg_graphics_install_unity_display_hook(void) {
    if (atomic_load(&display_hooked)) return YES;
    // Metadata lookup only: the class belongs to the game's Unity player, absent in other games.
    __unsafe_unretained Class connection = objc_lookUpClass("DisplayConnection");
    if (!connection) return NO;
    IMP previous = NULL;
    if (mulg_swizzle_checked_owned("graphics", connection, @selector(requestRenderingResolution:),
            (IMP)mulg_request_rendering, &previous, @encode(void), @[@(@encode(CGSize))]) != MulgSwizzleResultReplaced)
        return NO;
    previous_request_rendering = (void (*)(id, SEL, CGSize))previous;
    atomic_store(&display_hooked, true);
    return YES;
}

static BOOL display_method(Method method, const char *result) {
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char type[64];
    method_getReturnType(method, type, sizeof type);
    return strcmp(type, result) == 0;
}

/// Some Unity players expose this state only as an Objective-C ivar. Read its declared
/// type and runtime offset; never guess a layout or write Unity's display state directly.
static BOOL read_display_request(id display, Class connection, CGSize *size, NSString **source) {
    SEL requested = NSSelectorFromString(@"requestedRenderingSize");
    Method getter = class_getInstanceMethod(connection, requested);
    if (getter) {
        if (!display_method(getter, @encode(CGSize))) return NO;
        *size = ((CGSize (*)(id, SEL))objc_msgSend)(display, requested);
        *source = @"typed getter";
    } else {
        Ivar field = class_getInstanceVariable(connection, "_requestedRenderingSize");
        if (!field) return NO;
        const char *type = ivar_getTypeEncoding(field);
        if (!type || (strcmp(type, @encode(CGSize)) && strcmp(type, "{CGSize=\"width\"d\"height\"d}"))) return NO;
        ptrdiff_t offset = ivar_getOffset(field);
        size_t instanceSize = class_getInstanceSize(object_getClass(display));
        if (offset < (ptrdiff_t)sizeof(void *) || (size_t)offset > instanceSize ||
            sizeof *size > instanceSize - (size_t)offset) return NO;
        memcpy(size, (const uint8_t *)(__bridge const void *)display + offset, sizeof *size);
        *source = @"typed ivar";
    }
    return isfinite(size->width) && isfinite(size->height) && size->width <= 16384 && size->height <= 16384 &&
        ((size->width >= 1 && size->height >= 1) || CGSizeEqualToSize(*size, CGSizeZero));
}

/// Hooked after the game already asked, or before a player ever requests a custom size.
/// DisplayManager owns the main connection; zero restores its natural surface on release.
static void adopt_main_display(void) {
    os_unfair_lock_lock(&unity_lock);
    bool known = unity_display != nil;
    os_unfair_lock_unlock(&unity_lock);
    if (known) return;
    __unsafe_unretained Class manager = objc_lookUpClass("DisplayManager");
    __unsafe_unretained Class connection = objc_lookUpClass("DisplayConnection");
    SEL instance = NSSelectorFromString(@"Instance"), main = NSSelectorFromString(@"mainDisplay");
    if (!manager || !connection || !display_method(class_getClassMethod(manager, instance), @encode(id)) ||
        !display_method(class_getInstanceMethod(manager, main), @encode(id))) return;
    id shared = ((id (*)(Class, SEL))objc_msgSend)(manager, instance);
    if (![shared respondsToSelector:main]) return;
    id display = ((id (*)(id, SEL))objc_msgSend)(shared, main);
    if (![display isKindOfClass:connection]) return;
    CGSize size;
    NSString *source = nil;
    if (!read_display_request(display, connection, &size, &source)) return;
    os_unfair_lock_lock(&unity_lock);
    if (!unity_display) {
        unity_display = display;
        display_requested = true;
        display_default_adopted = CGSizeEqualToSize(size, CGSizeZero);
        display_snapshot_source = source;
        display_request = size;
        display_applied = (CGSize){ 0, 0 };
    }
    os_unfair_lock_unlock(&unity_lock);
}

BOOL mulg_graphics_unity_display_apply(void) {
    if (!atomic_load(&display_hooked)) return NO;
    adopt_main_display();
    os_unfair_lock_lock(&unity_lock);
    id display = unity_display;
    if (!display || !display_requested) { os_unfair_lock_unlock(&unity_lock); return NO; }
    CGSize forced = display_size(display_request);
    if (display_default_adopted && atomic_load(&forced_enabled)) {
        MulgForcedSize target = mulg_graphics_forced_target();
        if (target.width > 0 && target.height > 0) forced = CGSizeMake(target.width, target.height);
    }
    CGSize wanted = CGSizeEqualToSize(forced, display_request) ? (CGSize){ 0, 0 } : forced;
    BOOL changed = !CGSizeEqualToSize(wanted, display_applied);
    display_applied = wanted;
    CGSize call = changed && CGSizeEqualToSize(wanted, (CGSize){ 0, 0 }) ? display_request : wanted;
    os_unfair_lock_unlock(&unity_lock);
    if (!changed) return NO;
    if (!CGSizeEqualToSize(wanted, (CGSize){ 0, 0 })) atomic_fetch_add(&display_overrides, 1);
    // Off again: the game's own last request. Unity rebuilds its surface on the next frame.
    previous_request_rendering(display, @selector(requestRenderingResolution:), call);
    return YES;
}

/// A Unity game, also one that strips IL2CPP's exports: its class names stay. Unity keeps its own render
/// size and draws only that much of a larger drawable, so the drawable-size path must never touch it.
BOOL mulg_graphics_is_unity_engine(void) {
    static _Atomic(bool) found;
    if (atomic_load_explicit(&found, memory_order_relaxed)) return YES;
    if (NSClassFromString(@"UnityView") == nil && NSClassFromString(@"UnityAppController") == nil) return NO;
    atomic_store_explicit(&found, true, memory_order_relaxed);
    return YES;
}

BOOL mulg_graphics_forced_drawable_path(void) {
    return atomic_load(&forced_enabled) && !mulg_graphics_unity_resolution_active() && !mulg_graphics_is_unity_engine();
}

BOOL mulg_graphics_unity_resolution_active(void) {
    os_unfair_lock_lock(&unity_lock);
    bool active = variant != UnityNone;
    os_unfair_lock_unlock(&unity_lock);
    return active;
}

void mulg_graphics_set_forced_resolution(BOOL enabled, int width, int height) {
    atomic_store_explicit(&forced_target, pack(width, height), memory_order_release);
    atomic_store(&forced_enabled, enabled);
}

BOOL mulg_graphics_forced_resolution_enabled(void) {
    return atomic_load(&forced_enabled);
}

NSDictionary *mulg_graphics_forced_resolution_report(void) {
    os_unfair_lock_lock(&unity_lock);
    NSDictionary *report = @{
        @"forcedResolution": @(atomic_load(&forced_enabled)),
        @"forcedResolutionPath": variant != UnityNone ? @"Unity Screen.SetResolution"
            : atomic_load(&display_hooked) ? @"Unity player rendering size"
            : mulg_graphics_is_unity_engine() ? @"none (Unity without IL2CPP exports)" : @"engine render view",
        @"unityPlayerRequest": display_requested
            ? [NSString stringWithFormat:@"%.0fx%.0f", display_request.width, display_request.height] : @"",
        @"unityPlayerOverrides": @(atomic_load(&display_overrides)),
        @"unityPlayerSnapshotSource": display_snapshot_source,
        @"unityPlayerDefaultSurfaceAdopted": @(display_default_adopted),
        @"forcedTargetWidth": @(mulg_graphics_forced_target().width),
        @"forcedTargetHeight": @(mulg_graphics_forced_target().height),
        @"gameResolutionRequest": game_requested ? [NSString stringWithFormat:@"%dx%d", game_width, game_height] : @"",
        @"forcedResolutionOverrides": @(atomic_load(&unity_overrides)),
    };
    os_unfair_lock_unlock(&unity_lock);
    return report;
}

void mulg_graphics_reset_forced_resolution_for_testing(void) {
    os_unfair_lock_lock(&unity_lock);
    variant = UnityNone; original = NULL;
    game_requested = false; game_width = game_height = 0; game_mode = 1; game_rate = (MulgUnityRefreshRate){ 0, 1 };
    applied_width = applied_height = 0;
    unity_display = nil; display_requested = false;
    display_request = display_applied = (CGSize){ 0, 0 };
    display_default_adopted = false; display_snapshot_source = @"none";
    os_unfair_lock_unlock(&unity_lock);
    atomic_store(&forced_enabled, false);
    atomic_store(&forced_target, 0);
}
