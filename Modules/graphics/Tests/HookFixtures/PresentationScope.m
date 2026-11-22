#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <MulgEngineHooks.h>
#include <assert.h>

static double applied_delay;
void mulg_engine_set_frame_start_delay(double seconds) { applied_delay = seconds; }
void mulg_engine_frame_presented(void) {}
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) { mulg_engine_frame_presented(); }
BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
#import <Metal/Metal.h>
#define MTLCopyAllDevices() @[]
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices

@interface FixtureDrawable : NSObject
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic) CFTimeInterval presentedTime;
@property(nonatomic, copy) MTLDrawablePresentedHandler handler;
@end
@implementation FixtureDrawable
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { self.handler = handler; }
@end

@interface FixtureDelegate : NSObject <MulgGraphicsDelegate>
@property(nonatomic) int samples;
@end
@implementation FixtureDelegate
- (BOOL)upscale:(id<MTLTexture>)source into:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)buffer extendedRange:(BOOL)extendedRange { return NO; }
- (void)gameCreatedMetalFXObject:(NSString *)feature {}
- (void)layerUsesUnsupportedPresentPath:(CAMetalLayer *)layer {}
- (void)mainLayerCandidateChanged:(CAMetalLayer *)layer {}
- (void)framePresentedAtTime:(CFTimeInterval)time { self.samples++; }
@end

int main(void) { @autoreleasepool {
    MulgGraphicsConfig config = { .renderPercent = 100, .justInTimeFrameStart = 1,
        .reportPresentTimes = 1, .refreshesPerFrame = 1, .refreshPeriod = 1.0 / 60.0 };
    mulg_graphics_configure(config);
    CAMetalLayer *old = [CAMetalLayer layer], *next = [CAMetalLayer layer];
    mulg_graphics_set_main_layer(old);
    FixtureDelegate *delegate = [FixtureDelegate new];
    mulg_graphics_set_delegate(delegate);
    FixtureDrawable *frame = [FixtureDrawable new];
    frame.layer = old; frame.presentedTime = 100;
    report_present_time(config, (id<MTLDrawable>)frame);
    assert(frame.handler != nil);
    frame.handler((id<MTLDrawable>)frame);
    assert(delegate.samples == 1);
    FixtureDrawable *secondary = [FixtureDrawable new]; secondary.layer = next;
    report_present_time(config, (id<MTLDrawable>)secondary);
    assert(secondary.handler == nil);
    mulg_graphics_set_main_layer(next);
    frame.handler((id<MTLDrawable>)frame);
    assert(delegate.samples == 1);
    mulg_graphics_set_main_layer(old);
    frame.handler((id<MTLDrawable>)frame);
    assert(delegate.samples == 1); // Even rebinding the same layer cannot revive an old sample.

    watch_frame(frame, config, ^{ return 99.99; });
    mulg_graphics_set_main_layer(next);
    frame.handler((id<MTLDrawable>)frame);
    assert(applied_delay == 0);
    frame.layer = next;
    watch_frame(frame, config, ^{ return 99.99; });
    frame.handler((id<MTLDrawable>)frame);
    assert(applied_delay > 0); // Current feedback still converges.
    double delay = applied_delay;
    config.reportPresentTimes = 0; mulg_graphics_configure(config);
    assert(applied_delay == delay); // Unrelated settings do not reset the timing controller.
    frame.presentedTime += 1.0 / 60.0;
    watch_frame(frame, config, ^{ return frame.presentedTime - 0.01; });
    frame.handler((id<MTLDrawable>)frame);
    assert(applied_delay > delay);
    for (int change = 0; change < 5; change++) {
        watch_frame(frame, config, ^{ return 99.99; });
        switch (change) {
            case 0: config.refreshesPerFrame = 2; break;
            case 1: config.refreshPeriod = 1.0 / 120; break;
            case 2: config.vsyncDisabled = 1; break;
            case 3: config.variableRefresh = 1; break;
            case 4: config.justInTimeFrameStart = 0; break;
        }
        mulg_graphics_configure(config);
        assert(applied_delay == 0);
        frame.handler((id<MTLDrawable>)frame);
        assert(applied_delay == 0);
    }
    config.justInTimeFrameStart = 1; mulg_graphics_configure(config);
    frame.handler((id<MTLDrawable>)frame);
    assert(applied_delay == 0);
    watch_frame(frame, config, ^{ return 99.99; });
    frame.presentedTime = 100;
    frame.handler((id<MTLDrawable>)frame);
    assert(applied_delay > 0);
    mulg_graphics_set_main_layer(nil);
    mulg_graphics_set_delegate(nil);
    puts("PASS: main-surface measurement and generation-scoped frame-start feedback");
} }
