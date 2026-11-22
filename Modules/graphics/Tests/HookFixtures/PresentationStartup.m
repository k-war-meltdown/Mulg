#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <MulgEngineHooks.h>
#include <assert.h>

BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
void mulg_engine_set_frame_start_delay(double delay) {}
void mulg_engine_frame_presented(void) {}
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) {}

static id<MTLDevice> fixture_device(void);
#define MTLCreateSystemDefaultDevice fixture_device
#import <Metal/Metal.h>
#define MTLCopyAllDevices() @[]
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices
#undef MTLCreateSystemDefaultDevice

static int layersCreated, drawablesRequested, nativePresents, nativeCommits;
static int devicesCreated, classicQueuesCreated, metal4QueuesCreated, buffersCreated;
static IMP nativeLayerFactory;
static id acquiredDrawable;
static id<MTLDevice> gameDevice;

@interface StartupDrawable : NSObject
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic) CFTimeInterval presentedTime;
@property(nonatomic, copy) MTLDrawablePresentedHandler handler;
@end
@implementation StartupDrawable
- (void)present { nativePresents++; }
- (void)presentAtTime:(CFTimeInterval)time { nativePresents++; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)duration { nativePresents++; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { self.handler = handler; }
@end

@interface StartupBuffer : NSObject @end
@implementation StartupBuffer
- (instancetype)init { self = [super init]; if (self) buffersCreated++; return self; }
- (void)presentDrawable:(id)drawable { [drawable present]; }
- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)time { [drawable presentAtTime:time]; }
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)duration { [drawable presentAfterMinimumDuration:duration]; }
- (void)commit { nativeCommits++; }
@end

@interface StartupQueue : NSObject @end
@implementation StartupQueue
- (id)commandBuffer { return [StartupBuffer new]; }
- (id)commandBufferWithUnretainedReferences { return [StartupBuffer new]; }
- (id)commandBufferWithDescriptor:(id)descriptor { return [StartupBuffer new]; }
@end

@interface StartupQueue4 : NSObject @end
@implementation StartupQueue4
- (void)waitForDrawable:(id)drawable {}
- (void)signalDrawable:(id)drawable {}
@end

@interface StartupDevice : NSObject @end
@implementation StartupDevice
- (id)newCommandQueue { classicQueuesCreated++; return [StartupQueue new]; }
- (id)newMTL4CommandQueue { metal4QueuesCreated++; return [StartupQueue4 new]; }
@end

static id<MTLDevice> fixture_device(void) { devicesCreated++; return (id)[StartupDevice new]; }
static id layer_device(id self, SEL selector) { return gameDevice; }
static id counted_layer(id self, SEL selector) {
    layersCreated++;
    return ((Getter)nativeLayerFactory)(self, selector);
}
static id acquire_drawable(id self, SEL selector) {
    drawablesRequested++;
    return acquiredDrawable;
}

