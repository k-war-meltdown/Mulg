#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>
#include <assert.h>

@interface FixtureController : NSObject
+ (NSArray *)controllers;
+ (instancetype)current;
@end
@implementation FixtureController
+ (NSArray *)controllers { return @[]; }
+ (instancetype)current { return nil; }
@end
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#define GCController FixtureController
#include "../../Sources/MulgControlsHooks/MulgControllerHooks.m"
#undef GCController

int main(void) {
    @autoreleasepool {
        assert(mulg_controller_install_hooks() == 2);
        dispatch_apply(2000, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            @autoreleasepool {
                mulg_controller_set_virtual(index % 2 ? [FixtureController new] : nil);
                NSArray *controllers = FixtureController.controllers;
                assert(controllers.count <= 1);
                for (id controller in controllers) assert([controller isKindOfClass:FixtureController.class]);
                id current = FixtureController.current;
                assert(current == nil || [current isKindOfClass:FixtureController.class]);
            }
        });
        mulg_controller_set_virtual(nil);
        assert(FixtureController.controllers.count == 0 && FixtureController.current == nil);
        puts("PASS: concurrent controller replacement and polling retain safe snapshots");
    }
}
