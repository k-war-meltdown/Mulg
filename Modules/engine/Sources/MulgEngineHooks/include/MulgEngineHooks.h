//
//  MulgEngineHooks.h
//  engine module: swizzle helpers and the low-level C hooks every game gets
//  (PLAN.md §16.2 E1, E2, E4, E6).
//

#ifndef MULG_ENGINE_HOOKS_H
#define MULG_ENGINE_HOOKS_H

#import <Foundation/Foundation.h>
#import "MulgGameDataHooks.h"
#import <objc/runtime.h>
#include <mach-o/loader.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Swizzling

typedef NS_ENUM(NSInteger, MulgSwizzleResult) {
    MulgSwizzleResultReplaced = 0,
    MulgSwizzleResultClassMissing = 1,
    MulgSwizzleResultMethodMissing = 2,
    MulgSwizzleResultConflict = 3,
    MulgSwizzleResultSignatureMismatch = 4,
};

/// Ownership is checked under the installation lock before changing any implementation.
/// Class and instance methods are separate targets. The owner is a module id.
MulgSwizzleResult mulg_swizzle_instance_owned(const char *owner, Class _Nullable cls, SEL selector,
                                             IMP replacement, IMP _Nullable * _Nullable previous);
/// Type encodings are checked before replacement; offsets in the method encoding are ignored.
MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner, Class _Nullable cls, SEL selector,
                                            IMP replacement, IMP _Nullable * _Nullable previous,
                                           const char *returnType, NSArray<NSString *> *arguments);

/// Saved implementation for the receiver's concrete class (including inherited hooks).
IMP _Nullable mulg_swizzle_original(Class cls, SEL selector, IMP replacement);
MulgSwizzleResult mulg_swizzle_class_owned(const char *owner, Class _Nullable cls, SEL selector,
                                          IMP replacement, IMP _Nullable * _Nullable previous);
MulgSwizzleResult mulg_swizzle_instance_named_owned(const char *owner, const char *className, SEL selector,
                                                   IMP replacement, IMP _Nullable * _Nullable previous);
/// Snapshot of real installation results, including missing targets and rejected conflicts. A
/// by-name hook whose class this game does not have is marked "absent": it does not apply.
NSArray<NSDictionary<NSString *, id> *> *mulg_hook_installation_reports(void);
/// Changes whenever the reports do, so a reader can skip an unchanged snapshot.
uint64_t mulg_hook_installation_generation(void);

/// Replaces an instance method's implementation on `cls` and returns the previous one
/// through `previous` (the inherited implementation when `cls` did not define its own).
/// Installing on `cls` only never changes the superclass.
MulgSwizzleResult mulg_swizzle_instance(Class _Nullable cls, SEL selector, IMP replacement,
                                        IMP _Nullable * _Nullable previous);

/// The same for a class method.
MulgSwizzleResult mulg_swizzle_class(Class _Nullable cls, SEL selector, IMP replacement,
                                     IMP _Nullable * _Nullable previous);

/// Convenience: looks the class up by name first.
MulgSwizzleResult mulg_swizzle_instance_named(const char *className, SEL selector, IMP replacement,
                                              IMP _Nullable * _Nullable previous);

// MARK: - File hooks (E1, E2)

/// Turns the Unreal Engine path fix on for `homeDirectory` (the user's real home folder),
/// or off with NULL. When off, the file hooks only forward to the real functions.
void mulg_engine_configure_unreal_path_fix(const char *_Nullable homeDirectory);
/// Exact owned roots for Unreal's doubled-absolute-path repair. Nil disables it.
/// Publication is immutable; file calls never allocate, probe the disk or lock.
void mulg_engine_configure_unreal_paths(NSArray<NSString *> *_Nullable roots);
/// Repair absolute paths appended to owned Documents/Library roots for any game.
/// The broader legacy doubled-slash behavior is separately limited to Unreal.
void mulg_engine_configure_game_path_roots(NSArray<NSString *> *_Nullable roots, BOOL legacyUnreal);

/// For tests: applies the path fix to `path` exactly as the hooks do.
const char *mulg_engine_fix_path(const char *path);

// MARK: - Sleep throttle (E4)

/// Opt-in backoff for >100 successful 100 ms sleeps that actually return in <10 ms.
/// Normal polling and EINTR never qualify. One backoff resets the detector; 100–250 ms only.
void mulg_engine_configure_sleep_throttle(BOOL enabled, useconds_t throttledMicroseconds);

/// Number of threads the throttle has slowed down so far (for diagnostics).
NSUInteger mulg_engine_throttled_thread_count(void);
/// Pure detector shared with tests: successful 100 ms sleeps returning in <10 ms only.
/// A normal sleep, interruption, changed duration or disable resets the streak.
uint32_t mulg_engine_sleep_streak(uint32_t previous, useconds_t requested,
                                 uint64_t elapsedNanoseconds, int result);

// MARK: - Just-in-time frame start (§6.1)

/// How long the game waits before starting its next frame, set by `graphics` from how early
/// frames finish. Under a cap the game otherwise finishes early and waits in nextDrawable with
/// input it read too soon. 0 turns the wait off.
void mulg_engine_set_frame_start_delay(double seconds);

