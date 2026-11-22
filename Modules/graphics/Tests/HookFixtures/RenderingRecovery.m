#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <MulgEngineHooks.h>
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
void mulg_engine_set_frame_start_delay(double seconds) {}
void mulg_engine_frame_presented(void) {}
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) { mulg_engine_frame_presented(); }
static BOOL gameCaller = YES;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
#import <Metal/Metal.h>
#define MTLCopyAllDevices() @[]
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices

@interface TestDrawable : NSObject
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic) CFTimeInterval presentedTime;
@property(nonatomic, strong) NSMutableArray *handlers;
@property(nonatomic, strong) id texture;
- (void)present;
- (void)presentAtTime:(CFTimeInterval)time;
- (void)presentAfterMinimumDuration:(CFTimeInterval)duration;
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler;
@end
@implementation TestDrawable
- (instancetype)init { if ((self = [super init])) _handlers = [NSMutableArray new]; return self; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { [_handlers addObject:[handler copy]]; }
- (void)present {
    self.presentedTime = CACurrentMediaTime();
    NSArray *handlers = [_handlers copy]; [_handlers removeAllObjects];
    for (MTLDrawablePresentedHandler handler in handlers) handler((id)self);
}
- (void)presentAtTime:(CFTimeInterval)time { [self present]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)duration { [self present]; }
@end
static dispatch_semaphore_t handlerEntered, handlerResume;
@interface BlockingDrawable : TestDrawable @end
@implementation BlockingDrawable
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler {
    dispatch_semaphore_signal(handlerEntered);
    assert(dispatch_semaphore_wait(handlerResume, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    [self.handlers addObject:[handler copy]];
}
@end
@interface TestBuffer : NSObject
@property(nonatomic) double GPUEndTime;
- (void)presentDrawable:(id)drawable;
- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)time;
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)duration;
- (void)addCompletedHandler:(id)handler;
- (void)commit;
@end
@implementation TestBuffer
- (void)presentDrawable:(id)drawable { [drawable present]; }
- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)time { [drawable presentAtTime:time]; }
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)duration { [drawable presentAfterMinimumDuration:duration]; }
- (void)addCompletedHandler:(id)handler {}
- (void)commit {}
@end
@interface PartialBuffer : NSObject
- (void)presentDrawable:(id)drawable;
@end
@implementation PartialBuffer
- (void)presentDrawable:(id)drawable {}
@end
@interface PartialDrawable : NSObject
@property(nonatomic, strong) CAMetalLayer *layer;
@end
@implementation PartialDrawable @end
@interface TestQueue : NSObject
- (void)waitForDrawable:(id)drawable;
- (void)signalDrawable:(id)drawable;
@end
@implementation TestQueue
- (void)waitForDrawable:(id)drawable {}
- (void)signalDrawable:(id)drawable {}
@end
@interface PartialQueue : NSObject
- (void)signalDrawable:(id)drawable;
@end
@implementation PartialQueue
- (void)signalDrawable:(id)drawable {}
@end
@interface TestDelegate : NSObject <MulgGraphicsDelegate>
@property(nonatomic) int samples, ownFX, unsupported, shortages, encodes;
@end
@implementation TestDelegate
- (BOOL)upscale:(id<MTLTexture>)source into:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)buffer extendedRange:(BOOL)extendedRange { self.encodes++; return YES; }
- (void)gameCreatedMetalFXObject:(NSString *)feature { self.ownFX++; }
- (void)layerUsesUnsupportedPresentPath:(CAMetalLayer *)layer { self.unsupported++; }
- (void)outputDrawableUnavailable:(CAMetalLayer *)layer { self.shortages++; }
- (void)mainLayerCandidateChanged:(CAMetalLayer *)layer {}
- (void)framePresentedAtTime:(CFTimeInterval)time { self.samples++; }
@end
// A view with MTKView's resize contract, without loading a UI framework or GPU.
@interface MTKView : NSObject
@property(nonatomic) BOOL autoResizeDrawable;
@property(nonatomic, weak) id delegate;
- (void)setNeedsLayout;
@end
@implementation MTKView
- (void)setNeedsLayout {}
@end

