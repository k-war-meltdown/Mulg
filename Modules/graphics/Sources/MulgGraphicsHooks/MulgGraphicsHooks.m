//
//  MulgGraphicsHooks.m
//  graphics module: Metal presentation hooks (PLAN.md §5.2, §5.4, §6.1).
//
//  The MetalFX layer (design B, §5.2):
//  - while upscaling, the game's layer hands the game drawables of a smaller hidden layer (the
//    source) and reports the smaller size from drawableSize;
//  - when the game commits a command buffer presenting a source drawable, the delegate encodes a
//    MetalFX upscale into that same command buffer, into a drawable of the game's own layer, and
//    that drawable is presented with the game's own present call. The game's layer stays the
//    only layer on screen, so macOS can still show it directly (§5.4), and no frame of latency
//    is added;
//  - Metal 4 games present through MTL4CommandQueue: the upscale runs on Mulg's own queue once
//    the game's queue has finished the frame, and is presented by the game's own present call;
//  - the game's "presented" handlers and presentedTime are forwarded from the drawable that
//    was actually shown, so engines that pace frames from them keep working;
//  - a source drawable presented any other way is reported, and the module switches the layer
//    off (§5.2, "fall back cleanly").
//
//  Frame cap (§6.1): every way a drawable is presented (now, at a time, after a duration) is held
//  to the cap, with one rhythm per layer. Just-in-time frame start moves the wait a capped game
//  would spend in nextDrawable to before it reads input.
//
//  The hooks target the concrete Metal classes found on actual device use, never hard-coded driver
//  class names (§5.2.3).
//

#import "MulgGraphicsHooks.h"
#import <MulgEngineHooks.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <os/signpost.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <math.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/// The lock Mulg takes for a game or system object (a drawable, layer, queue, command buffer or Metal class):
/// a private object attached to it, never the object itself. `@synchronized (drawable)` shared its lock with
/// the game, Apple's frameworks and any other injected code that synchronizes on the same object, which could
/// deadlock them against Mulg's render-path hooks. Nil for nil, so `@synchronized` stays a no-op there.
static id mulg_lock(id object) {
    if (object == nil) return nil;
    static char key;
    id lock = objc_getAssociatedObject(object, &key);
    if (lock) return lock;
    static os_unfair_lock creation = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&creation);
    lock = objc_getAssociatedObject(object, &key);
    if (lock == nil) {
        lock = [NSObject new];
        objc_setAssociatedObject(object, &key, lock, OBJC_ASSOCIATION_RETAIN);
    }
    os_unfair_lock_unlock(&creation);
    return lock;
}

typedef void (*SetSize)(id, SEL, CGSize);
typedef CGSize (*SizeGetter)(id, SEL);
typedef id (*Getter)(id, SEL);
typedef void (*PresentDrawable)(id, SEL, id);
typedef void (*PresentDrawableAtTime)(id, SEL, id, CFTimeInterval);
typedef void (*Present)(id, SEL);
typedef void (*PresentAtTime)(id, SEL, CFTimeInterval);
typedef void (*Commit)(id, SEL);
typedef void (*AddPresentedHandler)(id, SEL, MTLDrawablePresentedHandler);
typedef CFTimeInterval (*TimeGetter)(id, SEL);
typedef id (*DescriptorFactory)(id, SEL, id);
typedef id (*NewFXObject)(id, SEL, id) __attribute__((ns_returns_retained));
typedef id (*NewFXObjectWithCompiler)(id, SEL, id, id) __attribute__((ns_returns_retained));

static IMP previous_set_drawable_size;
static IMP previous_drawable_size;
static IMP previous_mtk_drawable_size;
static IMP previous_next_drawable;
static IMP previous_fx_spatial;
static IMP previous_fx_temporal;
static IMP previous_fx_interpolator;
static IMP previous_fx_denoised;
static IMP previous_fx4_spatial;
static IMP previous_fx4_temporal;
static IMP previous_fx4_interpolator;
static IMP previous_fx4_denoised;

// Runtime classes outlive the process. Publish the first actual presentation classes without
// retaining an object or racing a render-thread discovery against diagnostic readback.
static _Atomic(uintptr_t) mulg_buffer_class_address;
static _Atomic(uintptr_t) mulg_drawable_class_address;
static _Atomic(uintptr_t) mulg_queue4_class_address;

static char kFullSizeKey;
/// The main layer's size as the game last set it, before forced resolution (restored when that is off).
static char kGameRequestKey;
static char kSizeNotificationPendingKey;
static char kLayerConfiguredKey;
static char kInterceptedKey;
static char kReplacementKey;
static char kPresentedHandlersKey;
static char kPresentedTimeKey;
static char kFramebufferOnlyKey;
static char kSourceKey;
static char kQueueEventKey;
static char kQueueResidencyKey;
static char kPendingBufferKey;
static char kSourcePendingKey;
static char kWrappedSourceKey;
static char kPresentationPathKey;
static char kReportedFrameKey;
static char kAcquisitionKey;
static char kLayerOwnerKey;
static char kBufferPresentsKey;
static char kClassicPresentKey;
static char kJITFrameKey;
// First game acquisition: native device (0), attempted recovery (1), repaired (2).
static char kInitialDeviceStateKey;
static __thread int mulg_in_own_submission;

@interface MulgLayerOwner : NSObject
@property(nonatomic, weak) CAMetalLayer *layer;
@end
@implementation MulgLayerOwner
@end

static CAMetalLayer *mulg_drawable_layer(id self, SEL selector);
static CAMetalLayer *physical_layer(id drawable);

/// A Metal 4 upscale waiting for the game to present its source frame. Whoever takes the buffer
/// first commits it: the present, or a later frame when the game dropped this one.
@interface MulgPendingFrame : NSObject {
@public
    id<MTLCommandBuffer> _buffer;
    __weak id _drawable;
    _Atomic(bool) _taken;
    BOOL _encoding; // Presentation state is guarded by the original drawable.
    BOOL _discardRequested;
    BOOL _presentRequested;
    SEL _how;
    CFTimeInterval _value;
}
@end

@implementation MulgPendingFrame
@end

static id<MTLCommandBuffer> take_pending(MulgPendingFrame *frame) {
    if (frame == nil || frame->_buffer == nil || atomic_exchange(&frame->_taken, true)) {
        return nil;
    }
    id<MTLCommandBuffer> buffer = frame->_buffer;
    frame->_buffer = nil;
    return buffer;
}

