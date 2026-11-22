#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <MulgEngineHooks.h>
#include <assert.h>
#include <string.h>
static BOOL gameCaller = YES;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
void mulg_engine_set_frame_start_delay(double delay) {}
void mulg_engine_frame_presented(void) {}
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) {}
static NSArray<id<MTLDevice>> *fixture_devices(void);
#define MTLCopyAllDevices fixture_devices
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices

@interface RecoveryDevice : NSObject
- (id)newCommandQueue;
- (id)newMTL4CommandQueue;
@end
@implementation RecoveryDevice
- (id)newCommandQueue { return nil; }
- (id)newMTL4CommandQueue { return nil; }
@end
@interface RecoveryLayer : CAMetalLayer
@property(nonatomic, strong) id fixtureDevice;
@property(nonatomic) int deviceWrites;
@end
@implementation RecoveryLayer
- (id<MTLDevice>)device { return self.fixtureDevice; }
- (void)setDevice:(id<MTLDevice>)device { self.deviceWrites++; self.fixtureDevice = device; }
@end
static NSArray *available;
static int enumerations;
static RecoveryLayer *changedDuringEnumeration;
static id concurrentDevice;
static NSArray<id<MTLDevice>> *fixture_devices(void) {
    enumerations++;
    if (changedDuringEnumeration) changedDuringEnumeration.device = concurrentDevice;
    return available;
}
static id acquire(id layer, SEL command) { return [(CAMetalLayer *)layer device] ? [NSObject new] : nil; }
static id request(RecoveryLayer *layer) {
    atomic_fetch_add(&mulg_config_generation, 1);
    return mulg_next_drawable(layer, @selector(nextDrawable));
}
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2);
    const char *scenario = argv[1];
    RecoveryDevice *first = [RecoveryDevice new], *second = [RecoveryDevice new];
    RecoveryLayer *layer = [RecoveryLayer layer];
    available = @[first];
    previous_next_drawable = (IMP)acquire;
    assert(enumerations == 0);
    if (!strcmp(scenario, "recover")) {
        assert(request(layer) != nil && layer.device == (id)first);
        assert(layer.deviceWrites == 1 && enumerations == 1);
        assert([mulg_graphics_render_geometry(layer)[@"metalDeviceRecovered"] boolValue]);
        assert(request(layer) != nil && layer.deviceWrites == 1 && enumerations == 1);
    } else if (!strcmp(scenario, "native")) {
        layer.device = (id)second;
        assert(request(layer) != nil && layer.device == (id)second && enumerations == 0);
        layer.device = nil;
        assert(request(layer) == nil && enumerations == 0);
    } else if (!strcmp(scenario, "multiple")) {
        available = @[first, second];
        assert(request(layer) == nil && layer.device == nil && layer.deviceWrites == 0 && enumerations == 1);
        assert(request(layer) == nil && enumerations == 1);
    } else if (!strcmp(scenario, "none")) {
        available = @[];
        assert(request(layer) == nil && enumerations == 1);
        assert(request(layer) == nil && enumerations == 1);
    } else if (!strcmp(scenario, "system")) {
        gameCaller = NO;
        assert(request(layer) == nil && layer.deviceWrites == 0 && enumerations == 0);
        gameCaller = YES;
        assert(request(layer) != nil && enumerations == 1);
    } else if (!strcmp(scenario, "concurrent-native")) {
        changedDuringEnumeration = layer; concurrentDevice = second;
        assert(request(layer) != nil && layer.device == (id)second && layer.deviceWrites == 1);
        assert(![mulg_graphics_render_geometry(layer)[@"metalDeviceRecovered"] boolValue]);
    } else if (!strcmp(scenario, "teardown")) {
        assert(request(layer) != nil && enumerations == 1);
        layer.device = nil;
        assert(request(layer) == nil && enumerations == 1 && layer.deviceWrites == 2);
    } else if (!strcmp(scenario, "layers")) {
        RecoveryLayer *other = [RecoveryLayer layer];
        assert(request(layer) != nil && request(other) != nil);
        assert(layer.device == (id)first && other.device == (id)first && enumerations == 2);
    } else if (!strcmp(scenario, "parallel")) {
        dispatch_apply(16, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
            @autoreleasepool { assert(request(layer) != nil); }
        });
        assert(enumerations == 1 && layer.deviceWrites == 1);
    } else { abort(); }
    printf("PASS: generic missing-device recovery %s\n", scenario);
    return 0;
}}