static CAMetalLayer *outputLayer;
static BOOL outputMissing;
static TestDrawable *reusedOutput;
static id acquireDrawable(id layer, SEL selector) {
    if (layer == outputLayer && outputMissing) return nil;
    if (layer == outputLayer && reusedOutput) return reusedOutput;
    TestDrawable *drawable = [TestDrawable new]; drawable.layer = layer; return drawable;
}
static id __attribute__((ns_returns_retained)) failedFactory(id self, SEL selector, id device) { return nil; }
static id __attribute__((ns_returns_retained)) successfulFactory(id self, SEL selector, id device) { return [NSObject new]; }

@interface TestArchive : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic) BOOL fail;
@property(nonatomic) uint64_t bytes;
- (BOOL)serializeToURL:(NSURL *)file error:(NSError **)error;
- (BOOL)addRenderPipelineFunctionsWithDescriptor:(id)descriptor error:(NSError **)error;
@end
static BOOL writeArchive(NSURL *file, uint64_t bytes) {
    int descriptor = open(file.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (descriptor < 0) return NO;
    BOOL success = ftruncate(descriptor, (off_t)bytes) == 0;
    close(descriptor); return success;
}
@implementation TestArchive
- (BOOL)serializeToURL:(NSURL *)file error:(NSError **)error {
    assert(error != NULL);
    if (self.fail) { *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]; return NO; }
    return writeArchive(file, self.bytes);
}
- (BOOL)addRenderPipelineFunctionsWithDescriptor:(id)descriptor error:(NSError **)error { assert(error != NULL); return YES; }
@end
@interface TestDevice : NSObject
- (id)newBinaryArchiveWithDescriptor:(id)descriptor error:(NSError **)error;
@end
@implementation TestDevice
- (id)newBinaryArchiveWithDescriptor:(id)descriptor error:(NSError **)error {
    assert(error != NULL);
    TestArchive *archive = [TestArchive new]; archive.device = self; archive.bytes = 8; return archive;
}
@end
@interface TestSerializer : NSObject
@property(nonatomic) int flushes;
@property(nonatomic) uint64_t bytes;
- (BOOL)serializeAsArchiveAndFlushToURL:(NSURL *)file error:(NSError **)error;
@end
@implementation TestSerializer
- (BOOL)serializeAsArchiveAndFlushToURL:(NSURL *)file error:(NSError **)error { assert(error != NULL); self.flushes++; return writeArchive(file, self.bytes); }
@end