int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2);
    BOOL experimental = !strcmp(argv[1], "experimental");
    Method factory = class_getClassMethod(CAMetalLayer.class, @selector(layer));
    nativeLayerFactory = method_setImplementation(factory, (IMP)counted_layer);
    method_setImplementation(class_getInstanceMethod(CAMetalLayer.class, @selector(nextDrawable)), (IMP)acquire_drawable);

    MulgGraphicsHook attempted = 0;
    MulgGraphicsHook installed = mulg_graphics_install_presentation_hooks(experimental, &attempted);
    assert(layersCreated == 0 && drawablesRequested == 0 && devicesCreated == 0);
    assert(classicQueuesCreated == 0 && metal4QueuesCreated == 0 && buffersCreated == 0);
    MulgGraphicsHook immediate = MulgGraphicsHookLayerDrawableSize | MulgGraphicsHookLayerNextDrawable;
    assert((installed & immediate) == immediate);
    assert((attempted & immediate) == immediate);
    MulgGraphicsHook drawableHooks = MulgGraphicsHookDrawablePresent | MulgGraphicsHookDrawablePresentedHandlers | MulgGraphicsHookDrawableLayer;
    MulgGraphicsHook lazy = drawableHooks | MulgGraphicsHookCommandBufferPresent
        | MulgGraphicsHookCommandBufferCommit | MulgGraphicsHookMetal4Present;
    assert((attempted & lazy) == 0 && (installed & lazy) == 0);
    assert([mulg_graphics_drawable_class_name() isEqualToString:@"?"]);
    assert([mulg_graphics_command_buffer_class_name() isEqualToString:@"?"]);
    assert([mulg_graphics_metal4_queue_class_name() isEqualToString:@"?"]);

    method_setImplementation(factory, nativeLayerFactory);
    method_setImplementation(class_getInstanceMethod(CAMetalLayer.class, @selector(device)), (IMP)layer_device);
    CAMetalLayer *layer = [CAMetalLayer layer];
    assert([layer nextDrawable] == nil && drawablesRequested == 1);
    assert(devicesCreated == 0 && classicQueuesCreated == 0 && metal4QueuesCreated == 0 && buffersCreated == 0);
    assert([mulg_graphics_drawable_class_name() isEqualToString:@"?"]);
    StartupDrawable *drawable = [StartupDrawable new]; drawable.layer = layer;
    acquiredDrawable = drawable;
    gameDevice = (id)[StartupDevice new];
    StartupQueue *earlyQueue = (id)[gameDevice newCommandQueue];
    StartupBuffer *earlyBuffer = [earlyQueue commandBuffer];
    StartupQueue4 *earlyQueue4 = (id)[gameDevice newMTL4CommandQueue];
    assert(class_getMethodImplementation(earlyBuffer.class, @selector(commit)) != (IMP)mulg_buffer_commit);
    // A device can appear after a nil drawable on the same layer/configuration. Discovery
    // must not wait for the half-second candidate heartbeat in that case.
    assert([layer nextDrawable] == drawable && drawablesRequested == 2);
    assert(devicesCreated == 0 && classicQueuesCreated == 2 && metal4QueuesCreated == 2);
    assert(buffersCreated == 2);
    assert([mulg_graphics_drawable_class_name() isEqualToString:NSStringFromClass(drawable.class)]);
    assert((install_drawable(drawable.class) & drawableHooks) == drawableHooks);
    assert([mulg_graphics_command_buffer_class_name() isEqualToString:@"StartupBuffer"]);
    assert([mulg_graphics_metal4_queue_class_name() isEqualToString:@"StartupQueue4"]);
    assert(class_getMethodImplementation(earlyBuffer.class, @selector(commit)) == (IMP)mulg_buffer_commit);
    assert(class_getMethodImplementation(earlyQueue4.class, @selector(signalDrawable:)) == (IMP)mulg_queue_signal_drawable);
    // Discovery finishes before the game can see the first drawable. Its native methods,
    // callback and layer remain usable on the first frame and on drawable reuse.
    assert(class_getMethodImplementation(drawable.class, @selector(present)) == (IMP)mulg_drawable_present);
    assert(class_getMethodImplementation(drawable.class, @selector(addPresentedHandler:)) == (IMP)mulg_add_presented_handler);
    assert(class_getMethodImplementation(drawable.class, @selector(layer)) == (IMP)mulg_drawable_layer);
    assert(drawable.layer == layer);
    __block id presented = nil;
    [drawable addPresentedHandler:^(id value) { presented = value; }];
    assert(drawable.handler != nil); drawable.handler((id)drawable); assert(presented == drawable);
    [drawable present]; [drawable presentAtTime:1]; [drawable presentAfterMinimumDuration:0.5];
    assert(nativePresents == 3);
    assert([layer nextDrawable] == drawable && drawablesRequested == 3);
    assert(classicQueuesCreated == 2 && metal4QueuesCreated == 2);
    assert(buffersCreated == 2);

    // Existing queues/buffers are covered on that first frame, not just future factories.
    [earlyBuffer presentDrawable:drawable]; [earlyBuffer commit];

    // Replacement by a second device of the same class is discovered immediately and seeded
    // independently; a class-only seed flag must not make the second device skip discovery.
    gameDevice = (id)[StartupDevice new];
    assert([layer nextDrawable] == drawable && drawablesRequested == 4);
    assert(classicQueuesCreated == 3 && metal4QueuesCreated == 3 && buffersCreated == 3);
    assert([layer nextDrawable] == drawable && drawablesRequested == 5);
    assert(classicQueuesCreated == 3 && metal4QueuesCreated == 3 && buffersCreated == 3);

    StartupQueue *queue = [[StartupDevice new] newCommandQueue];
    for (StartupBuffer *buffer in @[[queue commandBuffer], [queue commandBufferWithUnretainedReferences],
                                    [queue commandBufferWithDescriptor:nil]]) {
        [buffer presentDrawable:drawable]; [buffer commit];
    }
    assert(nativeCommits == 4 && nativePresents == 7);
    assert(devicesCreated == 0);
    puts("PASS: startup creates no device/queue/layer/drawable; actual-device discovery preserves first-frame presentation");
} }
