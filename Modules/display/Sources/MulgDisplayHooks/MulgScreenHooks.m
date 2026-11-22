//
//  MulgScreenHooks.m
//  display module: the screen the game sees (PLAN.md §4), ported from upstream
//  NSObject+Swizzle.m and MulgScreen.swift.
//
//  Upstream computed every value in Swift from global settings on each call; here each hook
//  reads the C configuration and does plain arithmetic. The screen hooks for scenes and
//  display modes use private FrontBoard classes; they are recorded in the private-API
//  register by the Swift side (PLAN.md §12 #17).
//

#import "MulgDisplayInternal.h"
#include <TargetConditionals.h>

#if TARGET_OS_IPHONE
// iOS and Mac Catalyst: the game process. (The macOS build below only exists so the pure
// rules can be unit-tested on a Mac.)

#import <UIKit/UIKit.h>
#import <MulgEngineHooks.h>

#include <math.h>

static IMP previous_scene_frame;
static IMP previous_scene_bounds;
static IMP previous_mode_size;
static IMP previous_orientation;
static IMP previous_screen_bounds;
static IMP previous_native_bounds;
static IMP previous_scale;
static IMP previous_native_scale;
static IMP previous_requires_full_screen;
static IMP previous_maximum_fps;
static IMP previous_thermal_state;
static IMP previous_low_power;
static IMP previous_potential_edr;

typedef CGRect (*RectGetter)(id, SEL);
typedef CGSize (*SizeGetter)(id, SEL);
typedef CGFloat (*FloatGetter)(id, SEL);
typedef NSInteger (*IntegerGetter)(id, SEL);
typedef BOOL (*BoolGetter)(id, SEL);

static BOOL is_adaptive(MulgDisplayConfig c) {
    return c.screenMode == MulgScreenModeAdaptive || c.screenMode == MulgScreenModeAdaptiveInverted;
}

// MARK: - Scene and display mode (private FrontBoard classes)

static CGRect mulg_scene_frame(id self, SEL _cmd) {
    CGRect original = ((RectGetter)previous_scene_frame)(self, _cmd);
    MulgDisplayConfig c = mulg_display_current_config();
    switch (c.screenMode) {
        case MulgScreenModeAdaptive:
            // Upstream `frame`: the reversed aspect ratio.
            return CGRectMake(original.origin.x, original.origin.y, c.height, c.width);
        case MulgScreenModeAdaptiveInverted:
            return CGRectMake(original.origin.x, original.origin.y, c.width, c.height);
        default:
            return original;
    }
}

static CGRect mulg_scene_bounds(id self, SEL _cmd) {
    CGRect original = ((RectGetter)previous_scene_bounds)(self, _cmd);
    MulgDisplayConfig c = mulg_display_current_config();
    if (!is_adaptive(c)) {
        return original;
    }
    return CGRectMake(original.origin.x, original.origin.y, c.width, c.height);
}

static CGSize mulg_mode_size(id self, SEL _cmd) {
    CGSize original = ((SizeGetter)previous_mode_size)(self, _cmd);
    MulgDisplayConfig c = mulg_display_current_config();
    switch (c.screenMode) {
        case MulgScreenModeAdaptive:
            return CGSizeMake(c.width, c.height);
        case MulgScreenModeAdaptiveInverted:
            return CGSizeMake(c.height, c.width);
        default:
            return original;
    }
}

static NSInteger mulg_orientation(id self, SEL _cmd) {
    MulgDisplayConfig c = mulg_display_current_config();
    if (is_adaptive(c)) {
        // Works around a macOS 13.2 issue, as upstream did.
        return UIDeviceOrientationUnknown;
    }
    return ((IntegerGetter)previous_orientation)(self, _cmd);
}

// MARK: - UIScreen

static CGRect mulg_screen_bounds(id self, SEL _cmd) {
    CGRect original = ((RectGetter)previous_screen_bounds)(self, _cmd);
    MulgDisplayConfig c = mulg_display_current_config();
    if (is_adaptive(c)) {
        return CGRectMake(original.origin.x, original.origin.y, c.width, c.height);
    }
    if (c.screenMode == MulgScreenModeResizable) {
        CGRect window; double scale;
        return mulg_display_window_geometry(self, &window, &scale) ? window : original;
    }
    return original;
}

