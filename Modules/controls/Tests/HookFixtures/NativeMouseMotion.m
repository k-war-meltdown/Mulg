#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <MulgEngineHooks.h>
#include <assert.h>

@class FixtureMouseInput;
typedef void (^FixtureMoved)(FixtureMouseInput *, float, float);
@interface FixtureMouseInput : NSObject
@property(nonatomic, copy) FixtureMoved mouseMovedHandler;
@property(nonatomic, strong) id valueDidChangeHandler;
@end
@implementation FixtureMouseInput
@end

@interface FixtureMouse : NSObject
@property(nonatomic, strong) FixtureMouseInput *mouseInput;
@property(nonatomic, strong) dispatch_queue_t handlerQueue;
+ (NSArray<FixtureMouse *> *)mice;
@end
static NSArray<FixtureMouse *> *connected_mice;
@implementation FixtureMouse
+ (NSArray<FixtureMouse *> *)mice { return connected_mice; }
- (instancetype)init {
    if ((self = [super init])) { _mouseInput = [FixtureMouseInput new]; _handlerQueue = dispatch_get_main_queue(); }
    return self;
}
@end

static const void *game_invoke;
BOOL mulg_engine_is_game_caller(const void *caller) { return caller == game_invoke; }
#define GCMouse FixtureMouse
#define GCMouseInput FixtureMouseInput
#define GCMouseMoved FixtureMoved
#include "../../Sources/MulgControlsHooks/MulgNativeMouseRelay.m"
#undef GCMouse
#undef GCMouseInput
#undef GCMouseMoved

int main(void) {
    @autoreleasepool {
        FixtureMouse *owner = [FixtureMouse new], *unbound = [FixtureMouse new], *native = [FixtureMouse new];
        connected_mice = @[owner, unbound, native];
        __block int game_calls = 0, native_calls = 0;
        __block float last_dx = 0, last_dy = 0;
        FixtureMoved game = ^(FixtureMouseInput *profile, float dx, float dy) {
            assert(profile == owner.mouseInput);
            game_calls++; last_dx = dx; last_dy = dy;
        };
        game_invoke = (const void *)((__bridge const MulgMouseBlockLayout *)game)->invoke;
        owner.mouseInput.mouseMovedHandler = game;
        FixtureMoved framework = ^(FixtureMouseInput *profile, float dx, float dy) { native_calls++; };
        native.mouseInput.mouseMovedHandler = framework;

        mulg_controls_start_native_mouse_relay();
        assert(unbound.mouseInput.mouseMovedHandler);
        assert(native.mouseInput.mouseMovedHandler == framework);
        assert(owner.mouseInput.mouseMovedHandler == game);
        assert([mulg_controls_native_mouse_relay_report()[@"borrowedMovementSources"] intValue] == 1);
        unbound.mouseInput.mouseMovedHandler(unbound.mouseInput, 7, -3);
        assert(game_calls == 1 && last_dx == 7 && last_dy == -3);
        assert([mulg_controls_native_mouse_relay_report()[@"forwardedMovementCallbacks"] intValue] == 1);
        assert(native_calls == 0);

        // An unrelated aggregate native handler must not be borrowed.
        FixtureMouse *aggregate = [FixtureMouse new];
        aggregate.mouseInput.valueDidChangeHandler = [NSObject new];
        connected_mice = @[owner, unbound, native, aggregate];
        mulg_controls_start_native_mouse_relay();
        assert(aggregate.mouseInput.mouseMovedHandler == nil);

        // Live callback clearing cannot leave a retained stale game callback in a relay.
        owner.mouseInput.mouseMovedHandler = nil;
        unbound.mouseInput.mouseMovedHandler(unbound.mouseInput, 9, 9);
        assert(game_calls == 1);
        owner.mouseInput.mouseMovedHandler = game;

        // A later native/game registration on the borrowed slot remains its owner.
        unbound.mouseInput.mouseMovedHandler = game;
        mulg_controls_start_native_mouse_relay();
        assert(unbound.mouseInput.mouseMovedHandler == game);
        assert([mulg_controls_native_mouse_relay_report()[@"borrowedMovementSources"] intValue] == 0);
        unbound.mouseInput.mouseMovedHandler = nil;
        mulg_controls_start_native_mouse_relay();
        FixtureMoved stale = unbound.mouseInput.mouseMovedHandler;
        mulg_controls_stop_native_mouse_relay();
        assert(unbound.mouseInput.mouseMovedHandler == nil);
        assert(owner.mouseInput.mouseMovedHandler == game);
        assert(native.mouseInput.mouseMovedHandler == framework);
        stale(unbound.mouseInput, 4, 4);
        assert(game_calls == 1);

        // Forwarding retains the registered device queue, not the donor's main queue.
        dispatch_queue_t game_queue = dispatch_queue_create("fixture.game.mouse", DISPATCH_QUEUE_SERIAL);
        dispatch_semaphore_t completed = dispatch_semaphore_create(0);
        owner.handlerQueue = game_queue;
        mulg_controls_start_native_mouse_relay();
        unbound.mouseInput.mouseMovedHandler(unbound.mouseInput, 11, -6);
        dispatch_async(game_queue, ^{ dispatch_semaphore_signal(completed); });
        assert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert(game_calls == 2 && last_dx == 11 && last_dy == -6);
        mulg_controls_stop_native_mouse_relay();
        assert(unbound.mouseInput.mouseMovedHandler == nil);

        // Queued motion must be cancelled if shutdown happens before its delivery.
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        dispatch_async(game_queue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
        mulg_controls_start_native_mouse_relay();
        unbound.mouseInput.mouseMovedHandler(unbound.mouseInput, 99, 99);
        mulg_controls_stop_native_mouse_relay();
        dispatch_semaphore_signal(gate);
        dispatch_async(game_queue, ^{ dispatch_semaphore_signal(completed); });
        assert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        assert(game_calls == 2);

        // Removing a disconnected donor only clears the adapter's own callback.
        owner.handlerQueue = dispatch_get_main_queue();
        mulg_controls_start_native_mouse_relay();
        assert(unbound.mouseInput.mouseMovedHandler);
        connected_mice = @[owner, native];
        mulg_controls_start_native_mouse_relay();
        assert(unbound.mouseInput.mouseMovedHandler == nil);
        assert(native.mouseInput.mouseMovedHandler == framework);
        mulg_controls_stop_native_mouse_relay();
        puts("PASS: native mouse motion relay ownership, late registrations, queue, disconnection and shutdown");
    }
}
