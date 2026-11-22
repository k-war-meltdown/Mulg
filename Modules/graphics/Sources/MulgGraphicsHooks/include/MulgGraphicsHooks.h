//
//  MulgGraphicsHooks.h
//  graphics module: Metal presentation hooks for the MetalFX layer, low latency and
//  full-screen performance mode (PLAN.md §5, §6.1).
//

#ifndef MULG_GRAPHICS_HOOKS_H
#define MULG_GRAPHICS_HOOKS_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import "MulgNativeSceneResolution.h"

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    /// Keep at most one finished frame waiting: maximumDrawableCount = 2 (§6.1).
    int lowLatency;
    /// Make game layers opaque, required for direct-to-display presentation (§5.4).
    int makeLayersOpaque;
    /// Render size of the upscaling layer, in percent per side (100 = full size).
    int renderPercent;
    /// Experiment X2: raise the priority of threads that present frames (§16.4).
    int raiseRenderThreadPriority;
    /// Report each presented frame's time to the delegate (input-lag measurement, §6.1).
    int reportPresentTimes;
    /// Display refreshes per capped frame (2 for 60 FPS at 120 Hz, 1.33 for 90); 0 = no cap. Caps
    /// that do not divide the refresh rate alternate hold times so the average matches.
    double refreshesPerFrame;
    /// Seconds per display refresh.
    double refreshPeriod;
    /// The display varies its refresh rate and the window is full screen: capped frames are held
    /// exactly 1/limit instead of whole refreshes.
    int variableRefresh;
    /// With a cap, the game waits before it starts a frame instead of after it, so the frame
    /// reads newer input (§6.1).
    int justInTimeFrameStart;
    /// Without Vsync, enforce the absolute cap before presentation instead of relying on scanout.
    int vsyncDisabled;
} MulgGraphicsConfig;

/// Receives presentation events. `upscale:into:commandBuffer:` runs on the game's render thread
/// and must be fast; the others may run on any thread.
@protocol MulgGraphicsDelegate <NSObject>
/// Encode an upscale of `source` (the game's small frame) into `destination` (a drawable of the
/// game's own layer) in `commandBuffer`. Returns NO when it could not.
- (BOOL)upscale:(id<MTLTexture>)source
           into:(id<MTLTexture>)destination
  commandBuffer:(id<MTLCommandBuffer>)commandBuffer
  extendedRange:(BOOL)extendedRange
    NS_SWIFT_NAME(upscale(_:into:commandBuffer:extendedRange:));
/// A drawable surface was seen; the main actor selects the visible gameplay viewport.
- (void)mainLayerCandidateChanged:(CAMetalLayer *)layer NS_SWIFT_NAME(mainLayerCandidateChanged(_:));
/// The game created its own MetalFX object ("spatial", "temporal", "interpolator").
- (void)gameCreatedMetalFXObject:(NSString *)feature NS_SWIFT_NAME(gameCreatedMetalFXObject(_:));
/// The upscaling layer was presented in a way that can't be upscaled (without a command buffer
/// or Metal 4 queue).
- (void)layerUsesUnsupportedPresentPath:(CAMetalLayer *)layer NS_SWIFT_NAME(layerUsesUnsupportedPresentPath(_:));
/// A frame reached the screen, in the CACurrentMediaTime clock.
- (void)framePresentedAtTime:(CFTimeInterval)time NS_SWIFT_NAME(framePresented(atTime:));
@optional
/// A temporary shortage of output drawables, not an unsupported presentation API.
- (void)outputDrawableUnavailable:(CAMetalLayer *)layer NS_SWIFT_NAME(outputDrawableUnavailable(_:));
@end

