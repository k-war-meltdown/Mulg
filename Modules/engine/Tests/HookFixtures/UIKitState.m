#import <MulgEngineHooks.h>
#import <Foundation/Foundation.h>
#include <assert.h>
static BOOL gameCaller = YES;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
@interface UIApplication : NSObject
- (NSInteger)applicationState;
@end
@implementation UIApplication
- (NSInteger)applicationState { return 0; }
@end
@interface UIScene : NSObject
- (NSInteger)activationState;
@end
@implementation UIScene
- (NSInteger)activationState { return 0; }
@end
@interface UIView : NSObject
@property(nonatomic) NSInteger layouts;
- (void)layoutSubviews;
@end
@implementation UIView
- (void)layoutSubviews { self.layouts++; }
@end
int main(void) { @autoreleasepool {
    __block int observed = 0;
    MulgEngineUIKitHook installed = mulg_engine_install_uikit_hooks(^(id view) { observed++; });
    assert(installed == (MulgEngineUIKitHookApplicationState | MulgEngineUIKitHookSceneState | MulgEngineUIKitHookViewLayout));
    UIApplication *app = [UIApplication new]; UIScene *scene = [UIScene new], *other = [UIScene new];
    mulg_engine_set_lifecycle_state(app, 2); mulg_engine_set_lifecycle_state(scene, 1);
    assert(app.applicationState == 2 && scene.activationState == 1 && other.activationState == 0);
    gameCaller = NO;
    assert(app.applicationState == 0 && scene.activationState == 0);
    assert(mulg_engine_effective_lifecycle_state(scene, @selector(activationState)) == 1);
    gameCaller = YES;
    mulg_engine_clear_lifecycle_state(app); mulg_engine_clear_lifecycle_state(scene);
    assert(app.applicationState == 0 && scene.activationState == 0);
    UIView *view = [UIView new]; [view layoutSubviews]; assert(view.layouts == 1 && observed == 1);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [view layoutSubviews]; dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(view.layouts == 2 && observed == 1);
    puts("PASS: effective app/scene state, native caller passthrough and main-thread layout publication");
    return 0;
} }
