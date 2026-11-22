//
//  MulgDisplayHooks.h
//  display module: what the game learns about the screen, and how fast it may draw
//  (PLAN.md §4, §6.1, §13.1).
//
//  The hooks read a plain C configuration set by Swift, so no Swift code runs on these hot
//  paths (PLAN.md §16.2 E3, E6). Every hook passes through to the original when the
//  configuration says so, which lets the configuration change at run time (for example when
//  the window moves to a 60 Hz display).
//

#ifndef MULG_DISPLAY_HOOKS_H
#define MULG_DISPLAY_HOOKS_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, MulgScreenMode) {
    /// The game sees the real screen.
    MulgScreenModeOff = 0,
    /// Adaptive display: the game sees a screen of `width` × `height` points.
    MulgScreenModeAdaptive = 1,
    /// Adaptive display with upstream's "inverse screen values" fix.
    MulgScreenModeAdaptiveInverted = 2,
    /// Resizable window: the screen follows the window.
    MulgScreenModeResizable = 3,
};

typedef struct {
    MulgScreenMode screenMode;
    /// Screen size reported to the game, in points (already swapped for the inverted mode).
    double width;
    double height;
    /// Upstream's custom scaler: nativeScale reports it, scale reports it rounded.
    double scale;
    /// Reported UIScreen.maximumFramesPerSecond; 0 reports the real value.
    int reportedMaximumFramesPerSecond;
    /// Raise frame-rate requests of 60 to `targetFramesPerSecond` (§4.2).
    int uncapFrameRate;
    /// Limit "as fast as possible" requests to `targetFramesPerSecond` (§6.1).
    int capAtTarget;
    /// Target for uncapping and capping; 0 disables both.
    int targetFramesPerSecond;
    /// Report NSProcessInfoThermalStateNominal (upstream always did).
    int reportNominalThermalState;
    /// Report Low Power Mode as off (upstream always did).
    int hideLowPowerMode;
    /// Reported UIScreen EDR headroom; 0 reports the real value.
    double edrHeadroom;
} MulgDisplayConfig;

typedef NS_OPTIONS(uint32_t, MulgDisplayHook) {
    MulgDisplayHookSceneFrame = 1u << 0,
    MulgDisplayHookSceneBounds = 1u << 1,
    MulgDisplayHookDisplayModeSize = 1u << 2,
    MulgDisplayHookDeviceOrientation = 1u << 3,
    MulgDisplayHookScreenBounds = 1u << 4,
    MulgDisplayHookScreenNativeBounds = 1u << 5,
    MulgDisplayHookScreenScale = 1u << 6,
    MulgDisplayHookScreenNativeScale = 1u << 7,
    MulgDisplayHookRequiresFullScreen = 1u << 8,
    MulgDisplayHookMaximumFramesPerSecond = 1u << 9,
    MulgDisplayHookThermalState = 1u << 10,
    MulgDisplayHookLowPowerMode = 1u << 11,
    MulgDisplayHookEDRHeadroom = 1u << 12,
    MulgDisplayHookDisplayLinkRate = 1u << 13,
    MulgDisplayHookDisplayLinkCreation = 1u << 14,
    MulgDisplayHookMetalKitViewRate = 1u << 15,
};

/// Sets the configuration the hooks read. Safe to call again at any time.
void mulg_display_configure(MulgDisplayConfig config);

/// The configuration currently in effect.
MulgDisplayConfig mulg_display_current_config(void);
/// Fixed render pixels, independent of UIKit window points. Zero follows native sizing.
void mulg_display_set_render_height(double pixels);
double mulg_display_render_height(void);

/// Main-thread viewport publication; getters only read the locked snapshot.
void mulg_display_set_window_geometry(id _Nullable screen, CGRect bounds, double nativeScale);
/// Returns NO until a valid resizable viewport exists, and for other screens.
BOOL mulg_display_window_geometry(id screen, CGRect *bounds, double *nativeScale);

/// Installs the hooks the configured screen mode needs, plus the frame-rate, thermal, power
/// and HDR hooks (which pass through while unused). Call once, after the first configure.
/// Returns the hooks installed; `attempted` receives every hook that was tried.
MulgDisplayHook mulg_display_install_hooks(MulgDisplayHook *_Nullable attempted);

/// Installs screen geometry hooks without display-link and frame-rate hooks. Used for
/// fixed-resolution rendering when the optional display module is switched off.
MulgDisplayHook mulg_display_install_screen_hooks(MulgDisplayConfig config,
                                                   MulgDisplayHook *_Nullable attempted);

/// Caps every display link at `framesPerSecond` while the window is hidden (§13.1);
/// 0 restores what the game asked for. Main thread only.
void mulg_display_set_background_throttle(int framesPerSecond);

/// Whether macOS Low Power Mode is really on, even while the game is told it is off
/// (`hideLowPowerMode`). Drives the battery saver (§7).
int mulg_display_real_low_power_mode(void);

/// The Mac's real thermal state, even while the game is told nominal
/// (`reportNominalThermalState`). Drives the thermal guard (§13.1).
NSProcessInfoThermalState mulg_display_real_thermal_state(void);

/// Bytes this process has written to disk since it started. While the window is hidden, fast
/// growth means the game is downloading or unpacking an update (§13.1).
uint64_t mulg_display_bytes_written(void);

/// Number of live display links being tracked (for diagnostics).
NSUInteger mulg_display_tracked_display_links(void);

/// For tests: the frame-rate range a request becomes under a configuration.
void mulg_display_transform_range(MulgDisplayConfig config, float *minimum, float *maximum, float *preferred);

/// Frame-rate unlock for Unity IL2CPP games (Application.targetFrameRate through Unity's internal
/// calls). Main thread only. `resolve` is NO for other engines and stripped builds.
BOOL mulg_display_unity_frame_rate_resolve(void);
/// The game's targetFrameRate, or INT32_MIN before `resolve` succeeded.
int32_t mulg_display_unity_target_frame_rate(void);
BOOL mulg_display_set_unity_target_frame_rate(int32_t framesPerSecond);
/// The value to set for `current` with an unlock `target`, or 0 to leave it (never lowers).
int32_t mulg_display_unity_unlock_target(int32_t current, int32_t target);
/// Any Unity player, IL2CPP names or not: -[UnityAppController callbackFramerateChange:] gets the target
/// instead of a lower request while the uncap is on (pure rule below). Main thread; NO until Unity is loaded.
BOOL mulg_display_apply_unity_player_rate(void);
static inline int mulg_display_unity_player_rate(int requested, MulgDisplayConfig config) {
    int target = config.targetFramesPerSecond;
    if (!config.uncapFrameRate || target <= 0 || requested >= target) return requested;
    return target;
}

NS_ASSUME_NONNULL_END

#endif