static CGRect mulg_native_bounds(id self, SEL _cmd) {
    CGRect original = ((RectGetter)previous_native_bounds)(self, _cmd);
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.screenMode == MulgScreenModeOff && c.scale == 1) {
        if (!mulg_engine_is_game_caller(__builtin_return_address(0))) return original;
        CGRect points = [(UIScreen *)self bounds];
        return CGRectMake(0, 0, points.size.width, points.size.height);
    }
    double pixels = mulg_display_render_height();
    if (pixels > 0) {
        // UIKit keeps its actual backing geometry; only game render queries see target pixels.
        if (!mulg_engine_is_game_caller(__builtin_return_address(0))) return original;
        CGRect window; double scale;
        CGSize points = mulg_display_window_geometry(self, &window, &scale) ? window.size : original.size;
        // Match the view's points-to-pixels calculation. The renderer owns its drawable;
        // changing that texture behind its back leaves the viewport at the old resolution.
        return points.height > 0
            ? CGRectMake(0, 0, floor(points.width * nextafter(pixels / points.height, INFINITY)), pixels) : original;
    }
    if (c.screenMode == MulgScreenModeResizable) {
        CGRect window; double scale;
        if (mulg_display_window_geometry(self, &window, &scale))
            return CGRectMake(0, 0, window.size.width * scale, window.size.height * scale);
        if (c.scale == 1) {
            CGRect points = [(UIScreen *)self bounds];
            return CGRectMake(0, 0, points.size.width, points.size.height);
        }
        return original;
    }
    if (!is_adaptive(c)) return original;
    return CGRectMake(original.origin.x, original.origin.y, c.width * c.scale, c.height * c.scale);
}

static CGFloat mulg_scale(id self, SEL _cmd) {
    MulgDisplayConfig config = mulg_display_current_config();
    if (config.screenMode == MulgScreenModeOff && config.scale == 1
        && mulg_engine_is_game_caller(__builtin_return_address(0))) return 1;
    double pixels = mulg_display_render_height();
    if (pixels > 0) {
        // The exact pixels-per-point ratio is often fractional (2064 rows in a 1169-point full
        // screen: 1.77), and a fixed height is the default since the iPad resolution became exact.
        // UIScreen.scale is a whole number on every iOS device, and games crash on a fractional one
        // (see below), so it is rounded. nativeScale and nativeBounds keep the exact ratio, as real
        // iPhones report fractional native scales; renderers size from those and the view's scale.
        CGRect window; double scale;
        if (mulg_engine_is_game_caller(__builtin_return_address(0))
            && mulg_display_window_geometry(self, &window, &scale) && window.size.height > 0)
            return MAX(1, round(pixels / window.size.height));
        return ((FloatGetter)previous_scale)(self, _cmd);
    }
    CGRect window; double scale;
    if (config.screenMode == MulgScreenModeResizable)
        return mulg_display_window_geometry(self, &window, &scale) ? round(scale)
            : config.scale == 1 ? 1 : ((FloatGetter)previous_scale)(self, _cmd);
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.screenMode == MulgScreenModeOff || c.scale <= 0) {
        return ((FloatGetter)previous_scale)(self, _cmd);
    }
    // Games crash on a fractional scale; upstream rounded it the same way.
    return round(c.scale);
}

static CGFloat mulg_native_scale(id self, SEL _cmd) {
    MulgDisplayConfig config = mulg_display_current_config();
    if (config.screenMode == MulgScreenModeOff && config.scale == 1
        && mulg_engine_is_game_caller(__builtin_return_address(0))) return 1;
    double pixels = mulg_display_render_height();
    if (pixels > 0) {
        CGRect window; double scale;
        if (mulg_engine_is_game_caller(__builtin_return_address(0))
            && mulg_display_window_geometry(self, &window, &scale) && window.size.height > 0)
            return pixels / window.size.height;
        return ((FloatGetter)previous_native_scale)(self, _cmd);
    }
    CGRect window; double scale;
    if (config.screenMode == MulgScreenModeResizable)
        return mulg_display_window_geometry(self, &window, &scale) ? scale
            : config.scale == 1 ? 1 : ((FloatGetter)previous_native_scale)(self, _cmd);
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.screenMode == MulgScreenModeOff || c.scale <= 0) {
        return ((FloatGetter)previous_native_scale)(self, _cmd);
    }
    return c.scale;
}