typedef NS_OPTIONS(uint32_t, MulgGraphicsHook) {
    MulgGraphicsHookLayerDrawableSize = 1u << 0,
    MulgGraphicsHookLayerNextDrawable = 1u << 1,
    MulgGraphicsHookCommandBufferPresent = 1u << 2,
    MulgGraphicsHookDrawablePresent = 1u << 3,
    MulgGraphicsHookDrawablePresentedHandlers = 1u << 4,
    MulgGraphicsHookMetalFXDetection = 1u << 5,
    MulgGraphicsHookCommandBufferCommit = 1u << 6,
    MulgGraphicsHookMetal4Present = 1u << 7,
    MulgGraphicsHookDrawableLayer = 1u << 8,
    MulgGraphicsHookMetalKitDrawableSize = 1u << 9,
    MulgGraphicsHookViewContentScale = 1u << 10,
    MulgGraphicsHookUnityRenderingSize = 1u << 11,
    MulgGraphicsHookRenderPassSizes = 1u << 12,
};

void mulg_graphics_configure(MulgGraphicsConfig config);
MulgGraphicsConfig mulg_graphics_current_config(void);
/// Select a real drawable pixel height independently of native window dimensions.
void mulg_graphics_set_render_height(int pixels);
/// Frame-rate unlock: game-requested present minimums of about 1/60 or 1/30 s shorten to this many
/// seconds (the unlock target's frame time); 0 leaves them.
void mulg_graphics_set_unlocked_frame_duration(double seconds);
CFTimeInterval mulg_graphics_unlocked_duration(CFTimeInterval requested);
/// Main thread: ask the owning view/engine to change resolution without changing window points.
/// A negative height follows the view at one pixel per point; zero releases the override.
void mulg_graphics_update_render_surface(CAMetalLayer *_Nullable layer, int pixelHeight);
/// UIView.setContentScaleFactor: guard: Metal-backed views never go below the screen's native
/// scale while full resolution is on (graphics.fullResolution), and the selected resolution's
/// scale replaces the engine's own on the render view.
BOOL mulg_graphics_install_full_resolution_hook(void);
void mulg_graphics_set_full_resolution(BOOL enabled);
/// Diagnostic: render-pass attachment sizes the game drew into, most used first ("WxH: N passes").
NSArray<NSString *> *mulg_graphics_render_pass_sizes(void);
/// Attachment sizes since the previous snapshot, including an explicit overflow count.
/// This observes render commands; it does not identify the main scene or alter any resources.
NSDictionary *mulg_graphics_recent_render_pass_sizes(void);
/// Opt-in bounded CPU call sites for large render targets allocated through a discovered device.
void mulg_graphics_set_scene_trace_enabled(BOOL enabled);
/// Explicit graphics-debug sessions only; normal launches install no render-pass probe.
void mulg_graphics_set_diagnostics_enabled(BOOL enabled);
// Main-thread scope for a verified game allocator return address. Returns the previous scope.
uintptr_t mulg_graphics_set_scene_apply_allocator(uintptr_t returnAddress);
NSDictionary *mulg_graphics_scene_trace(void);
/// Test entry: counts one render pass into `texture`.
void mulg_graphics_record_pass_for_testing(id _Nullable texture);
/// How many times the guard changed a scale the game asked for.
int mulg_graphics_full_resolution_raises(void);
// MARK: Forced resolution (graphics.forceRenderResolution, MulgForcedResolution.m)

