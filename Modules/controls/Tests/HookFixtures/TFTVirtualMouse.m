#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <MulgEngineHooks.h>
#include <assert.h>
static BOOL game_caller;
BOOL mulg_engine_is_game_caller(const void *caller) { return game_caller; }
int mulg_controls_install_mouse_device_hooks(void) { return 2; }
#include "../../Sources/MulgControlsHooks/MulgVirtualMouse.m"

int main(void) { @autoreleasepool {
    // Reproduce actual runtime order: the engine already owns notification registration.
    assert(mulg_engine_install_lifecycle_notifications());
    assert(!mulg_controls_prepare_tft_mouse(@"com.example.game"));
    assert(!mulg_controls_uses_tft_mouse(@"com.riotgames.league.teamfighttacticsOther"));
    assert(mulg_controls_uses_tft_mouse(@"com.riotgames.league.teamfighttactics.kr"));
    assert(mulg_controls_prepare_tft_mouse(@"com.riotgames.league.teamfighttactics"));
    assert(mulg_controls_prepare_tft_mouse(@"com.riotgames.league.teamfighttactics"));
    for (NSDictionary *report in mulg_hook_installation_reports()) {
        assert(![report[@"target"] isEqual:@"-NSNotificationCenter.addObserverForName:object:queue:usingBlock:"]
               || ([report[@"owner"] isEqual:@"engine"] && [report[@"result"] integerValue] == MulgSwizzleResultReplaced));
    }
    GCMouse *mouse = mulg_controls_virtual_mouse_device();
    GCMouseInput *profile = mouse.mouseInput;
    assert(profile.device == mouse && mouse.physicalInputProfile == profile);
    __block int movements = 0, presses = 0, values = 0, wheels = 0;
    profile.mouseMovedHandler = ^(GCMouseInput *p, float x, float y) {
        assert(p == profile && x == 2 && y == -3); movements++;
    };
    assert(mulg_controls_tft_mouse_move(2, -3) && movements == 1);
    profile.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float value, BOOL pressed) {
        assert(b == profile.leftButton && b.isPressed == pressed && value == pressed); presses++;
    };
    profile.leftButton.valueChangedHandler = ^(GCControllerButtonInput *b, float value, BOOL pressed) { values++; };
    assert(mulg_controls_tft_mouse_button(0, YES));
    assert(presses == 1 && values == 1 && profile.leftButton.isPressed);
    assert(mulg_controls_tft_mouse_button(0, YES) && presses == 1);
    assert([profile capture].leftButton.isPressed);
    mulg_controls_cancel_tft_mouse();
    assert(presses == 2 && values == 2 && !profile.leftButton.isPressed);
    profile.scroll.valueChangedHandler = ^(GCControllerDirectionPad *d, float x, float y) {
        assert(x == 4 && y == -7); wheels++;
    };
    assert(mulg_controls_tft_mouse_scroll(4, -7) && wheels == 1);
    assert(!mulg_controls_tft_mouse_button(99, YES));

    // Native observers keep the physical device; game observers keep the virtual one.
    NSNotificationCenter *center = [NSNotificationCenter new];
    NSObject *physical = [NSObject new];
    __block int native = 0, game = 0, removals = 0;
    game_caller = NO;
    id nativeToken = [center addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        assert(n.object == physical); native++;
    }];
    game_caller = YES;
    id gameToken = [center addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        assert(n.object == mouse); game++;
    }];
    id removeToken = [center addObserverForName:GCMouseDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { removals++; }];
    game_caller = NO;
    [center postNotificationName:GCMouseDidConnectNotification object:physical];
    [center postNotificationName:GCMouseDidDisconnectNotification object:physical];
    assert(native == 1 && game == 1 && removals == 0);
    [center removeObserver:nativeToken]; [center removeObserver:gameToken]; [center removeObserver:removeToken];

    // Respect a caller's queue, serialize transitions, and cancel pending input.
    dispatch_queue_t queue = dispatch_queue_create("fixture.mouse", DISPATCH_QUEUE_SERIAL);
    static int queueKey;
    dispatch_queue_set_specific(queue, &queueKey, &queueKey, NULL);
    mouse.handlerQueue = queue;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block int queued = 0;
    profile.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float value, BOOL pressed) {
        assert(dispatch_get_specific(&queueKey) == &queueKey);
        assert(pressed == (queued == 0)); queued++;
        if (queued == 2) dispatch_semaphore_signal(finished);
    };
    assert(mulg_controls_tft_mouse_button(1, YES));
    assert(mulg_controls_tft_mouse_button(1, NO));
    assert(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    dispatch_sync(((MulgMouseDevice *)mouse).deliveryQueue, ^{});
    dispatch_suspend(queue);
    assert(mulg_controls_tft_mouse_button(1, YES));
    mulg_controls_cancel_tft_mouse();
    dispatch_resume(queue);
    dispatch_sync(((MulgMouseDevice *)mouse).deliveryQueue, ^{});
    assert(queued == 2 && !profile.rightButton.isPressed);
    dispatch_suspend(queue);
    assert(mulg_controls_tft_mouse_button(1, YES));
    mulg_controls_stop_tft_mouse();
    dispatch_resume(queue);
    dispatch_sync(((MulgMouseDevice *)mouse).deliveryQueue, ^{});
    assert(queued == 2 && !mulg_controls_virtual_mouse_device());
    puts("PASS: identity, inline callbacks, paired buttons, raw scroll, observer isolation, queue order and cancellation");
} }