static NSInteger mulg_maximum_fps(id self, SEL _cmd) {
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.reportedMaximumFramesPerSecond > 0) {
        return c.reportedMaximumFramesPerSecond;
    }
    return ((IntegerGetter)previous_maximum_fps)(self, _cmd);
}

static CGFloat mulg_potential_edr(id self, SEL _cmd) {
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.edrHeadroom > 0) {
        return c.edrHeadroom;
    }
    return ((FloatGetter)previous_potential_edr)(self, _cmd);
}

static BOOL mulg_requires_full_screen(id self, SEL _cmd) {
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.screenMode == MulgScreenModeResizable) {
        return NO;
    }
    return ((BoolGetter)previous_requires_full_screen)(self, _cmd);
}

// MARK: - NSProcessInfo

// Game callers only, like the screen answers above: Apple's frameworks in the process use the real thermal
// and power state to throttle their own work, and were told "nominal" and "not low power" too.
static NSInteger mulg_thermal_state(id self, SEL _cmd) {
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.reportNominalThermalState && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        return NSProcessInfoThermalStateNominal;
    }
    return ((IntegerGetter)previous_thermal_state)(self, _cmd);
}

static BOOL mulg_low_power(id self, SEL _cmd) {
    MulgDisplayConfig c = mulg_display_current_config();
    if (c.hideLowPowerMode && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        return NO;
    }
    return ((BoolGetter)previous_low_power)(self, _cmd);
}

// MARK: - Installation

static void install(MulgDisplayHook hook, Class cls, SEL selector, IMP replacement, IMP *previous,
                    MulgDisplayHook *installed, MulgDisplayHook *attempted) {
    if (attempted != NULL) {
        *attempted |= hook;
    }
    const char *result = @encode(CGFloat);
    switch (hook) {
        case MulgDisplayHookSceneFrame: case MulgDisplayHookSceneBounds:
        case MulgDisplayHookScreenBounds: case MulgDisplayHookScreenNativeBounds: result = @encode(CGRect); break;
        case MulgDisplayHookDisplayModeSize: result = @encode(CGSize); break;
        case MulgDisplayHookDeviceOrientation: case MulgDisplayHookMaximumFramesPerSecond:
        case MulgDisplayHookThermalState: result = @encode(NSInteger); break;
        case MulgDisplayHookRequiresFullScreen: case MulgDisplayHookLowPowerMode: result = @encode(BOOL); break;
        default: break;
    }
    if (mulg_swizzle_checked_owned("display", cls, selector, replacement, previous, result, @[]) == MulgSwizzleResultReplaced) {
        *installed |= hook;
    }
}