typedef struct { int32_t width, height; } MulgForcedSize;
typedef NS_ENUM(NSInteger, MulgUnityResolutionState) {
    /// Not a Unity IL2CPP game with its exports: the drawable-size path applies.
    MulgUnityResolutionUnavailable = 0,
    /// Unity has not registered its internal calls yet; try again.
    MulgUnityResolutionWaiting = 1,
    MulgUnityResolutionInstalled = 2,
};
/// Main thread. The target is the window's pixel size at the selected resolution.
void mulg_graphics_set_forced_resolution(BOOL enabled, int width, int height);
BOOL mulg_graphics_forced_resolution_enabled(void);
MulgForcedSize mulg_graphics_forced_target(void);
/// `target` once both are known, whatever the game asked for; otherwise `requested` (pure).
MulgForcedSize mulg_graphics_forced_size(MulgForcedSize requested, MulgForcedSize target);
/// Replaces Unity's Screen.SetResolution internal call once Unity registered it.
MulgUnityResolutionState mulg_graphics_unity_resolution_install(void);
BOOL mulg_graphics_unity_resolution_active(void);
/// A Unity game (class names, also when IL2CPP exports are stripped).
BOOL mulg_graphics_is_unity_engine(void);
/// Forced resolution goes through the drawable size: on, and not a Unity game.
BOOL mulg_graphics_forced_drawable_path(void);
/// Main thread: asks Unity for the target (or, when off, the game's own last size) if that changed.
BOOL mulg_graphics_unity_apply_resolution(void);
/// Any Unity iOS player, IL2CPP names or not: hooks -[DisplayConnection requestRenderingResolution:]
/// so the game's rendering-size request is raised to the target. NO when this is not a Unity player.
BOOL mulg_graphics_install_unity_display_hook(void);
/// Main thread: re-sends the game's last Unity player request (raised, or its own when off) if that changed.
BOOL mulg_graphics_unity_display_apply(void);
/// Main thread, drawable-size path: gives the main layer the forced size, or back the game's own.
BOOL mulg_graphics_forced_apply_main_layer(void);
NSDictionary *mulg_graphics_forced_resolution_report(void);

// MARK: Unity render scale (graphics.forceRenderResolution, MulgUnityRenderScale.m)

typedef NS_ENUM(NSInteger, MulgUnityRenderScaleState) {
    /// No IL2CPP exports (Star Rail): the game keeps its own scene size.
    MulgUnityRenderScaleUnavailable = 0,
    /// IL2CPP has no pipeline getter yet; try again.
    MulgUnityRenderScaleWaiting = 1,
    /// Built-in renderer, or a pipeline without renderScale: nothing to set.
    MulgUnityRenderScaleNone = 2,
    /// The pipeline renders at 1.0.
    MulgUnityRenderScaleApplied = 3,
};
/// Main thread: keeps the active scriptable pipeline's renderScale at 1.0, or gives the game back its
/// own when `enabled` is NO.
MulgUnityRenderScaleState mulg_graphics_unity_render_scale_apply(BOOL enabled);
/// Main thread, graphics.unityHighestQuality: Unity's highest QualitySettings level (at most three times a launch
/// when the game sets its own back), or the game's own level back when `enabled` is NO.
void mulg_graphics_unity_quality_apply(BOOL enabled);
NSDictionary *mulg_graphics_unity_render_scale_report(void);

void mulg_graphics_reset_forced_resolution_for_testing(void);

/// Main thread: view scale, resize adapter and requested target (not proof of internal scene resolution).
NSDictionary *mulg_graphics_render_surface_report(CAMetalLayer *layer);
/// Actual output/source texture dimensions and presentation bounds for ordinary session diagnostics.
NSDictionary *mulg_graphics_render_geometry(CAMetalLayer *layer);
/// On the layer's owning render thread; also used by the restoration acceptance check.
void mulg_graphics_apply_layer_config(CAMetalLayer *layer);

void mulg_graphics_set_delegate(id<MulgGraphicsDelegate> _Nullable delegate);
void mulg_graphics_set_main_layer(CAMetalLayer *_Nullable layer);
CGSize mulg_graphics_main_drawable_size(void);
/// Lightweight surface readiness, independent of optional diagnostic probes.
BOOL mulg_graphics_has_game_drawable(void);
/// Real frames have verified the drawable callbacks and the renderer's buffer/queue hooks.
BOOL mulg_graphics_layer_can_upscale(CAMetalLayer *layer);

