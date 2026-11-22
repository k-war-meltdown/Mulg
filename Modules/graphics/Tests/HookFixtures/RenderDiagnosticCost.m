#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <assert.h>
#include <unistd.h>
BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
void mulg_engine_set_frame_start_delay(double delay) {}
void mulg_engine_frame_presented(void) {}
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) {}
#import <Metal/Metal.h>
#define MTLCopyAllDevices() @[]
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices

@interface CostTexture : NSObject
@property NSUInteger width, height, sampleCount;
@end
@implementation CostTexture
@end

@interface CostBuffer : NSObject
@end
@implementation CostBuffer
- (void)presentDrawable:(id)drawable {}
- (void)presentDrawable:(id)drawable atTime:(CFTimeInterval)time {}
- (void)presentDrawable:(id)drawable afterMinimumDuration:(CFTimeInterval)duration {}
- (void)commit {}
- (id)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor { return [NSObject new]; }
@end

int main(void) { @autoreleasepool {
    CostTexture *scene = [CostTexture new], *half = [CostTexture new];
    scene.width = 4092; scene.height = 2160;
    half.width = 2046; half.height = 1080;
    record_pass((id)scene); record_pass((id)half);
    // Alternating known sizes must not acquire the discovery lock again.
    // A regression terminates this fixture, rather than hanging the test runner.
    alarm(3);
    os_unfair_lock_lock(&pass_lock);
    for (int i = 0; i < 1000; i++) { record_pass((id)scene); record_pass((id)half); }
    os_unfair_lock_unlock(&pass_lock);
    alarm(0);
    NSArray *counts = mulg_graphics_render_pass_sizes();
    assert([counts containsObject:@"4092x2160: 1001 passes"]);
    assert([counts containsObject:@"2046x1080: 1001 passes"]);
    // Independent render threads discover/cache the same immutable slots.
    dispatch_apply(100, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
        record_pass((id)scene); record_pass((id)half);
    });
    counts = mulg_graphics_render_pass_sizes();
    assert([counts containsObject:@"4092x2160: 1101 passes"]);
    assert([counts containsObject:@"2046x1080: 1101 passes"]);

    // Normal launch discovers presentation support without interposing encoders.
    Class bufferClass = objc_lookUpClass("CostBuffer");
    SEL encoderSelector = @selector(renderCommandEncoderWithDescriptor:);
    IMP original = class_getMethodImplementation(bufferClass, encoderSelector);
    assert(!(install_buffer(bufferClass) & MulgGraphicsHookRenderPassSizes));
    assert(class_getMethodImplementation(bufferClass, encoderSelector) == original);
    mulg_graphics_set_diagnostics_enabled(YES);
    assert(class_getMethodImplementation(bufferClass, encoderSelector) != original);
    CostBuffer *buffer = [CostBuffer new];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = (id)scene;
    assert([buffer renderCommandEncoderWithDescriptor:pass]);
    assert([mulg_graphics_render_pass_sizes() containsObject:@"4092x2160: 1102 passes"]);
    mulg_graphics_set_diagnostics_enabled(NO);
    assert([buffer renderCommandEncoderWithDescriptor:pass]);
    assert([mulg_graphics_render_pass_sizes() containsObject:@"4092x2160: 1102 passes"]);

    mulg_graphics_set_scene_trace_enabled(YES);
    scene.sampleCount = half.sampleCount = 1;
    scene_allocation_count = 1;
    scene_allocations[0].observedColorPass = YES;
    scene_allocations[0].observedSameSizeDepth = YES;
    tag_scene_texture(scene, scene_trace_generation, 0);
    MulgSceneAllocationTag *tag = objc_getAssociatedObject(scene, &sceneAllocationKey);
    assert(!atomic_load(&tag->complete));
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = (id)scene;
    record_scene_pass(descriptor, NULL);
    assert(atomic_load(&tag->complete));
    uint64_t revision = scene_trace_revision;
    record_scene_pass(descriptor, NULL);
    assert(scene_trace_revision == revision);
    mulg_graphics_set_scene_trace_enabled(NO);
} return 0; }
