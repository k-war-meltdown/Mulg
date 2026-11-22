//
//  MulgControlsHooks.h
//  controls module: touch injection, the virtual gyro and the virtual controller
//  (PLAN.md §6.1, §14).
//

#ifndef MULG_CONTROLS_HOOKS_H
#define MULG_CONTROLS_HOOKS_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Touch injection (ported from upstream PTFakeMetaTouch)

/// Touch phases, matching UITouchPhase.
typedef NS_ENUM(NSInteger, MulgTouchPhase) {
    MulgTouchPhaseBegan = 0,
    MulgTouchPhaseMoved = 1,
    MulgTouchPhaseStationary = 2,
    MulgTouchPhaseEnded = 3,
    MulgTouchPhaseCancelled = 4,
};

/// Sets up delivery on the main run loop. Call once on the main thread before injecting.
void mulg_touch_prepare(void);
BOOL mulg_touch_is_available(void);
/// Read-only capability query for editable responders (including WebKit), gated by method ABI.
BOOL mulg_controls_responder_is_editable(id responder);

/// Injects one touch event. For `began`, `touchID` is ignored and a new ID is returned; for
/// other phases pass the ID from `began`. Returns -1 once the touch has ended.
/// `window` is a UIWindow and `view` the UIView under the point (hit-tested by the caller).
NSInteger mulg_touch_inject(NSInteger touchID, CGPoint point, MulgTouchPhase phase,
                            id _Nullable window, id _Nullable view);

/// Touches currently alive (for diagnostics and tests).
NSUInteger mulg_touch_live_count(void);
/// Whether UIKit has received this live contact's began phase.
BOOL mulg_touch_begin_delivered(NSInteger touchID);
/// Bounded numeric evidence from actual UIKit deliveries (main thread only).
NSDictionary *mulg_touch_delivery_diagnostics(void);
/// Commit one coherent contact snapshot at a frame boundary without waiting for a run-loop source.
void mulg_touch_flush(void);
/// Main thread: associate routed input with the touch batch that actually delivers it.
void mulg_touch_set_input_timestamp(uint64_t arrival);
BOOL mulg_touch_input_was_queued(void);
void mulg_touch_set_delivery_handler(void (^_Nullable handler)(uint64_t arrival, uint64_t delivered));
/// Main thread: called once for each contact whose began phase UIKit just received, right after
/// that delivery, so a waiting action starts without polling. nil removes it.
void mulg_touch_set_begin_handler(void (^_Nullable handler)(NSInteger touchID));

// MARK: - Virtual gyro (PLAN.md §14.3)

typedef struct {
    /// Rotation rate in the device frame, radians per second.
    double rateX, rateY, rateZ;
    /// Attitude quaternion.
    double qx, qy, qz, qw;
    /// Gravity in the device frame, in g.
    double gravityX, gravityY, gravityZ;
} MulgMotionSample;

/// Turns gyro emulation on or off. When off, Core Motion answers as normal.
void mulg_motion_configure(BOOL enabled);
BOOL mulg_motion_is_enabled(void);

/// Adds a rotation (radians, device frame) that happened since the last sample, for example
/// from mouse movement. It becomes rotation rate over the next sample period.
void mulg_motion_add_rotation(double x, double y, double z);

/// A steady rotation rate (radians per second, device frame), for example from held keys or a
/// controller's motion sensor. Replaces the previous steady rate.
void mulg_motion_set_steady_rate(double x, double y, double z);

/// Resets the attitude to upright landscape.
void mulg_motion_recenter(void);

/// Advances the integrator by `dt` seconds and returns the new sample. The hooks call this from
/// their own clock; exposed for tests.
MulgMotionSample mulg_motion_step(double dt);

/// The latest sample without advancing.
MulgMotionSample mulg_motion_latest(void);

/// Installs the Core Motion hooks. Returns the number of methods replaced.
int mulg_motion_install_hooks(void);

// MARK: - Virtual controller (PLAN.md §14.1)

/// Makes `controller` (a GCController) appear in the game's controller list and announces it
/// as connected; nil removes it and announces the disconnection.
void mulg_controller_set_virtual(id _Nullable controller);
/// Reads made by the game client, excluding Mulg's own controller diagnostics.
uint64_t mulg_controller_game_read_count(void);

/// Installs the GCController list hooks. Returns the number of methods replaced.
int mulg_controller_install_hooks(void);

// MARK: - Compatibility fixes (ported from upstream)

/// Hides the Mac mouse from GCMouse (`disableBuiltinMouse`), starts new motion managers at
/// 100 Hz (`limitMotionUpdateFrequency`), and refuses Unity's pointer lock. Returns the number
/// of methods replaced.
/// Override game-owned pointer locking only for mapped input or explicit cursor release.
void mulg_controls_set_pointer_cursor_override(BOOL enabled);
int mulg_controls_install_pointer_cursor_hooks(void);
/// Native games binding just one mouse can also receive motion from unbound HID endpoints.
/// Main-thread lifecycle. Existing callbacks and the owning mouse's delivery queue are preserved.
void mulg_controls_start_native_mouse_relay(void);
void mulg_controls_stop_native_mouse_relay(void);
NSDictionary<NSString *, NSNumber *> *mulg_controls_native_mouse_relay_report(void);
int mulg_controls_install_compat_hooks(BOOL hideMice, BOOL limitMotionRate);
/// TFT-family compatibility device, created before the game enumerates mice.
BOOL mulg_controls_uses_tft_mouse(NSString *identifier);
BOOL mulg_controls_prepare_tft_mouse(NSString *identifier);
id _Nullable mulg_controls_virtual_mouse_device(void);
int mulg_controls_install_mouse_device_hooks(void);
BOOL mulg_controls_tft_mouse_move(float dx, float dy);
BOOL mulg_controls_tft_mouse_button(NSInteger number, BOOL pressed);
BOOL mulg_controls_tft_mouse_scroll(float dx, float dy);
void mulg_controls_cancel_tft_mouse(void);
void mulg_controls_stop_tft_mouse(void);
NSDictionary *mulg_controls_tft_mouse_report(void);

/// A game view may expose its own coordinate-bearing contact entry point. Use it
/// only when the implementation belongs to the game and matches the checked ABI.
BOOL mulg_controls_game_touch_capable(id view);
NSObject * _Nullable mulg_controls_game_touch_begin(id view, CGPoint point);
void mulg_controls_game_touch_move(NSObject *contact, CGPoint point);
void mulg_controls_game_touch_end(NSObject *contact, CGPoint point);
void mulg_controls_game_touch_cancel(NSObject *contact);
NSDictionary *mulg_controls_game_touch_report(void);

/// Hide direct game device enumeration during touchscreen gameplay; wrapper/native UI retain access.
int mulg_controls_install_touch_isolation(void);
void mulg_controls_set_touch_isolation(BOOL enabled);

/// Catches exceptions from Unity's KeyboardDelegate.Initialize
/// (`ignoreUnityKeyboardInitializationError`). Returns 1 when installed.
int mulg_controls_install_unity_keyboard_fix(void);

/// Keeps a weak list of the web views in a window (WKWebView.didMoveToWindow), so the native
/// interface check looks at those few views instead of walking every view. 0 until WebKit is
/// loaded; 1 once installed. Main thread.
int mulg_controls_track_web_views(void);
/// Adds a web view that was already in a window before tracking started. Main thread.
void mulg_controls_note_web_view(id view);
/// The tracked web views that are in a window now. Main thread.
NSArray *mulg_controls_web_views(void);

NS_ASSUME_NONNULL_END

#endif