/// Main thread. The layer to upscale (§5.2, design B): the game renders into a smaller hidden
/// layer and the upscaled frame is written into this layer's own drawables. nil stops upscaling
/// and gives the previous layer its framebufferOnly back. The game is told the size it now
/// reads, as on a window resize.
void mulg_graphics_set_upscaling_layer(CAMetalLayer *_Nullable layer);
CAMetalLayer *_Nullable mulg_graphics_upscaling_layer(void);

/// Main thread. Gives the hidden source layer the render size of the current config (a new
/// preset) in place, so frames already on their way are still upscaled, and tells the game.
void mulg_graphics_refresh_render_size(void);

/// The drawable size the game asked for on `layer` (its full size), before any reduction.
CGSize mulg_graphics_full_drawable_size(CAMetalLayer *layer);

/// Main thread. While a live window resize runs, the selected game layer keeps its size; the
/// last size asked for is applied once when it ends. The main layer's MTKView, if any, stops
/// resizing its drawable until then.
void mulg_graphics_set_live_resize(BOOL resizing);

/// Brackets Mulg's own MetalFX object creation so it is not reported as the game's.
void mulg_graphics_begin_own_metalfx(void);
void mulg_graphics_end_own_metalfx(void);

/// Installs the hooks. Returns those installed; `attempted` receives every hook tried.
MulgGraphicsHook mulg_graphics_install_hooks(MulgGraphicsHook *_Nullable attempted);
/// Stable presentation services; experimental=false skips MetalFX detection hooks.
/// Metadata-only setup: never creates a device, queue, buffer, layer or drawable. Concrete
/// queue/buffer/drawable hooks install on actual render-device use before nextDrawable returns;
/// those hooks are not attempted during setup. Device changes are discovered immediately.
MulgGraphicsHook mulg_graphics_install_presentation_hooks(BOOL experimental, MulgGraphicsHook *_Nullable attempted);

/// The concrete classes discovered so far, for the hook register ("?" when unknown).
NSString *mulg_graphics_command_buffer_class_name(void);
NSString *mulg_graphics_drawable_class_name(void);
NSString *mulg_graphics_metal4_queue_class_name(void);

/// Shader archive (PLAN.md §5.6): render, compute, mesh and tile pipelines the game builds from descriptors
/// are recorded into the Metal binary archive at `url`, and later launches look them up there
/// before compiling. Saves coalesce into ten-second batches and flush when the game quits.
/// Returns NO when the device class could not be hooked.
BOOL mulg_graphics_start_shader_archive(NSURL *url);
/// Shared disk budget; each archive backend gets half.
static const uint64_t MulgGraphicsShaderArchiveLimit = 1ULL << 30;

/// Metal 4 archives cannot be merged. Keep up to eight numbered files, including at most four
/// pinned launch lookups; live saves evict only unpinned files within the byte budget.
BOOL mulg_graphics_start_metal4_shader_archive(NSURL *url);
/// Flush captured shaders under pressure; game pipeline builds continue normally.
void mulg_graphics_purge_shader_cache(void);
/// Saves captured shaders now (window hidden), on the archive queues. Nothing when unchanged.
void mulg_graphics_save_shader_archives(void);

/// The concrete MTLDevice class hooked by the shader archive ("?" when unknown).
NSString *mulg_graphics_device_class_name(void);

/// For tests: the reduced size for a full size and percentage (even numbers, at least 2).
CGSize mulg_graphics_reduced_size(CGSize full, int percent);

/// For tests: whole refreshes to hold the next frame. `carry` keeps the fraction between frames,
/// so 1.33 refreshes per frame gives 1, 1, 2, … (90 FPS at 120 Hz).
int mulg_graphics_next_hold(double *carry, double refreshesPerFrame);

/// The presentation deadline/duration after applying the current per-layer frame cap.
CFTimeInterval mulg_graphics_pace(id drawable, CFTimeInterval value, BOOL atTime);

NS_ASSUME_NONNULL_END

#endif