MulgDisplayHook mulg_display_install_screen_hooks(MulgDisplayConfig config, MulgDisplayHook *attempted) {
    MulgDisplayHook installed = 0;
    Class screen = [UIScreen class];

    if (is_adaptive(config)) {
        // Since iOS 17.1 `frame` lives on FBSSceneSettingsCore; fall back for older layouts.
        Class sceneCore = objc_getClass("FBSSceneSettingsCore");
        Class scene = objc_getClass("FBSSceneSettings");
        install(MulgDisplayHookSceneFrame, sceneCore != Nil ? sceneCore : scene, @selector(frame),
                (IMP)mulg_scene_frame, &previous_scene_frame, &installed, attempted);
        install(MulgDisplayHookSceneBounds, scene, @selector(bounds),
                (IMP)mulg_scene_bounds, &previous_scene_bounds, &installed, attempted);
        install(MulgDisplayHookDisplayModeSize, objc_getClass("FBSDisplayMode"), @selector(size),
                (IMP)mulg_mode_size, &previous_mode_size, &installed, attempted);
        install(MulgDisplayHookDeviceOrientation, [UIDevice class], @selector(orientation),
                (IMP)mulg_orientation, &previous_orientation, &installed, attempted);
        install(MulgDisplayHookScreenNativeBounds, screen, @selector(nativeBounds),
                (IMP)mulg_native_bounds, &previous_native_bounds, &installed, attempted);
    }
    if (config.screenMode == MulgScreenModeOff && config.scale == 1) {
        install(MulgDisplayHookScreenNativeBounds, screen, @selector(nativeBounds),
                (IMP)mulg_native_bounds, &previous_native_bounds, &installed, attempted);
    }
    if (is_adaptive(config) || config.screenMode == MulgScreenModeResizable
        || (config.screenMode == MulgScreenModeOff && config.scale == 1)) {
        // Like upstream, UIScreen.bounds is only replaced for the resizable window; in the
        // adaptive modes UIKit derives it from the scene settings replaced above.
        if (config.screenMode == MulgScreenModeResizable) {
            install(MulgDisplayHookScreenNativeBounds, screen, @selector(nativeBounds),
                    (IMP)mulg_native_bounds, &previous_native_bounds, &installed, attempted);
            install(MulgDisplayHookScreenBounds, screen, @selector(bounds),
                    (IMP)mulg_screen_bounds, &previous_screen_bounds, &installed, attempted);
        }
        install(MulgDisplayHookScreenScale, screen, @selector(scale),
                (IMP)mulg_scale, &previous_scale, &installed, attempted);
        install(MulgDisplayHookScreenNativeScale, screen, @selector(nativeScale),
                (IMP)mulg_native_scale, &previous_native_scale, &installed, attempted);
    }
    if (config.screenMode == MulgScreenModeResizable) {
        install(MulgDisplayHookRequiresFullScreen, objc_getClass("_UIApplicationInfoParser"),
                NSSelectorFromString(@"requiresFullScreen"),
                (IMP)mulg_requires_full_screen, &previous_requires_full_screen, &installed, attempted);
    }

    // Always installed; they pass through until configured.
    install(MulgDisplayHookMaximumFramesPerSecond, screen, @selector(maximumFramesPerSecond),
            (IMP)mulg_maximum_fps, &previous_maximum_fps, &installed, attempted);
    install(MulgDisplayHookEDRHeadroom, screen, @selector(potentialEDRHeadroom),
            (IMP)mulg_potential_edr, &previous_potential_edr, &installed, attempted);
    install(MulgDisplayHookThermalState, [NSProcessInfo class], @selector(thermalState),
            (IMP)mulg_thermal_state, &previous_thermal_state, &installed, attempted);
    install(MulgDisplayHookLowPowerMode, [NSProcessInfo class], @selector(isLowPowerModeEnabled),
            (IMP)mulg_low_power, &previous_low_power, &installed, attempted);
    return installed;
}

MulgDisplayHook mulg_display_install_hooks(MulgDisplayHook *attempted) {
    MulgDisplayHook tried = 0;
    MulgDisplayConfig config = mulg_display_current_config();
    MulgDisplayHook installed = mulg_display_install_screen_hooks(config, &tried);
    installed |= mulg_display_install_frame_rate_hooks(&tried);
    if (attempted != NULL) {
        *attempted = tried;
    }
    return installed;
}

#else

MulgDisplayHook mulg_display_install_screen_hooks(MulgDisplayConfig config, MulgDisplayHook *attempted) {
    return 0;
}

MulgDisplayHook mulg_display_install_hooks(MulgDisplayHook *attempted) {
    if (attempted != NULL) {
        *attempted = 0;
    }
    return 0;
}

#endif

int mulg_display_real_low_power_mode(void) {
    NSProcessInfo *info = [NSProcessInfo processInfo];
#if TARGET_OS_IPHONE
    // The hook may hide Low Power Mode from the game; the battery saver needs the real state.
    if (previous_low_power != NULL) {
        return ((BoolGetter)previous_low_power)(info, @selector(isLowPowerModeEnabled));
    }
#endif
    return info.isLowPowerModeEnabled;
}

NSProcessInfoThermalState mulg_display_real_thermal_state(void) {
    NSProcessInfo *info = [NSProcessInfo processInfo];
#if TARGET_OS_IPHONE
    // The hook may report nominal to the game; the thermal guard needs the real state.
    if (previous_thermal_state != NULL) {
        return (NSProcessInfoThermalState)((IntegerGetter)previous_thermal_state)(info, @selector(thermalState));
    }
#endif
    return info.thermalState;
}