/// Called by `graphics` when the game committed the command buffer that presents its main
/// layer, or presented its Metal 4 main-layer drawable: waits the delay before the game's loop
/// reads input again, unless the frame came from a display-link callback (that wait happens
/// before the callback instead).
void mulg_engine_frame_presented(void);
/// Capture at presentation registration and finish at submission, even on another thread.
/// A retained display-link context suppresses a second wait and records that the link drew.
id _Nullable mulg_engine_frame_start_context(void);
void mulg_engine_frame_presented_in_context(id _Nullable context);

/// Called by `display` around a display-link callback. `drivesFrames` (whether the link presented
/// a frame last time) waits the delay first. Returns whether a frame was presented in `callback`.
BOOL mulg_engine_display_link_callback(BOOL drivesFrames, void (NS_NOESCAPE ^callback)(void));

/// Main thread. Runs `handler` on the main thread just before each display-link frame starts,
/// after any just-in-time wait, so input collected up to that moment reaches the frame. Several
/// links ticking in the same refresh run it once. nil removes it.
void mulg_engine_set_frame_start_handler(void (^_Nullable handler)(void));

// MARK: - Platform

/// Identity's metadata-only observer of native Metal factory results. Runs synchronously on the
/// calling thread before the result reaches its caller; never create a device in the handler.
/// One identity-owned handler, nil until registered (early startup stays native), nil to remove.
typedef void (*MulgMetalDeviceHandler)(id device);
void mulg_engine_set_metal_device_handler(MulgMetalDeviceHandler _Nullable handler);
/// A further module's handler, called after the one above for every device the game creates (up to 4).
void mulg_engine_add_metal_device_handler(MulgMetalDeviceHandler handler);

/// The platform the interposed dyld_get_active_platform reports: PLATFORM_IOS, as upstream.
int mulg_engine_reported_platform(void);
/// Runtime constructor only, after libSystem initialization; early interposes return native answers.
void mulg_engine_prepare_game_callers(void);
BOOL mulg_engine_is_game_caller(const void *_Nullable caller);
/// Memory compatibility only: also classifies loaded game images before runtime boot,
/// using loader metadata without allocating, dispatching or initializing Objective-C.
BOOL mulg_engine_is_game_memory_caller(const void *_Nullable caller);
/// Optional identity budget; zero keeps the Mac's budget. Compatibility remains active.
void mulg_engine_set_memory_limit(uint64_t bytes);
/// Resolve an unsupported native zero using measured headroom, preserving native callers,
/// positive native answers, real exhaustion and the optional device budget.
uint64_t mulg_engine_available_memory_answer(uint64_t native, BOOL game, uint64_t physical,
                                            uint64_t footprint, uint64_t headroom, uint64_t limit);
/// The executable segment of `header`'s image that contains `address`, at its runtime address.
BOOL mulg_engine_code_range(const struct mach_header *_Nullable header, const void *_Nullable address,
                            uintptr_t *_Nonnull start, uintptr_t *_Nonnull end);
/// Tests only: treat images under `bundle` as the game's, on any platform, and forget the cache.
void mulg_engine_set_game_callers_for_testing(const char *_Nonnull bundle, BOOL anyPlatform);
BOOL mulg_engine_is_game_image(const char *image, const char *bundle);
/// Loaded image metadata only; native macOS helpers retain the system platform answer.
BOOL mulg_engine_image_uses_ios_platform(const struct mach_header *_Nullable header);
/// Coalesced main-thread delivery; the dyld callback performs no Objective-C work.
void mulg_engine_observe_images(void (^handler)(void));

// MARK: - Loading trace

/// Regular files this process holds open, at least `minimumSize` bytes, under one of `roots`
/// (path prefixes ending in "/"). Read through libproc from any thread; no hook sees the game's
/// opens. Paths are as the kernel reports them, at most `limit` of them.
NSArray<NSString *> *mulg_engine_open_files(NSArray<NSString *> *roots, int64_t minimumSize, NSUInteger limit);

// MARK: - Compatibility fixes (ported from upstream)

