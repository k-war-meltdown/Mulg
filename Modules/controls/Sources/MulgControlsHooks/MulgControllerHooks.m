//
//  MulgControllerHooks.m
//  controls module: makes the virtual controller visible to the game (PLAN.md §14.1).
//
//  The controller itself is an ordinary GCController made with Apple's public
//  +controllerWithExtendedGamepad; its buttons and sticks are set from Swift. These hooks only
//  add it to the lists the game reads (+controllers, +current) and announce it the way a real
//  controller connects.
//

#import "MulgControlsHooks.h"
#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <GameController/GameController.h>
#import <MulgEngineHooks.h>
#include <os/lock.h>
#include <stdatomic.h>
static _Atomic(uint64_t) game_controller_reads;
uint64_t mulg_controller_game_read_count(void) { return atomic_load(&game_controller_reads); }

typedef id (*ClassGetter)(id, SEL);

static IMP previous_controllers;
static IMP previous_current;
static GCController *mulg_virtual_controller;
static GCController *announced_controller;
static uint64_t controller_generation;
static os_unfair_lock controller_lock = OS_UNFAIR_LOCK_INIT;

static GCController *virtual_controller_snapshot(void) {
    os_unfair_lock_lock(&controller_lock);
    GCController *controller = mulg_virtual_controller;
    os_unfair_lock_unlock(&controller_lock);
    return controller;
}

static id mulg_controllers(id cls, SEL _cmd) {
    if (mulg_engine_is_game_caller(__builtin_return_address(0))) atomic_fetch_add(&game_controller_reads, 1);
    NSArray<GCController *> *real = ((ClassGetter)previous_controllers)(cls, _cmd);
    GCController *virtualController = virtual_controller_snapshot();
    if (virtualController == nil || [real containsObject:virtualController]) {
        return real;
    }
    return [(real ?: @[]) arrayByAddingObject:virtualController];
}

static id mulg_current(id cls, SEL _cmd) {
    if (mulg_engine_is_game_caller(__builtin_return_address(0))) atomic_fetch_add(&game_controller_reads, 1);
    GCController *real = ((ClassGetter)previous_current)(cls, _cmd);
    return real ?: virtual_controller_snapshot();
}

void mulg_controller_set_virtual(id controller) {
    os_unfair_lock_lock(&controller_lock);
    __attribute__((objc_precise_lifetime)) GCController *retired = mulg_virtual_controller;
    mulg_virtual_controller = controller;
    uint64_t generation = ++controller_generation;
    os_unfair_lock_unlock(&controller_lock);
    (void)retired; // Release a replaced controller outside the shared lock.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Startup snapshot -> connected native controller -> disconnect may all happen
        // before this queue drains. Announce only the current desired device.
        os_unfair_lock_lock(&controller_lock);
        if (generation != controller_generation) { os_unfair_lock_unlock(&controller_lock); return; }
        GCController *old = announced_controller;
        if (old != controller) announced_controller = nil;
        os_unfair_lock_unlock(&controller_lock);
        if (old != nil && old != controller) {
            [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:old];
        }
        // Notification handlers can themselves replace/disconnect the virtual device.
        os_unfair_lock_lock(&controller_lock);
        BOOL current = generation == controller_generation;
        if (current) announced_controller = controller;
        os_unfair_lock_unlock(&controller_lock);
        if (current && controller != nil && controller != old) {
            [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:controller];
            if (@available(iOS 14.0, *)) {
                GCController *native = previous_current
                    ? ((ClassGetter)previous_current)(GCController.class, @selector(current)) : GCController.current;
                os_unfair_lock_lock(&controller_lock);
                current = generation == controller_generation;
                os_unfair_lock_unlock(&controller_lock);
                // Match +current: a physical/native controller keeps its precedence.
                if (current && (native == nil || native == controller))
                    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidBecomeCurrentNotification
                                                                      object:controller];
            }
        }
    });
}

int mulg_controller_install_hooks(void) {
    int count = 0;
    Class cls = [GCController class];
    if (mulg_swizzle_class_owned("controls", cls, @selector(controllers), (IMP)mulg_controllers, &previous_controllers)
        == MulgSwizzleResultReplaced) {
        count += 1;
    }
    if (mulg_swizzle_class_owned("controls", cls, @selector(current), (IMP)mulg_current, &previous_current)
        == MulgSwizzleResultReplaced) {
        count += 1;
    }
    return count;
}

#else

uint64_t mulg_controller_game_read_count(void) { return 0; }
void mulg_controller_set_virtual(id controller) {}

int mulg_controller_install_hooks(void) {
    return 0;
}

#endif
