#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MulgEngineHooks.h>
#include <assert.h>
#include <string.h>

@interface FixtureDevice : NSObject
- (NSString *)name;
@end
@implementation FixtureDevice
- (NSString *)name { return @"Actual Mac GPU"; }
@end
@interface OtherFixtureDevice : NSObject
- (NSString *)name;
@end
@implementation OtherFixtureDevice
- (NSString *)name { return @"Other Mac GPU"; }
@end
static NSUInteger deviceCreations;
static BOOL deviceUnavailable;
static id<MTLDevice> fixture_device(void) {
    if (deviceUnavailable) return nil;
    deviceCreations++;
    return (id<MTLDevice>)[FixtureDevice new];
}
static NSArray<id<MTLDevice>> *fixture_all_devices(void) {
    deviceCreations += 2;
    return @[(id)[FixtureDevice new], (id)[OtherFixtureDevice new]];
}
static BOOL gameCaller;
static BOOL identityActive = YES;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
int mulg_identity_is_active(void) { return identityActive; }
#define MTLCreateSystemDefaultDevice fixture_device
#define MTLCopyAllDevices fixture_all_devices
#include "../../../engine/Sources/MulgEngineHooks/MulgMetalDeviceHooks.m"
#undef MTLCopyAllDevices
#include "../../Sources/MulgIdentityHooks/MulgGPUNameHook.m"
#undef MTLCreateSystemDefaultDevice

int main(void) {
    @autoreleasepool {
        FixtureDevice *device = [FixtureDevice new];
        char configured[64];
        assert(mulg_identity_copy_gpu_name(configured, sizeof(configured)) == 0);
        assert(deviceCreations == 0);
        // Missing native devices pass through; registering identity creates no device itself.
        deviceUnavailable = YES;
        assert(mulg_create_default_device() == nil && deviceCreations == 0);
        deviceUnavailable = NO;
        int prepared = mulg_identity_install_gpu_name_hook("iPad GPU");
        assert(prepared == 0 || prepared == 1); // Native metadata may already include driver base classes.
        assert(deviceCreations == 0);
        device = (id)mulg_create_default_device();
        assert(device != nil);
        assert(mulg_identity_install_gpu_name_hook("iPad GPU") == 1);
        assert(deviceCreations == 1);
        // Configuration diagnostics must not create a Metal device or use the game getter.
        assert(mulg_identity_copy_gpu_name(configured, sizeof(configured)) == 1);
        assert(strcmp(configured, "iPad GPU") == 0);
        assert(mulg_identity_copy_gpu_name(configured, 1) == 0);
        assert(deviceCreations == 1);
        assert([device.name isEqualToString:@"Actual Mac GPU"]);
        gameCaller = YES;
        assert([device.name isEqualToString:@"iPad GPU"]);
        gameCaller = NO;
        assert(mulg_identity_install_gpu_name_hook("Another iPad GPU") == 1);
        assert(mulg_identity_copy_gpu_name(configured, sizeof(configured)) == 1);
        assert(strcmp(configured, "Another iPad GPU") == 0);
        assert(deviceCreations == 1);
        assert([device.name isEqualToString:@"Actual Mac GPU"]);
        gameCaller = YES;
        assert([device.name isEqualToString:@"Another iPad GPU"]);
        NSArray *all = mulg_copy_all_devices();
        assert(all.count == 2 && deviceCreations == 3);
        OtherFixtureDevice *other = all[1];
        assert([other.name isEqualToString:@"Another iPad GPU"]);
        gameCaller = NO;
        assert([other.name isEqualToString:@"Other Mac GPU"]);
        assert([device.name isEqualToString:@"Actual Mac GPU"]);
        identityActive = NO;
        assert(mulg_identity_copy_gpu_name(configured, sizeof(configured)) == 0);
        assert([device.name isEqualToString:@"Actual Mac GPU"]);
        assert([other.name isEqualToString:@"Other Mac GPU"]);
        puts("PASS: lazy GPU identity creates no device, preserves factory results and per-class native names");
    }
}