/// VideoSubscriberAccount no-op, the Unreal Engine regular-expression crash fix (Chinese system
/// encodings only), and synchronous microphone permission answers. Returns methods replaced.
typedef NS_OPTIONS(NSUInteger, MulgEngineCompatHook) {
    MulgEngineCompatHookSubscription = 1 << 0,
    MulgEngineCompatHookRegex = 1 << 1,
    MulgEngineCompatHookMicrophone = 1 << 2,
    MulgEngineCompatHookBackgroundTasks = 1 << 3,
    /// Microphone answered "denied" while the Mac has no audio input (AVAudioSession, AVAudioApplication,
    /// AVCaptureDevice).
    MulgEngineCompatHookMissingMicrophone = 1 << 4,
    /// Photos and location answered "denied" when the game may not use them (PrivacySettings).
    MulgEngineCompatHookPrivacy = 1 << 5,
};
/// Whether the Mac has no audio input device (no default input, or one without input streams).
BOOL mulg_engine_audio_input_missing(void);
/// engine.muteWhenUnfocused (MulgAudioMute.m): silences everything the game plays (its output audio units
/// and audio queues) while YES; sound comes back at once when NO. Any thread.
void mulg_engine_set_audio_muted(BOOL muted);
BOOL mulg_engine_audio_muted(void);
/// Output buffers silenced so far (diagnostics and tests).
unsigned mulg_engine_audio_silenced_buffers(void);
/// Tests: what the AudioQueueNewOutput and AudioQueueSetParameter hooks do, for an AudioQueueRef.
void mulg_engine_audio_mute_track_queue_for_testing(void *_Nonnull queue);
int32_t mulg_engine_audio_queue_set_volume_for_testing(void *_Nonnull queue, float volume);
int32_t mulg_engine_audio_queue_dispose_for_testing(void *_Nonnull queue);
/// What the game may use; the rest is answered "denied" to game callers. Microphone stays denied
/// while the Mac has no audio input.
void mulg_engine_configure_privacy(BOOL microphone, BOOL camera, BOOL photos, BOOL location);
MulgEngineCompatHook mulg_engine_install_compat_hooks(BOOL unrealEngine, BOOL micPermissionSync);
/// Fail unsupported continued-processing submissions on Catalyst with the public
/// unavailable error; supported task types and native system callers remain native.
int mulg_engine_install_continued_processing_hooks(void);
unsigned mulg_engine_unavailable_continued_tasks(void);
NSUInteger mulg_engine_background_task_count(void);
BOOL mulg_engine_background_tracking_available(void);

// UIKit fallbacks; native transitions clear the override. Engine clients can read the effective
// state explicitly, while the checked getters expose it only to game callers.
typedef NS_OPTIONS(NSUInteger, MulgEngineUIKitHook) {
    MulgEngineUIKitHookApplicationState = 1 << 0,
    MulgEngineUIKitHookSceneState = 1 << 1,
    MulgEngineUIKitHookViewLayout = 1 << 2,
};
MulgEngineUIKitHook mulg_engine_install_uikit_hooks(void (^handler)(id view));
void mulg_engine_set_lifecycle_state(id object, NSInteger state);
void mulg_engine_clear_lifecycle_state(id object);
NSInteger mulg_engine_effective_lifecycle_state(id object, SEL selector);
void mulg_engine_set_keep_active(BOOL enabled);
BOOL mulg_engine_keeps_game_active(void);
/// Keep game-owned suspend callbacks consistent with active game-state getters.
int mulg_engine_install_lifecycle_delegate_hooks(void);

/// Frame-critical game threads (engine render and per-frame worker threads, found by the name
/// they give themselves) get a QoS class that prefers the performance cores. Applies to threads
/// named after it is switched on. See MulgThreadPriority.m.
typedef NS_ENUM(NSInteger, MulgEngineThreadRole) {
    MulgEngineThreadRoleNone = 0,
    MulgEngineThreadRoleRender = 1,
    MulgEngineThreadRoleWorker = 2,
};
MulgEngineThreadRole mulg_engine_thread_role(const char *_Nullable name);
void mulg_engine_set_thread_priorities(BOOL enabled);
unsigned mulg_engine_prioritized_thread_count(void);
/// Raised workers allowed for `fastCores` (fast cores - 2, at least 0); -1 when unknown (no limit).
int mulg_engine_worker_budget(int fastCores);
/// Cores in every performance level except the slowest (hw.perflevel*), or -1.
int mulg_engine_fast_core_count(void);
unsigned mulg_engine_raised_worker_count(void);

/// Remembers game-owned lifecycle observers without changing native notification delivery.
/// Fallback events must use notify_game_lifecycle, never NSNotificationCenter.post.
BOOL mulg_engine_install_lifecycle_notifications(void);
/// Input adapters share the engine-owned observer hook. Only callbacks whose code belongs
/// to the game are transformed; native observers, queues, filters and lifecycle tracking stay intact.
typedef void (^MulgNotificationHandler)(NSNotification *notification);
typedef MulgNotificationHandler _Nonnull (^MulgGameNotificationTransform)(NSString *_Nullable name,
                                                                       MulgNotificationHandler handler);
BOOL mulg_engine_set_game_notification_transform(MulgGameNotificationTransform _Nullable transform);
void mulg_engine_notify_game_lifecycle(NSNotificationName name, id _Nullable object);
/// Direct fallback delegate calls are restricted to implementations in game images too.
void mulg_engine_call_game_lifecycle_delegate(id _Nullable delegate, SEL selector, id object);

// Per-game audio preference. Client buffer formats and actual-rate getters remain native.
typedef NS_OPTIONS(NSUInteger, MulgEngineAudioHook) {
    MulgEngineAudioHookPreferredRate = 1 << 0,
    MulgEngineAudioHookActive = 1 << 1,
    MulgEngineAudioHookActiveOptions = 1 << 2,
};
MulgEngineAudioHook mulg_engine_install_audio_hooks(void);
void mulg_engine_configure_audio_preference(double rate, void (^_Nullable handler)(void));
double mulg_engine_audio_session_sample_rate(void);

NS_ASSUME_NONNULL_END

#endif