int main(void) { @autoreleasepool {
    previous_set_drawable_size = [CAMetalLayer instanceMethodForSelector:@selector(setDrawableSize:)];
    previous_drawable_size = [CAMetalLayer instanceMethodForSelector:@selector(drawableSize)];
    previous_next_drawable = (IMP)acquireDrawable;
    MulgGraphicsConfig config = { .renderPercent = 50, .reportPresentTimes = 1 };
    mulg_graphics_configure(config);
    CAMetalLayer *main = [CAMetalLayer layer]; main.drawableSize = CGSizeMake(128,128); outputLayer = main;
    mulg_graphics_set_main_layer(main);
    TestDelegate *delegate = [TestDelegate new]; mulg_graphics_set_delegate(delegate);
    TestDrawable *native = [TestDrawable new]; native.layer = main;
    TestBuffer *buffer = [TestBuffer new];
    assert(!mulg_graphics_layer_can_upscale(main)); // No startup drawable or queue probe needed.
    assert(install_buffer(TestBuffer.class) & MulgGraphicsHookCommandBufferPresent);
    [buffer presentDrawable:(id)native];
    assert(mulg_graphics_layer_can_upscale(main) && delegate.samples == 1);
    native = discover_drawable(acquireDrawable(main, @selector(nextDrawable)));
    report_present_time(config, (id)native); report_present_time(config, (id)native);
    [native presentAtTime:0]; assert(delegate.samples == 2); // Buffer/direct hooks cannot double count.
    native = discover_drawable(acquireDrawable(main, @selector(nextDrawable)));
    [native present]; assert(delegate.samples == 3); // A fresh direct present registers its own handler.
    TestDrawable *secondaryFrame = [TestDrawable new]; secondaryFrame.layer = [CAMetalLayer layer];
    [buffer presentDrawable:(id)secondaryFrame]; assert(delegate.samples == 3);
    install_buffer(PartialBuffer.class);
    note_presentation_path(native, (install_buffer(PartialBuffer.class) & MulgGraphicsHookCommandBufferPresent) != 0);
    assert(!mulg_graphics_layer_can_upscale(main));
    PartialDrawable *partial = [PartialDrawable new]; partial.layer = main;
    note_presentation_path(partial, YES); assert(!mulg_graphics_layer_can_upscale(main));
    assert(!(install_queue4(PartialQueue.class) & MulgGraphicsHookMetal4Present));
    [(id)[PartialQueue new] signalDrawable:(id)native]; assert(!mulg_graphics_layer_can_upscale(main));
    assert(install_queue4(TestQueue.class) & MulgGraphicsHookMetal4Present);
    native = discover_drawable(acquireDrawable(main, @selector(nextDrawable)));
    [(id)[TestQueue new] signalDrawable:(id)native];
    assert(mulg_graphics_layer_can_upscale(main));
    [native presentAfterMinimumDuration:0]; assert(delegate.samples == 4);
    puts("PASS: actual path readiness, partial hook fallback and exactly-once presentation reporting");

    // Each timing change resets pacing, but reporting/low latency/preset changes do not.
    config.refreshesPerFrame = 1.5; config.refreshPeriod = 1.0 / 60;
    mulg_graphics_configure(config);
    double first = mulg_graphics_pace(native, 0, NO);
    config.lowLatency = 1; config.reportPresentTimes = 0; config.renderPercent = 67;
    mulg_graphics_configure(config);
    assert(mulg_graphics_pace(native, 0, NO) > first * 2);
    config.refreshesPerFrame = 2; mulg_graphics_configure(config);
    assert(fabs(mulg_graphics_pace(native, 0, NO) - 1.5 / 60) < 1e-6);
    config.refreshesPerFrame = 0; config.lowLatency = 0; mulg_graphics_configure(config);

    mulg_graphics_set_upscaling_layer(main);
    CAMetalLayer *source = mulg_source_layer;
    TestDrawable *small = [TestDrawable new]; small.layer = source;
    [small addPresentedHandler:^(id<MTLDrawable> drawable) {}];
    assert(small.handlers.count == 0); // Hidden driver callbacks must not retain the game's handler too.
    outputMissing = YES;
    assert(upscale((id)small, (id)buffer) == nil && delegate.shortages == 1 && delegate.unsupported == 0);
    assert(objc_getAssociatedObject(small, &kPresentedHandlersKey) == nil);
    outputMissing = NO;
    assert(upscale((id)small, (id)buffer) != nil && delegate.encodes == 1);
    // The output bypasses the public layer hook; its reused drawable still starts a new sample.
    config.reportPresentTimes = 1; mulg_graphics_configure(config);
    reusedOutput = [TestDrawable new]; reusedOutput.layer = main;
    report_present_time(config, (id)reusedOutput);
    int beforeReuse = delegate.samples;
    [reusedOutput present];
    assert(upscale((id)small, (id)buffer) == reusedOutput);
    report_present_time(config, (id)reusedOutput); [reusedOutput present];
    assert(delegate.samples == beforeReuse + 2);
    reusedOutput = nil;
    config.lowLatency = 1; mulg_graphics_configure(config);
    mulg_graphics_apply_layer_config(main);
    assert(mulg_next_drawable(main, @selector(nextDrawable)) != nil);
    assert(main.maximumDrawableCount == 2 && source.maximumDrawableCount == 2);
    config.lowLatency = 0; mulg_graphics_configure(config);
    mulg_graphics_apply_layer_config(main); main.allowsNextDrawableTimeout = NO;
    assert(mulg_next_drawable(main, @selector(nextDrawable)) != nil);
    assert(source.maximumDrawableCount == main.maximumDrawableCount && !source.allowsNextDrawableTimeout && !source.framebufferOnly);
    mulg_graphics_set_upscaling_layer(nil);
    puts("PASS: transient output recovery and synchronized source acquisition settings");

    CAMetalLayer *second = [CAMetalLayer layer]; second.drawableSize = CGSizeMake(128,128);
    MTKView *firstView = [MTKView new], *secondView = [MTKView new];
    firstView.autoResizeDrawable = YES; secondView.autoResizeDrawable = YES;
    main.delegate = (id)firstView; second.delegate = (id)secondView;
    mulg_graphics_set_live_resize(YES);
    mulg_set_drawable_size(main, @selector(setDrawableSize:), CGSizeMake(64,64));
    mulg_set_drawable_size(second, @selector(setDrawableSize:), CGSizeMake(64,64));
    assert(main.drawableSize.width == 64 && second.drawableSize.width == 64 && firstView.autoResizeDrawable && atomic_load(&mulg_live_resize));
    mulg_graphics_set_main_layer(second);
    assert(main.drawableSize.width == 64 && firstView.autoResizeDrawable && secondView.autoResizeDrawable && atomic_load(&mulg_live_resize));
    mulg_set_drawable_size(second, @selector(setDrawableSize:), CGSizeMake(32,32));
    assert(second.drawableSize.width == 32 && atomic_load(&mulg_live_resize));
    mulg_graphics_set_live_resize(NO);
    assert(second.drawableSize.width == 32 && secondView.autoResizeDrawable && !atomic_load(&mulg_live_resize));
    puts("PASS: immediate native drawable resize, unchanged MTKView ownership and stable resize ownership across replacement");

    config.reportPresentTimes = 1; mulg_graphics_configure(config);
    BlockingDrawable *concurrent = [BlockingDrawable new]; concurrent.layer = second;
    install_drawable(BlockingDrawable.class);
    handlerEntered = dispatch_semaphore_create(0); handlerResume = dispatch_semaphore_create(0);
    dispatch_semaphore_t started = dispatch_semaphore_create(0), finished = dispatch_semaphore_create(0);
    dispatch_group_t group = dispatch_group_create();
    int samples = delegate.samples;
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        report_present_time(config, (id)concurrent);
    });
    assert(dispatch_semaphore_wait(handlerEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_semaphore_signal(started);
        [concurrent present]; dispatch_semaphore_signal(finished);
    });
    assert(dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 100)) != 0);
    dispatch_semaphore_signal(handlerResume);
    assert(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(delegate.samples == samples + 1);
    puts("PASS: concurrent Metal 4/direct presentation cannot race handler registration");

    previous_fx_spatial = (IMP)failedFactory;
    assert(mulg_fx_spatial(nil, @selector(newSpatialScalerWithDevice:), nil) == nil && delegate.ownFX == 0);
    previous_fx_spatial = (IMP)successfulFactory;
    gameCaller = NO;
    assert(mulg_fx_spatial(nil, @selector(newSpatialScalerWithDevice:), nil) != nil && delegate.ownFX == 0);
    gameCaller = YES; mulg_graphics_begin_own_metalfx();
    assert(mulg_fx_spatial(nil, @selector(newSpatialScalerWithDevice:), nil) != nil && delegate.ownFX == 0);
    mulg_graphics_end_own_metalfx();
    assert(mulg_fx_spatial(nil, @selector(newSpatialScalerWithDevice:), nil) != nil && delegate.ownFX == 1);
    puts("PASS: failed probes, native helpers and wrapper factories do not report game MetalFX");

    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    assert([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL]);
    shader_queue = dispatch_queue_create("fixture.shader3", DISPATCH_QUEUE_SERIAL);
    shader_save_timer = archive_save_timer(shader_queue, &shader_save_scheduled, ^{});
    TestDevice *device = [TestDevice new];
    shader_record = open_archive((id)device, nil);
    shader_archive_url = [folder URLByAppendingPathComponent:@"cache.metallib"];
    for (int i = 0; i < 1000; i++) record_pipeline([NSObject new], PipelineRender);
    dispatch_sync(shader_queue, ^{
        assert(shader_generation == 1000 && shader_save_scheduled);
        ((TestArchive *)shader_record).fail = YES; save_shader_archive();
        assert(shader_saved_generation == 0);
        ((TestArchive *)shader_record).fail = NO; save_shader_archive();
        assert(shader_saved_generation == 1000 && archive_file_size(shader_archive_url) == 8);
        ((TestArchive *)shader_record).bytes = MulgGraphicsShaderArchiveLimit / 2 + 1;
        shader_generation++; save_shader_archive();
        assert(shader_saved_generation == shader_generation && archive_file_size(shader_archive_url) == 8);
        assert(((TestArchive *)shader_record).bytes == 8);
    });

    shader4_queue = dispatch_queue_create("fixture.shader4", DISPATCH_QUEUE_SERIAL);
    shader4_save_timer = archive_save_timer(shader4_queue, &shader4_save_scheduled, ^{});
    TestSerializer *serializer = [TestSerializer new]; serializer.bytes = 8;
    shader4_serializer = (id)serializer; shader4_session_files = [NSMutableArray new];
    shader4_lookups = (id)@[[NSObject new], [NSObject new], [NSObject new], [NSObject new]];
    shader4_lookup_bytes = 32;
    NSURL *pinned = [folder URLByAppendingPathComponent:@"pinned.mtl4archive"]; assert(writeArchive(pinned, 32));
    shader4_url = [folder URLByAppendingPathComponent:@"cache.mtl4archive"];
    NSURL *blocked = [shader4_url URLByAppendingPathExtension:@"0"];
    assert([NSFileManager.defaultManager createDirectoryAtURL:blocked withIntermediateDirectories:NO attributes:nil error:NULL]);
    dispatch_sync(shader4_queue, ^{
        shader4_generation = 1; save_metal4_archive();
        assert(shader4_partial_generation == 1 && shader4_saved_generation == 0 && serializer.flushes == 1);
        assert([NSFileManager.defaultManager fileExistsAtPath:[[blocked URLByAppendingPathExtension:@"partial"] path]]);
        shader4_generation = 2; assert([NSFileManager.defaultManager removeItemAtURL:blocked error:NULL]);
        save_metal4_archive(); assert(shader4_saved_generation == 1 && serializer.flushes == 1);
        save_metal4_archive(); assert(shader4_saved_generation == 2 && serializer.flushes == 2);
        for (int i = 0; i < 12; i++) {
            shader4_generation++; save_metal4_archive();
            assert(shader4_session_files.count + shader4_lookups.count <= kMetal4ArchivesKept);
        }
        serializer.bytes = MulgGraphicsShaderArchiveLimit / 2 + 1;
        shader4_generation++; save_metal4_archive();
        assert(shader4_session_files.count == 0 && archive_file_size(pinned) == 32);
    });
    id compiler = [NSObject new];
    objc_setAssociatedObject(compiler, &kCompilerCaptures, @YES, OBJC_ASSOCIATION_RETAIN);
    for (int i = 0; i < 1000; i++) note_metal4_pipeline(compiler);
    dispatch_sync(shader4_queue, ^{ assert(shader4_save_scheduled); });
    mulg_graphics_purge_shader_cache();
    dispatch_sync(shader_queue, ^{}); dispatch_sync(shader4_queue, ^{});
    dispatch_source_cancel(shader_save_timer); dispatch_source_cancel(shader4_save_timer);
    assert([NSFileManager.defaultManager removeItemAtURL:folder error:NULL]);
    mulg_graphics_set_main_layer(nil); mulg_graphics_set_delegate(nil);
    puts("PASS: bounded save work, live archive retention, failed-publication retry and pressure flushing");
} }