static void discard_pending(MulgPendingFrame *frame) {
    if (!frame) return;
    id drawable = frame->_drawable;
    id<MTLCommandBuffer> buffer;
    @synchronized (mulg_lock(drawable)) {
        if (frame->_encoding) { frame->_discardRequested = YES; return; }
        buffer = take_pending(frame);
    }
    if (buffer == nil) return;
    // Break the original -> replacement -> presented-handler ownership on dropped frames.
    if (drawable != nil) {
        @synchronized (mulg_lock(drawable)) {
            if (objc_getAssociatedObject(drawable, &kPendingBufferKey) == frame) {
                objc_setAssociatedObject(drawable, &kReplacementKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(drawable, &kPresentedHandlersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(drawable, &kPendingBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(drawable, &kJITFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    [buffer commit];
}

static BOOL skip_present(id drawable, SEL how, CFTimeInterval value);

// Per source, rather than per queue: two game queues still share one drawable pool.
static void retire_source_frames(CAMetalLayer *source, NSUInteger keep, BOOL present) {
    if (source == nil || objc_getAssociatedObject(source, &kSourcePendingKey) == nil) return;
    NSMutableArray<MulgPendingFrame *> *retired = nil;
    @synchronized (mulg_lock(source)) {
        NSMutableArray<MulgPendingFrame *> *frames = objc_getAssociatedObject(source, &kSourcePendingKey);
        for (MulgPendingFrame *frame in [frames copy]) {
            if (atomic_load(&frame->_taken)) [frames removeObject:frame];
        }
        while (frames.count > keep) {
            if (retired == nil) retired = [NSMutableArray new];
            [retired addObject:frames.firstObject];
            [frames removeObjectAtIndex:0];
        }
    }
    // Commit outside the source lock; completion/presentation may call back into hooks.
    for (MulgPendingFrame *frame in retired) {
        id drawable = frame->_drawable;
        if (!present || drawable == nil || !skip_present(drawable, @selector(present), 0)) discard_pending(frame);
    }
}

static NSUInteger pending_budget(CAMetalLayer *source, CAMetalLayer *output) {
    NSUInteger count = MIN(source.maximumDrawableCount, output.maximumDrawableCount);
    return count > 1 ? count - 1 : 0;
}

static inline uintptr_t address(id object) {
    return (uintptr_t)(__bridge void *)object;
}

static void jit_configure(MulgGraphicsConfig old, MulgGraphicsConfig config);
static void jit_reset(void);
static BOOL same_pacing(MulgGraphicsConfig a, MulgGraphicsConfig b);
static void note_presentation_path(id drawable, BOOL supported);
static void mulg_drawable_present_after_duration(id self, SEL _cmd, CFTimeInterval duration);
static MulgGraphicsHook install_buffer(Class cls);
static MulgGraphicsHook install_drawable(Class cls);
static MulgGraphicsHook install_queue4(Class cls);
static void install_device(Class cls);
static void discover_presentation_device(id<MTLDevice> device);
static BOOL install_shader_device(Class cls);
static BOOL install_shader4_device(Class cls);
static id<MTLBinaryArchive> open_archive(id<MTLDevice> device, NSURL *url);
#define ORIGINAL(object, selector, replacement) mulg_swizzle_original(object_getClass(object), selector, (IMP)replacement)

static atomic_bool game_drawable_seen;
BOOL mulg_graphics_has_game_drawable(void) { return atomic_load_explicit(&game_drawable_seen, memory_order_relaxed); }

static id discover_drawable(id drawable) {
    if (drawable) {
        if (!atomic_load_explicit(&game_drawable_seen, memory_order_relaxed))
            atomic_store_explicit(&game_drawable_seen, true, memory_order_relaxed);
        install_drawable(object_getClass(drawable));
        MulgPendingFrame *previous;
        @synchronized (mulg_lock(drawable)) {
            previous = objc_getAssociatedObject(drawable, &kPendingBufferKey);
            objc_setAssociatedObject(drawable, &kAcquisitionKey, [NSObject new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            void *keys[] = { &kReportedFrameKey, &kInterceptedKey, &kReplacementKey,
                &kPresentedHandlersKey, &kPresentedTimeKey, &kPendingBufferKey, &kClassicPresentKey, &kJITFrameKey };
            for (NSUInteger index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
                objc_setAssociatedObject(drawable, keys[index], nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        discard_pending(previous);
    }
    return drawable;
}

// MARK: - Configuration and delegate

static MulgGraphicsConfig mulg_config = { .renderPercent = 100 };
static os_unfair_lock mulg_config_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic(unsigned) mulg_config_generation = 1;
static _Atomic(unsigned) mulg_timing_generation = 1;
static _Atomic(int) mulg_render_height;
static _Atomic(uintptr_t) mulg_main_address;

void mulg_graphics_set_render_height(int pixels) {
    int value = pixels > 0 && pixels <= 16384 ? pixels : 0;
    if (atomic_exchange(&mulg_render_height, value) != value) atomic_fetch_add(&mulg_config_generation, 1);
}

void mulg_graphics_configure(MulgGraphicsConfig config) {
    os_unfair_lock_lock(&mulg_config_lock);
    MulgGraphicsConfig old = mulg_config;
    mulg_config = config;
    if (!same_pacing(old, config)) atomic_fetch_add(&mulg_timing_generation, 1);
    jit_configure(old, config);
    // Publish the new version while its configuration and timing are still
    // protected together. Cached readers never label a new snapshot as old.
    atomic_fetch_add_explicit(&mulg_config_generation, 1, memory_order_release);
    os_unfair_lock_unlock(&mulg_config_lock);
}

typedef struct {
    MulgGraphicsConfig config;
    unsigned configuration, timing;
} MulgGraphicsSnapshot;

static MulgGraphicsSnapshot graphics_snapshot(void) {
    // Value-only thread storage: no game objects or resources are retained.
    // Steady-state presentation needs one acquire load instead of a shared lock.
    static __thread MulgGraphicsSnapshot cached;
    unsigned generation = atomic_load_explicit(&mulg_config_generation, memory_order_acquire);
    if (cached.configuration != generation) {
        os_unfair_lock_lock(&mulg_config_lock);
        cached.config = mulg_config;
        cached.timing = atomic_load_explicit(&mulg_timing_generation, memory_order_relaxed);
        cached.configuration = atomic_load_explicit(&mulg_config_generation, memory_order_relaxed);
        os_unfair_lock_unlock(&mulg_config_lock);
    }
    return cached;
}

MulgGraphicsConfig mulg_graphics_current_config(void) {
    return graphics_snapshot().config;
}

static id<MulgGraphicsDelegate> mulg_delegate;
static os_unfair_lock mulg_delegate_lock = OS_UNFAIR_LOCK_INIT;

void mulg_graphics_set_delegate(id<MulgGraphicsDelegate> delegate) {
    os_unfair_lock_lock(&mulg_delegate_lock);
    id<MulgGraphicsDelegate> old = mulg_delegate;
    mulg_delegate = delegate;
    os_unfair_lock_unlock(&mulg_delegate_lock);
    (void)old; // released here, outside the lock
}

static id<MulgGraphicsDelegate> current_delegate(void) {
    os_unfair_lock_lock(&mulg_delegate_lock);
    id<MulgGraphicsDelegate> delegate = mulg_delegate;
    os_unfair_lock_unlock(&mulg_delegate_lock);
    return delegate;
}

// MARK: - Upscaling state

static __weak CAMetalLayer *mulg_upscaling_layer;
static __weak CAMetalLayer *mulg_source_layer;
/// The two layers' addresses, compared only, never dereferenced: checked on every frame and
/// every drawableSize read without a weak load.
static _Atomic(uintptr_t) mulg_upscaled_address = 0;
static _Atomic(uintptr_t) mulg_source_address = 0;
/// When the upscaling layer was last set (CLOCK_UPTIME_RAW, ns). Frames already on their way
/// were presented before their drawables could be marked, so they are not reported.
static _Atomic(uint64_t) mulg_upscaling_since = 0;
static const uint64_t kUpscalingGraceNanoseconds = 250000000ULL;
/// Set while Mulg itself reads a size or takes a drawable, so the upscaled layer's real size is
/// seen instead of the one reported to the game.
static __thread int mulg_in_own_call = 0;

static BOOL is_source_drawable(id drawable) {
    uintptr_t source = atomic_load_explicit(&mulg_source_address, memory_order_relaxed);
    return source != 0 && [drawable respondsToSelector:@selector(layer)]
        && address(physical_layer(drawable)) == source;
}

static CAMetalLayer *physical_layer(id drawable) {
    if (![drawable respondsToSelector:@selector(layer)]) return nil;
    SEL selector = @selector(layer);
    Method method = class_getInstanceMethod(object_getClass(drawable), selector);
    if (!method) return nil;
    IMP current = method_getImplementation(method);
    if (current == (IMP)mulg_drawable_layer) {
        return ((Getter)ORIGINAL(drawable, selector, mulg_drawable_layer))(drawable, selector);
    }
    // A rejected native override must still use its own getter, not an ancestor's saved IMP.
    // Guard unknown getters before interpreting their result as a layer object.
    char result[3] = {0};
    method_getReturnType(method, result, sizeof(result));
    if (strcmp(result, @encode(id)) != 0 || method_getNumberOfArguments(method) != 2) return nil;
    mulg_in_own_call++;
    @try { return ((Getter)current)(drawable, selector); }
    @finally { mulg_in_own_call--; }
}

static CAMetalLayer *mulg_drawable_layer(id self, SEL selector) {
    CAMetalLayer *source = ((Getter)ORIGINAL(self, selector, mulg_drawable_layer))(self, selector);
    if (!mulg_in_own_call && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        MulgLayerOwner *owner = objc_getAssociatedObject(source, &kLayerOwnerKey);
        CAMetalLayer *visible = owner.layer;
        if (visible) return visible;
    }
    return source;
}

// MARK: - Sizes

CGSize mulg_graphics_reduced_size(CGSize full, int percent) {
    if (percent <= 0 || percent >= 100) {
        return full;
    }
    long width = (long)full.width * percent / 100;
    long height = (long)full.height * percent / 100;
    width -= width % 2;
    height -= height % 2;
    return CGSizeMake(width < 2 ? 2 : width, height < 2 ? 2 : height);
}

static CGSize real_drawable_size(CAMetalLayer *layer) {
    mulg_in_own_call += 1;
    CGSize size = layer.drawableSize;
    mulg_in_own_call -= 1;
    return size;
}

static void remember_full_size(CAMetalLayer *layer, CGSize size) {
    NSValue *value = [NSValue valueWithBytes:&size objCType:@encode(CGSize)];
    objc_setAssociatedObject(layer, &kFullSizeKey, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

CGSize mulg_graphics_full_drawable_size(CAMetalLayer *layer) {
    NSValue *value = objc_getAssociatedObject(layer, &kFullSizeKey);
    if (value != nil) {
        CGSize size;
        [value getValue:&size size:sizeof(size)];
        return size;
    }
    // Never set explicitly: the current size is the full size.
    return real_drawable_size(layer);
}

NSDictionary *mulg_graphics_render_geometry(CAMetalLayer *layer) {
    CGSize output = real_drawable_size(layer);
    CAMetalLayer *source = objc_getAssociatedObject(layer, &kSourceKey);
    CGSize input = source ? real_drawable_size(source) : output;
    CGSize points = layer.bounds.size;
    CGSize requested = mulg_graphics_full_drawable_size(layer);
    CGSize nativeRequest = requested;
    NSValue *gameRequest = objc_getAssociatedObject(layer, &kGameRequestKey);
    if (gameRequest) [gameRequest getValue:&nativeRequest size:sizeof(nativeRequest)];
    NSMutableDictionary *report = [@{@"outputPixelWidth": @(output.width), @"outputPixelHeight": @(output.height),
        @"inputPixelWidth": @(input.width), @"inputPixelHeight": @(input.height),
        @"gameRequestedPixelWidth": @(requested.width), @"gameRequestedPixelHeight": @(requested.height),
        @"nativeRequestedPixelWidth": @(nativeRequest.width), @"nativeRequestedPixelHeight": @(nativeRequest.height),
        @"drawableMatchesGameRequest": @(CGSizeEqualToSize(requested, output)),
        @"metalDeviceAvailable": @(layer.device != nil),
        @"metalDeviceRecovered": @([objc_getAssociatedObject(layer, &kInitialDeviceStateKey) intValue] == 2),
        @"surfacePointWidth": @(points.width), @"surfacePointHeight": @(points.height),
        @"targetPixelHeight": @(atomic_load(&mulg_render_height)), @"upscaling": @(source != nil)} mutableCopy];
    [report addEntriesFromDictionary:mulg_graphics_render_surface_report(layer)];
    return report;
}

/// Gives the source layer the render size for an upscaled layer of size `full`. Returns YES
/// when that changed the size the game reads.
static BOOL size_source(CAMetalLayer *source, CGSize full) {
    CGSize size = mulg_graphics_reduced_size(full, mulg_graphics_current_config().renderPercent);
    if (CGSizeEqualToSize(source.drawableSize, size)) {
        return NO;
    }
    ((SetSize)previous_set_drawable_size)(source, @selector(setDrawableSize:), size);
    return YES;
}

/// Notify the renderer through MTKView's pixel-size callback. Generic renderers read their
/// drawable size. UIKit layout must never be driven by MetalFX's reduced render targets.
static void announce_drawable_size(CAMetalLayer *layer) {
    // Preserve renderers that size the layer directly, but publish only the newest size
    // once per main-queue turn rather than replaying every intermediate resize callback.
    @synchronized (mulg_lock(layer)) {
        if (objc_getAssociatedObject(layer, &kSizeNotificationPendingKey)) return;
        objc_setAssociatedObject(layer, &kSizeNotificationPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    __weak CAMetalLayer *weakLayer = layer;
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *strong = weakLayer;
        if (!strong) return;
        @synchronized (mulg_lock(strong)) {
            objc_setAssociatedObject(strong, &kSizeNotificationPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        id view = strong.delegate;
        Class mtkView = objc_getClass("MTKView");
        if (mtkView != Nil && [view isKindOfClass:mtkView]) {
            id delegate = [view valueForKey:@"delegate"];
            SEL willChange = sel_registerName("mtkView:drawableSizeWillChange:");
            if ([delegate respondsToSelector:willChange]) {
                CAMetalLayer *source = objc_getAssociatedObject(strong, &kSourceKey);
                CGSize reported = source ? real_drawable_size(source) : real_drawable_size(strong);
                ((void (*)(id, SEL, id, CGSize))objc_msgSend)(delegate, willChange, view, reported);
            }
        }
        // A render-target change must never request UIKit/window layout. Generic engines
        // observe their drawable size; MTKView receives the render-specific callback above.
    });
}

/// Gives `layer` its size, and the source layer the reduced size when `layer` is upscaled.
static void apply_drawable_size(CAMetalLayer *layer, CGSize size) {
    // Resolution changes go through the owning render view. Never replace an engine's
    // request with larger textures while its viewport/depth targets keep the old size.
    BOOL changed = !CGSizeEqualToSize(real_drawable_size(layer), size);
    if (changed) ((SetSize)previous_set_drawable_size)(layer, @selector(setDrawableSize:), size);
    BOOL sourceChanged = NO;
    if (address(layer) == atomic_load(&mulg_upscaled_address)) {
        CAMetalLayer *source = mulg_source_layer;
        sourceChanged = source != nil && size_source(source, size);
    }
    if (changed || sourceChanged) announce_drawable_size(layer);
}

// MARK: - Live resize (§5.2)

// Native drawable writes must follow the engine's depth/MSAA targets throughout a resize.
// Layer configuration waits until dragging ends; native size requests remain immediate.
static _Atomic(int) mulg_live_resize = 0;
static __weak CAMetalLayer *mulg_candidate_layer;

CGSize mulg_graphics_main_drawable_size(void) {
    CAMetalLayer *layer = mulg_candidate_layer;
    return layer ? real_drawable_size(layer) : CGSizeZero;
}

void mulg_graphics_set_live_resize(BOOL resizing) {
    atomic_store(&mulg_live_resize, resizing ? 1 : 0);
}

// MARK: - Main-layer candidate

void mulg_graphics_set_main_layer(CAMetalLayer *layer) {
    os_unfair_lock_lock(&mulg_config_lock);
    CAMetalLayer *old = mulg_candidate_layer;
    mulg_candidate_layer = layer;
    if (atomic_exchange(&mulg_main_address, address(layer)) != address(layer)) {
        atomic_fetch_add(&mulg_timing_generation, 1);
        jit_reset();
        // Publish only after the surface timing/reset is complete. A snapshot
        // must not cache this version with the previous timing generation.
        atomic_fetch_add_explicit(&mulg_config_generation, 1, memory_order_release);
    }
    os_unfair_lock_unlock(&mulg_config_lock);
    // Layer setters can enter the renderer; never call them under the settings lock.
    if (old && old != layer) mulg_graphics_apply_layer_config(old);
    if (layer) mulg_graphics_apply_layer_config(layer);
}

static void note_candidate(CAMetalLayer *layer, CGSize size) {
    if (size.width > 0 && size.height > 0) {
        [current_delegate() mainLayerCandidateChanged:layer];
    }
}

BOOL mulg_graphics_layer_can_upscale(CAMetalLayer *layer) {
    return previous_set_drawable_size && previous_drawable_size && previous_next_drawable
        && [objc_getAssociatedObject(layer, &kPresentationPathKey) boolValue];
}

static BOOL drawable_callbacks_ready(id drawable) {
    MulgGraphicsHook needed = MulgGraphicsHookDrawablePresent | MulgGraphicsHookDrawablePresentedHandlers | MulgGraphicsHookDrawableLayer;
    return (install_drawable(object_getClass(drawable)) & needed) == needed;
}

/// Learn from real native frames, not a startup probe. A source cannot prove its own path.
static void note_presentation_path(id drawable, BOOL supported) {
    if (![drawable respondsToSelector:@selector(layer)]) return;
    CAMetalLayer *layer = physical_layer(drawable);
    supported = supported && drawable_callbacks_ready(drawable);
    if (objc_getAssociatedObject(layer, &kWrappedSourceKey)) {
        if (!supported && is_source_drawable(drawable)) {
            CAMetalLayer *output = mulg_upscaling_layer;
            if (output) [current_delegate() layerUsesUnsupportedPresentPath:output];
        }
        return;
    }
    // Stable frames still validate the drawable's capabilities and source
    // ownership above, but do not need to reacquire the layer bookkeeping lock.
    NSNumber *known = objc_getAssociatedObject(layer, &kPresentationPathKey);
    if (known && known.boolValue == supported) return;
    BOOL changed;
    @synchronized (mulg_lock(layer)) {
        NSNumber *previous = objc_getAssociatedObject(layer, &kPresentationPathKey);
        changed = previous == nil || previous.boolValue != supported;
        if (changed) objc_setAssociatedObject(layer, &kPresentationPathKey, @(supported), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (changed) note_candidate(layer, mulg_graphics_full_drawable_size(layer));
}

// MARK: - Upscaling layer

void mulg_graphics_set_upscaling_layer(CAMetalLayer *layer) {
    CAMetalLayer *previous = mulg_upscaling_layer;
    if (previous == layer) {
        return;
    }
    retire_source_frames(mulg_source_layer, 0, YES);
    atomic_store(&mulg_upscaled_address, 0);
    atomic_store(&mulg_source_address, 0);
    mulg_source_layer = nil;
    mulg_upscaling_layer = layer;
    if (previous != nil) {
        objc_setAssociatedObject(previous, &kSourceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // framebufferOnly lets the GPU keep the frame compressed; give it back.
        NSNumber *framebufferOnly = objc_getAssociatedObject(previous, &kFramebufferOnlyKey);
        if (framebufferOnly != nil) {
            previous.framebufferOnly = framebufferOnly.boolValue;
            objc_setAssociatedObject(previous, &kFramebufferOnlyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        announce_drawable_size(previous);
    }
    if (layer == nil) {
        return;
    }
    CGSize full = mulg_graphics_full_drawable_size(layer);
    if (!objc_getAssociatedObject(layer, &kFullSizeKey)) remember_full_size(layer, full);
    // MetalFX writes the upscaled frame into the game's drawables.
    objc_setAssociatedObject(layer, &kFramebufferOnlyKey, @(layer.framebufferOnly), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    layer.framebufferOnly = NO;

    // Never in a layer tree: only its drawables are used, as the game's small frames.
    CAMetalLayer *source = [CAMetalLayer layer];
    MulgLayerOwner *owner = [MulgLayerOwner new];
    owner.layer = layer;
    objc_setAssociatedObject(source, &kLayerOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(source, &kWrappedSourceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    source.device = layer.device;
    source.pixelFormat = layer.pixelFormat;
    source.maximumDrawableCount = layer.maximumDrawableCount;
    source.allowsNextDrawableTimeout = layer.allowsNextDrawableTimeout;
    // MetalFX must be able to read the game's frame (§5.2, "readable frames").
    source.framebufferOnly = NO;
    size_source(source, full);
    objc_setAssociatedObject(layer, &kSourceKey, source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    mulg_source_layer = source;
    atomic_store(&mulg_upscaling_since, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    atomic_store(&mulg_source_address, address(source));
    atomic_store(&mulg_upscaled_address, address(layer));
    announce_drawable_size(layer);
}

CAMetalLayer *mulg_graphics_upscaling_layer(void) {
    return mulg_upscaling_layer;
}

void mulg_graphics_refresh_render_size(void) {
    CAMetalLayer *layer = mulg_upscaling_layer;
    CAMetalLayer *source = mulg_source_layer;
    if (layer != nil && source != nil && size_source(source, mulg_graphics_full_drawable_size(layer))) {
        announce_drawable_size(layer);
    }
}

// MARK: - Own MetalFX objects

static __thread int mulg_creating_own_metalfx = 0;

void mulg_graphics_begin_own_metalfx(void) {
    mulg_creating_own_metalfx += 1;
}

void mulg_graphics_end_own_metalfx(void) {
    mulg_creating_own_metalfx -= 1;
}

// MARK: - CAMetalLayer

static void mulg_set_drawable_size(CAMetalLayer *self, SEL _cmd, CGSize size) {
    if (address(self) == atomic_load_explicit(&mulg_source_address, memory_order_relaxed)) {
        ((SetSize)previous_set_drawable_size)(self, _cmd, size);
        return;
    }
    if (!isfinite(size.width) || !isfinite(size.height) || size.width < 0 || size.height < 0) return;
    if (address(self) == atomic_load(&mulg_upscaled_address)
        && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        CAMetalLayer *source = mulg_source_layer;
        // Some engines echo the size they read. That is the SOURCE size, and must
        // never become a new output size that gets reduced again on the next frame.
        if (source && CGSizeEqualToSize(size, real_drawable_size(source))) return;
    }
    // Forced resolution, every game Unity's own call does not cover: a smaller size the game sets on
    // its main layer becomes the window's pixel size, and the engine hears of it as on a resize.
    if (!mulg_in_own_call && address(self) == atomic_load(&mulg_main_address)) {
        objc_setAssociatedObject(self, &kGameRequestKey, [NSValue valueWithBytes:&size objCType:@encode(CGSize)],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The engine owns the matching viewport/depth/MSAA targets. Enlarging only this
    // layer makes engines reject every drawable whose texture size differs from them.
    // Resolution requests must go through a coordinated render-view/engine adapter.
    remember_full_size(self, size);
    note_candidate(self, size);
    apply_drawable_size(self, size);
}

/// The upscaled layer reports its source's (smaller) size to the game, which renders into the
/// source's drawables.
static CGSize mulg_drawable_size(CAMetalLayer *self, SEL _cmd) {
    if (!mulg_in_own_call && mulg_engine_is_game_caller(__builtin_return_address(0))
        && address(self) == atomic_load_explicit(&mulg_upscaled_address, memory_order_relaxed)) {
        CAMetalLayer *source = mulg_source_layer;
        if (source != nil) {
            return ((SizeGetter)previous_drawable_size)(source, _cmd);
        }
    }
    return ((SizeGetter)previous_drawable_size)(self, _cmd);
}

static CGSize mulg_mtk_drawable_size(id self, SEL _cmd) {
    if (!mulg_in_own_call && mulg_engine_is_game_caller(__builtin_return_address(0))) {
        CAMetalLayer *layer = [self layer];
        if ([layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *source = objc_getAssociatedObject(layer, &kSourceKey);
            if (source) return real_drawable_size(source);
            if (address(layer) == atomic_load(&mulg_main_address) && atomic_load(&mulg_render_height) > 0)
                return mulg_graphics_full_drawable_size(layer);
        }
    }
    return ((SizeGetter)previous_mtk_drawable_size)(self, _cmd);
}

/// Save the game's values and restore them when a live setting is switched off.
void mulg_graphics_apply_layer_config(CAMetalLayer *layer) {
    @synchronized (mulg_lock(layer)) {
    NSMutableDictionary *saved = objc_getAssociatedObject(layer, &kLayerConfiguredKey);
    if (!saved) {
        saved = [@{@"drawables": @(layer.maximumDrawableCount), @"opaque": @(layer.opaque),
                   @"lowLatency": @NO, @"forceOpaque": @NO} mutableCopy];
        objc_setAssociatedObject(layer, &kLayerConfiguredKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    MulgGraphicsConfig config = mulg_graphics_current_config();
    BOOL forceOpaque = config.makeLayersOpaque && address(layer) == atomic_load(&mulg_main_address);
    if (config.lowLatency) {
        // Engines can reset these properties when recreating their render surface.
        // Reassert the active policy and remember their latest value for restoration.
        if (![saved[@"lowLatency"] boolValue] || layer.maximumDrawableCount != 2)
            saved[@"drawables"] = @(layer.maximumDrawableCount);
        if (layer.maximumDrawableCount > 2) layer.maximumDrawableCount = 2;
    } else if (!config.lowLatency && [saved[@"lowLatency"] boolValue]) {
        if (layer.maximumDrawableCount == 2) layer.maximumDrawableCount = [saved[@"drawables"] unsignedIntegerValue];
    }
    if (forceOpaque) {
        if (![saved[@"forceOpaque"] boolValue] || !layer.opaque) saved[@"opaque"] = @(layer.opaque);
        if (!layer.opaque) layer.opaque = YES;
    } else if (!forceOpaque && [saved[@"forceOpaque"] boolValue]) {
        if (layer.opaque) layer.opaque = [saved[@"opaque"] boolValue];
    }
    saved[@"lowLatency"] = @(config.lowLatency);
    saved[@"forceOpaque"] = @(forceOpaque);
    }
    if (previous_set_drawable_size && previous_drawable_size
        && !atomic_load(&mulg_live_resize) && !objc_getAssociatedObject(layer, &kWrappedSourceKey)) {
        apply_drawable_size(layer, mulg_graphics_full_drawable_size(layer));
    }
}

/// iOS engines can leave the layer's device implicit; Catalyst then returns no drawable.
/// Resolve only the first game-owned acquisition, using the sole native GPU. Never choose
/// among multiple devices, replace an assigned device, or undo a later teardown/reset.
static id<MTLDevice> prepare_layer_device(CAMetalLayer *layer, const void *caller) {
    if (!mulg_engine_is_game_caller(caller)) return layer.device;
    @synchronized (mulg_lock(layer)) {
        if (objc_getAssociatedObject(layer, &kInitialDeviceStateKey)) return layer.device;
        id<MTLDevice> device = layer.device;
        objc_setAssociatedObject(layer, &kInitialDeviceStateKey, device ? @0 : @1, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (device) return device;
        // No device/queue creation during hook installation. This runs only when the
        // game actually requests its first frame, and enumeration is bounded to once.
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        if (devices.count == 1 && layer.device == nil) {
            layer.device = devices.firstObject;
            if (layer.device != nil) {
                objc_setAssociatedObject(layer, &kInitialDeviceStateKey, @2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                os_log(os_log_create("io.mulg", "graphics"), "Recovered missing Metal device on game render layer (single native GPU)");
            }
        }
        return layer.device;
    }
}
static void reap_abandoned_presents(void);

static id mulg_next_drawable(CAMetalLayer *self, SEL _cmd) {
    // An abandoned buffer may own the last free drawable. Reclaim its request before
    // blocking for another drawable; waiting for the next present can deadlock the pool.
    reap_abandoned_presents();
    uintptr_t me = address(self);
    if (me == atomic_load_explicit(&mulg_source_address, memory_order_relaxed)) {
        retire_source_frames(self, pending_budget(self, mulg_upscaling_layer), NO);
        return discover_drawable(((Getter)previous_next_drawable)(self, _cmd));
    }
    // Runs every frame on the render thread. When the layer is the one this thread saw last,
    // skip the associated-object lookups and the candidate lock; size changes still reach
    // note_candidate through setDrawableSize:.
    // Activity must arrive well inside the viewport's two-second expiry, even at low FPS.
    static __thread __unsafe_unretained CAMetalLayer *last_layer;
    static __thread __unsafe_unretained id<MTLDevice> last_device;
    static __thread uint64_t last_check;
    static __thread unsigned last_generation;
    id<MTLDevice> device = self.device;
    unsigned generation = atomic_load(&mulg_config_generation);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (self != last_layer || device != last_device || generation != last_generation || now - last_check >= 500000000ULL) {
        device = prepare_layer_device(self, __builtin_return_address(0));
        last_layer = self;
        last_device = device;
        last_generation = generation;
        last_check = now;
        discover_presentation_device(device);
        mulg_graphics_apply_layer_config(self);
        note_candidate(self, mulg_graphics_full_drawable_size(self));
    }
    if (me == atomic_load_explicit(&mulg_upscaled_address, memory_order_relaxed)) {
        CAMetalLayer *source = mulg_source_layer;
        if (source != nil) {
            retire_source_frames(source, pending_budget(source, self), NO);
            // The game may change these at any time; the source follows before each frame.
            if (source.pixelFormat != self.pixelFormat) {
                source.pixelFormat = self.pixelFormat;
            }
            if (source.device != self.device) {
                source.device = self.device;
            }
            if (source.maximumDrawableCount != self.maximumDrawableCount) {
                source.maximumDrawableCount = self.maximumDrawableCount;
            }
            if (source.allowsNextDrawableTimeout != self.allowsNextDrawableTimeout) {
                source.allowsNextDrawableTimeout = self.allowsNextDrawableTimeout;
            }
            id drawable = discover_drawable(((Getter)previous_next_drawable)(source, _cmd));
            if (drawable && !drawable_callbacks_ready(drawable)) {
                [current_delegate() layerUsesUnsupportedPresentPath:self];
                return nil; // Never give the game a source whose callbacks cannot be forwarded.
            }
            return drawable;
        }
    }
    return discover_drawable(((Getter)previous_next_drawable)(self, _cmd));
}

// MARK: - Presentation

static BOOL is_main_drawable(id drawable) {
    uintptr_t main = atomic_load(&mulg_main_address);
    return main != 0 && [drawable respondsToSelector:@selector(layer)]
        && address(physical_layer(drawable)) == main;
}

/// An owned override leaves the thread's requested QoS intact. End it on every exit path,
/// including exceptions; disabling the option never waits for another present on this thread.
static pthread_override_t begin_render_priority(id drawable) {
    if (!drawable || mulg_in_own_submission || !mulg_graphics_current_config().raiseRenderThreadPriority
        || (!is_main_drawable(drawable) && !is_source_drawable(drawable))) return NULL;
    return pthread_override_qos_class_start_np(pthread_self(), QOS_CLASS_USER_INTERACTIVE, 0);
}

static void end_render_priority(pthread_override_t override) {
    if (override) pthread_override_qos_class_end_np(override);
}

static void report_present_time(MulgGraphicsConfig config, id<MTLDrawable> drawable) {
    if (!config.reportPresentTimes || !is_main_drawable(drawable)) {
        return;
    }
    unsigned generation = atomic_load(&mulg_config_generation);
    @synchronized (mulg_lock(drawable)) {
        NSNumber *registered = objc_getAssociatedObject(drawable, &kReportedFrameKey);
        if (registered && registered.unsignedIntValue == generation) return;
        objc_setAssociatedObject(drawable, &kReportedFrameKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id acquisition = objc_getAssociatedObject(drawable, &kAcquisitionKey);
        // Register under the same lock: a concurrent present must not beat handler installation.
        [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            CFTimeInterval time = presented.presentedTime;
            if (time > 0 && generation == atomic_load(&mulg_config_generation) && is_main_drawable(presented)
                && acquisition == objc_getAssociatedObject(presented, &kAcquisitionKey)) {
                [current_delegate() framePresentedAtTime:time];
            }
        }];
    }
}

/// Calls `handlers` when the replacement reaches the screen, passing the game's own drawable as
/// the game expects.
static void forward_presented_handlers(NSArray *handlers, id<CAMetalDrawable> game, id<CAMetalDrawable> replacement) {
    if (handlers.count == 0) {
        return;
    }
    id acquisition = objc_getAssociatedObject(game, &kAcquisitionKey);
    [replacement addPresentedHandler:^(id<MTLDrawable> presented) {
        @synchronized (mulg_lock(game)) {
            if (acquisition != objc_getAssociatedObject(game, &kAcquisitionKey)) return;
            objc_setAssociatedObject(game, &kPresentedTimeKey, @(presented.presentedTime), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        for (MTLDrawablePresentedHandler handler in handlers) {
            handler(game);
        }
        @synchronized (mulg_lock(game)) {
            if (acquisition == objc_getAssociatedObject(game, &kAcquisitionKey)) {
                objc_setAssociatedObject(game, &kReplacementKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(game, &kPresentedHandlersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }];
}

/// The game's small frame in `drawable` (a source drawable), upscaled into a drawable of the
/// game's own layer by work encoded into `buffer`; nil when that failed.
static id<CAMetalDrawable> upscale(id<CAMetalDrawable> drawable, id<MTLCommandBuffer> buffer) {
    objc_setAssociatedObject(drawable, &kPresentedTimeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(drawable, &kInterceptedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CAMetalLayer *game = mulg_upscaling_layer;
    if (game == nil || !is_source_drawable(drawable)) {
        return nil;
    }
    // MetalFX writes into the game's drawables, which framebufferOnly forbids. A game (or its
    // MTKView) may set it again after the layer was attached: clear it again, and remember the
    // game's wish for when the layer is detached.
    if (game.framebufferOnly) {
        objc_setAssociatedObject(game, &kFramebufferOnlyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        game.framebufferOnly = NO;
    }
    NSUInteger budget = pending_budget(physical_layer(drawable), game);
    retire_source_frames(physical_layer(drawable), budget > 0 ? budget - 1 : 0, NO);
    mulg_in_own_call += 1;
    id<CAMetalDrawable> output = discover_drawable(((Getter)previous_next_drawable)(game, @selector(nextDrawable)));
    mulg_in_own_call -= 1;
    if (output == nil) {
        id<MulgGraphicsDelegate> delegate = current_delegate();
        if ([delegate respondsToSelector:@selector(outputDrawableUnavailable:)]) [delegate outputDrawableUnavailable:game];
        objc_setAssociatedObject(drawable, &kPresentedHandlersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }
    if (!drawable_callbacks_ready(output)) {
        [current_delegate() layerUsesUnsupportedPresentPath:game];
        objc_setAssociatedObject(drawable, &kPresentedHandlersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }
    if (![current_delegate() upscale:drawable.texture into:output.texture commandBuffer:buffer extendedRange:game.wantsExtendedDynamicRangeContent]) {
        objc_setAssociatedObject(drawable, &kPresentedHandlersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return nil;
    }
    // Together, so a handler the game adds meanwhile is forwarded once: here or by the hook.
    NSArray *handlers;
    @synchronized (mulg_lock(drawable)) {
        objc_setAssociatedObject(drawable, &kReplacementKey, output, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        handlers = [objc_getAssociatedObject(drawable, &kPresentedHandlersKey) copy];
    }
    forward_presented_handlers(handlers, drawable, output);
    __weak id weakDrawable = drawable;
    id acquisition = objc_getAssociatedObject(drawable, &kAcquisitionKey);
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError) {
            id original = weakDrawable;
            @synchronized (mulg_lock(original)) {
                if (acquisition != objc_getAssociatedObject(original, &kAcquisitionKey)) return;
                objc_setAssociatedObject(original, &kReplacementKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(original, &kPresentedHandlersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }];
    return output;
}

// MARK: - Just-in-time frame start (§6.1)

// With a cap, the game finishes its frame early and then waits for a drawable, so the frame was
// built from input read long before it is shown. Instead, the time frames of the main layer
// wait between the GPU finishing them and the screen showing them is measured, and the game is
// made to wait that long (less a margin) before it starts the next frame: after it commits the
// frame (Metal 4: presents it), or before its display-link callback (engine module).
// The wait follows commit/present ownership across thread handoffs. Display-link frames keep
// their engine context so this cannot add a second wait or inject input inside rendering.
static struct {
    double delay;
    CFTimeInterval lastShown;
    int enabled;
    uint64_t generation;
    unsigned recoveryFrames;
} jit;
static os_unfair_lock jit_lock = OS_UNFAIR_LOCK_INIT;
/// Frames should still be ready this long before they are shown.
static const double kJustInTimeMargin = 0.002;

static void jit_reset_locked(void) {
    jit.generation++;
    jit.delay = 0;
    jit.lastShown = 0;
    jit.recoveryFrames = 0;
    mulg_engine_set_frame_start_delay(0);
}

static void jit_reset(void) {
    os_unfair_lock_lock(&jit_lock);
    jit_reset_locked();
    os_unfair_lock_unlock(&jit_lock);
}

static BOOL same_pacing(MulgGraphicsConfig a, MulgGraphicsConfig b) {
    return a.refreshesPerFrame == b.refreshesPerFrame
        && a.refreshPeriod == b.refreshPeriod && a.variableRefresh == b.variableRefresh
        && a.vsyncDisabled == b.vsyncDisabled;
}

static BOOL same_timing(MulgGraphicsConfig a, MulgGraphicsConfig b) {
    return a.justInTimeFrameStart == b.justInTimeFrameStart && same_pacing(a, b);
}

static void jit_configure(MulgGraphicsConfig old, MulgGraphicsConfig config) {
    os_unfair_lock_lock(&jit_lock);
    // Vsync-off submission already performs the CPU cap wait. Do not add a second
    // timing controller based on compositor latency to that same render loop.
    BOOL enabled = config.justInTimeFrameStart && config.refreshesPerFrame > 0 && !config.vsyncDisabled;
    if (jit.enabled != enabled || !same_timing(old, config)) jit_reset_locked();
    jit.enabled = enabled;
    os_unfair_lock_unlock(&jit_lock);
}

static BOOL jit_watches(MulgGraphicsConfig config, id drawable) {
    if (!config.justInTimeFrameStart || config.refreshesPerFrame <= 0 || config.vsyncDisabled) {
        return NO;
    }
    return is_main_drawable(drawable);
}

@interface MulgFrameTiming : NSObject {
@public
    __weak id _drawable;
    id _acquisition;
    uintptr_t _surface;
    uint64_t _generation;
    double _ready, _shown, _frame, _late, _margin;
    BOOL _consumed;
}
@end
@implementation MulgFrameTiming
@end

/// Pair GPU and presentation observations in either callback order, without waiting on either.
static void observe_frame(MulgFrameTiming *sample, double ready, double shown) {
    if (!sample) return;
    @synchronized (sample) {
        if (sample->_consumed) return;
        if (ready > 0 && isfinite(ready)) sample->_ready = ready;
        if (shown > 0 && isfinite(shown)) sample->_shown = shown;
        if (sample->_ready <= 0 || sample->_shown <= 0) return;
        sample->_consumed = YES;
        // The probe is an upper bound on GPU completion. If it finished after presentation,
        // discard it rather than treating queue/listener scheduling latency as frame slack.
        if (sample->_ready > sample->_shown || sample->_shown - sample->_ready > 0.5) return;
        id drawable = sample->_drawable;
        if (!drawable || sample->_acquisition != objc_getAssociatedObject(drawable, &kAcquisitionKey)) return;
        os_unfair_lock_lock(&jit_lock);
        if (jit.enabled && jit.generation == sample->_generation && sample->_surface == atomic_load(&mulg_main_address)
            && sample->_shown > jit.lastShown) {
            if (jit.lastShown > 0 && sample->_shown - jit.lastShown > sample->_late) {
                jit.delay = 0;
                jit.recoveryFrames = 8;
            } else if (jit.recoveryFrames > 0) {
                --jit.recoveryFrames;
                jit.delay = 0;
            } else {
                jit.delay += (sample->_shown - sample->_ready - sample->_margin) / 4;
            }
            // Keep render-time headroom instead of using half the frame's budget for
            // an optional input-latency wait. A miss recovers before learning resumes.
            jit.delay = MAX(0, MIN(sample->_frame / 4, jit.delay));
            jit.lastShown = sample->_shown;
            mulg_engine_set_frame_start_delay(jit.delay);
        }
        os_unfair_lock_unlock(&jit_lock);
    }
}

/// `ready` can supply an already available classic GPU time; completion supplies late times.
static MulgFrameTiming *watch_frame(id shown, MulgGraphicsConfig config, CFTimeInterval (^ready)(void)) {
    if (!is_main_drawable(shown) || !isfinite(config.refreshPeriod) || config.refreshPeriod <= 0
        || !isfinite(config.refreshesPerFrame) || config.refreshesPerFrame <= 0) return nil;
    uintptr_t surface = address(physical_layer(shown));
    // Configuration and feedback generation must describe the same timing snapshot.
    os_unfair_lock_lock(&mulg_config_lock);
    if (!same_timing(mulg_config, config)) { os_unfair_lock_unlock(&mulg_config_lock); return nil; }
    os_unfair_lock_lock(&jit_lock);
    uint64_t generation = jit.generation;
    os_unfair_lock_unlock(&jit_lock);
    os_unfair_lock_unlock(&mulg_config_lock);
    double period = config.refreshPeriod;
    double frame = config.refreshesPerFrame * period;
    // Shown later than this after the previous frame: the wait made the frame miss its refresh.
    double late = (config.variableRefresh ? frame : ceil(config.refreshesPerFrame - 1e-6) * period) + period / 2;
    MulgFrameTiming *sample = [MulgFrameTiming new];
    sample->_drawable = shown;
    sample->_acquisition = objc_getAssociatedObject(shown, &kAcquisitionKey);
    sample->_surface = surface; sample->_generation = generation;
    sample->_frame = frame; sample->_late = late;
    sample->_margin = MAX(kJustInTimeMargin, MIN(period / 2, frame / 4));
    [(id<MTLDrawable>)shown addPresentedHandler:^(id<MTLDrawable> presented) {
        observe_frame(sample, ready(), presented.presentedTime);
    }];
    return sample;
}

@interface MulgJITFrame : NSObject {
@public
    __weak id _drawable;
    id _acquisition, _context;
    uint64_t _generation;
    uintptr_t _surface;
}
@end
@implementation MulgJITFrame
@end

static void mark_jit_frame(id owner, id drawable) {
    MulgJITFrame *frame = [MulgJITFrame new];
    frame->_drawable = drawable;
    frame->_acquisition = objc_getAssociatedObject(drawable, &kAcquisitionKey);
    os_unfair_lock_lock(&jit_lock);
    frame->_generation = jit.generation;
    os_unfair_lock_unlock(&jit_lock);
    frame->_context = mulg_engine_frame_start_context();
    frame->_surface = atomic_load(&mulg_main_address);
    @synchronized (mulg_lock(owner)) {
        objc_setAssociatedObject(owner, &kJITFrameKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void jit_presented(id owner) {
    // Most commits carry no frame. A frame is attached on the presenting path before this commit,
    // on its thread, so an unlocked look is enough to skip creating a lock object per command buffer.
    if (!objc_getAssociatedObject(owner, &kJITFrameKey)) return;
    MulgJITFrame *frame;
    @synchronized (mulg_lock(owner)) {
        frame = objc_getAssociatedObject(owner, &kJITFrameKey);
        objc_setAssociatedObject(owner, &kJITFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!frame) return;
    id drawable = frame->_drawable;
    if (!drawable || frame->_acquisition != objc_getAssociatedObject(drawable, &kAcquisitionKey)) return;
    if (objc_getAssociatedObject(physical_layer(drawable), &kWrappedSourceKey) && !is_source_drawable(drawable)) return;
    os_unfair_lock_lock(&jit_lock);
    BOOL current = atomic_load(&mulg_main_address) == frame->_surface && frame->_generation == jit.generation;
    os_unfair_lock_unlock(&jit_lock);
    if (current) mulg_engine_frame_presented_in_context(frame->_context);
}

@interface MulgBufferPresent : NSObject
@property(nonatomic, strong) id drawable;
@property(nonatomic, strong) id acquisition;
@property(nonatomic, strong) id frameContext;
@property(nonatomic) SEL selector;
@property(nonatomic) CFTimeInterval value;
@property(nonatomic) BOOL deferred;
@property(nonatomic) uint64_t jitGeneration;
@property(nonatomic) uint64_t order;
@end
@implementation MulgBufferPresent
@end

static id intercept(id<MTLCommandBuffer> buffer, id drawable, BOOL presentationChecked);
static void mulg_buffer_present(id self, SEL selector, id drawable);
static void mulg_buffer_present_at_time(id self, SEL selector, id drawable, CFTimeInterval time);
static void mulg_buffer_present_after_duration(id self, SEL selector, id drawable, CFTimeInterval duration);

static void native_buffer_present(id buffer, SEL selector, id drawable, CFTimeInterval value) {
    IMP replacement = selector == @selector(presentDrawable:) ? (IMP)mulg_buffer_present
        : selector == @selector(presentDrawable:atTime:) ? (IMP)mulg_buffer_present_at_time
        : (IMP)mulg_buffer_present_after_duration;
    IMP original = ORIGINAL(buffer, selector, replacement);
    if (selector == @selector(presentDrawable:)) ((PresentDrawable)original)(buffer, selector, drawable);
    else ((PresentDrawableAtTime)original)(buffer, selector, drawable, value);
}

// MARK: - Pending presents

// A present waits on its command buffer until commit, normally one per frame. A small table under
// one unfair lock holds them, instead of a @synchronized block, an NSMutableArray and associated
// objects (whose lock is shared by the whole process) on every present and every commit. A commit
// with nothing waiting, most of a frame's buffers, reads one counter. A full table falls back to
// the associated object, which stays correct. The buffer is held weakly: a buffer the game drops
// without committing must not keep its drawable alive (a layer has about three; leaking them
// blocks nextDrawable and freezes the game). Reap its slot and request before the next
// drawable acquisition as well as on a subsequent present.
enum { kPresentSlots = 16 };
static os_unfair_lock present_slots_lock = OS_UNFAIR_LOCK_INIT;
static __weak id present_slot_buffers[kPresentSlots];
// Negative lookup only: raw addresses never own or validate a buffer. A matching
// address still requires the zeroing weak reference to match, including reuse
// of an address after an uncommitted buffer was deallocated.
static uintptr_t present_slot_addresses[kPresentSlots];
static _Atomic(uint64_t) present_slot_mask;
static uint64_t present_address_bit(uintptr_t key) {
    return key ? UINT64_C(1) << ((((uint64_t)key >> 4) * UINT64_C(0x9e3779b97f4a7c15)) >> 58) : 0;
}
// Called with the table lock held. Collisions only cause a full lookup; an
// address is still checked against its weak owner before a request is consumed.
static void publish_present_mask(void) {
    uint64_t mask = 0;
    for (int i = 0; i < kPresentSlots; i++) mask |= present_address_bit(present_slot_addresses[i]);
    atomic_store_explicit(&present_slot_mask, mask, memory_order_release);
}
static __strong MulgBufferPresent *present_slot_requests[kPresentSlots];
static uint64_t present_slot_order[kPresentSlots];
static uint64_t present_next_order;
static _Atomic(int) pending_presents;
static _Atomic(int) overflow_presents;

/// The overflow list dies with an uncommitted buffer. Balance its fast-path
/// counters on abandonment as well as commit, without retaining that buffer.
@interface MulgPresentOverflow : NSObject
@property(nonatomic, strong) NSMutableArray<MulgBufferPresent *> *requests;
@end
@implementation MulgPresentOverflow
- (void)dealloc {
    int abandoned = (int)_requests.count;
    if (abandoned) {
        atomic_fetch_sub(&overflow_presents, abandoned);
        atomic_fetch_sub(&pending_presents, abandoned);
    }
}
@end

static void reap_abandoned_presents(void) {
    if (atomic_load_explicit(&pending_presents, memory_order_acquire) == 0) return;
    __strong MulgBufferPresent *orphans[kPresentSlots];
    int count = 0;
    os_unfair_lock_lock(&present_slots_lock);
    for (int i = 0; i < kPresentSlots; i++) {
        if (present_slot_buffers[i] != nil || present_slot_requests[i] == nil) continue;
        orphans[count++] = present_slot_requests[i];
        present_slot_requests[i] = nil;
        present_slot_addresses[i] = 0;
    }
    if (count) atomic_fetch_sub(&pending_presents, count);
    if (count) publish_present_mask();
    os_unfair_lock_unlock(&present_slots_lock);
    // Releasing a drawable can enter the native driver. Never do that under the table lock.
    for (int i = 0; i < count; i++) orphans[i] = nil;
}

static void hold_present(id buffer, MulgBufferPresent *request) {
    BOOL stored = NO;
    __strong MulgBufferPresent *orphans[kPresentSlots];
    int orphaned = 0;
    os_unfair_lock_lock(&present_slots_lock);
    request.order = ++present_next_order;
    for (int i = 0; i < kPresentSlots; i++) {
        if (present_slot_buffers[i] != nil) continue;
        present_slot_addresses[i] = 0;
        if (present_slot_requests[i] != nil) {
            // Its buffer was released without a commit: drop the request outside the lock.
            orphans[orphaned++] = present_slot_requests[i];
            present_slot_requests[i] = nil;
        }
        if (stored) continue;
        present_slot_buffers[i] = buffer;
        present_slot_addresses[i] = address(buffer);
        present_slot_requests[i] = request;
        present_slot_order[i] = request.order;
        stored = YES;
    }
    if (stored) atomic_fetch_add(&pending_presents, 1);
    if (orphaned > 0) atomic_fetch_sub(&pending_presents, orphaned);
    if (stored || orphaned) publish_present_mask();
    os_unfair_lock_unlock(&present_slots_lock);
    for (int i = 0; i < orphaned; i++) orphans[i] = nil;
    if (!stored) {
        @synchronized (mulg_lock(buffer)) {
            MulgPresentOverflow *overflow = objc_getAssociatedObject(buffer, &kBufferPresentsKey);
            if (!overflow) {
                overflow = [MulgPresentOverflow new];
                overflow.requests = [NSMutableArray new];
                objc_setAssociatedObject(buffer, &kBufferPresentsKey, overflow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [overflow.requests addObject:request];
            atomic_fetch_add(&overflow_presents, 1);
            atomic_fetch_add(&pending_presents, 1);
        }
    }
}

/// The presents waiting on `buffer`, in the order they were made; nil when there are none.
static NSArray<MulgBufferPresent *> *take_presents(id buffer) {
    if (!buffer || atomic_load_explicit(&pending_presents, memory_order_acquire) == 0) return nil;
    uintptr_t key = address(buffer);
    // Overflow requests are owned by their buffers rather than indexed here.
    // Otherwise a negative bitmap lookup avoids locking for unrelated commits.
    if (atomic_load_explicit(&overflow_presents, memory_order_acquire) == 0 &&
        !(atomic_load_explicit(&present_slot_mask, memory_order_acquire) & present_address_bit(key))) return nil;
    __strong MulgBufferPresent *found[kPresentSlots];
    uint64_t order[kPresentSlots];
    int count = 0;
    os_unfair_lock_lock(&present_slots_lock);
    for (int i = 0; i < kPresentSlots; i++) {
        if (present_slot_addresses[i] != key) continue;
        if (present_slot_buffers[i] != buffer) continue;
        found[count] = present_slot_requests[i];
        order[count++] = present_slot_order[i];
        // The caller still holds the buffer and `found` the request: nothing is freed under the lock.
        present_slot_buffers[i] = nil;
        present_slot_addresses[i] = 0;
        present_slot_requests[i] = nil;
    }
    if (count) publish_present_mask();
    os_unfair_lock_unlock(&present_slots_lock);
    for (int i = 1; i < count; i++) { // insertion sort: there are one or two
        MulgBufferPresent *request = found[i];
        uint64_t key = order[i];
        int j = i - 1;
        for (; j >= 0 && order[j] > key; j--) { found[j + 1] = found[j]; order[j + 1] = order[j]; }
        found[j + 1] = request;
        order[j + 1] = key;
    }
    NSArray<MulgBufferPresent *> *overflow = nil;
    if (atomic_load(&overflow_presents) > 0) {
        @synchronized (mulg_lock(buffer)) {
            MulgPresentOverflow *owner = objc_getAssociatedObject(buffer, &kBufferPresentsKey);
            overflow = owner.requests;
            // Ownership transfers to this commit; dealloc must not count it again.
            owner.requests = nil;
            if (owner) objc_setAssociatedObject(buffer, &kBufferPresentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (overflow.count) atomic_fetch_sub(&overflow_presents, (int)overflow.count);
    }
    int total = count + (int)overflow.count;
    if (total == 0) return nil;
    atomic_fetch_sub(&pending_presents, total);
    NSArray<MulgBufferPresent *> *requests = [NSArray arrayWithObjects:found count:(NSUInteger)count];
    if (!overflow.count) return requests;
    // A full table can overflow, then gain a free slot before this buffer's next
    // present. Merge by call order, rather than placing all slot entries first.
    return [[requests arrayByAddingObjectsFromArray:overflow]
        sortedArrayUsingComparator:^NSComparisonResult(MulgBufferPresent *a, MulgBufferPresent *b) {
            return a.order < b.order ? NSOrderedAscending : a.order > b.order ? NSOrderedDescending : NSOrderedSame;
        }];
}

int mulg_graphics_pending_present_count(void) {
    return atomic_load(&pending_presents);
}

static void mulg_buffer_commit(id self, SEL _cmd) {
    NSArray<MulgBufferPresent *> *requests = take_presents(self);
    pthread_override_t priority = NULL;
    for (MulgBufferPresent *request in requests) {
        if (request.acquisition == objc_getAssociatedObject(request.drawable, &kAcquisitionKey)) {
            priority = begin_render_priority(request.drawable);
            if (priority) break;
        }
    }
    @try {
    for (MulgBufferPresent *request in requests) {
        id drawable = request.drawable;
        if (request.acquisition != objc_getAssociatedObject(drawable, &kAcquisitionKey)) continue;
        id visible = request.deferred ? intercept(self, drawable, NO) : drawable;
        if (!visible) continue;
        if (request.deferred) {
            @synchronized (mulg_lock(self)) {
                MulgJITFrame *frame = objc_getAssociatedObject(self, &kJITFrameKey);
                if (frame) {
                    frame->_context = request.frameContext;
                    frame->_generation = request.jitGeneration;
                }
            }
        }
        // Driver-scheduled presentation never performs a CPU wait. Pace submission once.
        objc_setAssociatedObject(visible, &kClassicPresentKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (mulg_graphics_current_config().vsyncDisabled) mulg_graphics_pace(visible, 0, NO);
        if (request.deferred) native_buffer_present(self, request.selector, visible, request.value);
    }
    ((Commit)ORIGINAL(self, _cmd, mulg_buffer_commit))(self, _cmd);
    } @finally { end_render_priority(priority); }
    jit_presented(self);
}

// MARK: - Command buffer presents

static id intercept(id<MTLCommandBuffer> buffer, id drawable, BOOL presentationChecked) {
    // Reuse this thread's coherent settings snapshot until a live change.
    MulgGraphicsConfig config = mulg_graphics_current_config();
    if (drawable == nil) {
        return drawable;
    }
    pthread_override_t priority = begin_render_priority(drawable);
    @try {
    // Immediate presentation was validated by this very scheduling call.
    // Deferred source frames must revalidate when they reach commit instead.
    if (!presentationChecked) {
        MulgGraphicsHook required = MulgGraphicsHookCommandBufferPresent | MulgGraphicsHookCommandBufferCommit;
        note_presentation_path(drawable, (install_buffer(object_getClass(buffer)) & required) == required);
    }
    id result = drawable;
    // Only source drawables are marked: with MetalFX off, no associated object is written per
    // frame (a global lock, and a slower drawable dealloc).
    if (is_source_drawable(drawable)) {
        result = upscale(drawable, buffer);
        if (result == nil) return nil;
    }
    if (!mulg_in_own_submission && is_main_drawable(result)) {
        mark_jit_frame(buffer, result);
    }
    if (!mulg_in_own_submission && jit_watches(config, result)) {
        __weak id<MTLCommandBuffer> weakBuffer = buffer;
        MulgFrameTiming *sample = watch_frame(result, config, ^{ return weakBuffer.GPUEndTime; });
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusError) observe_frame(sample, completed.GPUEndTime, 0);
        }];
    }
    report_present_time(config, result);
    return result;
    } @finally { end_render_priority(priority); }
}

// The command buffer calls the drawable's present, presentAtTime: or presentAfterMinimumDuration:
// once it is scheduled. Vsync pacing stays there; Vsync-off CPU pacing happens at submission.

static void schedule_buffer_present(id self, SEL selector, id drawable, CFTimeInterval value) {
    BOOL source = is_source_drawable(drawable);
    MulgGraphicsHook installed = install_buffer(object_getClass(self));
    BOOL complete = (installed & (MulgGraphicsHookCommandBufferPresent | MulgGraphicsHookCommandBufferCommit))
        == (MulgGraphicsHookCommandBufferPresent | MulgGraphicsHookCommandBufferCommit);
    note_presentation_path(drawable, complete);
    if (source && !complete) return;
    if (complete && drawable) {
        MulgBufferPresent *request = [MulgBufferPresent new];
        request.drawable = drawable;
        request.acquisition = objc_getAssociatedObject(drawable, &kAcquisitionKey);
        request.frameContext = mulg_engine_frame_start_context();
        os_unfair_lock_lock(&jit_lock);
        request.jitGeneration = jit.generation;
        os_unfair_lock_unlock(&jit_lock);
        request.selector = selector; request.value = value; request.deferred = source;
        hold_present(self, request);
    }
    if (!source) {
        id visible = intercept(self, drawable, YES);
        if (visible) native_buffer_present(self, selector, visible, value);
    }
}

/// An Instruments interval ("present", io.mulg/graphics) around Mulg's share of each present.
/// Free unless a trace records it.
static void signposted_buffer_present(id self, SEL selector, id drawable, CFTimeInterval value) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.mulg", "graphics"); });
    os_signpost_id_t interval = os_signpost_enabled(log) ? os_signpost_id_generate(log) : OS_SIGNPOST_ID_NULL;
    if (interval != OS_SIGNPOST_ID_NULL) os_signpost_interval_begin(log, interval, "present");
    schedule_buffer_present(self, selector, drawable, value);
    if (interval != OS_SIGNPOST_ID_NULL) os_signpost_interval_end(log, interval, "present");
}

static void mulg_buffer_present(id self, SEL _cmd, id drawable) {
    signposted_buffer_present(self, _cmd, drawable, 0);
}

static void mulg_buffer_present_at_time(id self, SEL _cmd, id drawable, CFTimeInterval time) {
    signposted_buffer_present(self, _cmd, drawable, time);
}

static void mulg_buffer_present_after_duration(id self, SEL _cmd, id drawable, CFTimeInterval duration) {
    signposted_buffer_present(self, _cmd, drawable, mulg_graphics_unlocked_duration(duration));
}

// MARK: - Frame-rate unlock

// Games that pace themselves with "present after at least 1/60 s" (or 1/30) stay at that rate on
// a 120 Hz Mac whatever their display link does. While the unlock is on, such a minimum shortens
// to the unlock target's frame time. Mulg's own frame cap is applied after this.
static _Atomic(double) unlocked_frame_duration = 0;

void mulg_graphics_set_unlocked_frame_duration(double seconds) {
    atomic_store(&unlocked_frame_duration, isfinite(seconds) && seconds > 0 && seconds < 1.0 / 30 ? seconds : 0);
}

CFTimeInterval mulg_graphics_unlocked_duration(CFTimeInterval requested) {
    double unlocked = atomic_load_explicit(&unlocked_frame_duration, memory_order_relaxed);
    // Only frame-pacing minimums (about 1/60 or 1/30 s), never a game's deliberate long hold.
    if (unlocked <= 0 || !isfinite(requested) || requested <= unlocked * 1.05 || requested > 1.0 / 29) return requested;
    return unlocked;
}

// MARK: - Frame cap (§6.1)

int mulg_graphics_next_hold(double *carry, double refreshesPerFrame) {
    *carry += refreshesPerFrame;
    int whole = (int)floor(*carry + 1e-6);  // 3 × 1.333… must give 4, not 3.999…
    *carry -= whole;
    return whole < 1 ? 1 : whole;
}

/// One layer's rhythm: when its last frame is due on screen, and the fraction of a refresh
/// carried to its next hold. Per layer, so a game drawing two layers per frame is not held twice.
typedef struct {
    uintptr_t layer;
    double carry;
    CFTimeInterval last;
    unsigned generation;
} Rhythm;

static Rhythm rhythms[4];
static os_unfair_lock rhythm_lock = OS_UNFAIR_LOCK_INIT;
/// Set inside a drawable present hook, so present methods calling each other are held once.
static __thread int in_present = 0;

/// With a cap, `value` held to it: a present time (`atTime`) no earlier than the layer's last
/// frame plus the hold, or an on-screen time no shorter than the hold. Without a cap, `value`.
/// With Vsync, fixed-rate screens hold whole refreshes, half a refresh short so a frame due on a boundary is
/// not pushed to the next one; variable-rate screens in full screen hold exactly 1/cap. Never
/// longer than 0.2 s, because a game waiting in nextDrawable gets nil after one second.
CFTimeInterval mulg_graphics_pace(id drawable, CFTimeInterval value, BOOL atTime) {
    MulgGraphicsSnapshot snapshot = graphics_snapshot();
    MulgGraphicsConfig config = snapshot.config;
    unsigned generation = snapshot.timing;
    if (config.refreshesPerFrame <= 0 || !is_main_drawable(drawable)) {
        return value;
    }
    uintptr_t layer = address(physical_layer(drawable));
    CFTimeInterval now = CACurrentMediaTime();
    double period = config.refreshPeriod;
    os_unfair_lock_lock(&rhythm_lock);
    Rhythm *rhythm = &rhythms[0];
    for (int i = 0; i < 4; i++) {
        if (rhythms[i].layer == layer) {
            rhythm = &rhythms[i];
            break;
        }
        if (rhythms[i].last < rhythm->last) {
            rhythm = &rhythms[i];  // least recently used
        }
    }
    if (rhythm->layer != layer || rhythm->generation != generation || now - rhythm->last > 0.5) {
        *rhythm = (Rhythm){ .layer = layer, .generation = generation };
    }
    // A CPU deadline with Vsync off is an exact time interval, independent of
    // scanout boundaries. Quantizing 120 FPS on a 180 Hz monitor alternated
    // 5.56/11.11 ms waits; caps above refresh were incorrectly clamped to it.
    double refreshes = (config.variableRefresh || config.vsyncDisabled) ? config.refreshesPerFrame
        : mulg_graphics_next_hold(&rhythm->carry, config.refreshesPerFrame);
    CFTimeInterval hold = MIN(0.2, refreshes * period);
    CFTimeInterval early = config.variableRefresh ? 0 : period / 2;
    if (config.vsyncDisabled) {
        CFTimeInterval due = MAX(now, rhythm->last + hold);
        rhythm->last = due;
        os_unfair_lock_unlock(&rhythm_lock);
        // A driver may ignore duration-based presents without Vsync. Bound the wait, outside
        // the shared lock, on the presenting thread; nested present hooks still pace only once.
        while (generation == atomic_load(&mulg_timing_generation) && is_main_drawable(drawable)) {
            double remaining = MIN(0.005, due - CACurrentMediaTime());
            if (remaining <= 0) break;
            struct timespec delay = { 0, (long)(remaining * 1e9) };
            if (nanosleep(&delay, NULL) != 0 && errno != EINTR) break;
        }
        return value;
    }
    CFTimeInterval result;
    if (atTime) {
        CFTimeInterval due = MAX(now, rhythm->last + hold);
        rhythm->last = MAX(value, due);
        result = MAX(now, MAX(value, due - early));
    } else {
        rhythm->last = MAX(now, rhythm->last + MAX(value, hold));
        result = MAX(value, hold - early);
    }
    os_unfair_lock_unlock(&rhythm_lock);
    return result;
}

/// Source drawables are never shown themselves. Returns YES when the upscaled replacement is
/// presented instead: on Metal 4, the command buffer waiting in kPendingBufferKey presents it the
/// way the game presents the source (`how`, with `value`), so the game's time is kept and the
/// replacement's own present hooks cap it. A source drawable that never went through an upscale
/// can't be upscaled, and is reported.
static BOOL skip_present(id drawable, SEL how, CFTimeInterval value) {
    @synchronized (mulg_lock(drawable)) {
        MulgPendingFrame *frame = objc_getAssociatedObject(drawable, &kPendingBufferKey);
        if (frame != nil && frame->_encoding) {
            frame->_presentRequested = YES;
            frame->_how = how;
            frame->_value = value;
            return YES;
        }
        id<CAMetalDrawable> replacement = objc_getAssociatedObject(drawable, &kReplacementKey);
        if (replacement != nil) {
            id<MTLCommandBuffer> pending = take_pending(objc_getAssociatedObject(drawable, &kPendingBufferKey));
            if (pending != nil) {
                objc_setAssociatedObject(drawable, &kPendingBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                mulg_in_own_submission++;
                @try {
                    if (how == @selector(presentAtTime:)) {
                        [pending presentDrawable:replacement atTime:value];
                    } else if (how == @selector(presentAfterMinimumDuration:)) {
                        [pending presentDrawable:replacement afterMinimumDuration:value];
                    } else {
                        [pending presentDrawable:replacement];
                    }
                    [pending commit];
                } @finally { mulg_in_own_submission--; }
            }
            return YES;
        }
    }
    if (!is_source_drawable(drawable)) {
        return [drawable respondsToSelector:@selector(layer)]
            && objc_getAssociatedObject(physical_layer(drawable), &kWrappedSourceKey) != nil;
    }
    CAMetalLayer *upscaling = mulg_upscaling_layer;
    if (upscaling != nil && objc_getAssociatedObject(drawable, &kInterceptedKey) == nil
        && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - atomic_load(&mulg_upscaling_since) > kUpscalingGraceNanoseconds) {
        [current_delegate() layerUsesUnsupportedPresentPath:upscaling];
    }
    // A hidden source can never be a visible fallback. Switch off upscaling and drop this frame.
    return YES;
}

static CFTimeInterval drawable_pace(id drawable, CFTimeInterval value, BOOL atTime) {
    if (objc_getAssociatedObject(drawable, &kClassicPresentKey) && mulg_graphics_current_config().vsyncDisabled) return value;
    return mulg_graphics_pace(drawable, value, atTime);
}

static void track_direct_frame(id drawable) {
    if (!mulg_in_own_submission && is_main_drawable(drawable)
        && !objc_getAssociatedObject(drawable, &kClassicPresentKey)
        && !objc_getAssociatedObject(drawable, &kJITFrameKey)) mark_jit_frame(drawable, drawable);
}

static void mulg_drawable_present(id self, SEL _cmd) {
    if (in_present) {
        ((Present)ORIGINAL(self, _cmd, mulg_drawable_present))(self, _cmd);
        return;
    }
    if (skip_present(self, _cmd, 0)) {
        jit_presented(self);
        return;
    }
    report_present_time(mulg_graphics_current_config(), self);
    CFTimeInterval hold = drawable_pace(self, 0, NO);
    track_direct_frame(self);
    pthread_override_t priority = begin_render_priority(self);
    in_present = 1;
    @try {
    IMP afterDuration = ORIGINAL(self, @selector(presentAfterMinimumDuration:), mulg_drawable_present_after_duration);
    if (hold > 0 && afterDuration != NULL) {
        // Metal paces the frame, and the game waits in nextDrawable instead of drawing frames
        // nobody sees.
        ((PresentAtTime)afterDuration)(self, @selector(presentAfterMinimumDuration:), hold);
    } else {
        ((Present)ORIGINAL(self, _cmd, mulg_drawable_present))(self, _cmd);
    }
    } @finally { in_present = 0; end_render_priority(priority); }
    jit_presented(self);
}

static void mulg_drawable_present_at_time(id self, SEL _cmd, CFTimeInterval time) {
    BOOL outer = !in_present;
    if (outer) {
        if (skip_present(self, _cmd, time)) {
            jit_presented(self);
            return;
        }
        report_present_time(mulg_graphics_current_config(), self);
        time = drawable_pace(self, time, YES);
    }
    in_present += 1;
    if (outer) track_direct_frame(self);
    pthread_override_t priority = outer ? begin_render_priority(self) : NULL;
    @try {
    ((PresentAtTime)ORIGINAL(self, _cmd, mulg_drawable_present_at_time))(self, _cmd, time);
    } @finally { in_present -= 1; end_render_priority(priority); }
    if (outer) {
        jit_presented(self);
    }
}

static void mulg_drawable_present_after_duration(id self, SEL _cmd, CFTimeInterval duration) {
    BOOL outer = !in_present;
    if (outer) duration = mulg_graphics_unlocked_duration(duration);
    if (outer) {
        if (skip_present(self, _cmd, duration)) {
            jit_presented(self);
            return;
        }
        report_present_time(mulg_graphics_current_config(), self);
        duration = drawable_pace(self, duration, NO);
    }
    in_present += 1;
    if (outer) track_direct_frame(self);
    pthread_override_t priority = outer ? begin_render_priority(self) : NULL;
    @try {
    ((PresentAtTime)ORIGINAL(self, _cmd, mulg_drawable_present_after_duration))(self, _cmd, duration);
    } @finally { in_present -= 1; end_render_priority(priority); }
    if (outer) {
        jit_presented(self);
    }
}

/// Only source drawables keep their handlers: they are the only ones replaced. A handler added
/// after the upscale (on Metal 4, between signalDrawable: and present) goes to the replacement.
static void mulg_add_presented_handler(id self, SEL _cmd, MTLDrawablePresentedHandler handler) {
    if (handler != nil && (is_source_drawable(self) || objc_getAssociatedObject(self, &kReplacementKey) != nil)) {
        id<CAMetalDrawable> replacement;
        @synchronized (mulg_lock(self)) {
            replacement = objc_getAssociatedObject(self, &kReplacementKey);
            if (replacement == nil) {
                NSMutableArray *list = objc_getAssociatedObject(self, &kPresentedHandlersKey);
                if (list == nil) {
                    list = [NSMutableArray array];
                    objc_setAssociatedObject(self, &kPresentedHandlersKey, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                [list addObject:[handler copy]];
            }
        }
        if (replacement != nil) {
            forward_presented_handlers(@[[handler copy]], self, replacement);
        }
        return; // The hidden source is never presented; only the visible replacement owns callbacks.
    }
    ((AddPresentedHandler)ORIGINAL(self, _cmd, mulg_add_presented_handler))(self, _cmd, handler);
}

static CFTimeInterval mulg_presented_time(id self, SEL _cmd) {
    NSNumber *remembered = objc_getAssociatedObject(self, &kPresentedTimeKey);
    if (remembered != nil) return remembered.doubleValue;
    id<MTLDrawable> replacement = objc_getAssociatedObject(self, &kReplacementKey);
    if (replacement != nil) {
        return replacement.presentedTime;
    }
    return ((TimeGetter)ORIGINAL(self, _cmd, mulg_presented_time))(self, _cmd);
}

// MARK: - Metal 4 presents (§5.2)

// A Metal 4 game presents with [queue waitForDrawable:], commit:count:, [queue signalDrawable:]
// and [drawable present]. The cap needs nothing more: present is hooked above. After
// signalDrawable:, the game's queue signals an event, which marks when the frame's work is done:
// - for the MetalFX layer, Mulg's own command buffer waits for it and upscales into the game's
//   layer, and the game's present of the source drawable presents that buffer's frame instead;
// - native just-in-time feedback uses a bounded classic wait probe's GPU end time as a
//   conservative completion bound, never the shared-event listener's CPU dispatch time.

/// The event a game queue signals when a frame is done, and the last value signalled.
@interface MulgQueueEvent : NSObject {
@public
    id<MTLSharedEvent> _event;
    uint64_t _value;
    _Atomic(unsigned) _probes;
    id<MTLCommandQueue> _probeQueue;
}
@end

@implementation MulgQueueEvent
@end

/// Device wrappers and device replacement must never reuse another object's command queue.
static id<MTLCommandQueue> own_queue(id<MTLDevice> device) {
    static id<MTLCommandQueue> queue;
    @synchronized ([MulgPendingFrame class]) {
        if (queue.device != device) queue = [device newCommandQueue];
        return queue;
    }
}

/// Game queues still holding a source layer's residency set. Checked with one atomic load per
/// frame, so a game that never used the MetalFX layer pays nothing more.
static _Atomic(int) mulg_source_residency_queues = 0;

/// The queue owns this lease and the same residency set it previously retained
/// directly. Abandoning a queue balances the count without messaging it during
/// deallocation; replacing its set does not create another lease.
@interface MulgQueueResidency : NSObject
@property(nonatomic, strong) id<MTLResidencySet> set;
- (instancetype)initWithSet:(id<MTLResidencySet>)set;
@end
@implementation MulgQueueResidency
- (instancetype)initWithSet:(id<MTLResidencySet>)set {
    if ((self = [super init])) {
        _set = set;
        atomic_fetch_add(&mulg_source_residency_queues, 1);
    }
    return self;
}
- (void)dealloc { atomic_fetch_sub(&mulg_source_residency_queues, 1); }
@end

/// Metal 4 resources must be made resident: the source layer's drawables are added to the
/// game's queue, since the game only knows its own layer's residency set. Once MetalFX is off,
/// the queue lets them go, with the frames it kept for a present that will not come.
static void mulg_queue_wait_drawable(id queue, SEL _cmd, id drawable) {
    // Without an active source or a retired source lease, bookkeeping is a
    // no-op. Keep native waits outside every Mulg lock in both paths.
    if (atomic_load_explicit(&mulg_source_address, memory_order_acquire) == 0 &&
        atomic_load_explicit(&mulg_source_residency_queues, memory_order_acquire) == 0) {
        ((PresentDrawable)ORIGINAL(queue, _cmd, mulg_queue_wait_drawable))(queue, _cmd, drawable);
        return;
    }
    // Only the residency bookkeeping is locked. waitForDrawable: blocks until the GPU releases
    // the drawable; holding the queue's lock meanwhile would stop signalDrawable: on another
    // thread of the same queue, and the game would freeze.
    @synchronized (mulg_lock(queue)) {
        if (is_source_drawable(drawable)) {
            id<MTLResidencySet> set = physical_layer(drawable).residencySet;
            MulgQueueResidency *owner = objc_getAssociatedObject(queue, &kQueueResidencyKey);
            id<MTLResidencySet> added = owner.set;
            if (set != nil && set != added) {
                if (added != nil) {
                    [(id<MTL4CommandQueue>)queue removeResidencySet:added];
                }
                [(id<MTL4CommandQueue>)queue addResidencySet:set];
                if (owner) owner.set = set;
                else {
                    owner = [[MulgQueueResidency alloc] initWithSet:set];
                    objc_setAssociatedObject(queue, &kQueueResidencyKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        } else if (atomic_load_explicit(&mulg_source_residency_queues, memory_order_relaxed) > 0
                   && atomic_load_explicit(&mulg_source_address, memory_order_relaxed) == 0) {
            MulgQueueResidency *owner = objc_getAssociatedObject(queue, &kQueueResidencyKey);
            if (owner != nil) {
                [(id<MTL4CommandQueue>)queue removeResidencySet:owner.set];
                objc_setAssociatedObject(queue, &kQueueResidencyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    ((PresentDrawable)ORIGINAL(queue, _cmd, mulg_queue_wait_drawable))(queue, _cmd, drawable);
}

static void mulg_queue_signal_drawable(id queue, SEL _cmd, id drawable) {
    @synchronized (mulg_lock(queue)) {
        pthread_override_t priority = begin_render_priority(drawable);
        @try {
        BOOL source = is_source_drawable(drawable);
        MulgGraphicsConfig config = mulg_graphics_current_config();
        note_presentation_path(drawable, (install_queue4(object_getClass(queue)) & MulgGraphicsHookMetal4Present) != 0);
        if (!source) report_present_time(config, drawable);
        MulgFrameTiming *nativeSample = nil;
        // Native signal can wake a presenting thread immediately. Publish ownership and the
        // presentation observation before calling it, just as source encoding state is published.
        if (!source && is_main_drawable(drawable)) mark_jit_frame(drawable, drawable);
        if (!source && jit_watches(config, drawable) && drawable_callbacks_ready(drawable)) {
            nativeSample = watch_frame(drawable, config, ^{ return 0.0; });
        }
        // Publish the encoding state before the native signal can wake another presenting thread.
        MulgPendingFrame *frame = source ? [MulgPendingFrame new] : nil;
        if (frame != nil) {
            frame->_drawable = drawable;
            frame->_encoding = YES;
            @synchronized (mulg_lock(drawable)) {
                objc_setAssociatedObject(drawable, &kPendingBufferKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        ((PresentDrawable)ORIGINAL(queue, _cmd, mulg_queue_signal_drawable))(queue, _cmd, drawable);
        if (!source && !jit_watches(config, drawable)) {
            return;
        }
        id<MTL4CommandQueue> gameQueue = queue;
        MulgQueueEvent *done = objc_getAssociatedObject(queue, &kQueueEventKey);
        if (done == nil) {
            done = [MulgQueueEvent new];
            done->_event = [gameQueue.device newSharedEvent];
            objc_setAssociatedObject(queue, &kQueueEventKey, done, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (done->_event == nil) {
            @synchronized (mulg_lock(drawable)) {
                objc_setAssociatedObject(drawable, &kPendingBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            CAMetalLayer *layer = mulg_upscaling_layer;
            if (source && layer != nil) [current_delegate() layerUsesUnsupportedPresentPath:layer];
            return;
        }
        uint64_t value = ++done->_value;
        [gameQueue signalEvent:done->_event value:value];

        if (!source) {
            if (!nativeSample) return;
            // A stalled game queue must not grow wait probes/callback records without bound.
            if (atomic_fetch_add(&done->_probes, 1) >= 3) {
                atomic_fetch_sub(&done->_probes, 1);
                return;
            }
            // An observation waiting on one producer must never order visible upscale work.
            // Each game queue owns at most three probes and its own observational queue.
            if (!done->_probeQueue) done->_probeQueue = [gameQueue.device newCommandQueue];
            id<MTLCommandBuffer> probe = [done->_probeQueue commandBuffer];
            if (!probe) { atomic_fetch_sub(&done->_probes, 1); return; }
            [probe encodeWaitForEvent:done->_event value:value];
            [probe addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                atomic_fetch_sub(&done->_probes, 1);
                if (completed.status != MTLCommandBufferStatusError) observe_frame(nativeSample, completed.GPUEndTime, 0);
            }];
            [probe commit];
            return;
        }

        id<MTLCommandBuffer> buffer = [own_queue(gameQueue.device) commandBuffer];
        if (buffer == nil) {
            @synchronized (mulg_lock(drawable)) {
                objc_setAssociatedObject(drawable, &kPendingBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            CAMetalLayer *layer = mulg_upscaling_layer;
            if (layer != nil) [current_delegate() layerUsesUnsupportedPresentPath:layer];
            return;
        }
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusError) return;
            discard_pending(frame);
        }];
        [buffer encodeWaitForEvent:done->_event value:value];
        id output = upscale(drawable, buffer);
        if (output != nil) {
            mark_jit_frame(drawable, drawable);
            if (jit_watches(config, output)) {
                MulgFrameTiming *sample = watch_frame(output, config, ^{ return 0.0; });
                [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                    if (completed.status != MTLCommandBufferStatusError) observe_frame(sample, completed.GPUEndTime, 0);
                }];
            }
            // Presented and committed by skip_present when the game presents the source drawable.
            // Keep a free source/output slot, including when different queues share this layer.
            BOOL discardRequested, presentRequested;
            SEL requestedHow;
            CFTimeInterval requestedValue;
            @synchronized (mulg_lock(drawable)) {
                frame->_buffer = buffer;
                frame->_encoding = NO;
                discardRequested = frame->_discardRequested;
                presentRequested = frame->_presentRequested;
                requestedHow = frame->_how;
                requestedValue = frame->_value;
            }
            if (discardRequested) { discard_pending(frame); return; }
            CAMetalLayer *sourceLayer = physical_layer(drawable);
            @synchronized (mulg_lock(sourceLayer)) {
                NSMutableArray *frames = objc_getAssociatedObject(sourceLayer, &kSourcePendingKey);
                if (frames == nil) {
                    frames = [NSMutableArray new];
                    objc_setAssociatedObject(sourceLayer, &kSourcePendingKey, frames, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                [frames addObject:frame];
            }
            retire_source_frames(sourceLayer, pending_budget(sourceLayer, mulg_upscaling_layer), NO);
            if (presentRequested) {
                skip_present(drawable, requestedHow, requestedValue);
                jit_presented(drawable);
            }
            else if (!is_source_drawable(drawable)) retire_source_frames(sourceLayer, 0, YES);
        } else {
            @synchronized (mulg_lock(drawable)) {
                objc_setAssociatedObject(drawable, &kPendingBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [buffer commit];
        }
        } @finally { end_render_priority(priority); }
    }
}

// MARK: - Native MetalFX detection (§5.2.7)

static void report_game_metalfx(NSString *feature, id object, const void *caller) {
    if (object && !mulg_creating_own_metalfx && mulg_engine_is_game_caller(caller)) {
        [current_delegate() gameCreatedMetalFXObject:feature];
    }
}

static id __attribute__((ns_returns_retained)) mulg_fx_spatial(id self, SEL _cmd, id device) {
    id object = ((NewFXObject)previous_fx_spatial)(self, _cmd, device);
    report_game_metalfx(@"spatial", object, __builtin_return_address(0));
    return object;
}

static id __attribute__((ns_returns_retained)) mulg_fx_temporal(id self, SEL _cmd, id device) {
    id object = ((NewFXObject)previous_fx_temporal)(self, _cmd, device);
    report_game_metalfx(@"temporal", object, __builtin_return_address(0));
    return object;
}

static id __attribute__((ns_returns_retained)) mulg_fx_interpolator(id self, SEL _cmd, id device) {
    id object = ((NewFXObject)previous_fx_interpolator)(self, _cmd, device);
    report_game_metalfx(@"interpolator", object, __builtin_return_address(0));
    return object;
}

static id __attribute__((ns_returns_retained)) mulg_fx_denoised(id self, SEL _cmd, id device) {
    id result = ((NewFXObject)previous_fx_denoised)(self, _cmd, device);
    report_game_metalfx(@"temporal denoised", result, __builtin_return_address(0));
    return result;
}

static id __attribute__((ns_returns_retained)) mulg_fx4_spatial(id self, SEL _cmd, id device, id compiler) {
    id object = ((NewFXObjectWithCompiler)previous_fx4_spatial)(self, _cmd, device, compiler);
    report_game_metalfx(@"spatial", object, __builtin_return_address(0));
    return object;
}

static id __attribute__((ns_returns_retained)) mulg_fx4_temporal(id self, SEL _cmd, id device, id compiler) {
    id object = ((NewFXObjectWithCompiler)previous_fx4_temporal)(self, _cmd, device, compiler);
    report_game_metalfx(@"temporal", object, __builtin_return_address(0));
    return object;
}

static id __attribute__((ns_returns_retained)) mulg_fx4_interpolator(id self, SEL _cmd, id device, id compiler) {
    id object = ((NewFXObjectWithCompiler)previous_fx4_interpolator)(self, _cmd, device, compiler);
    report_game_metalfx(@"interpolator", object, __builtin_return_address(0));
    return object;
}

static id __attribute__((ns_returns_retained)) mulg_fx4_denoised(id self, SEL _cmd, id device, id compiler) {
    id result = ((NewFXObjectWithCompiler)previous_fx4_denoised)(self, _cmd, device, compiler);
    report_game_metalfx(@"Metal 4 temporal denoised", result, __builtin_return_address(0));
    return result;
}

// MARK: - Shader archive (§5.6)

typedef id (*NewPipeline)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));
typedef id (*NewPipelineWithReflection)(id, SEL, id, MTLPipelineOption, __autoreleasing id *, NSError **) __attribute__((ns_returns_retained));
typedef void (*NewPipelineAsync)(id, SEL, id, id);
typedef void (*NewPipelineWithOptionsAsync)(id, SEL, id, MTLPipelineOption, id);


/// Render, compute, mesh and tile pipelines share the `options:` builds: one hook per shape,
/// the kind found from the selector.
typedef NS_ENUM(int, PipelineKind) { PipelineRender, PipelineCompute, PipelineMesh, PipelineTile, PipelineKinds };
static SEL options_selectors[PipelineKinds];        // …:options:reflection:error:
static SEL options_async_selectors[PipelineKinds];  // …:options:completionHandler:

static id<MTLBinaryArchive> shader_lookup;  // the file as it was at launch, for lookups only
static id<MTLBinaryArchive> shader_record;  // rotated on shader_queue; readers use shader_state_lock
static NSURL *shader_archive_url;
static dispatch_queue_t shader_queue;       // every add and save to shader_record
static dispatch_source_t shader_save_timer;
static BOOL shader_save_scheduled;
static os_unfair_lock shader_state_lock = OS_UNFAIR_LOCK_INIT;
static uint64_t shader_generation;          // on shader_queue only
static uint64_t shader_saved_generation;    // on shader_queue only
static _Atomic(bool) shader_ready;
static _Atomic(bool) shader_capture_suspended;
static unsigned shader_save_failures;       // on shader_queue only
static char shader_queue_key;
static os_unfair_lock shader_recording_lock = OS_UNFAIR_LOCK_INIT;
static NSMapTable *shader_recorded_pipelines; // weak identity keys; never retains game pipelines
static NSUInteger shader_pending_records;
static uint64_t shader_recording_epoch;
static const NSUInteger kMaxPendingPipelineRecords = 64;
static NSString *mulg_device_class_name = @"?";
/// Device methods call each other internally; only the outermost call is handled.
static __thread int in_pipeline_hook = 0;

// An archive add compiles the pipeline again through the same driver. A game warming up its
// shaders (first launch, after an update) builds thousands of pipelines on many threads while it
// renders; Endfield 1.6.3 crashed there with a corrupt lock in the driver's program cache
// (2026-10-17). Capture is optional, so Mulg's compiler work waits until the game's goes quiet: no
// build in flight and none started or finished for archive_quiet_nanoseconds. Builds that pass
// in the meantime are dropped (bounded queue) and captured the next time the game builds them.
static _Atomic(int) game_pipeline_builds;
static _Atomic(uint64_t) game_pipeline_activity;  // CLOCK_UPTIME_RAW nanoseconds
static uint64_t archive_quiet_nanoseconds = 3 * NSEC_PER_SEC;
static _Atomic(bool) shader_exiting;

static void game_build_seen(void) {
    atomic_store(&game_pipeline_activity, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
}
static void game_build_began(void) {
    atomic_fetch_add(&game_pipeline_builds, 1);
    game_build_seen();
}
static void game_build_ended(void) {
    game_build_seen();
    atomic_fetch_sub(&game_pipeline_builds, 1);
}
static void game_build_ended_once(atomic_bool *finished) {
    if (!atomic_exchange_explicit(finished, true, memory_order_relaxed)) game_build_ended();
}

/// On the archive queue: blocks until the game's compilation is quiet. NO when the game is quitting.
static BOOL wait_for_quiet_compilation(void) {
    for (;;) {
        if (atomic_load(&shader_exiting)) return NO;
        uint64_t last = atomic_load(&game_pipeline_activity);
        uint64_t idle = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last;  // read after `last`: never negative
        if (atomic_load(&game_pipeline_builds) <= 0 && idle >= archive_quiet_nanoseconds) return YES;
        uint64_t wait = idle < archive_quiet_nanoseconds ? archive_quiet_nanoseconds - idle : archive_quiet_nanoseconds;
        usleep((useconds_t)(MAX(MIN(wait, 250 * NSEC_PER_MSEC), NSEC_PER_MSEC) / NSEC_PER_USEC));
    }
}

static uint64_t archive_file_size(NSURL *file) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:NULL][NSFileSize] unsignedLongLongValue];
}

/// One pending wakeup per backend, even during continuous compilation. All calls are on its queue.
/// Seconds from a new pipeline to the save, by how many saves this launch already made. Each
/// save rewrites the whole archive (Metal 3) or adds a file (Metal 4), so while the game keeps
/// building pipelines (a new area) the saves spread out instead of competing with its streaming
/// every 10 s. A hidden window, memory pressure and quitting still save at once.
static const uint64_t kArchiveSaveDelays[] = { 10, 30, 60, 120, 300 };

static void schedule_archive_save(dispatch_source_t timer, BOOL *scheduled) {
    if (timer == nil || *scheduled) return;
    *scheduled = YES;
    // The timer's context counts its saves (see archive_save_timer).
    uintptr_t saves = (uintptr_t)dispatch_get_context(timer);
    size_t last = sizeof(kArchiveSaveDelays) / sizeof(kArchiveSaveDelays[0]) - 1;
    uint64_t delay = kArchiveSaveDelays[saves < last ? saves : last];
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, delay * NSEC_PER_SEC / 10);
}

static dispatch_queue_t shader_archive_queue(const char *label) {
    dispatch_queue_attr_t attribute = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    attribute = dispatch_queue_attr_make_with_autorelease_frequency(attribute, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
    return dispatch_queue_create(label, attribute);
}

static dispatch_source_t archive_save_timer(dispatch_queue_t queue, BOOL *scheduled, dispatch_block_t save) {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (timer == nil) return nil;
    __weak dispatch_source_t weakTimer = timer;
    dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(timer, ^{
        dispatch_source_t strong = weakTimer;
        if (strong) {
            dispatch_source_set_timer(strong, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            dispatch_set_context(strong, (void *)((uintptr_t)dispatch_get_context(strong) + 1));
        }
        *scheduled = NO;
        save();
    });
    dispatch_resume(timer);
    return timer;
}

static BOOL archive_compilation_failed(NSError *error) {
    return [error.domain isEqualToString:MTLBinaryArchiveDomain]
        && (error.code == MTLBinaryArchiveErrorCompilationFailure
            || error.code == MTLBinaryArchiveErrorUnexpectedElement);
}

/// A compiler rejection (for example Metal 3 cannot pack aliases for an iOS-targeted air64) will
/// repeat on every launch, so later launches skip the work: see GraphicsModule.archiveUnsupported.
/// The folder is per game, GPU and macOS build; the marker adds the game build.
static void remember_archive_unsupported(void) {
    if (shader_archive_url == nil) return;
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    NSURL *marker = [[shader_archive_url URLByDeletingPathExtension] URLByAppendingPathExtension:@"unsupported"];
    [build ?: @"" writeToURL:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

/// Optional capture must not repeatedly recompile an archive that Metal cannot serialize.
/// Leave published lookups and the game's pipelines intact; retry capture next launch, unless
/// `permanent`: the compiler itself rejects this game's shaders, which no retry changes.
/// Called only on shader_queue, including when an archive API raises an exception.
static void suspend_shader_capture(BOOL permanent) {
    if (atomic_exchange(&shader_capture_suspended, true)) return;
    if (permanent) remember_archive_unsupported();
    if (shader_save_timer) dispatch_source_set_timer(shader_save_timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    shader_save_scheduled = NO;
    os_log_error(OS_LOG_DEFAULT, "Mulg shader capture suspended for this launch; native compilation and existing lookups remain available");
}

/// Metal 3 archives cannot remove individual entries. Restart capture when full or under pressure;
/// existing lookup objects and encoded game pipelines keep their resources.
static void reset_shader_record(void) {
    id<MTLBinaryArchive> empty = open_archive(shader_record.device, nil);
    os_unfair_lock_lock(&shader_state_lock);
    shader_record = empty;
    os_unfair_lock_unlock(&shader_state_lock);
    os_unfair_lock_lock(&shader_recording_lock);
    [shader_recorded_pipelines removeAllObjects];
    ++shader_recording_epoch;
    os_unfair_lock_unlock(&shader_recording_lock);
}

/// A copy of the game's descriptor that also looks in the archive, or nil to leave the call
/// alone. A copy, so the game's own descriptor is never changed and the recorded one is a
/// snapshot the game can't change while it waits on the queue.
static id with_archive(id<MTLDevice> device, id descriptor, BOOL *addedLookup) {
    if (addedLookup) *addedLookup = NO;
    if (in_pipeline_hook > 0 || descriptor == nil) return nil;
    os_unfair_lock_lock(&shader_state_lock);
    id<MTLBinaryArchive> record = shader_record, lookup = shader_lookup;
    os_unfair_lock_unlock(&shader_state_lock);
    BOOL recording = !atomic_load(&shader_capture_suspended) && record != nil && record.device == device;
    BOOL lookupAvailable = lookup != nil && lookup.device == device;
    if (!recording && !lookupAvailable) {
        return nil;
    }
    NSArray *archives = lookupAvailable ? ([descriptor binaryArchives] ?: @[]) : nil;
    BOOL append = lookupAvailable && ![archives containsObject:lookup];
    if (!recording && !append) return nil;
    id copy = [descriptor copy];
    if (append) {
        [copy setBinaryArchives:[archives arrayByAddingObject:lookup]];
        if (addedLookup) *addedLookup = YES;
    }
    return copy;
}

/// Written to a temporary file and renamed, so a game quitting mid-save leaves the old archive,
/// and the lookup archive keeps reading the file it opened.
static void save_shader_archive(void) {
    if (atomic_load(&shader_capture_suspended) || shader_record == nil) return;
    wait_for_quiet_compilation();  // returns at once when quitting: that save goes ahead
    NSURL *partial = [shader_archive_url URLByAppendingPathExtension:@"partial"];
    NSError *error = nil;
    BOOL serialized = NO, saved = NO;
    @try { serialized = [shader_record serializeToURL:partial error:&error]; }
    @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT, "Mulg shader archive serialization raised %{public}@", exception.name);
        suspend_shader_capture(NO);
    }
    if (serialized) {
        if (archive_file_size(partial) > MulgGraphicsShaderArchiveLimit / 2) {
            // Not a flush: the published lookup stays intact while capture starts a bounded batch.
            [NSFileManager.defaultManager removeItemAtURL:partial error:NULL];
            reset_shader_record();
            shader_saved_generation = shader_generation;
            saved = YES;
        } else if (rename(partial.fileSystemRepresentation, shader_archive_url.fileSystemRepresentation) == 0) {
            shader_saved_generation = shader_generation;
            saved = YES;
        } else {
            os_log_error(OS_LOG_DEFAULT, "Mulg shader archive replacement failed: %{public}d", errno);
        }
    } else {
        os_log_error(OS_LOG_DEFAULT, "Mulg shader archive serialization failed: %{public}@", error);
        [NSFileManager.defaultManager removeItemAtURL:partial error:NULL];
    }
    if (saved) shader_save_failures = 0;
    else if (archive_compilation_failed(error)) suspend_shader_capture(YES);
    else if (++shader_save_failures >= 3) suspend_shader_capture(NO);
    if (!atomic_load(&shader_capture_suspended) && shader_saved_generation != shader_generation)
        schedule_archive_save(shader_save_timer, &shader_save_scheduled);
}

/// The game is quitting: add what is still queued and save it, so the last pipelines are not lost.
static void save_shader_archive_at_exit(void) {
    if (atomic_load(&shader_capture_suspended) || !shader_queue) return;
    atomic_store(&shader_exiting, true);  // queued adds stop waiting for quiet compilation
    dispatch_block_t save = ^{
        if (shader_generation != shader_saved_generation) {
            save_shader_archive();
        }
    };
    // A native compiler failure may terminate from this very queue. Never sync to ourselves.
    if (dispatch_get_specific(&shader_queue_key)) save();
    else dispatch_sync(shader_queue, save);
}

/// Adds the pipeline's compiled functions to the archive after the game got its pipeline, so
/// Metal's own cache already holds them and the add is cheap.
// Use the actual compiled pipeline's identity: guessing descriptor equivalence can conflate
// function constants, linked functions or future Metal options. Bound optional recording;
// a full queue never holds up the pipeline already returned to the game.
static void record_pipeline(id descriptor, PipelineKind kind, id pipeline) {
    if (!pipeline || !descriptor || atomic_load(&shader_capture_suspended)) return;
    os_unfair_lock_lock(&shader_recording_lock);
    if (!shader_recorded_pipelines) shader_recorded_pipelines = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
        valueOptions:NSPointerFunctionsStrongMemory];
    // A full backlog already rejects this record; avoid the weak-table lookup
    // under the shared lock when it cannot change the admission decision.
    if (shader_pending_records >= kMaxPendingPipelineRecords || [shader_recorded_pipelines objectForKey:pipeline]) {
        os_unfair_lock_unlock(&shader_recording_lock);
        return;
    }
    [shader_recorded_pipelines setObject:@1 forKey:pipeline];
    ++shader_pending_records;
    uint64_t epoch = shader_recording_epoch;
    os_unfair_lock_unlock(&shader_recording_lock);
    dispatch_async(shader_queue, ^{
        BOOL added = NO;
        NSError *error = nil;
        @try {
            if (wait_for_quiet_compilation() && !atomic_load(&shader_capture_suspended)) {
                switch (kind) {
                case PipelineRender: added = [shader_record addRenderPipelineFunctionsWithDescriptor:descriptor error:&error]; break;
                case PipelineCompute: added = [shader_record addComputePipelineFunctionsWithDescriptor:descriptor error:&error]; break;
                case PipelineMesh: added = [shader_record addMeshRenderPipelineFunctionsWithDescriptor:descriptor error:&error]; break;
                case PipelineTile: added = [shader_record addTileRenderPipelineFunctionsWithDescriptor:descriptor error:&error]; break;
                case PipelineKinds: break;
                }
            }
        } @catch (NSException *exception) {
            os_log_error(OS_LOG_DEFAULT, "Mulg shader archive capture raised %{public}@", exception.name);
            suspend_shader_capture(NO);
        }
        os_unfair_lock_lock(&shader_recording_lock);
        --shader_pending_records;
        if (epoch == shader_recording_epoch) {
            // An unsupported descriptor will not become recordable by retrying the same
            // compiled object. Keep transient failures eligible for a later retry.
            if (added || archive_compilation_failed(error)) [shader_recorded_pipelines setObject:@2 forKey:pipeline];
            else [shader_recorded_pipelines removeObjectForKey:pipeline];
        }
        os_unfair_lock_unlock(&shader_recording_lock);
        if (!added || atomic_load(&shader_capture_suspended)) return;
        ++shader_generation;
        schedule_archive_save(shader_save_timer, &shader_save_scheduled);
    });
}

/// The archive is optional: a request that failed with it is made again exactly as the game
/// asked, so the cache never turns a pipeline the game would have got into a nil one.
static void note_archive_fallback(NSError *error) {
    static _Atomic(bool) noted = false;
    if (atomic_exchange(&noted, true)) return;
    os_log_error(OS_LOG_DEFAULT, "Mulg shader archive: a pipeline failed with the archive attached and was created "
                 "without it: %{public}@", error.localizedDescription ?: @"no error");
}

static id __attribute__((ns_returns_retained)) mulg_render_pipeline(id self, SEL _cmd, id descriptor, NSError **error) {
    BOOL addedLookup = NO;
    id copy = with_archive(self, descriptor, &addedLookup);
    NewPipeline original = (NewPipeline)ORIGINAL(self, _cmd, mulg_render_pipeline);
    id pipeline;
    in_pipeline_hook += 1;
    game_build_began();
    @try {
        pipeline = original(self, _cmd, addedLookup ? copy : descriptor, error);
        if (addedLookup && pipeline == nil) {
            note_archive_fallback(error ? *error : nil);
            pipeline = original(self, _cmd, descriptor, error);
            copy = nil;
        }
    } @finally { game_build_ended(); in_pipeline_hook -= 1; }
    if (copy != nil && pipeline != nil) {
        record_pipeline(copy, PipelineRender, pipeline);
    }
    return pipeline;
}

static void mulg_render_pipeline_async(id self, SEL _cmd, id descriptor, MTLNewRenderPipelineStateCompletionHandler handler) {
    if (handler == nil) {
        NewPipelineAsync original = (NewPipelineAsync)ORIGINAL(self, _cmd, mulg_render_pipeline_async);
        // No completion can record or retry this request. Preserve native nil-callback
        // semantics without allocating the completion's shared atomic state or blocks.
        game_build_seen();
        in_pipeline_hook += 1;
        @try { original(self, _cmd, descriptor, nil); }
        @finally { in_pipeline_hook -= 1; }
        return;
    }
    __block atomic_bool finished = false;
    BOOL addedLookup = NO;
    id copy = handler != nil ? with_archive(self, descriptor, &addedLookup) : nil;
    // The caller may reuse its mutable descriptor as soon as this call returns.
    // Keep the original request, without our archive, for an asynchronous retry.
    id retryDescriptor = addedLookup ? [descriptor copy] : nil;
    NewPipelineAsync original = (NewPipelineAsync)ORIGINAL(self, _cmd, mulg_render_pipeline_async);
    if (handler == nil) game_build_seen(); else game_build_began();
    in_pipeline_hook += 1;
    @try {
        original(self, _cmd, addedLookup ? copy : descriptor, handler == nil ? nil
            : ^(id<MTLRenderPipelineState> pipeline, NSError *error) {
                if (!addedLookup || pipeline != nil) {
                    game_build_ended_once(&finished);
                    if (copy != nil) record_pipeline(copy, PipelineRender, pipeline);
                    handler(pipeline, error);
                    return;
                }
                note_archive_fallback(error);
                @try {
                    original(self, _cmd, retryDescriptor, ^(id<MTLRenderPipelineState> retried, NSError *retryError) {
                        game_build_ended_once(&finished);
                        handler(retried, retryError);
                    });
                } @catch (NSException *exception) { game_build_ended_once(&finished); @throw; }
            });
    } @catch (NSException *exception) {
        if (handler) game_build_ended_once(&finished);
        @throw;
    } @finally { in_pipeline_hook -= 1; }
}

static PipelineKind kind_of(SEL selector, const SEL *selectors) {
    PipelineKind kind = PipelineRender;
    while (kind < PipelineKinds - 1 && selectors[kind] != selector) {
        kind++;
    }
    return kind;
}

static id __attribute__((ns_returns_retained)) mulg_pipeline_options(id self, SEL _cmd, id descriptor, MTLPipelineOption options,
                                __autoreleasing id *reflection, NSError **error) {
    PipelineKind kind = kind_of(_cmd, options_selectors);
    BOOL addedLookup = NO;
    id copy = with_archive(self, descriptor, &addedLookup);
    NewPipelineWithReflection original = (NewPipelineWithReflection)ORIGINAL(self, _cmd, mulg_pipeline_options);
    id pipeline;
    in_pipeline_hook += 1;
    game_build_began();
    @try {
        pipeline = original(self, _cmd, addedLookup ? copy : descriptor, options, reflection, error);
        if (addedLookup && pipeline == nil) {
            note_archive_fallback(error ? *error : nil);
            pipeline = original(self, _cmd, descriptor, options, reflection, error);
            copy = nil;
        }
    } @finally { game_build_ended(); in_pipeline_hook -= 1; }
    if (copy != nil && pipeline != nil) {
        record_pipeline(copy, kind, pipeline);
    }
    return pipeline;
}

/// Every `options:completionHandler:` handler takes (pipeline, reflection, error).
static void mulg_pipeline_options_async(id self, SEL _cmd, id descriptor, MTLPipelineOption options,
                                        void (^handler)(id, id, NSError *)) {
    if (handler == nil) {
        NewPipelineWithOptionsAsync original = (NewPipelineWithOptionsAsync)ORIGINAL(self, _cmd, mulg_pipeline_options_async);
        game_build_seen();
        in_pipeline_hook += 1;
        @try { original(self, _cmd, descriptor, options, nil); }
        @finally { in_pipeline_hook -= 1; }
        return;
    }
    __block atomic_bool finished = false;
    PipelineKind kind = kind_of(_cmd, options_async_selectors);
    BOOL addedLookup = NO;
    id copy = handler != nil ? with_archive(self, descriptor, &addedLookup) : nil;
    id retryDescriptor = addedLookup ? [descriptor copy] : nil;
    NewPipelineWithOptionsAsync original = (NewPipelineWithOptionsAsync)ORIGINAL(self, _cmd, mulg_pipeline_options_async);
    if (handler == nil) game_build_seen(); else game_build_began();
    in_pipeline_hook += 1;
    @try {
        original(self, _cmd, addedLookup ? copy : descriptor, options,
            handler == nil ? nil : ^(id pipeline, id reflection, NSError *error) {
                if (!addedLookup || pipeline != nil) {
                    game_build_ended_once(&finished);
                    if (copy != nil) record_pipeline(copy, kind, pipeline);
                    handler(pipeline, reflection, error);
                    return;
                }
                note_archive_fallback(error);
                @try {
                    original(self, _cmd, retryDescriptor, options, ^(id retried, id retriedReflection, NSError *retryError) {
                        game_build_ended_once(&finished);
                        handler(retried, retriedReflection, retryError);
                    });
                } @catch (NSException *exception) { game_build_ended_once(&finished); @throw; }
            });
    } @catch (NSException *exception) {
        if (handler) game_build_ended_once(&finished);
        @throw;
    } @finally { in_pipeline_hook -= 1; }
}

// Function APIs have the default compute descriptor semantics. Keep their original methods
// as the fallback, so an optional archive never turns working compilation into a game error.
static id function_archive(id device, id function) {
    if (!function || in_pipeline_hook || ![function respondsToSelector:@selector(functionType)]
        || [(id<MTLFunction>)function functionType] != MTLFunctionTypeKernel) return nil;
    MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
    descriptor.computeFunction = function;
    return with_archive(device, descriptor, NULL);
}

static BOOL function_lookup(id descriptor, MTLPipelineOption options) {
    return descriptor && shader_lookup && !(options & MTLPipelineOptionFailOnBinaryArchiveMiss);
}

static id __attribute__((ns_returns_retained)) mulg_compute_function(id self, SEL selector, id function, NSError **error);
static id __attribute__((ns_returns_retained)) mulg_compute_function_options(id self, SEL selector, id function, MTLPipelineOption options,
                                                                          id __autoreleasing *reflection, NSError **error);
static id __attribute__((ns_returns_retained)) compute_function(id self, SEL selector, id function, MTLPipelineOption options,
                                                               id __autoreleasing *reflection, NSError **error, BOOL withOptions) {
    id descriptor = function_archive(self, function);
    IMP nativeDescriptor = ORIGINAL(self, @selector(newComputePipelineStateWithDescriptor:options:reflection:error:), mulg_pipeline_options);
    id result = nil;
    in_pipeline_hook++;
    game_build_began();
    @try {
        if (nativeDescriptor && function_lookup(descriptor, options)) {
            id lookupReflection = nil;
            result = ((NewPipelineWithReflection)nativeDescriptor)(self,
                @selector(newComputePipelineStateWithDescriptor:options:reflection:error:), descriptor, options, reflection ? &lookupReflection : NULL, NULL);
            if (result && reflection) *reflection = lookupReflection;
        }
        if (!result) {
            IMP original = ORIGINAL(self, selector, (withOptions ? (IMP)mulg_compute_function_options : (IMP)mulg_compute_function));
            result = withOptions ? ((NewPipelineWithReflection)original)(self, selector, function, options, reflection, error)
                : ((NewPipeline)original)(self, selector, function, error);
        }
    } @finally { game_build_ended(); in_pipeline_hook--; }
    if (result && descriptor) record_pipeline(descriptor, PipelineCompute, result);
    return result;
}

static id __attribute__((ns_returns_retained)) mulg_compute_function(id self, SEL selector, id function, NSError **error) {
    return compute_function(self, selector, function, 0, NULL, error, NO);
}
static id __attribute__((ns_returns_retained)) mulg_compute_function_options(id self, SEL selector, id function, MTLPipelineOption options,
                                                                          id __autoreleasing *reflection, NSError **error) {
    return compute_function(self, selector, function, options, reflection, error, YES);
}

static void mulg_compute_function_async(id self, SEL selector, id function, MTLNewComputePipelineStateCompletionHandler handler);
static void mulg_compute_function_options_async(id self, SEL selector, id function, MTLPipelineOption options,
                                               void (^handler)(id, id, NSError *));
static void compute_function_async(id self, SEL selector, id function, MTLPipelineOption options, id handler, BOOL withOptions) {
    if (handler == nil) {
        IMP original = ORIGINAL(self, selector, (withOptions ? (IMP)mulg_compute_function_options_async : (IMP)mulg_compute_function_async));
        game_build_seen();
        in_pipeline_hook++;
        @try {
            if (withOptions) ((NewPipelineWithOptionsAsync)original)(self, selector, function, options, nil);
            else ((NewPipelineAsync)original)(self, selector, function, nil);
        } @finally { in_pipeline_hook--; }
        return;
    }
    __block atomic_bool finished = false;
    id descriptor = handler ? function_archive(self, function) : nil;
    IMP original = ORIGINAL(self, selector, (withOptions ? (IMP)mulg_compute_function_options_async : (IMP)mulg_compute_function_async));
    if (handler == nil) game_build_seen(); else game_build_began();
    void (^finish)(id, id, NSError *) = ^(id pipeline, id reflection, NSError *error) {
        game_build_ended_once(&finished);
        if (pipeline && descriptor) record_pipeline(descriptor, PipelineCompute, pipeline);
        if (withOptions) ((void (^)(id, id, NSError *))handler)(pipeline, reflection, error);
        else ((MTLNewComputePipelineStateCompletionHandler)handler)(pipeline, error);
    };
    void (^native)(void) = ^{
        in_pipeline_hook++;
        @try {
            if (withOptions) ((NewPipelineWithOptionsAsync)original)(self, selector, function, options, handler ? finish : nil);
            else ((NewPipelineAsync)original)(self, selector, function, handler ? ^(id pipeline, NSError *error) { finish(pipeline, nil, error); } : nil);
        } @catch (NSException *exception) {
            if (handler) game_build_ended_once(&finished);
            @throw;
        } @finally { in_pipeline_hook--; }
    };
    IMP nativeDescriptor = ORIGINAL(self, @selector(newComputePipelineStateWithDescriptor:options:completionHandler:), mulg_pipeline_options_async);
    if (nativeDescriptor && function_lookup(descriptor, options)) {
        in_pipeline_hook++;
        @try {
            ((NewPipelineWithOptionsAsync)nativeDescriptor)(self, @selector(newComputePipelineStateWithDescriptor:options:completionHandler:),
                descriptor, options, ^(id pipeline, id reflection, NSError *error) {
                    if (pipeline) finish(pipeline, reflection, error); else native();
                });
        } @catch (NSException *exception) {
            if (handler) game_build_ended_once(&finished);
            @throw;
        } @finally { in_pipeline_hook--; }
    } else native();
}
static void mulg_compute_function_async(id self, SEL selector, id function, MTLNewComputePipelineStateCompletionHandler handler) {
    compute_function_async(self, selector, function, 0, handler, NO);
}
static void mulg_compute_function_options_async(id self, SEL selector, id function, MTLPipelineOption options,
                                               void (^handler)(id, id, NSError *)) {
    compute_function_async(self, selector, function, options, handler, YES);
}

// MARK: - Render target sizes (diagnostic)

// Counts the pixel size of each render pass's first color attachment (depth when there is none), so the
// render report shows what a game really draws at below its drawable. Fixed table: later sizes beyond it
// are not counted.
typedef struct { uint32_t width, height; _Atomic(uint64_t) passes, recent; } MulgPassSize;
static MulgPassSize pass_sizes[128];
static os_unfair_lock pass_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic(uint64_t) pass_size_overflow;
static atomic_bool graphics_diagnostics_enabled;

/// The slot this thread counted last: passes into the same size in a row (shadow cascades, a blur
/// chain) count without the lock. A slot never changes its size once used.
static __thread MulgPassSize *last_pass_slot;
// Frames alternate between scene, shadow and post-process sizes. Keeping only
// the immediately previous size made those repeated passes scan the shared
// table under a global lock. Slots are immutable once published, so cache their
// addresses per thread and retain the lock only for discovery/cache collisions.
static __thread MulgPassSize *pass_slot_cache[64][2];

static void record_pass(id<MTLTexture> texture) {
    if (!texture) return;
    uint32_t width = (uint32_t)texture.width, height = (uint32_t)texture.height;
    MulgPassSize *last = last_pass_slot;
    if (last && last->width == width && last->height == height) {
        atomic_fetch_add_explicit(&last->passes, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&last->recent, 1, memory_order_relaxed);
        return;
    }
    uint32_t bucket = ((width * 0x9e3779b1U) ^ (height * 0x85ebca6bU)) >> 26;
    for (unsigned way = 0; way < 2; way++) {
        MulgPassSize *cached = pass_slot_cache[bucket][way];
        if (cached && cached->width == width && cached->height == height) {
            atomic_fetch_add_explicit(&cached->passes, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&cached->recent, 1, memory_order_relaxed);
            last_pass_slot = cached;
            return;
        }
    }
    os_unfair_lock_lock(&pass_lock);
    for (size_t i = 0; i < sizeof pass_sizes / sizeof *pass_sizes; i++) {
        MulgPassSize *slot = &pass_sizes[i];
        BOOL occupied = atomic_load_explicit(&slot->passes, memory_order_relaxed) != 0;
        if (occupied && (slot->width != width || slot->height != height)) continue;
        if (!occupied) { slot->width = width; slot->height = height; }
        atomic_fetch_add_explicit(&slot->passes, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&slot->recent, 1, memory_order_relaxed);
        last_pass_slot = slot;
        pass_slot_cache[bucket][1] = pass_slot_cache[bucket][0];
        pass_slot_cache[bucket][0] = slot;
        os_unfair_lock_unlock(&pass_lock);
        return;
    }
    atomic_fetch_add_explicit(&pass_size_overflow, 1, memory_order_relaxed);
    os_unfair_lock_unlock(&pass_lock);
}

static void record_scene_pass(MTLRenderPassDescriptor *descriptor, const void *caller);

static id mulg_render_encoder(id self, SEL selector, MTLRenderPassDescriptor *descriptor) {
    if (!atomic_load_explicit(&graphics_diagnostics_enabled, memory_order_relaxed))
        return ((DescriptorFactory)ORIGINAL(self, selector, mulg_render_encoder))(self, selector, descriptor);
    // The pass size count for rendering.json (renderPassSizes).
    id<MTLTexture> texture = descriptor ? (descriptor.colorAttachments[0].texture ?: descriptor.depthAttachment.texture) : nil;
    record_pass(texture);
    id encoder = ((DescriptorFactory)ORIGINAL(self, selector, mulg_render_encoder))(self, selector, descriptor);
    if (encoder) record_scene_pass(descriptor, __builtin_return_address(0));
    return encoder;
}

NSArray<NSString *> *mulg_graphics_render_pass_sizes(void) {
    // Plain counts: an atomic field has no NSValue encoding (valueWithBytes:objCType: returned nil
    // and the report crashed every game in build 1012).
    typedef struct { uint32_t width, height; uint64_t passes; } Count;
    Count counts[sizeof pass_sizes / sizeof *pass_sizes];
    size_t used = 0;
    os_unfair_lock_lock(&pass_lock);
    for (size_t i = 0; i < sizeof pass_sizes / sizeof *pass_sizes; i++) {
        uint64_t passes = atomic_load_explicit(&pass_sizes[i].passes, memory_order_relaxed);
        if (!passes) break;
        counts[used++] = (Count){ pass_sizes[i].width, pass_sizes[i].height, passes };
    }
    os_unfair_lock_unlock(&pass_lock);
    // Most used first; this is a lifetime histogram, not the current frame graph.
    for (size_t i = 1; i < used; i++) {
        Count item = counts[i];
        size_t j = i;
        for (; j > 0 && counts[j - 1].passes < item.passes; j--) counts[j] = counts[j - 1];
        counts[j] = item;
    }
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:used];
    for (size_t i = 0; i < used; i++)
        [lines addObject:[NSString stringWithFormat:@"%ux%u: %llu passes", counts[i].width, counts[i].height, counts[i].passes]];
    return lines;
}

NSDictionary *mulg_graphics_recent_render_pass_sizes(void) {
    NSMutableArray<NSDictionary *> *sizes = [NSMutableArray array];
    os_unfair_lock_lock(&pass_lock);
    for (size_t i = 0; i < sizeof pass_sizes / sizeof *pass_sizes; i++) {
        MulgPassSize *slot = &pass_sizes[i];
        uint64_t count = atomic_exchange_explicit(&slot->recent, 0, memory_order_relaxed);
        if (count) [sizes addObject:@{@"width": @(slot->width), @"height": @(slot->height), @"passes": @(count)}];
    }
    os_unfair_lock_unlock(&pass_lock);
    [sizes sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"passes"] compare:a[@"passes"]];
    }];
    return @{@"sizes": sizes, @"unrecordedPasses": @(atomic_exchange_explicit(&pass_size_overflow, 0, memory_order_relaxed)),
        @"scope": @"Render attachments observed since the previous report; scene identity unverified"};
}

/// Test entry: counts one render pass into `texture`, as the encoder hook does.
void mulg_graphics_record_pass_for_testing(id texture) { record_pass(texture); }

// MARK: - Scene allocation call sites (diagnostic)

enum { MulgSceneGeneralLimit = 24, MulgSceneSampleLimit = 32, MulgSceneStackLimit = 24 };
typedef struct {
    NSUInteger width, height, format;
    const void *caller;
    void *stack[MulgSceneStackLimit];
    int stackCount;
    BOOL observedColorPass, observedSameSizeDepth;
    BOOL duringSceneApply, fromCameraAllocator;
} MulgSceneAllocation;

static _Atomic(bool) scene_trace_enabled;
static os_unfair_lock scene_trace_lock = OS_UNFAIR_LOCK_INIT;
static MulgSceneAllocation scene_allocations[MulgSceneSampleLimit];
static size_t scene_allocation_count;
static struct {
    const void *caller;
    NSUInteger colorFormat, depthFormat, sampleCount;
} native_color_depth_passes[8];
static size_t native_color_depth_pass_count;
static uint64_t scene_trace_generation;
static uint64_t scene_trace_revision;
static uint64_t scene_report_revision;
static NSDictionary *scene_cached_report;
static char sceneAllocationKey;
static __thread uintptr_t sceneApplyAllocator;

uintptr_t mulg_graphics_set_scene_apply_allocator(uintptr_t returnAddress) {
    uintptr_t previous = sceneApplyAllocator;
    sceneApplyAllocator = returnAddress;
    return previous;
}

@interface MulgSceneAllocationTag : NSObject {
@public
    uint64_t generation;
    size_t slot;
    atomic_bool complete;
}
@end

@implementation MulgSceneAllocationTag
@end

void mulg_graphics_set_scene_trace_enabled(BOOL enabled) {
    os_unfair_lock_lock(&scene_trace_lock);
    if (atomic_load(&scene_trace_enabled) != enabled) {
        scene_allocation_count = 0;
        native_color_depth_pass_count = 0;
        scene_trace_generation++;
        scene_trace_revision++;
        atomic_store(&scene_trace_enabled, enabled);
    }
    os_unfair_lock_unlock(&scene_trace_lock);
}

static void tag_scene_texture(id texture, uint64_t generation, size_t slot) {
    MulgSceneAllocationTag *tag = [MulgSceneAllocationTag new];
    tag->generation = generation;
    tag->slot = slot;
    atomic_init(&tag->complete, false);
    objc_setAssociatedObject(texture, &sceneAllocationKey, tag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void record_scene_pass(MTLRenderPassDescriptor *descriptor, const void *caller) {
    if (!descriptor || !atomic_load_explicit(&scene_trace_enabled, memory_order_relaxed)) return;
    MTLRenderPassColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    id<MTLTexture> colorTexture = color.texture;
    if (!colorTexture || color.level != 0) return;
    MulgSceneAllocationTag *tag = objc_getAssociatedObject(colorTexture, &sceneAllocationKey);
    BOOL nativeSize = colorTexture.width == 2880 && colorTexture.height == 1800;
    if (!tag && !nativeSize) return;
    // The report records whether a sampled allocation has ever been used with
    // matching depth. Once established, repeated uses need no depth inspection
    // or shared trace lock. Keep collecting distinct native-pair call sites.
    if (tag && !nativeSize && atomic_load_explicit(&tag->complete, memory_order_relaxed)) return;
    MTLRenderPassDepthAttachmentDescriptor *depth = descriptor.depthAttachment;
    id<MTLTexture> depthTexture = depth.texture;
    BOOL matched = depthTexture && depth.level == 0 && depthTexture.width == colorTexture.width &&
        depthTexture.height == colorTexture.height && depthTexture.sampleCount == colorTexture.sampleCount;
    if (!tag && !matched) return;
    BOOL nativePair = nativeSize && matched;
    NSUInteger colorFormat = nativePair ? colorTexture.pixelFormat : 0;
    NSUInteger depthFormat = nativePair ? depthTexture.pixelFormat : 0;
    NSUInteger sampleCount = nativePair ? colorTexture.sampleCount : 0;
    if (!os_unfair_lock_trylock(&scene_trace_lock)) return;
    if (tag && tag->generation == scene_trace_generation && tag->slot < scene_allocation_count) {
        MulgSceneAllocation *sample = &scene_allocations[tag->slot];
        if (!sample->observedColorPass || (matched && !sample->observedSameSizeDepth)) {
            sample->observedColorPass = YES;
            sample->observedSameSizeDepth |= matched;
            scene_trace_revision++;
        }
        if (sample->observedColorPass && sample->observedSameSizeDepth)
            atomic_store_explicit(&tag->complete, true, memory_order_relaxed);
    }
    if (nativePair && atomic_load_explicit(&scene_trace_enabled, memory_order_relaxed)) {
        size_t i = 0;
        for (; i < native_color_depth_pass_count; i++) {
            if (native_color_depth_passes[i].caller == caller &&
                native_color_depth_passes[i].colorFormat == colorFormat &&
                native_color_depth_passes[i].depthFormat == depthFormat &&
                native_color_depth_passes[i].sampleCount == sampleCount) break;
        }
        if (i == native_color_depth_pass_count && i < sizeof native_color_depth_passes / sizeof *native_color_depth_passes) {
            native_color_depth_passes[i] = (__typeof__(*native_color_depth_passes)){caller, colorFormat, depthFormat, sampleCount};
            native_color_depth_pass_count++;
            scene_trace_revision++;
        }
    }
    os_unfair_lock_unlock(&scene_trace_lock);
}

static void record_scene_allocation(id texture, MTLTextureDescriptor *descriptor, const void *caller) {
    if (!(descriptor.usage & MTLTextureUsageRenderTarget) ||
        (descriptor.textureType != MTLTextureType2D && descriptor.textureType != MTLTextureType2DMultisample)) return;
    NSUInteger width = descriptor.width, height = descriptor.height, format = descriptor.pixelFormat;
    if (MIN(width, height) < 540 || MAX(width, height) < 960 || !mulg_engine_is_game_caller(caller)) return;
    MulgSceneAllocation sample = { .width = width, .height = height, .format = format, .caller = caller };
    if (sceneApplyAllocator) {
        sample.duringSceneApply = YES;
        sample.stackCount = backtrace(sample.stack, MulgSceneStackLimit);
        for (int i = 0; i < sample.stackCount; i++) {
            if ((uintptr_t)sample.stack[i] == sceneApplyAllocator) {
                sample.fromCameraAllocator = YES;
                break;
            }
        }
    }
    if (!os_unfair_lock_trylock(&scene_trace_lock)) return;
    if (!atomic_load(&scene_trace_enabled)) {
        os_unfair_lock_unlock(&scene_trace_lock);
        return;
    }
    for (size_t i = 0; i < scene_allocation_count; i++) {
        const MulgSceneAllocation *existing = &scene_allocations[i];
        if (existing->width == width && existing->height == height && existing->format == format &&
            existing->caller == caller && existing->duringSceneApply == sample.duringSceneApply &&
            existing->fromCameraAllocator == sample.fromCameraAllocator) {
            uint64_t generation = scene_trace_generation;
            os_unfair_lock_unlock(&scene_trace_lock);
            tag_scene_texture(texture, generation, i);
            return;
        }
    }
    size_t limit = sample.duringSceneApply ? MulgSceneSampleLimit : MulgSceneGeneralLimit;
    if (scene_allocation_count >= limit) {
        os_unfair_lock_unlock(&scene_trace_lock);
        return;
    }
    size_t slot = scene_allocation_count++;
    uint64_t generation = scene_trace_generation;
    scene_allocations[slot] = sample;
    scene_trace_revision++;
    os_unfair_lock_unlock(&scene_trace_lock);
    tag_scene_texture(texture, generation, slot);
    // Unwind outside our lock. Symbol lookup is deferred until the report is read.
    if (sample.duringSceneApply) return;
    sample.stackCount = backtrace(sample.stack, MulgSceneStackLimit);
    if (!os_unfair_lock_trylock(&scene_trace_lock)) return;
    if (generation == scene_trace_generation) {
        scene_allocations[slot].stackCount = sample.stackCount;
        memcpy(scene_allocations[slot].stack, sample.stack, sizeof sample.stack);
        scene_trace_revision++;
    }
    os_unfair_lock_unlock(&scene_trace_lock);
}

typedef id (*NewSceneTexture)(id, SEL, MTLTextureDescriptor *) __attribute__((ns_returns_retained));

static id __attribute__((ns_returns_retained)) mulg_new_scene_texture(id self, SEL selector, MTLTextureDescriptor *descriptor) {
    id texture = ((NewSceneTexture)ORIGINAL(self, selector, mulg_new_scene_texture))(self, selector, descriptor);
    if (texture && atomic_load_explicit(&scene_trace_enabled, memory_order_relaxed))
        record_scene_allocation(texture, descriptor, __builtin_return_address(0));
    return texture;
}

NSDictionary *mulg_graphics_scene_trace(void) {
    MulgSceneAllocation samples[MulgSceneSampleLimit];
    __typeof__(native_color_depth_passes) nativePasses;
    os_unfair_lock_lock(&scene_trace_lock);
    uint64_t revision = scene_trace_revision;
    if (scene_cached_report && revision == scene_report_revision) {
        NSDictionary *cached = scene_cached_report;
        os_unfair_lock_unlock(&scene_trace_lock);
        return cached;
    }
    size_t count = scene_allocation_count;
    size_t nativePassCount = native_color_depth_pass_count;
    memcpy(samples, scene_allocations, count * sizeof *samples);
    memcpy(nativePasses, native_color_depth_passes, nativePassCount * sizeof *nativePasses);
    os_unfair_lock_unlock(&scene_trace_lock);
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        const MulgSceneAllocation *sample = &samples[i];
        NSMutableArray *callSites = [NSMutableArray array];
        for (int j = -1; j < sample->stackCount; j++) {
            const void *pc = j < 0 ? sample->caller : sample->stack[j];
            Dl_info info;
            if (!mulg_engine_is_game_caller(pc) || !dladdr(pc, &info) || !info.dli_fname || !info.dli_fbase) continue;
            NSString *name = [NSString stringWithUTF8String:info.dli_fname].lastPathComponent;
            if (!name) continue;
            NSString *offset = [NSString stringWithFormat:@"0x%llx", (unsigned long long)((uintptr_t)pc - (uintptr_t)info.dli_fbase)];
            NSDictionary *site = @{@"image": name, @"returnOffset": offset};
            if (![callSites containsObject:site]) [callSites addObject:site];
        }
        [rows addObject:@{@"width": @(sample->width), @"height": @(sample->height),
            @"pixelFormat": @(sample->format), @"callSites": callSites,
            @"allocatedDuringSceneApply": @(sample->duringSceneApply),
            @"verifiedCameraAllocatorOnStack": @(sample->fromCameraAllocator),
            @"observedAsColorAttachment": @(sample->observedColorPass),
            @"observedWithMatchingDepthAttachment": @(sample->observedSameSizeDepth)}];
    }
    NSMutableArray *passRows = [NSMutableArray arrayWithCapacity:nativePassCount];
    for (size_t i = 0; i < nativePassCount; i++) {
        const void *caller = nativePasses[i].caller;
        Dl_info info;
        NSString *image = nil, *offset = nil;
        if (caller && dladdr(caller, &info) && info.dli_fname && info.dli_fbase) {
            image = [NSString stringWithUTF8String:info.dli_fname].lastPathComponent;
            offset = [NSString stringWithFormat:@"0x%llx", (unsigned long long)((uintptr_t)caller - (uintptr_t)info.dli_fbase)];
        }
        [passRows addObject:@{@"colorPixelFormat": @(nativePasses[i].colorFormat),
            @"depthPixelFormat": @(nativePasses[i].depthFormat), @"sampleCount": @(nativePasses[i].sampleCount),
            @"image": image ?: NSNull.null, @"returnOffset": offset ?: NSNull.null}];
    }
    NSDictionary *report = @{@"scope": @"Game-owned Metal device allocations; heap targets and existing textures may be absent",
        @"sampleLimit": @(MulgSceneSampleLimit), @"samples": rows,
        @"colorDepthPassesAt2880x1800": passRows};
    os_unfair_lock_lock(&scene_trace_lock);
    if (scene_trace_revision == revision) {
        scene_cached_report = report;
        scene_report_revision = revision;
    }
    os_unfair_lock_unlock(&scene_trace_lock);
    return report;
}

// MARK: - Installation

static BOOL hook(Class cls, SEL selector, IMP replacement, IMP *previous, const char *result, NSArray<NSString *> *arguments) {
    return mulg_swizzle_checked_owned("graphics", cls, selector, replacement, previous, result, arguments) == MulgSwizzleResultReplaced;
}

static char kBufferDiscovery, kDrawableDiscovery, kQueueDiscovery, kQueue4Discovery, kDeviceDiscovery;

static MulgGraphicsHook install_buffer(Class cls) {
    if (!cls) return 0;
    NSNumber *known = objc_getAssociatedObject(cls, &kBufferDiscovery);
    if (known) return (MulgGraphicsHook)known.unsignedIntValue;
    @synchronized (mulg_lock(cls)) {
        NSNumber *known = objc_getAssociatedObject(cls, &kBufferDiscovery);
        if (known) return (MulgGraphicsHook)known.unsignedIntValue;
        MulgGraphicsHook installed = 0;
        BOOL plain = hook(cls, @selector(presentDrawable:), (IMP)mulg_buffer_present, NULL, @encode(void), @[@(@encode(id))]);
        BOOL timed = hook(cls, @selector(presentDrawable:atTime:), (IMP)mulg_buffer_present_at_time, NULL, @encode(void), @[@(@encode(id)), @(@encode(CFTimeInterval))]);
        BOOL duration = hook(cls, @selector(presentDrawable:afterMinimumDuration:), (IMP)mulg_buffer_present_after_duration, NULL, @encode(void), @[@(@encode(id)), @(@encode(CFTimeInterval))]);
        if (plain && timed && duration) installed |= MulgGraphicsHookCommandBufferPresent;
        if (hook(cls, @selector(commit), (IMP)mulg_buffer_commit, NULL, @encode(void), @[])) installed |= MulgGraphicsHookCommandBufferCommit;
        if (atomic_load(&graphics_diagnostics_enabled) &&
            hook(cls, @selector(renderCommandEncoderWithDescriptor:), (IMP)mulg_render_encoder, NULL, @encode(id), @[@(@encode(id))]))
            installed |= MulgGraphicsHookRenderPassSizes;
        objc_setAssociatedObject(cls, &kBufferDiscovery, @(installed), OBJC_ASSOCIATION_RETAIN);
        uintptr_t unknown = 0;
        atomic_compare_exchange_strong(&mulg_buffer_class_address, &unknown, (uintptr_t)(__bridge void *)cls);
        return installed;
    }
}

void mulg_graphics_set_diagnostics_enabled(BOOL enabled) {
    if (atomic_exchange(&graphics_diagnostics_enabled, enabled) == (bool)enabled || !enabled) return;
    Class cls = (__bridge Class)(void *)atomic_load(&mulg_buffer_class_address);
    if (!cls) return; // Normal command-buffer discovery installs it later.
    @synchronized (mulg_lock(cls)) {
        MulgGraphicsHook installed = (MulgGraphicsHook)[objc_getAssociatedObject(cls, &kBufferDiscovery) unsignedIntValue];
        if (!(installed & MulgGraphicsHookRenderPassSizes) &&
            hook(cls, @selector(renderCommandEncoderWithDescriptor:), (IMP)mulg_render_encoder, NULL, @encode(id), @[@(@encode(id))])) {
            installed |= MulgGraphicsHookRenderPassSizes;
            objc_setAssociatedObject(cls, &kBufferDiscovery, @(installed), OBJC_ASSOCIATION_RETAIN);
        }
    }
}

static MulgGraphicsHook install_drawable(Class cls) {
    if (!cls) return 0;
    NSNumber *known = objc_getAssociatedObject(cls, &kDrawableDiscovery);
    if (known) return (MulgGraphicsHook)known.unsignedIntValue;
    @synchronized (mulg_lock(cls)) {
        known = objc_getAssociatedObject(cls, &kDrawableDiscovery);
        if (known) return (MulgGraphicsHook)known.unsignedIntValue;
        MulgGraphicsHook installed = 0;
        BOOL plain = hook(cls, @selector(present), (IMP)mulg_drawable_present, NULL, @encode(void), @[]);
        BOOL timed = hook(cls, @selector(presentAtTime:), (IMP)mulg_drawable_present_at_time, NULL, @encode(void), @[@(@encode(CFTimeInterval))]);
        BOOL duration = hook(cls, @selector(presentAfterMinimumDuration:), (IMP)mulg_drawable_present_after_duration, NULL, @encode(void), @[@(@encode(CFTimeInterval))]);
        if (plain && timed && duration) installed |= MulgGraphicsHookDrawablePresent;
        BOOL handlers = hook(cls, @selector(addPresentedHandler:), (IMP)mulg_add_presented_handler, NULL, @encode(void), @[@"@?"]);
        BOOL time = hook(cls, @selector(presentedTime), (IMP)mulg_presented_time, NULL, @encode(CFTimeInterval), @[]);
        if (handlers && time) installed |= MulgGraphicsHookDrawablePresentedHandlers;
        if (hook(cls, @selector(layer), (IMP)mulg_drawable_layer, NULL, @encode(id), @[])) installed |= MulgGraphicsHookDrawableLayer;
        objc_setAssociatedObject(cls, &kDrawableDiscovery, @(installed), OBJC_ASSOCIATION_RETAIN);
        uintptr_t unknown = 0;
        atomic_compare_exchange_strong(&mulg_drawable_class_address, &unknown, (uintptr_t)(__bridge void *)cls);
        return installed;
    }
}

static MulgGraphicsHook install_queue4(Class cls) {
    if (!cls) return 0;
    NSNumber *known = objc_getAssociatedObject(cls, &kQueue4Discovery);
    if (known) return (MulgGraphicsHook)known.unsignedIntValue;
    @synchronized (mulg_lock(cls)) {
    known = objc_getAssociatedObject(cls, &kQueue4Discovery);
    if (known) return (MulgGraphicsHook)known.unsignedIntValue;
    BOOL wait = hook(cls, @selector(waitForDrawable:), (IMP)mulg_queue_wait_drawable, NULL, @encode(void), @[@(@encode(id))]);
    BOOL signal = hook(cls, @selector(signalDrawable:), (IMP)mulg_queue_signal_drawable, NULL, @encode(void), @[@(@encode(id))]);
    MulgGraphicsHook installed = wait && signal ? MulgGraphicsHookMetal4Present : 0;
    objc_setAssociatedObject(cls, &kQueue4Discovery, @(installed), OBJC_ASSOCIATION_RETAIN);
    uintptr_t unknown = 0;
    atomic_compare_exchange_strong(&mulg_queue4_class_address, &unknown, (uintptr_t)(__bridge void *)cls);
    return installed;
    }
}

static id mulg_new_buffer(id self, SEL selector) {
    id buffer = ((Getter)ORIGINAL(self, selector, mulg_new_buffer))(self, selector);
    install_buffer(object_getClass(buffer));
    return buffer;
}

static id mulg_new_buffer_descriptor(id self, SEL selector, id descriptor) {
    id buffer = ((DescriptorFactory)ORIGINAL(self, selector, mulg_new_buffer_descriptor))(self, selector, descriptor);
    install_buffer(object_getClass(buffer));
    return buffer;
}

static id discover_queue(id queue) {
    if (!queue) return nil;
    Class cls = object_getClass(queue);
    @synchronized (mulg_lock(cls)) {
        if (objc_getAssociatedObject(cls, &kQueueDiscovery)) return queue;
        if ([queue respondsToSelector:@selector(commandBuffer)]) {
            for (NSString *name in @[@"commandBuffer", @"commandBufferWithUnretainedReferences"]) {
                mulg_swizzle_checked_owned("graphics", cls, NSSelectorFromString(name), (IMP)mulg_new_buffer, NULL, @encode(id), @[]);
            }
            mulg_swizzle_checked_owned("graphics", cls, @selector(commandBufferWithDescriptor:),
                                      (IMP)mulg_new_buffer_descriptor, NULL, @encode(id), @[@(@encode(id))]);
        }
        if ([queue respondsToSelector:@selector(signalDrawable:)]) install_queue4(cls);
        objc_setAssociatedObject(cls, &kQueueDiscovery, @YES, OBJC_ASSOCIATION_RETAIN);
    }
    return queue;
}

typedef id (*NewQueue)(id, SEL) __attribute__((ns_returns_retained));
typedef id (*NewQueueCount)(id, SEL, NSUInteger) __attribute__((ns_returns_retained));
typedef id (*NewQueueDescriptor)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));

static id __attribute__((ns_returns_retained)) mulg_new_queue(id self, SEL selector) {
    return discover_queue(((NewQueue)ORIGINAL(self, selector, mulg_new_queue))(self, selector));
}

static id __attribute__((ns_returns_retained)) mulg_new_queue_count(id self, SEL selector, NSUInteger count) {
    return discover_queue(((NewQueueCount)ORIGINAL(self, selector, mulg_new_queue_count))(self, selector, count));
}

static id __attribute__((ns_returns_retained)) mulg_new_queue_descriptor(id self, SEL selector, id descriptor, NSError **error) {
    return discover_queue(((NewQueueDescriptor)ORIGINAL(self, selector, mulg_new_queue_descriptor))(self, selector, descriptor, error));
}

static void install_device(Class cls) {
    if (!cls) return;
    install_shader_device(cls);
    install_shader4_device(cls);
    if (!cls || objc_getAssociatedObject(cls, &kDeviceDiscovery)) return;
    @synchronized (mulg_lock(cls)) {
        if (objc_getAssociatedObject(cls, &kDeviceDiscovery)) return;
        for (NSString *name in @[@"newCommandQueue", @"newMTL4CommandQueue"]) {
            mulg_swizzle_checked_owned("graphics", cls, NSSelectorFromString(name), (IMP)mulg_new_queue, NULL, @encode(id), @[]);
        }
        mulg_swizzle_checked_owned("graphics", cls, @selector(newCommandQueueWithMaxCommandBufferCount:),
                                  (IMP)mulg_new_queue_count, NULL, @encode(id), @[@(@encode(NSUInteger))]);
        mulg_swizzle_checked_owned("graphics", cls, @selector(newMTL4CommandQueueWithDescriptor:error:),
                                  (IMP)mulg_new_queue_descriptor, NULL, @encode(id), @[@(@encode(id)), @(@encode(NSError *__autoreleasing *))]);
        objc_setAssociatedObject(cls, &kDeviceDiscovery, @YES, OBJC_ASSOCIATION_RETAIN);
    }
}

static void install_scene_trace(Class cls) {
    static char key;
    if (!cls || !atomic_load_explicit(&scene_trace_enabled, memory_order_relaxed) || objc_getAssociatedObject(cls, &key)) return;
    @synchronized (mulg_lock(cls)) {
        if (objc_getAssociatedObject(cls, &key)) return;
        hook(cls, @selector(newTextureWithDescriptor:), (IMP)mulg_new_scene_texture, NULL, @encode(id), @[@(@encode(id))]);
        objc_setAssociatedObject(cls, &key, @YES, OBJC_ASSOCIATION_RETAIN);
    }
}

/// Called only when the game requests a drawable on its actual device. Startup installation
/// must not create a Metal device or queue while sibling SDKs are still initializing in dyld.
/// Seed the concrete queue/buffer classes before returning that first drawable, covering queues
/// and buffers the game created earlier as well as future factories. No drawable is acquired here.
static void discover_presentation_device(id<MTLDevice> device) {
    if (!device) return;
    __unsafe_unretained Class cls = object_getClass(device);
    install_device(cls);
    install_scene_trace(cls);
    static char seeded;
    if (objc_getAssociatedObject(device, &seeded)) return;
    @synchronized (mulg_lock(device)) {
        if (objc_getAssociatedObject(device, &seeded)) return;
        // Publish before calling factories: native implementations can reenter graphics hooks.
        objc_setAssociatedObject(device, &seeded, @YES, OBJC_ASSOCIATION_RETAIN);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        discover_queue(queue);
        install_buffer(object_getClass([queue commandBuffer]));
        id<MTL4CommandQueue> queue4 = [device newMTL4CommandQueue];
        discover_queue(queue4);
        if (!queue && !queue4) objc_setAssociatedObject(device, &seeded, nil, OBJC_ASSOCIATION_RETAIN);
    }
}

/// An archive read from `url`, or an empty one when `url` is nil.
static id<MTLBinaryArchive> open_archive(id<MTLDevice> device, NSURL *url) {
    MTLBinaryArchiveDescriptor *descriptor = [MTLBinaryArchiveDescriptor new];
    descriptor.url = url;
    NSError *error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:descriptor error:&error];
    if (archive == nil) os_log_error(OS_LOG_DEFAULT, "Mulg shader archive creation failed: %{public}@", error);
    return archive;
}

BOOL mulg_graphics_start_shader_archive(NSURL *url) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil || shader_record != nil || atomic_load(&shader_capture_suspended)) {
        return NO;
    }
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:url.path];
    if (exists && archive_file_size(url) > MulgGraphicsShaderArchiveLimit / 2) {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
        exists = NO;
    }
    shader_lookup = exists ? open_archive(device, url) : nil;
    if (exists && shader_lookup == nil) {
        // Damaged or from another Metal version: start again.
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    }
    shader_record = open_archive(device, shader_lookup != nil ? url : nil);
    if (shader_record == nil) {
        shader_lookup = nil;
        return NO;
    }
    shader_archive_url = url;
    shader_queue = shader_archive_queue("mulg.graphics.shader-archive");
    dispatch_queue_set_specific(shader_queue, &shader_queue_key, &shader_queue_key, NULL);
    shader_save_timer = archive_save_timer(shader_queue, &shader_save_scheduled, ^{
        if (shader_generation != shader_saved_generation) save_shader_archive();
    });
    atexit(save_shader_archive_at_exit);

    Class cls = [device class];
    mulg_device_class_name = NSStringFromClass(cls);
    // Metal 4 compilers: mulg_graphics_start_metal4_shader_archive.
    options_selectors[PipelineRender] = @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:);
    options_selectors[PipelineCompute] = @selector(newComputePipelineStateWithDescriptor:options:reflection:error:);
    options_selectors[PipelineMesh] = @selector(newRenderPipelineStateWithMeshDescriptor:options:reflection:error:);
    options_selectors[PipelineTile] = @selector(newRenderPipelineStateWithTileDescriptor:options:reflection:error:);
    options_async_selectors[PipelineRender] = @selector(newRenderPipelineStateWithDescriptor:options:completionHandler:);
    options_async_selectors[PipelineCompute] = @selector(newComputePipelineStateWithDescriptor:options:completionHandler:);
    options_async_selectors[PipelineMesh] = @selector(newRenderPipelineStateWithMeshDescriptor:options:completionHandler:);
    options_async_selectors[PipelineTile] = @selector(newRenderPipelineStateWithTileDescriptor:options:completionHandler:);
    atomic_store(&shader_ready, true);
    return install_shader_device(cls);
}

static BOOL install_shader_device(Class cls) {
    static char key;
    if (!cls || !atomic_load(&shader_ready)) return NO;
    @synchronized (mulg_lock(cls)) {
        NSNumber *known = objc_getAssociatedObject(cls, &key);
        if (known) return known.boolValue;
        BOOL all = mulg_swizzle_checked_owned("graphics", cls, @selector(newRenderPipelineStateWithDescriptor:error:),
            (IMP)mulg_render_pipeline, NULL, @encode(id), @[@(@encode(id)), @(@encode(NSError *__autoreleasing *))]) == MulgSwizzleResultReplaced;
        all &= mulg_swizzle_checked_owned("graphics", cls, @selector(newRenderPipelineStateWithDescriptor:completionHandler:),
            (IMP)mulg_render_pipeline_async, NULL, @encode(void), @[@(@encode(id)), @"@?"]) == MulgSwizzleResultReplaced;
        for (int kind = 0; kind < PipelineKinds; kind++) {
            all &= mulg_swizzle_checked_owned("graphics", cls, options_selectors[kind], (IMP)mulg_pipeline_options, NULL,
                @encode(id), @[@(@encode(id)), @(@encode(MTLPipelineOption)), @(@encode(id __autoreleasing *)), @(@encode(NSError *__autoreleasing *))]) == MulgSwizzleResultReplaced;
            all &= mulg_swizzle_checked_owned("graphics", cls, options_async_selectors[kind], (IMP)mulg_pipeline_options_async, NULL,
                @encode(void), @[@(@encode(id)), @(@encode(MTLPipelineOption)), @"@?"]) == MulgSwizzleResultReplaced;
        }
        all &= hook(cls, @selector(newComputePipelineStateWithFunction:error:), (IMP)mulg_compute_function, NULL,
                    @encode(id), @[@(@encode(id)), @(@encode(NSError *__autoreleasing *))]);
        all &= hook(cls, @selector(newComputePipelineStateWithFunction:options:reflection:error:), (IMP)mulg_compute_function_options, NULL,
                    @encode(id), @[@(@encode(id)), @(@encode(MTLPipelineOption)), @(@encode(id __autoreleasing *)), @(@encode(NSError *__autoreleasing *))]);
        all &= hook(cls, @selector(newComputePipelineStateWithFunction:completionHandler:), (IMP)mulg_compute_function_async, NULL,
                    @encode(void), @[@(@encode(id)), @"@?"]);
        all &= hook(cls, @selector(newComputePipelineStateWithFunction:options:completionHandler:), (IMP)mulg_compute_function_options_async, NULL,
                    @encode(void), @[@(@encode(id)), @(@encode(MTLPipelineOption)), @"@?"]);
        objc_setAssociatedObject(cls, &key, @(all), OBJC_ASSOCIATION_RETAIN);
        return all;
    }
}

NSString *mulg_graphics_device_class_name(void) {
    return mulg_device_class_name;
}

// MARK: - Metal 4 shader archive (§5.6)

// Metal 4 games build pipelines with an MTL4Compiler. Every compiler the game makes gets a
// serializer that captures the compiled binaries, and every pipeline it builds also looks in the
// archive saved by the previous launch.

typedef id (*NewCompiler)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));
typedef id (*NewPipeline4)(id, SEL, id, id, NSError **) __attribute__((ns_returns_retained));
typedef id (*NewLinkedPipeline4)(id, SEL, id, id, id, NSError **) __attribute__((ns_returns_retained));
typedef id (*NewPipeline4Async)(id, SEL, id, id, id) __attribute__((ns_returns_retained));
typedef id (*NewLinkedPipeline4Async)(id, SEL, id, id, id, id) __attribute__((ns_returns_retained));

/// The compiler's render and compute builds, with and without dynamic linking, synchronous and
/// with a completion handler. Each hook finds its previous implementation by selector.
enum { kCompilerBuilds = 8 };

/// Set once before the hooks go in, never changed afterwards.
static id<MTLDevice> shader4_device;
/// Archives saved by recent launches, all looked up.
static NSArray<id<MTL4Archive>> *shader4_lookups;
static id<MTL4PipelineDataSetSerializer> shader4_serializer;
/// Archive files are `<shader4_url>.<n>`; the next save writes number `shader4_next`.
static NSURL *shader4_url;
static long shader4_next;  // on shader4_queue only
static dispatch_queue_t shader4_queue;
static dispatch_source_t shader4_save_timer;
static BOOL shader4_save_scheduled;
static NSMutableArray<NSURL *> *shader4_session_files; // On shader4_queue only; never used for lookup.
static uint64_t shader4_lookup_bytes;
static uint64_t shader4_generation;  // on shader4_queue only
static uint64_t shader4_saved_generation;  // on shader4_queue only
static uint64_t shader4_partial_generation;
static _Atomic(bool) shader4_ready;

// No API merges archives, a launch may not capture pipelines it found in an older archive, and a
// save flushes the serializer (…AndFlushToURL:), so a second save holds only what came after the
// first. So every save writes a new numbered file, never over an earlier one, and the newest
// files are all looked up. Older ones are deleted at launch; their pipelines are captured again
// the next time they are built.
static const int kMetal4ArchivesKept = 8;
static const int kMetal4LookupArchives = 4;

static void prune_metal4_session_archives(void) {
    uint64_t size = shader4_lookup_bytes;
    for (NSURL *file in shader4_session_files) size += archive_file_size(file);
    while (shader4_session_files.count > 0 &&
           (shader4_session_files.count + shader4_lookups.count > kMetal4ArchivesKept ||
            size > MulgGraphicsShaderArchiveLimit / 2)) {
        NSURL *oldest = shader4_session_files.firstObject;
        uint64_t bytes = archive_file_size(oldest);
        if ([NSFileManager.defaultManager fileExistsAtPath:oldest.path] &&
            ![NSFileManager.defaultManager removeItemAtURL:oldest error:NULL]) {
            schedule_archive_save(shader4_save_timer, &shader4_save_scheduled);
            break;
        }
        [shader4_session_files removeObjectAtIndex:0];
        size -= bytes;
    }
}

static void save_metal4_archive(void) {
    NSURL *file = [shader4_url URLByAppendingPathExtension:[NSString stringWithFormat:@"%ld", shader4_next]];
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    // A successful serialization flushes the serializer. Retain that file across rename failures.
    NSError *error = nil;
    if (shader4_partial_generation != 0 || [shader4_serializer serializeAsArchiveAndFlushToURL:partial error:&error]) {
        if (shader4_partial_generation == 0) shader4_partial_generation = shader4_generation;
        if (rename(partial.fileSystemRepresentation, file.fileSystemRepresentation) == 0) {
            shader4_saved_generation = shader4_partial_generation;
            shader4_partial_generation = 0;
            shader4_next++;
            [shader4_session_files addObject:file];
            prune_metal4_session_archives();
        } else {
            os_log_error(OS_LOG_DEFAULT, "Mulg Metal 4 archive replacement failed: %{public}d", errno);
        }
    } else {
        os_log_error(OS_LOG_DEFAULT, "Mulg Metal 4 archive serialization failed: %{public}@", error);
        [NSFileManager.defaultManager removeItemAtURL:partial error:NULL];
    }
    if (shader4_saved_generation != shader4_generation) schedule_archive_save(shader4_save_timer, &shader4_save_scheduled);
}

static char shader4_queue_key;

static void save_metal4_archive_at_exit(void) {
    if (!shader4_queue) return;
    dispatch_block_t save = ^{
        if (shader4_generation != shader4_saved_generation) {
            save_metal4_archive();
        }
    };
    // As for Metal 3: an exit from this very queue must not sync to itself (dispatch traps).
    if (dispatch_get_specific(&shader4_queue_key)) save();
    else dispatch_sync(shader4_queue, save);
}

static char kCompilerCaptures;
static os_unfair_lock shader4_note_lock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *shader4_noted_pipelines;
static uint64_t shader4_pending_notes;
static BOOL shader4_note_queued;

static void drain_metal4_notes(void) {
    os_unfair_lock_lock(&shader4_note_lock);
    uint64_t count = shader4_pending_notes;
    shader4_pending_notes = 0;
    shader4_note_queued = NO;
    os_unfair_lock_unlock(&shader4_note_lock);
    shader4_generation += count;
    if (count) schedule_archive_save(shader4_save_timer, &shader4_save_scheduled);
}
static void note_metal4_pipeline(id compiler, id pipeline) {
    if (![objc_getAssociatedObject(compiler, &kCompilerCaptures) boolValue]) return;
    os_unfair_lock_lock(&shader4_note_lock);
    if (!shader4_noted_pipelines) shader4_noted_pipelines = [NSHashTable
        hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    if ([shader4_noted_pipelines containsObject:pipeline]) {
        os_unfair_lock_unlock(&shader4_note_lock); return;
    }
    [shader4_noted_pipelines addObject:pipeline];
    ++shader4_pending_notes;
    BOOL enqueue = !shader4_note_queued;
    shader4_note_queued = YES;
    os_unfair_lock_unlock(&shader4_note_lock);
    if (enqueue) dispatch_async(shader4_queue, ^{ drain_metal4_notes(); });
}

/// The game's options plus the lookup archives, as a copy so the game's options are never changed.
static MTL4CompilerTaskOptions *with_lookup(id<MTL4Compiler> compiler, MTL4CompilerTaskOptions *options) {
    if (shader4_lookups.count == 0 || compiler.device != shader4_device) {
        return options;
    }
    NSArray *existing = options.lookupArchives ?: @[];
    NSMutableArray *combined = nil;
    for (id archive in shader4_lookups) {
        // Once copied, combined already contains every existing archive. Searching
        // both lists would scan the same prefix twice for each new lookup archive.
        if ([(combined ?: existing) containsObject:archive]) continue;
        if (!combined) combined = [existing mutableCopy];
        [combined addObject:archive];
    }
    // With no actual addition, preserve the original options identity. Callers
    // then avoid retry snapshots and never remove a game-owned archive on error.
    if (!combined) return options;
    MTL4CompilerTaskOptions *copy = options != nil ? [options copy] : [MTL4CompilerTaskOptions new];
    copy.lookupArchives = combined;
    return copy;
}

/// Render and compute completion handlers both take (pipeline, error). With `retry`, a failure
/// with Mulg's lookup archives attached is built again exactly as the game asked.
static id noting_metal4_pipeline_or_retry(id compiler, void (^handler)(id, NSError *), void (^retry)(void)) {
    if (handler == nil) return nil;
    return ^(id pipeline, NSError *error) {
        if (pipeline == nil && retry != nil) {
            note_archive_fallback(error);
            retry();
            return;
        }
        if (pipeline != nil) note_metal4_pipeline(compiler, pipeline);
        handler(pipeline, error);
    };
}

static id noting_metal4_pipeline(id compiler, void (^handler)(id, NSError *)) {
    if (handler == nil) {
        return nil;
    }
    return ^(id pipeline, NSError *error) {
        if (pipeline != nil) {
            note_metal4_pipeline(compiler, pipeline);
        }
        handler(pipeline, error);
    };
}

static id __attribute__((ns_returns_retained)) mulg_compiler_build(id self, SEL _cmd, id descriptor, id options, NSError **error) {
    NewPipeline4 original = (NewPipeline4)ORIGINAL(self, _cmd, mulg_compiler_build);
    id lookup = with_lookup(self, options);
    id pipeline = original(self, _cmd, descriptor, lookup, error);
    if (pipeline == nil && lookup != options) {
        note_archive_fallback(error ? *error : nil);
        pipeline = original(self, _cmd, descriptor, options, error);
    }
    if (pipeline != nil) {
        note_metal4_pipeline(self, pipeline);
    }
    return pipeline;
}

static id __attribute__((ns_returns_retained)) mulg_compiler_linked_build(id self, SEL _cmd, id descriptor, id linking, id options, NSError **error) {
    NewLinkedPipeline4 original = (NewLinkedPipeline4)ORIGINAL(self, _cmd, mulg_compiler_linked_build);
    id lookup = with_lookup(self, options);
    id pipeline = original(self, _cmd, descriptor, linking, lookup, error);
    if (pipeline == nil && lookup != options) {
        note_archive_fallback(error ? *error : nil);
        pipeline = original(self, _cmd, descriptor, linking, options, error);
    }
    if (pipeline != nil) {
        note_metal4_pipeline(self, pipeline);
    }
    return pipeline;
}

static id __attribute__((ns_returns_retained)) mulg_compiler_build_async(id self, SEL _cmd, id descriptor, id options, void (^handler)(id, NSError *)) {
    NewPipeline4Async original = (NewPipeline4Async)ORIGINAL(self, _cmd, mulg_compiler_build_async);
    id lookup = with_lookup(self, options);
    // Lookup still applies without a callback, but no callback can request a
    // retry. Avoid snapshots that can never be consumed in that case.
    BOOL canRetry = handler != nil && lookup != options;
    id retryDescriptor = canRetry ? [descriptor copy] : nil;
    id retryOptions = canRetry ? [options copy] : nil;
    void (^retry)(void) = !canRetry ? nil : ^{
        (void)original(self, _cmd, retryDescriptor, retryOptions, noting_metal4_pipeline(self, handler));
    };
    return original(self, _cmd, descriptor, lookup, noting_metal4_pipeline_or_retry(self, handler, retry));
}

static id __attribute__((ns_returns_retained)) mulg_compiler_linked_build_async(id self, SEL _cmd, id descriptor, id linking, id options,
                                           void (^handler)(id, NSError *)) {
    NewLinkedPipeline4Async original = (NewLinkedPipeline4Async)ORIGINAL(self, _cmd, mulg_compiler_linked_build_async);
    id lookup = with_lookup(self, options);
    BOOL canRetry = handler != nil && lookup != options;
    id retryDescriptor = canRetry ? [descriptor copy] : nil;
    id retryLinking = canRetry ? [linking copy] : nil;
    id retryOptions = canRetry ? [options copy] : nil;
    void (^retry)(void) = !canRetry ? nil : ^{
        (void)original(self, _cmd, retryDescriptor, retryLinking, retryOptions, noting_metal4_pipeline(self, handler));
    };
    return original(self, _cmd, descriptor, linking, lookup, noting_metal4_pipeline_or_retry(self, handler, retry));
}

static id __attribute__((ns_returns_retained)) mulg_compiler_specialize(id self, SEL selector, id descriptor, id pipeline, NSError **error) {
    id result = ((NewPipeline4)ORIGINAL(self, selector, mulg_compiler_specialize))(self, selector, descriptor, pipeline, error);
    if (result) note_metal4_pipeline(self, result);
    return result;
}

static id __attribute__((ns_returns_retained)) mulg_compiler_specialize_async(id self, SEL selector, id descriptor, id pipeline,
                                                                         void (^handler)(id, NSError *)) {
    return ((NewPipeline4Async)ORIGINAL(self, selector, mulg_compiler_specialize_async))
        (self, selector, descriptor, pipeline, noting_metal4_pipeline(self, handler));
}

static id __attribute__((ns_returns_retained)) mulg_new_compiler(id self, SEL _cmd, MTL4CompilerDescriptor *descriptor, NSError **error) {
    MTL4CompilerDescriptor *copy = descriptor;
    if (self == shader4_device && descriptor.pipelineDataSetSerializer == nil) {
        copy = descriptor != nil ? [descriptor copy] : [MTL4CompilerDescriptor new];
        copy.pipelineDataSetSerializer = shader4_serializer;
    }
    NewCompiler original = (NewCompiler)ORIGINAL(self, _cmd, mulg_new_compiler);
    id compiler = original(self, _cmd, copy, error);
    if (compiler == nil && copy != descriptor) {
        // Mulg's pipeline recorder is optional: a compiler Metal refuses with it is made as asked.
        note_archive_fallback(error ? *error : nil);
        copy = descriptor;
        compiler = original(self, _cmd, descriptor, error);
    }
    if (compiler != nil) {
        objc_setAssociatedObject(compiler, &kCompilerCaptures,
            @(shader4_serializer != nil && copy.pipelineDataSetSerializer == shader4_serializer), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The concrete compiler class is only known once the game makes one.
        static char key;
        Class cls = object_getClass(compiler);
        @synchronized (mulg_lock(cls)) {
            if (objc_getAssociatedObject(cls, &key)) return compiler;
            const struct { SEL selector; IMP replacement; } builds[kCompilerBuilds] = {
                { @selector(newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:), (IMP)mulg_compiler_build },
                { @selector(newComputePipelineStateWithDescriptor:compilerTaskOptions:error:), (IMP)mulg_compiler_build },
                { @selector(newRenderPipelineStateWithDescriptor:dynamicLinkingDescriptor:compilerTaskOptions:error:),
                  (IMP)mulg_compiler_linked_build },
                { @selector(newComputePipelineStateWithDescriptor:dynamicLinkingDescriptor:compilerTaskOptions:error:),
                  (IMP)mulg_compiler_linked_build },
                { @selector(newRenderPipelineStateWithDescriptor:compilerTaskOptions:completionHandler:),
                  (IMP)mulg_compiler_build_async },
                { @selector(newComputePipelineStateWithDescriptor:compilerTaskOptions:completionHandler:),
                  (IMP)mulg_compiler_build_async },
                { @selector(newRenderPipelineStateWithDescriptor:dynamicLinkingDescriptor:compilerTaskOptions:completionHandler:),
                  (IMP)mulg_compiler_linked_build_async },
                { @selector(newComputePipelineStateWithDescriptor:dynamicLinkingDescriptor:compilerTaskOptions:completionHandler:),
                  (IMP)mulg_compiler_linked_build_async },
            };
            for (int i = 0; i < kCompilerBuilds; i++) {
                BOOL linked = i == 2 || i == 3 || i == 6 || i == 7;
                BOOL async = i >= 4;
                NSMutableArray *arguments = [@[@(@encode(id))] mutableCopy];
                if (linked) [arguments addObject:@(@encode(id))];
                [arguments addObject:@(@encode(id))];
                [arguments addObject:async ? @"@?" : @(@encode(NSError *__autoreleasing *))];
                mulg_swizzle_checked_owned("graphics", cls, builds[i].selector, builds[i].replacement, NULL, @encode(id), arguments);
            }
            hook(cls, @selector(newRenderPipelineStateBySpecializationWithDescriptor:pipeline:error:),
                 (IMP)mulg_compiler_specialize, NULL, @encode(id),
                 @[@(@encode(id)), @(@encode(id)), @(@encode(NSError *__autoreleasing *))]);
            hook(cls, @selector(newRenderPipelineStateBySpecializationWithDescriptor:pipeline:completionHandler:),
                 (IMP)mulg_compiler_specialize_async, NULL, @encode(id), @[@(@encode(id)), @(@encode(id)), @"@?"]);
            objc_setAssociatedObject(cls, &key, @YES, OBJC_ASSOCIATION_RETAIN);
        }
    }
    return compiler;
}

BOOL mulg_graphics_start_metal4_shader_archive(NSURL *url) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil || shader4_serializer != nil) {
        return NO;
    }
    MTL4PipelineDataSetSerializerDescriptor *descriptor = [MTL4PipelineDataSetSerializerDescriptor new];
    descriptor.configuration = MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
    id<MTL4PipelineDataSetSerializer> serializer = [device newPipelineDataSetSerializerWithDescriptor:descriptor];
    if (serializer == nil) {
        return NO;
    }
    // The numbers of this build's saved archives, oldest first. Saves cut off by a crash are deleted.
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *prefix = [url.lastPathComponent stringByAppendingString:@"."];
    NSCharacterSet *notDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
    for (NSString *name in [files contentsOfDirectoryAtPath:url.URLByDeletingLastPathComponent.path error:NULL]) {
        NSString *suffix = [name hasPrefix:prefix] ? [name substringFromIndex:prefix.length] : @"";
        if (suffix.length > 0 && suffix.length < 12 && [suffix rangeOfCharacterFromSet:notDigits].location == NSNotFound) {
            [numbers addObject:@(suffix.longLongValue)];
        } else if ([suffix hasSuffix:@".partial"]) {
            [files removeItemAtPath:[url.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:name] error:NULL];
        }
    }
    [numbers sortUsingSelector:@selector(compare:)];
    NSMutableArray<id<MTL4Archive>> *lookups = [NSMutableArray array];
    for (NSNumber *number in numbers.reverseObjectEnumerator) {
        NSURL *file = [url URLByAppendingPathExtension:number.stringValue];
        uint64_t bytes = archive_file_size(file);
        // Leave slots and bytes for this session without deleting a live lookup later.
        id<MTL4Archive> archive = lookups.count < kMetal4LookupArchives &&
            shader4_lookup_bytes + bytes <= MulgGraphicsShaderArchiveLimit / 4
            ? [device newArchiveWithURL:file error:NULL] : nil;
        if (archive != nil) {
            [lookups addObject:archive];
            shader4_lookup_bytes += bytes;
        } else {
            [files removeItemAtURL:file error:NULL];
        }
    }
    shader4_url = url;
    shader4_next = numbers.count > 0 ? numbers.lastObject.longValue + 1 : 0;
    shader4_lookups = lookups;
    shader4_device = device;
    shader4_serializer = serializer;
    shader4_session_files = [NSMutableArray new];
    shader4_queue = shader_archive_queue("mulg.graphics.metal4-shader-archive");
    dispatch_queue_set_specific(shader4_queue, &shader4_queue_key, &shader4_queue_key, NULL);
    shader4_save_timer = archive_save_timer(shader4_queue, &shader4_save_scheduled, ^{
        if (shader4_generation != shader4_saved_generation) save_metal4_archive();
        prune_metal4_session_archives();
    });
    atexit(save_metal4_archive_at_exit);
    atomic_store(&shader4_ready, true);
    return install_shader4_device(object_getClass(device));
}

void mulg_graphics_save_shader_archives(void) {
    if (shader_queue) dispatch_async(shader_queue, ^{
        if (!atomic_load(&shader_capture_suspended) && shader_generation != shader_saved_generation) save_shader_archive();
    });
    if (shader4_queue) dispatch_async(shader4_queue, ^{
        if (shader4_generation != shader4_saved_generation) save_metal4_archive();
    });
}

void mulg_graphics_purge_shader_cache(void) {
    if (shader_queue) dispatch_async(shader_queue, ^{
        if (shader_generation != shader_saved_generation) save_shader_archive();
        if (shader_generation == shader_saved_generation && shader_record) reset_shader_record();
    });
    if (shader4_queue) dispatch_async(shader4_queue, ^{
        if (shader4_generation != shader4_saved_generation) save_metal4_archive();
        prune_metal4_session_archives();
    });
}

static BOOL install_shader4_device(Class cls) {
    static char key;
    if (!cls || !atomic_load(&shader4_ready)) return NO;
    @synchronized (mulg_lock(cls)) {
        NSNumber *known = objc_getAssociatedObject(cls, &key);
        if (known) return known.boolValue;
        BOOL installed = mulg_swizzle_checked_owned("graphics", cls, @selector(newCompilerWithDescriptor:error:),
            (IMP)mulg_new_compiler, NULL, @encode(id), @[@(@encode(id)), @(@encode(NSError *__autoreleasing *))]) == MulgSwizzleResultReplaced;
        objc_setAssociatedObject(cls, &key, @(installed), OBJC_ASSOCIATION_RETAIN);
        return installed;
    }
}

static BOOL hook_fx(const char *className, NSString *selectorName, IMP replacement, IMP *previous) {
    __unsafe_unretained Class cls = objc_lookUpClass(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (cls == Nil || class_getInstanceMethod(cls, selector) == NULL) {
        return NO;
    }
    return hook(cls, selector, replacement, previous, @encode(id),
        [selectorName hasSuffix:@"compiler:"] ? @[@(@encode(id)), @(@encode(id))] : @[@(@encode(id))]);
}

MulgGraphicsHook mulg_graphics_install_hooks(MulgGraphicsHook *attempted) {
    return mulg_graphics_install_presentation_hooks(YES, attempted);
}

MulgGraphicsHook mulg_graphics_install_presentation_hooks(BOOL experimental, MulgGraphicsHook *attempted) {
    MulgGraphicsHook installed = 0;
    MulgGraphicsHook tried = 0;
    // Metadata lookup sends no +class/retain/instancesRespondToSelector: messages that
    // would initialize framework classes under dyld. Real game use owns initialization.
    __unsafe_unretained Class layerClass = objc_lookUpClass("CAMetalLayer");

    tried |= MulgGraphicsHookLayerDrawableSize | MulgGraphicsHookLayerNextDrawable;
    BOOL setter = hook(layerClass, @selector(setDrawableSize:), (IMP)mulg_set_drawable_size, &previous_set_drawable_size, @encode(void), @[@(@encode(CGSize))]);
    BOOL getter = hook(layerClass, @selector(drawableSize), (IMP)mulg_drawable_size, &previous_drawable_size, @encode(CGSize), @[]);
    if (setter && getter) {
        installed |= MulgGraphicsHookLayerDrawableSize;
    }
    __unsafe_unretained Class mtkView = objc_lookUpClass("MTKView");
    if (mtkView) {
        tried |= MulgGraphicsHookMetalKitDrawableSize;
        if (hook(mtkView, @selector(drawableSize), (IMP)mulg_mtk_drawable_size,
            &previous_mtk_drawable_size, @encode(CGSize), @[])) installed |= MulgGraphicsHookMetalKitDrawableSize;
    }
    tried |= MulgGraphicsHookViewContentScale;
    if (mulg_graphics_install_full_resolution_hook()) installed |= MulgGraphicsHookViewContentScale;
    if (objc_lookUpClass("DisplayConnection")) {
        tried |= MulgGraphicsHookUnityRenderingSize;
        if (mulg_graphics_install_unity_display_hook()) installed |= MulgGraphicsHookUnityRenderingSize;
    }
    if (hook(layerClass, @selector(nextDrawable), (IMP)mulg_next_drawable, &previous_next_drawable, @encode(id), @[])) {
        installed |= MulgGraphicsHookLayerNextDrawable;
    }

    if (experimental) {
    tried |= MulgGraphicsHookMetalFXDetection;
    BOOL spatial = hook_fx("MTLFXSpatialScalerDescriptor", @"newSpatialScalerWithDevice:",
                           (IMP)mulg_fx_spatial, &previous_fx_spatial);
    hook_fx("MTLFXTemporalScalerDescriptor", @"newTemporalScalerWithDevice:",
            (IMP)mulg_fx_temporal, &previous_fx_temporal);
    hook_fx("MTLFXFrameInterpolatorDescriptor", @"newFrameInterpolatorWithDevice:",
            (IMP)mulg_fx_interpolator, &previous_fx_interpolator);
    hook_fx("MTLFXTemporalDenoisedScalerDescriptor", @"newTemporalDenoisedScalerWithDevice:",
            (IMP)mulg_fx_denoised, &previous_fx_denoised);
    hook_fx("MTLFXSpatialScalerDescriptor", @"newSpatialScalerWithDevice:compiler:",
            (IMP)mulg_fx4_spatial, &previous_fx4_spatial);
    hook_fx("MTLFXTemporalScalerDescriptor", @"newTemporalScalerWithDevice:compiler:",
            (IMP)mulg_fx4_temporal, &previous_fx4_temporal);
    hook_fx("MTLFXFrameInterpolatorDescriptor", @"newFrameInterpolatorWithDevice:compiler:",
            (IMP)mulg_fx4_interpolator, &previous_fx4_interpolator);
    hook_fx("MTLFXTemporalDenoisedScalerDescriptor", @"newTemporalDenoisedScalerWithDevice:compiler:",
            (IMP)mulg_fx4_denoised, &previous_fx4_denoised);
    if (spatial) {
        installed |= MulgGraphicsHookMetalFXDetection;
    }
    }

    if (attempted != NULL) {
        *attempted = tried;
    }
    return installed;
}

NSString *mulg_graphics_command_buffer_class_name(void) {
    __unsafe_unretained Class cls = (__bridge Class)(void *)atomic_load(&mulg_buffer_class_address);
    return cls ? NSStringFromClass(cls) : @"?";
}

NSString *mulg_graphics_drawable_class_name(void) {
    Class cls = (__bridge Class)(void *)atomic_load(&mulg_drawable_class_address);
    return cls ? NSStringFromClass(cls) : @"?";
}

NSString *mulg_graphics_metal4_queue_class_name(void) {
    __unsafe_unretained Class cls = (__bridge Class)(void *)atomic_load(&mulg_queue4_class_address);
    return cls ? NSStringFromClass(cls) : @"?";
}

// MARK: - Forced resolution through the owning MetalKit view

BOOL mulg_graphics_forced_apply_main_layer(void) {
    NSCAssert(NSThread.isMainThread, @"Forced resolution changes require the main thread");
    CAMetalLayer *layer = mulg_candidate_layer;
    if (!layer || mulg_graphics_unity_resolution_active() || mulg_graphics_is_unity_engine()
        || address(layer) == atomic_load(&mulg_upscaled_address)) return NO;
    Class metalView = objc_lookUpClass("MTKView");
    id view = layer.delegate;
    // A raw CAMetalLayer setter cannot notify an unknown engine's render targets.
    // Its normal view-scale/layout path remains responsible for resolution changes.
    if (!metalView || ![view isKindOfClass:metalView] || [view layer] != layer) return NO;
    CGSize current = mulg_graphics_full_drawable_size(layer);
    NSValue *value = objc_getAssociatedObject(layer, &kGameRequestKey);
    CGSize game = current;
    if (value) [value getValue:&game size:sizeof(game)];
    CGSize wanted = game;
    if (mulg_graphics_forced_resolution_enabled()) {
        MulgForcedSize forced = mulg_graphics_forced_size((MulgForcedSize){ (int32_t)game.width, (int32_t)game.height },
                                                         mulg_graphics_forced_target());
        wanted = CGSizeMake(forced.width, forced.height);
    }
    if (wanted.width <= 0 || wanted.height <= 0 || CGSizeEqualToSize(wanted, current)) return NO;
    mulg_in_own_call++;
    @try {
        // MetalKit rebuilds its attachments and notifies its renderer together.
        ((SetSize)objc_msgSend)(view, @selector(setDrawableSize:), wanted);
    } @finally { mulg_in_own_call--; }
    return YES;
}
