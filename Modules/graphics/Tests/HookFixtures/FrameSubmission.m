#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <MulgEngineHooks.h>
#include <assert.h>
static int frameStarts;
static double appliedDelay;
void mulg_engine_set_frame_start_delay(double value) { appliedDelay = value; }
void mulg_engine_frame_presented(void) { frameStarts++; }
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) { mulg_engine_frame_presented(); }
static BOOL gameCaller = YES;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
#import <Metal/Metal.h>
#define MTLCopyAllDevices() @[]
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices

@interface AuditDrawable : NSObject
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic, strong) NSMutableArray *handlers;
@property(nonatomic) double presentedTime;
@property(nonatomic, strong) id texture;
@end
@implementation AuditDrawable
- (instancetype)init { if ((self = [super init])) _handlers = [NSMutableArray new]; return self; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { [self.handlers addObject:[handler copy]]; }
- (void)present {
    self.presentedTime = CACurrentMediaTime();
    NSArray *handlers = [self.handlers copy]; [self.handlers removeAllObjects];
    for (MTLDrawablePresentedHandler handler in handlers) handler((id)self);
}
- (void)presentAtTime:(double)time { [self present]; }
- (void)presentAfterMinimumDuration:(double)duration { [self present]; }
@end
static BOOL driverThread;
static double driverSpent;
static BOOL stallProbes;
static NSMutableArray *stalled;
@interface AuditBuffer : NSObject
@property(nonatomic, strong) id drawable;
@property(nonatomic, strong) NSMutableArray *drawables;
@property(nonatomic, strong) NSMutableArray *completions;
@property(nonatomic) SEL mode;
@property(nonatomic) double value;
@property(nonatomic) MTLCommandBufferStatus status;
@property(nonatomic) int commits;
@property(nonatomic) BOOL gameEncoded;
@property(nonatomic) double GPUEndTime;
@end
@implementation AuditBuffer
- (instancetype)init { if ((self = [super init])) { _drawables = [NSMutableArray new]; _completions = [NSMutableArray new]; } return self; }
- (void)presentDrawable:(id)drawable { self.drawable = drawable; [self.drawables addObject:drawable]; self.mode = _cmd; }
- (void)presentDrawable:(id)drawable atTime:(double)time { self.drawable = drawable; [self.drawables addObject:drawable]; self.mode = _cmd; self.value = time; }
- (void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration { self.drawable = drawable; [self.drawables addObject:drawable]; self.mode = _cmd; self.value = duration; }
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { [self.completions addObject:[handler copy]]; }
- (void)encodeWaitForEvent:(id)event value:(uint64_t)value {}
- (void)commit {
    self.commits++;
    if (stallProbes && self.drawables.count == 0) { [stalled addObject:self]; return; }
    self.GPUEndTime = CACurrentMediaTime();
    if (driverThread) {
        dispatch_semaphore_t complete = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            assert(!pthread_main_np());
            double start = CACurrentMediaTime(); [self.drawable present]; driverSpent += CACurrentMediaTime() - start;
            dispatch_semaphore_signal(complete);
        });
        assert(dispatch_semaphore_wait(complete, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    } else for (id drawable in self.drawables) [drawable present];
    self.status = MTLCommandBufferStatusCompleted;
    for (MTLCommandBufferHandler handler in self.completions) handler((id)self);
}
@end
@interface AuditClassicQueue : NSObject
@property(nonatomic, strong) id device;
@end
@implementation AuditClassicQueue
- (id)commandBuffer { return [AuditBuffer new]; }
@end
@interface AuditDevice : NSObject @end
@implementation AuditDevice
- (id)newCommandQueue { AuditClassicQueue *queue = [AuditClassicQueue new]; queue.device = self; return queue; }
- (id)newSharedEvent { return [NSObject new]; }
@end
@interface AuditQueue4 : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic) BOOL earlyPresent;
@end
@implementation AuditQueue4
- (void)waitForDrawable:(id)drawable {}
- (void)signalDrawable:(id)drawable { if (self.earlyPresent) [drawable present]; }
- (void)signalEvent:(id)event value:(uint64_t)value {}
@end
@interface BadBuffer : NSObject @end
@implementation BadBuffer
- (void)presentDrawable:(NSUInteger)drawable {}
- (void)presentDrawable:(NSUInteger)drawable atTime:(double)time {}
- (void)presentDrawable:(NSUInteger)drawable afterMinimumDuration:(double)duration {}
@end
@interface NoCommitBuffer : NSObject @end
@implementation NoCommitBuffer
- (void)presentDrawable:(id)drawable {}
- (void)presentDrawable:(id)drawable atTime:(double)time {}
- (void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration {}
@end
@interface BadDrawable : NSObject @end
@implementation BadDrawable
- (void)addPresentedHandler:(id)handler {}
- (NSUInteger)presentedTime { return 0; }
- (NSUInteger)layer { return 1; }
@end
@interface NativeLayerOverride : AuditDrawable
@property(nonatomic) int reads;
@end
@implementation NativeLayerOverride
- (CAMetalLayer *)layer { self.reads++; return [super layer]; }
@end
@interface BadLayer : NSObject @end
@implementation BadLayer
- (id)drawableSize { return nil; }
- (void)setDrawableSize:(id)size {}
@end
@interface AuditDelegate : NSObject <MulgGraphicsDelegate>
@property(nonatomic) BOOL sawUnfinishedGameWork;
@end
@implementation AuditDelegate
- (BOOL)upscale:(id<MTLTexture>)source into:(id<MTLTexture>)output commandBuffer:(id<MTLCommandBuffer>)buffer extendedRange:(BOOL)range {
    self.sawUnfinishedGameWork = !((AuditBuffer *)buffer).gameEncoded; return YES;
}
- (void)gameCreatedMetalFXObject:(NSString *)feature {}
- (void)layerUsesUnsupportedPresentPath:(CAMetalLayer *)layer {}
- (void)mainLayerCandidateChanged:(CAMetalLayer *)layer {}
- (void)framePresentedAtTime:(double)time {}
@end
static BOOL missingOutput;
static id acquire(id layer, SEL selector) {
    if (missingOutput) return nil;
    AuditDrawable *frame = [AuditDrawable new]; frame.layer = layer; return frame;
}
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2);
    previous_set_drawable_size = [CAMetalLayer instanceMethodForSelector:@selector(setDrawableSize:)];
    previous_drawable_size = [CAMetalLayer instanceMethodForSelector:@selector(drawableSize)];
    previous_next_drawable = (IMP)acquire;
    CAMetalLayer *main = [CAMetalLayer layer]; main.drawableSize = CGSizeMake(128,128);
    mulg_graphics_set_main_layer(main);
    AuditDelegate *delegate = [AuditDelegate new]; mulg_graphics_set_delegate(delegate);
    MulgGraphicsConfig config = { .renderPercent = 50 };
    mulg_graphics_configure(config);
    install_drawable(AuditDrawable.class); install_buffer(AuditBuffer.class);
    AuditBuffer *buffer = [AuditBuffer new];
    if (strcmp(argv[1], "validation") == 0) {
        // A native override exercises the actual getter instead of an inherited
        // saved IMP. Immediate presents need one capability observation plus
        // the main-surface check, not another full capability pass.
        for (int mode = 0; mode < 3; mode++) {
            objc_setAssociatedObject(main, &kPresentationPathKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NativeLayerOverride *frame = [NativeLayerOverride new]; frame.layer = main;
            AuditBuffer *next = [AuditBuffer new];
            if (mode == 0) [next presentDrawable:frame];
            else if (mode == 1) [next presentDrawable:frame atTime:0.123];
            else [next presentDrawable:frame afterMinimumDuration:0.123];
            assert(frame.reads > 0 && frame.reads <= 2);
            // Native getter overrides can deliberately lack full hook support;
            // their capability result must still be observed, not assumed true.
            assert(objc_getAssociatedObject(main, &kPresentationPathKey) != nil);
            assert(next.drawable == frame && next.drawables.count == 1);
            if (mode) assert(next.value == 0.123);
            [next commit];
        }
        assert(atomic_load(&pending_presents) == 0);
        puts("PASS: immediate native presents validate once and preserve all native present modes");
    } else if (strcmp(argv[1], "order") == 0) {
        mulg_graphics_set_upscaling_layer(main);
        AuditDrawable *source = acquire(mulg_source_layer, @selector(nextDrawable));
        [buffer presentDrawable:(id)source];
        assert(delegate.sawUnfinishedGameWork == NO && buffer.drawable == nil);
        buffer.gameEncoded = YES; [buffer commit];
        assert(delegate.sawUnfinishedGameWork == NO && buffer.drawable != nil && buffer.drawable != source);
        for (int mode = 0; mode < 3; mode++) {
            AuditBuffer *multi = [AuditBuffer new];
            AuditDrawable *first = discover_drawable(acquire(mulg_source_layer, @selector(nextDrawable)));
            AuditDrawable *second = discover_drawable(acquire(mulg_source_layer, @selector(nextDrawable)));
            if (mode == 0) [multi presentDrawable:first];
            else if (mode == 1) [multi presentDrawable:first atTime:42];
            else [multi presentDrawable:first afterMinimumDuration:0.123];
            [multi presentDrawable:second];
            __block int handlers = 0;
            [first addPresentedHandler:^(id drawable) { assert(drawable == first); handlers++; }];
            [second addPresentedHandler:^(id drawable) { assert(drawable == second); handlers++; }];
            assert(multi.drawables.count == 0);
            multi.gameEncoded = YES; [multi commit];
            assert(handlers == 2 && multi.drawables.count == 2 && !delegate.sawUnfinishedGameWork);
            if (mode == 1) assert(multi.value == 42);
            if (mode == 2) assert(multi.value == 0.123);
        }
        puts("PASS: upscale follows final game encoding at commit");
    } else if (strcmp(argv[1], "config") == 0) {
        assert(mulg_graphics_current_config().renderPercent == 50);
        // Repeated reads and uncapped pacing must not reacquire the shared
        // settings lock after the thread has obtained its first snapshot.
        alarm(3);
        os_unfair_lock_lock(&mulg_config_lock);
        for (int i = 0; i < 2000; i++) {
            assert(mulg_graphics_current_config().renderPercent == 50);
            assert(mulg_graphics_pace(nil, 0.125, NO) == 0.125);
        }
        os_unfair_lock_unlock(&mulg_config_lock);
        alarm(0);
        MulgGraphicsConfig (^tagged)(int) = ^MulgGraphicsConfig(int tag) {
            return (MulgGraphicsConfig){ .lowLatency = tag, .makeLayersOpaque = tag,
                .renderPercent = tag, .raiseRenderThreadPriority = tag, .reportPresentTimes = tag,
                .refreshesPerFrame = tag + 1, .refreshPeriod = (tag + 1) / 120.0,
                .variableRefresh = tag, .justInTimeFrameStart = tag, .vsyncDisabled = tag };
        };
        mulg_graphics_configure(tagged(0));
        unsigned baseline = graphics_snapshot().timing;
        void (^check)(void) = ^{
            MulgGraphicsSnapshot snapshot = graphics_snapshot();
            MulgGraphicsConfig value = snapshot.config;
            int tag = value.renderPercent;
            assert(tag == 0 || tag == 1);
            assert(value.lowLatency == tag && value.makeLayersOpaque == tag);
            assert(value.raiseRenderThreadPriority == tag && value.reportPresentTimes == tag);
            assert(value.variableRefresh == tag && value.justInTimeFrameStart == tag && value.vsyncDisabled == tag);
            assert(value.refreshesPerFrame == tag + 1 && value.refreshPeriod == (tag + 1) / 120.0);
            // The pacing generation must come from the very same version.
            assert(((snapshot.timing - baseline) & 1) == tag);
        };
        dispatch_apply(5, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t worker) {
            if (worker == 0) {
                for (int i = 0; i < 5000; i++) mulg_graphics_configure(tagged(i & 1));
            } else {
                for (int i = 0; i < 10000; i++) check();
            }
        });
        check(); assert(mulg_graphics_current_config().renderPercent == 1);
        // A worker's completed update must invalidate this thread immediately.
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            mulg_graphics_configure(tagged(0));
        });
        check(); assert(mulg_graphics_current_config().renderPercent == 0);
        // Hold the reset lock so a surface change pauses before publication.
        // The old implementation exposed the new config version too early,
        // allowing a reader to cache it with the previous pacing generation.
        CAMetalLayer *replacement = [CAMetalLayer layer];
        replacement.drawableSize = CGSizeMake(128, 128);
        MulgGraphicsSnapshot beforeLayer = graphics_snapshot();
        dispatch_semaphore_t changedLayer = dispatch_semaphore_create(0);
        os_unfair_lock_lock(&jit_lock);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            mulg_graphics_set_main_layer(replacement);
            dispatch_semaphore_signal(changedLayer);
        });
        uint64_t timeout = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + NSEC_PER_SEC;
        while (atomic_load(&mulg_timing_generation) == beforeLayer.timing
               && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < timeout) usleep(1000);
        assert(atomic_load(&mulg_timing_generation) == beforeLayer.timing + 1);
        assert(atomic_load(&mulg_main_address) == address(replacement));
        assert(atomic_load(&mulg_config_generation) == beforeLayer.configuration);
        assert(graphics_snapshot().timing == beforeLayer.timing);
        os_unfair_lock_unlock(&jit_lock);
        assert(dispatch_semaphore_wait(changedLayer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        MulgGraphicsSnapshot afterLayer = graphics_snapshot();
        assert(afterLayer.configuration == beforeLayer.configuration + 1);
        assert(afterLayer.timing == beforeLayer.timing + 1);
        // Render-height invalidation changes only configuration; a repeated
        // selection of the same surface must not restart its pacing cadence.
        mulg_graphics_set_render_height(2160);
        MulgGraphicsSnapshot afterHeight = graphics_snapshot();
        assert(afterHeight.configuration == afterLayer.configuration + 1);
        assert(afterHeight.timing == afterLayer.timing);
        mulg_graphics_set_main_layer(replacement);
        assert(graphics_snapshot().configuration == afterHeight.configuration);
        assert(graphics_snapshot().timing == afterHeight.timing);
        mulg_graphics_set_render_height(0);
        mulg_graphics_set_main_layer(main);
        assert(graphics_snapshot().timing == afterHeight.timing + 1);
        puts("PASS: cached settings avoid locking and preserve coherent live configuration/timing updates");
    } else if (strcmp(argv[1], "lookup") == 0) {
        AuditBuffer *owner = [AuditBuffer new], *unrelated = [AuditBuffer new];
        NSMutableArray *collisions = [NSMutableArray new];
        while (present_address_bit(address(owner)) == present_address_bit(address(unrelated))) {
            [collisions addObject:unrelated]; unrelated = [AuditBuffer new];
            assert(collisions.count < 128);
        }
        MulgBufferPresent *one = [MulgBufferPresent new];
        hold_present(owner, one);
        // An unrelated commit must not acquire the shared table lock. Bound a
        // regression to this standalone process rather than hanging the runner.
        alarm(3);
        os_unfair_lock_lock(&present_slots_lock);
        assert(take_presents(unrelated) == nil);
        os_unfair_lock_unlock(&present_slots_lock);
        alarm(0);
        assert([take_presents(owner) isEqual:@[one]]);
        assert(atomic_load(&present_slot_mask) == 0);
        NSMutableArray *expected = [NSMutableArray new];
        // Includes overflow: address filtering must preserve cross-storage order.
        for (int i = 0; i < kPresentSlots + 1; i++) {
            MulgBufferPresent *request = [MulgBufferPresent new];
            request.drawable = [NSObject new]; [expected addObject:request];
            hold_present(owner, request);
        }
        assert(atomic_load(&pending_presents) == kPresentSlots + 1);
        assert(take_presents(unrelated) == nil && take_presents(nil) == nil);
        // Simulate a stale address hint. It cannot override actual weak identity.
        os_unfair_lock_lock(&present_slots_lock);
        uintptr_t saved = present_slot_addresses[0];
        present_slot_addresses[0] = address(unrelated);
        publish_present_mask();
        os_unfair_lock_unlock(&present_slots_lock);
        assert(take_presents(unrelated) == nil);
        os_unfair_lock_lock(&present_slots_lock);
        present_slot_addresses[0] = saved;
        publish_present_mask();
        os_unfair_lock_unlock(&present_slots_lock);
        assert([take_presents(owner) isEqual:expected]);
        assert(atomic_load(&pending_presents) == 0 && atomic_load(&overflow_presents) == 0);
        for (int i = 0; i < kPresentSlots; i++) assert(present_slot_addresses[i] == 0);

        __weak id orphanDrawable;
        @autoreleasepool {
            AuditBuffer *abandoned = [AuditBuffer new];
            MulgBufferPresent *request = [MulgBufferPresent new];
            request.drawable = [NSObject new]; orphanDrawable = request.drawable;
            hold_present(abandoned, request);
        }
        assert(orphanDrawable && present_slot_buffers[0] == nil);
        os_unfair_lock_lock(&present_slots_lock);
        present_slot_addresses[0] = address(unrelated);
        publish_present_mask();
        os_unfair_lock_unlock(&present_slots_lock);
        assert(take_presents(unrelated) == nil && atomic_load(&pending_presents) == 1);
        reap_abandoned_presents();
        assert(!orphanDrawable && atomic_load(&pending_presents) == 0 && present_slot_addresses[0] == 0);
        assert(atomic_load(&present_slot_mask) == 0);
        // Publish on worker threads, then consume on other workers. This fills
        // both storage paths and exercises concurrent mask/counter updates.
        NSMutableArray *buffers = [NSMutableArray new], *requests = [NSMutableArray new];
        for (int i = 0; i < kPresentSlots * 2; i++) {
            [buffers addObject:[AuditBuffer new]]; [requests addObject:[MulgBufferPresent new]];
        }
        dispatch_queue_t workers = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        for (int round = 0; round < 8; round++) {
            dispatch_apply(buffers.count, workers, ^(size_t i) { hold_present(buffers[i], requests[i]); });
            assert(atomic_load(&pending_presents) == buffers.count);
            dispatch_apply(buffers.count, workers, ^(size_t i) {
                assert([take_presents(buffers[i]) isEqual:@[requests[i]]]);
            });
            assert(atomic_load(&pending_presents) == 0 && atomic_load(&overflow_presents) == 0);
            assert(atomic_load(&present_slot_mask) == 0);
        }
        puts("PASS: negative lookup preserves weak identity, overflow order and abandonment cleanup");
    } else if (strcmp(argv[1], "reuse") == 0) {
        mulg_graphics_set_upscaling_layer(main);
        AuditDrawable *source = acquire(mulg_source_layer, @selector(nextDrawable));
        missingOutput = YES; assert(upscale((id)source, (id)buffer) == nil);
        [source addPresentedHandler:^(id frame) {}]; // Added after the dropped presentation request.
        assert([objc_getAssociatedObject(source, &kPresentedHandlersKey) count] == 1);
        assert(discover_drawable(source) == source);
        assert(objc_getAssociatedObject(source, &kPresentedHandlersKey) == nil);
        assert(objc_getAssociatedObject(source, &kInterceptedKey) == nil);
        missingOutput = NO;
        id stale = upscale((id)source, (id)buffer);
        __block int delivered = 0;
        [source addPresentedHandler:^(id frame) { delivered++; }];
        discover_drawable(source);
        id current = upscale((id)source, (id)buffer);
        [stale present];
        assert(delivered == 0 && objc_getAssociatedObject(source, &kReplacementKey) == current);
        buffer.status = MTLCommandBufferStatusError;
        ((MTLCommandBufferHandler)buffer.completions.firstObject)((id)buffer);
        assert(objc_getAssociatedObject(source, &kReplacementKey) == current);
        MulgPendingFrame *encoding = [MulgPendingFrame new]; encoding->_drawable = source; encoding->_encoding = YES;
        objc_setAssociatedObject(source, &kPendingBufferKey, encoding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        discover_drawable(source);
        assert(encoding->_discardRequested && !atomic_load(&encoding->_taken));
        objc_setAssociatedObject(source, &kReplacementKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        AuditBuffer *encoded = [AuditBuffer new]; encoding->_buffer = (id)encoded; encoding->_encoding = NO;
        discard_pending(encoding); discard_pending(encoding);
        assert(encoded.commits == 1 && objc_getAssociatedObject(source, &kReplacementKey) == current);
        puts("PASS: reacquisition clears dropped handlers and old callbacks cannot clear new frames");
    } else if (strcmp(argv[1], "layer") == 0) {
        mulg_graphics_set_upscaling_layer(main);
        AuditDrawable *source = mulg_next_drawable(main, @selector(nextDrawable));
        assert(source.layer == main && physical_layer(source) == mulg_source_layer);
        CAMetalLayer *cachedByGame = source.layer;
        gameCaller = NO; assert(source.layer == mulg_source_layer); gameCaller = YES;
        NativeLayerOverride *native = [NativeLayerOverride new]; native.layer = mulg_source_layer;
        assert(!(install_drawable(NativeLayerOverride.class) & MulgGraphicsHookDrawableLayer));
        assert(native.layer == main && native.reads == 1);
        assert(physical_layer(native) == mulg_source_layer && native.reads == 2);
        mulg_graphics_set_upscaling_layer(nil);
        assert(((AuditDrawable *)mulg_next_drawable(cachedByGame, @selector(nextDrawable))).layer == cachedByGame);
        assert(cachedByGame == main && source.layer == main);
        puts("PASS: game layer round trip survives fallback; driver retains physical source");
    } else if (strcmp(argv[1], "abi") == 0) {
        IMP before = class_getMethodImplementation(BadBuffer.class, @selector(presentDrawable:));
        assert(!(install_buffer(BadBuffer.class) & MulgGraphicsHookCommandBufferPresent));
        assert(before == class_getMethodImplementation(BadBuffer.class, @selector(presentDrawable:)));
        Method method = class_getInstanceMethod(BadBuffer.class, @selector(presentDrawable:));
        char *argument = method_copyArgumentType(method, 2);
        assert(strcmp(argument, "@") != 0); free(argument);
        assert(!(install_drawable(BadDrawable.class) & MulgGraphicsHookDrawablePresentedHandlers));
        assert(physical_layer([BadDrawable new]) == nil);
        assert(!hook(BadLayer.class, @selector(drawableSize), (IMP)mulg_drawable_size, NULL, @encode(CGSize), @[]));
        assert(!hook(BadLayer.class, @selector(setDrawableSize:), (IMP)mulg_set_drawable_size, NULL, @encode(void), @[@(@encode(CGSize))]));
        assert(install_buffer(NoCommitBuffer.class) & MulgGraphicsHookCommandBufferPresent);
        assert(!(install_buffer(NoCommitBuffer.class) & MulgGraphicsHookCommandBufferCommit));
        [[NoCommitBuffer new] presentDrawable:acquire(main, @selector(nextDrawable))];
        assert(!mulg_graphics_layer_can_upscale(main));
        puts("PASS: incompatible argument ABI stays native and cannot enable upscaling");
    } else if (strcmp(argv[1], "jit") == 0) {
        config.justInTimeFrameStart = 1; config.refreshesPerFrame = 2; config.refreshPeriod = 1.0 / 60;
        mulg_graphics_configure(config);
        [buffer presentDrawable:acquire(main, @selector(nextDrawable))];
        dispatch_semaphore_t complete = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            assert(!pthread_main_np()); [buffer commit]; dispatch_semaphore_signal(complete);
        });
        assert(dispatch_semaphore_wait(complete, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert(frameStarts == 1 && objc_getAssociatedObject(buffer, &kJITFrameKey) == nil);
        jit_presented(buffer); assert(frameStarts == 1);
        AuditDrawable *handoff = discover_drawable(acquire(main, @selector(nextDrawable)));
        mark_jit_frame(handoff, handoff);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [handoff present]; dispatch_semaphore_signal(complete);
        });
        assert(dispatch_semaphore_wait(complete, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert(frameStarts == 2);
        mark_jit_frame(handoff, handoff); discover_drawable(handoff); jit_presented(handoff);
        assert(frameStarts == 2);
        AuditDrawable *reused = discover_drawable(acquire(main, @selector(nextDrawable)));
        AuditBuffer *staleBuffer = [AuditBuffer new];
        [staleBuffer presentDrawable:reused]; discover_drawable(reused); [staleBuffer commit];
        assert(frameStarts == 2); // A buffer cannot retain ownership of a later acquisition.
        puts("PASS: classic and drawable thread handoffs notify once; reuse clears ownership");
    } else if (strcmp(argv[1], "metal4") == 0) {
        config.justInTimeFrameStart = 1; config.refreshesPerFrame = 2; config.refreshPeriod = 1.0 / 60;
        mulg_graphics_configure(config);
        AuditQueue4 *queue = [AuditQueue4 new]; queue.device = [AuditDevice new];
        assert(install_queue4(AuditQueue4.class) & MulgGraphicsHookMetal4Present);
        for (int scenario = 0; scenario < 3; scenario++) {
            BOOL source = scenario == 2;
            if (source) mulg_graphics_set_upscaling_layer(main);
            queue.earlyPresent = scenario != 1;
            AuditDrawable *frame = discover_drawable(acquire(source ? mulg_source_layer : main, @selector(nextDrawable)));
            [queue signalDrawable:frame];
            if (!queue.earlyPresent) {
                dispatch_semaphore_t complete = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [frame present]; dispatch_semaphore_signal(complete);
                });
                assert(dispatch_semaphore_wait(complete, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
            }
            assert(frameStarts == scenario + 1);
            jit_presented(frame); assert(frameStarts == scenario + 1);
        }
        mulg_graphics_set_upscaling_layer(nil); queue.earlyPresent = NO;
        stalled = [NSMutableArray new]; stallProbes = YES;
        for (int i = 0; i < 8; i++) {
            AuditDrawable *frame = discover_drawable(acquire(main, @selector(nextDrawable)));
            [queue signalDrawable:frame]; [frame present];
        }
        MulgQueueEvent *event = objc_getAssociatedObject(queue, &kQueueEventKey);
        assert(stalled.count == 3 && atomic_load(&event->_probes) == 3);
        assert(event->_probeQueue != own_queue(queue.device));
        AuditQueue4 *otherQueue = [AuditQueue4 new]; otherQueue.device = queue.device;
        AuditDrawable *otherFrame = discover_drawable(acquire(main, @selector(nextDrawable)));
        [otherQueue signalDrawable:otherFrame];
        MulgQueueEvent *otherEvent = objc_getAssociatedObject(otherQueue, &kQueueEventKey);
        assert(otherEvent->_probeQueue != event->_probeQueue && stalled.count == 4);
        stallProbes = NO;
        for (AuditBuffer *probe in stalled) {
            probe.status = MTLCommandBufferStatusError;
            for (MTLCommandBufferHandler completion in probe.completions) completion((id)probe);
        }
        assert(atomic_load(&event->_probes) == 0); [stalled removeAllObjects];
        puts("PASS: native early signal/present, cross-thread Metal 4 and early source present each notify once");
    } else if (strcmp(argv[1], "driver") == 0) {
        driverThread = YES; config.vsyncDisabled = 1; config.variableRefresh = 1;
        config.refreshesPerFrame = 2; config.refreshPeriod = 1.0 / 60;
        mulg_graphics_configure(config);
        double start = CACurrentMediaTime();
        for (int i = 0; i < 4; i++) {
            AuditBuffer *next = [AuditBuffer new];
            [next presentDrawable:acquire(main, @selector(nextDrawable))]; [next commit];
        }
        assert(CACurrentMediaTime() - start > 0.08 && driverSpent < 0.04);
        // Changing the cap cancels a pending deadline instead of waiting out its old 200 ms.
        config.refreshesPerFrame = 12; mulg_graphics_configure(config);
        id frame = acquire(main, @selector(nextDrawable));
        mulg_graphics_pace(frame, 0, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 20), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            MulgGraphicsConfig changed = config; changed.refreshesPerFrame = 0; mulg_graphics_configure(changed);
        });
        start = CACurrentMediaTime(); mulg_graphics_pace(frame, 0, NO);
        assert(CACurrentMediaTime() - start < 0.1);
        // Fixed-refresh displays must not quantize the Vsync-off CPU deadline,
        // including caps above refresh. The first request has no sleep; inspect
        // the carry directly rather than relying on scheduler timing tolerances.
        config.variableRefresh = 0;
        const double ratios[] = {1.5, 0.5, 1.2};
        for (unsigned i = 0; i < sizeof ratios / sizeof *ratios; i++) {
            config.refreshesPerFrame = ratios[i]; config.refreshPeriod = 1.0 / 180;
            mulg_graphics_configure(config);
            mulg_graphics_pace(frame, 0, NO);
            BOOL found = NO;
            for (int j = 0; j < 4; j++) if (rhythms[j].layer == address(main)) {
                found = YES; assert(rhythms[j].carry == 0);
            }
            assert(found);
        }
        // Vsync-on still uses whole-refresh holds, with its original margin.
        config.vsyncDisabled = 0; config.refreshesPerFrame = 1.5;
        mulg_graphics_configure(config);
        assert(fabs(mulg_graphics_pace(frame, 0, NO) - config.refreshPeriod * 0.5) < 1e-8);
        assert(fabs(mulg_graphics_pace(frame, 0, NO) - config.refreshPeriod * 1.5) < 1e-8);
        printf("PASS: submission respects cap; driver callbacks spend %.3f seconds without cap sleeps\n", driverSpent);
    } else if (strcmp(argv[1], "timing") == 0) {
        config.justInTimeFrameStart = 1; config.refreshesPerFrame = 2; config.refreshPeriod = 1.0 / 60;
        mulg_graphics_configure(config);
        __block double shown = CACurrentMediaTime();
        void (^feed)(double) = ^(double elapsed) {
            shown += elapsed;
            AuditDrawable *frame = acquire(main, @selector(nextDrawable));
            MulgFrameTiming *sample = watch_frame(frame, config, ^{ return 0.0; });
            observe_frame(sample, shown - 0.015, shown);
        };
        for (int i = 0; i < 16; i++) feed(1.0 / 30);
        assert(appliedDelay > 0 && appliedDelay <= 1.0 / 120);
        feed(0.1); assert(appliedDelay == 0);
        for (int i = 0; i < 8; i++) { feed(1.0 / 30); assert(appliedDelay == 0); }
        feed(1.0 / 30); assert(appliedDelay > 0);
        AuditDrawable *stale = acquire(main, @selector(nextDrawable));
        mark_jit_frame(stale, stale);
        int before = frameStarts;
        config.vsyncDisabled = 1;
        mulg_graphics_configure(config);
        assert(appliedDelay == 0 && !jit_watches(config, stale));
        jit_presented(stale); assert(frameStarts == before);
        puts("PASS: bounded timing delay, missed-frame recovery, one Vsync-off limiter and stale-generation rejection");
    } else if (strcmp(argv[1], "ready") == 0) {
        config.justInTimeFrameStart = 1; config.refreshesPerFrame = 2; config.refreshPeriod = 1.0 / 60;
        mulg_graphics_configure(config);
        AuditDrawable *frame = acquire(main, @selector(nextDrawable));
        __block double done = 0;
        MulgFrameTiming *sample = watch_frame(frame, config, ^{ return done; });
        [frame present]; done = frame.presentedTime - 0.01;
        assert(appliedDelay == 0 && frame.handlers.count == 0);
        observe_frame(sample, done, 0); assert(appliedDelay > 0);
        double previous = appliedDelay;
        observe_frame(sample, done, frame.presentedTime); assert(appliedDelay == previous);
        AuditDrawable *late = acquire(main, @selector(nextDrawable));
        sample = watch_frame(late, config, ^{ return 0.0; });
        [late present]; observe_frame(sample, late.presentedTime + 0.1, 0);
        assert(appliedDelay == previous);
        AuditDrawable *early = acquire(main, @selector(nextDrawable));
        sample = watch_frame(early, config, ^{ return 0.0; });
        observe_frame(sample, CACurrentMediaTime() - 0.01, 0); [early present];
        assert(appliedDelay > previous);
        puts("PASS: either callback order converges once; delayed GPU probes are rejected");
    } else abort();
} }
