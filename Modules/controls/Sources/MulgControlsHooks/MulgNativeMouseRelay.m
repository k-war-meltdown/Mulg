#import "MulgControlsHooks.h"
#import <MulgEngineHooks.h>
#import <GameController/GameController.h>
#include <stdatomic.h>
#include <pthread.h>

// A game may bind only GCMouse.current during startup. Another already-connected
// HID collection can later become current without a connect notification. Borrow
// only empty movement slots; buttons, scroll, native UI and independent owners stay native.
typedef struct {
    void *isa;
    int flags, reserved;
    void (*invoke)(void *, ...);
} MulgMouseBlockLayout;

static BOOL game_mouse_handler(GCMouseMoved handler) {
    if (!handler) return NO;
    const MulgMouseBlockLayout *block = (__bridge const void *)handler;
    return mulg_engine_is_game_caller((const void *)block->invoke);
}

@interface MulgMouseMotionRelay : NSObject {
@public
    _Atomic(BOOL) active;
}
@property(nonatomic, weak) GCMouse *owner;
@property(nonatomic, weak) GCMouseInput *target;
@property(nonatomic, copy) GCMouseMoved callback;
@end
@implementation MulgMouseMotionRelay
@end

static NSMutableArray<MulgMouseMotionRelay *> *motion_relays; // main thread only
static NSMutableArray<id> *mouse_observers;
static BOOL mouse_relay_running, mouse_reconcile_pending;
static _Atomic(uint64_t) forwarded_moves;

static void remove_motion_relay(MulgMouseMotionRelay *relay) {
    atomic_store_explicit(&relay->active, NO, memory_order_release);
    GCMouseInput *target = relay.target;
    // A game/native interface can take this slot after us. Never clear its handler.
    if (target && target.mouseMovedHandler == relay.callback) target.mouseMovedHandler = nil;
    [motion_relays removeObjectIdenticalTo:relay];
}

static void reconcile_mouse_sources(void) {
    if (!mouse_relay_running) return;
    NSArray<GCMouse *> *mice = GCMouse.mice;
    GCMouse *owner = nil;
    NSUInteger owners = 0;
    for (GCMouse *mouse in mice) {
        if (game_mouse_handler(mouse.mouseInput.mouseMovedHandler)) { owner = mouse; owners++; }
    }
    // Multiple explicit owners mean the game already has its own device routing.
    for (MulgMouseMotionRelay *relay in motion_relays.copy) {
        BOOL connected = NO;
        for (GCMouse *mouse in mice) connected |= mouse.mouseInput == relay.target;
        if (owners != 1 || relay.owner != owner || !connected
            || relay.target.mouseMovedHandler != relay.callback) remove_motion_relay(relay);
    }
    if (owners != 1 || mice.count < 2) return;
    for (GCMouse *mouse in mice) {
        GCMouseInput *input = mouse.mouseInput;
        if (!input || mouse == owner || input.mouseMovedHandler || input.valueDidChangeHandler) continue;
        MulgMouseMotionRelay *relay = [MulgMouseMotionRelay new];
        relay.owner = owner; relay.target = input;
        atomic_store_explicit(&relay->active, YES, memory_order_release);
        __weak MulgMouseMotionRelay *weakRelay = relay;
        relay.callback = ^(GCMouseInput *source, float dx, float dy) {
            MulgMouseMotionRelay *current = weakRelay;
            if (!current || !atomic_load_explicit(&current->active, memory_order_acquire)) return;
            GCMouse *receiver = current.owner;
            if (!receiver) return;
            dispatch_queue_t queue = receiver.handlerQueue;
            void (^deliver)(void) = ^{
                if (!atomic_load_explicit(&current->active, memory_order_acquire)) return;
                GCMouseInput *profile = receiver.mouseInput;
                GCMouseMoved handler = profile.mouseMovedHandler;
                // Fetch at delivery time: a cleared/replaced game callback is never replayed.
                if (!game_mouse_handler(handler)) return;
                atomic_fetch_add_explicit(&forwarded_moves, 1, memory_order_relaxed);
                handler(profile, dx, dy);
            };
            if (queue == dispatch_get_main_queue() && pthread_main_np()) deliver();
            else if (queue) dispatch_async(queue, deliver);
        };
        [motion_relays addObject:relay];
        input.mouseMovedHandler = relay.callback;
    }
}

static void schedule_mouse_reconciliation(void) {
    if (!mouse_relay_running || mouse_reconcile_pending) return;
    mouse_reconcile_pending = YES;
    // Let the game's own connection callback finish before examining its handler slots.
    dispatch_async(dispatch_get_main_queue(), ^{
        mouse_reconcile_pending = NO;
        reconcile_mouse_sources();
    });
}

void mulg_controls_start_native_mouse_relay(void) {
    if (mouse_relay_running) { reconcile_mouse_sources(); return; }
    mouse_relay_running = YES;
    motion_relays = [NSMutableArray array];
    mouse_observers = [NSMutableArray array];
    for (NSString *name in @[GCMouseDidConnectNotification, GCMouseDidDisconnectNotification,
                            GCMouseDidBecomeCurrentNotification]) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { schedule_mouse_reconciliation(); }];
        [mouse_observers addObject:token];
    }
    reconcile_mouse_sources();
    schedule_mouse_reconciliation();
}

void mulg_controls_stop_native_mouse_relay(void) {
    mouse_relay_running = NO;
    for (id token in mouse_observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [mouse_observers removeAllObjects];
    for (MulgMouseMotionRelay *relay in motion_relays.copy) remove_motion_relay(relay);
}

NSDictionary<NSString *, NSNumber *> *mulg_controls_native_mouse_relay_report(void) {
    return @{@"running": @(mouse_relay_running), @"connectedMice": @(GCMouse.mice.count),
             @"borrowedMovementSources": @(motion_relays.count),
             @"forwardedMovementCallbacks": @(atomic_load_explicit(&forwarded_moves, memory_order_relaxed))};
}
