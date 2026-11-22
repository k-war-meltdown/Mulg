#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#define UIView NSView
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>
#include <assert.h>
#import <objc/runtime.h>
#include <string.h>

static BOOL game_caller;
static id virtual_device;
id mulg_controls_virtual_mouse_device(void) { return virtual_device; }
BOOL mulg_engine_is_game_caller(const void *caller) { return game_caller; }
BOOL mulg_touch_is_available(void) { return NO; }
@interface FixtureMouse : NSObject
+ (instancetype)current;
+ (NSArray *)mice;
@end
static FixtureMouse *connected;
@implementation FixtureMouse
+ (instancetype)current { return connected; }
+ (NSArray *)mice { return connected ? @[connected] : @[]; }
@end
static Class fixture_class(const char *name) {
    return strcmp(name, "GCMouse") == 0 ? FixtureMouse.class : objc_getClass(name);
}
@interface FixtureMotion : NSObject
@property(nonatomic) NSTimeInterval accelerometerUpdateInterval, deviceMotionUpdateInterval, gyroUpdateInterval;
@end
@implementation FixtureMotion
@end
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#define objc_getClass fixture_class
#define CMMotionManager FixtureMotion
#include "../../Sources/MulgControlsHooks/MulgControlsCompatHooks.m"
#undef objc_getClass
#undef CMMotionManager

int main(void) { @autoreleasepool {
    connected = [FixtureMouse new];
    assert(mulg_controls_install_compat_hooks(YES, NO) == 2);
    assert(mulg_controls_install_compat_hooks(YES, NO) == 2); // Repeated installation preserves the originals.
    assert(FixtureMouse.current == connected && FixtureMouse.mice.count == 1);
    game_caller = YES;
    assert(FixtureMouse.current == nil && FixtureMouse.mice.count == 0);
    virtual_device = [NSObject new];
    assert(FixtureMouse.current == virtual_device && FixtureMouse.mice.firstObject == virtual_device);
    game_caller = NO;
    assert(FixtureMouse.current == connected && FixtureMouse.mice.firstObject == connected);
    virtual_device = nil;
    connected = nil;
    assert(FixtureMouse.current == nil);
    connected = [FixtureMouse new];
    assert(FixtureMouse.current == connected && FixtureMouse.mice.count == 1);
    puts("PASS: wrapper sees connected and reconnected mice while game getters remain hidden");
} }
