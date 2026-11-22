#import "MulgControlsHooks.h"
#import <GameController/GameController.h>
#import <MulgEngineHooks.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <objc/runtime.h>
#include <string.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

@interface MulgGameContact : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic) CGPoint point;
@property(nonatomic) CGPoint previousPoint;
@property(nonatomic) BOOL ended;
@end

@implementation MulgGameContact
- (NSInteger)type { return UITouchTypeDirect; }
- (CGPoint)locationInView:(UIView *)view {
    return view ? [view convertPoint:self.point fromView:self.view] : [self.view convertPoint:self.point toView:nil];
}
- (CGPoint)previousLocationInView:(UIView *)view {
    return view ? [view convertPoint:self.previousPoint fromView:self.view]
                : [self.view convertPoint:self.previousPoint toView:nil];
}
- (CGFloat)force { return 1; }
- (CGFloat)maximumPossibleForce { return 1; }
@end

static SEL game_touch_selector(void) { return @selector(HandleTouches:ofType:); }
static _Atomic(uint64_t) game_touch_candidates, game_touch_matches;
static _Atomic(uint64_t) game_touch_begins, game_touch_moves, game_touch_ends;

static IMP game_touch_implementation(id view) {
    if (![view isKindOfClass:UIView.class]) return NULL;
    Method method = class_getInstanceMethod(object_getClass(view), game_touch_selector());
    if (!method) return NULL;
    IMP implementation = method_getImplementation(method);
    if (!implementation || !mulg_engine_is_game_caller((const void *)implementation)) return NULL;
    const char *types = method_getTypeEncoding(method);
    if (!types) return NULL;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
        if (!signature || signature.numberOfArguments != 4 || strcmp(signature.methodReturnType, "v")
            || strcmp([signature getArgumentTypeAtIndex:2], "@")
            || strcmp([signature getArgumentTypeAtIndex:3], "i")) return NULL;
    } @catch (NSException *exception) { return NULL; }
    return implementation;
}

BOOL mulg_controls_game_touch_capable(id view) {
    atomic_fetch_add(&game_touch_candidates, 1);
    BOOL capable = game_touch_implementation(view) != NULL;
    if (capable) atomic_fetch_add(&game_touch_matches, 1);
    return capable;
}

static BOOL deliver_game_touch(MulgGameContact *contact, int phase) {
    UIView *view = contact.view;
    IMP implementation = game_touch_implementation(view);
    if (!implementation) return NO;
    ((void (*)(id, SEL, id, int))implementation)(view, game_touch_selector(), [NSSet setWithObject:contact], phase);
    if (phase == 0) atomic_fetch_add(&game_touch_begins, 1);
    else if (phase == 1) atomic_fetch_add(&game_touch_moves, 1);
    else if (phase == 2) atomic_fetch_add(&game_touch_ends, 1);
    return YES;
}

NSObject *mulg_controls_game_touch_begin(id view, CGPoint point) {
    if (!NSThread.isMainThread || !isfinite(point.x) || !isfinite(point.y)
        || !game_touch_implementation(view)) return nil;
    MulgGameContact *contact = [MulgGameContact new];
    contact.view = view; contact.point = point; contact.previousPoint = point;
    return deliver_game_touch(contact, 0) ? contact : nil;
}

void mulg_controls_game_touch_move(NSObject *contact, CGPoint point) {
    if (!NSThread.isMainThread || ![contact isKindOfClass:MulgGameContact.class]) return;
    MulgGameContact *touch = contact;
    if (touch.ended || !isfinite(point.x) || !isfinite(point.y) || CGPointEqualToPoint(point, touch.point)) return;
    touch.previousPoint = touch.point; touch.point = point;
    deliver_game_touch(touch, 1);
}

void mulg_controls_game_touch_end(NSObject *contact, CGPoint point) {
    if (!NSThread.isMainThread || ![contact isKindOfClass:MulgGameContact.class]) return;
    MulgGameContact *touch = contact;
    if (touch.ended) return;
    touch.ended = YES;
    if (isfinite(point.x) && isfinite(point.y)) {
        touch.previousPoint = touch.point; touch.point = point;
    }
    deliver_game_touch(touch, 2);
}

void mulg_controls_game_touch_cancel(NSObject *contact) {
    if (![contact isKindOfClass:MulgGameContact.class]) return;
    MulgGameContact *touch = contact;
    mulg_controls_game_touch_end(touch, touch.point);
}
NSDictionary *mulg_controls_game_touch_report(void) {
    return @{@"candidateChecks": @(atomic_load(&game_touch_candidates)),
             @"compatibleViews": @(atomic_load(&game_touch_matches)),
             @"beganCalls": @(atomic_load(&game_touch_begins)),
             @"movedCalls": @(atomic_load(&game_touch_moves)),
             @"endedCalls": @(atomic_load(&game_touch_ends))};
}
#else
BOOL mulg_controls_game_touch_capable(id view) { return NO; }
NSObject *mulg_controls_game_touch_begin(id view, CGPoint point) { return nil; }
void mulg_controls_game_touch_move(NSObject *contact, CGPoint point) {}
void mulg_controls_game_touch_end(NSObject *contact, CGPoint point) {}
void mulg_controls_game_touch_cancel(NSObject *contact) {}
NSDictionary *mulg_controls_game_touch_report(void) { return @{}; }
#endif

// A stable device for TFT's single-mouse registration. The public snapshot supplies
// actual GameController elements; setters update state but do not invoke callbacks.
// No game addresses, device drivers, UITouch objects or global device notifications.
@interface MulgMouseProfile : GCMouseInput
@property(nonatomic, strong) GCController *snapshot;
@property(nonatomic, weak) id<GCDevice> mouse;
@property(atomic) NSTimeInterval eventTime;
@property(atomic, copy) GCMouseMoved moved;
@property(atomic, copy) void (^changed)(__kindof GCPhysicalInputProfile *, GCControllerElement *);
@end

@implementation MulgMouseProfile
- (instancetype)init {
    if ((self = [super init])) _snapshot = [GCController controllerWithExtendedGamepad];
    return self;
}
- (id<GCDevice>)device { return self.mouse; }
- (NSTimeInterval)lastEventTimestamp { return self.eventTime; }
- (instancetype)capture {
    MulgMouseProfile *copy = [MulgMouseProfile new];
    copy.snapshot = [self.snapshot capture]; copy.mouse = self.mouse; copy.eventTime = self.eventTime;
    return copy;
}
- (void)setStateFromPhysicalInput:(GCPhysicalInputProfile *)profile {
    if (![profile isKindOfClass:MulgMouseProfile.class]) return;
    MulgMouseProfile *other = (MulgMouseProfile *)profile;
    [self.snapshot.extendedGamepad setStateFromPhysicalInput:other.snapshot.extendedGamepad];
    self.eventTime = other.eventTime;
}
- (GCMouseMoved)mouseMovedHandler { return self.moved; }
- (void)setMouseMovedHandler:(GCMouseMoved)handler { self.moved = handler; }
- (void (^)(__kindof GCPhysicalInputProfile *, GCControllerElement *))valueDidChangeHandler { return self.changed; }
- (void)setValueDidChangeHandler:(void (^)(__kindof GCPhysicalInputProfile *, GCControllerElement *))handler { self.changed = handler; }
- (GCControllerButtonInput *)leftButton { return self.snapshot.extendedGamepad.buttonA; }
- (GCControllerButtonInput *)rightButton { return self.snapshot.extendedGamepad.buttonB; }
- (GCControllerButtonInput *)middleButton { return self.snapshot.extendedGamepad.buttonX; }
- (NSArray *)auxiliaryButtons { return @[self.snapshot.extendedGamepad.leftShoulder, self.snapshot.extendedGamepad.rightShoulder]; }
- (GCControllerDirectionPad *)scroll { return self.snapshot.extendedGamepad.leftThumbstick; }
- (NSDictionary *)buttons {
    return @{@"Left Button":self.leftButton, @"Right Button":self.rightButton,
             @"Middle Button":self.middleButton};
}
- (NSDictionary *)axes { return @{@"Scroll X":self.scroll.xAxis, @"Scroll Y":self.scroll.yAxis}; }
- (NSDictionary *)elements {
    NSMutableDictionary *values = [self.buttons mutableCopy];
    [values addEntriesFromDictionary:self.axes]; values[@"Scroll Wheel"] = self.scroll;
    return values;
}
- (NSSet *)allButtons { return [NSSet setWithArray:[self.buttons.allValues arrayByAddingObjectsFromArray:self.auxiliaryButtons]]; }
- (NSSet *)allAxes { return [NSSet setWithArray:self.axes.allValues]; }
- (NSSet *)allDpads { return [NSSet setWithObject:self.scroll]; }
- (NSSet *)allTouchpads { return [NSSet set]; }
- (id)objectForKeyedSubscript:(NSString *)key { return self.elements[key]; }
@end

@interface MulgMouseDevice : GCMouse {
@public
    _Atomic(BOOL) active;
    _Atomic(uint64_t) epoch, moves, buttons, scrolls;
}
@property(nonatomic, strong) MulgMouseProfile *profile;
@property(atomic, strong) dispatch_queue_t requestedQueue;
@property(atomic, strong) dispatch_queue_t deliveryQueue;
@end
@implementation MulgMouseDevice
- (instancetype)init {
    if ((self = [super init])) {
        _profile = [MulgMouseProfile new]; _profile.mouse = self;
        self.handlerQueue = dispatch_get_main_queue();
        atomic_store(&active, YES);
    }
    return self;
}
- (GCMouseInput *)mouseInput { return self.profile; }
- (GCPhysicalInputProfile *)physicalInputProfile { return self.profile; }
- (NSString *)vendorName { return @"Mulg TFT Mouse"; }
- (NSString *)productCategory { return GCProductCategoryMouse; }
- (dispatch_queue_t)handlerQueue { return self.requestedQueue; }
- (void)setHandlerQueue:(dispatch_queue_t)queue {
    queue = queue ?: dispatch_get_main_queue();
    // Serial delivery retains press/release ordering even if the game supplies a concurrent queue.
    dispatch_queue_t delivery = dispatch_queue_create("io.mulg.controls.tft-mouse", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(delivery, queue);
    self.requestedQueue = queue; self.deliveryQueue = delivery;
}
@end

static os_unfair_lock virtual_mouse_lock = OS_UNFAIR_LOCK_INIT;
static MulgMouseDevice *virtual_mouse;
static MulgMouseDevice *mouse_snapshot(void) {
    os_unfair_lock_lock(&virtual_mouse_lock);
    MulgMouseDevice *mouse = virtual_mouse;
    os_unfair_lock_unlock(&virtual_mouse_lock);
    return mouse;
}

BOOL mulg_controls_uses_tft_mouse(NSString *identifier) {
    // App updates retain their bundle identity; regional suffixes remain in the TFT family.
    NSString *base = @"com.riotgames.league.teamfighttactics";
    return [identifier isEqualToString:base] || [identifier hasPrefix:[base stringByAppendingString:@"."]];
}

id mulg_controls_virtual_mouse_device(void) {
    MulgMouseDevice *mouse = mouse_snapshot();
    return mouse && atomic_load(&mouse->active) ? mouse : nil;
}

// Keep the virtual device stable when a physical HID collection connects, disconnects
// or becomes current. Only TFT's registrations are wrapped; Apple/native observers
// continue receiving the original device and notification on their original queue.
static MulgNotificationHandler mouse_observer(NSString *name, MulgNotificationHandler handler) {
    MulgMouseDevice *mouse = mouse_snapshot();
    BOOL connection = [name isEqual:GCMouseDidConnectNotification] || [name isEqual:GCMouseDidBecomeCurrentNotification];
    BOOL removal = [name isEqual:GCMouseDidDisconnectNotification] || [name isEqual:GCMouseDidStopBeingCurrentNotification];
    if (!mouse || (!connection && !removal)) return handler;
    void (^wrapped)(NSNotification *) = ^(NSNotification *note) {
        id current = mulg_controls_virtual_mouse_device();
        if (!current) { handler(note); return; }
        if (removal) return; // The virtual mouse does not disconnect with a physical endpoint.
        handler([NSNotification notificationWithName:note.name object:current userInfo:note.userInfo]);
    };
    return wrapped;
}

BOOL mulg_controls_prepare_tft_mouse(NSString *identifier) {
    if (!mulg_controls_uses_tft_mouse(identifier)) return NO;
    if (mouse_snapshot()) return YES;
    MulgMouseDevice *mouse = [MulgMouseDevice new];
    if (!mouse.profile.snapshot.extendedGamepad || mulg_controls_install_mouse_device_hooks() != 2) return NO;
    if (!mulg_engine_set_game_notification_transform(^MulgNotificationHandler(NSString *name, MulgNotificationHandler handler) {
        return mouse_observer(name, handler);
    })) return NO;
    os_unfair_lock_lock(&virtual_mouse_lock); virtual_mouse = mouse; os_unfair_lock_unlock(&virtual_mouse_lock);
    return YES;
}

static void deliver(MulgMouseDevice *mouse, void (^action)(MulgMouseProfile *)) {
    uint64_t epoch = atomic_load(&mouse->epoch);
    void (^work)(void) = ^{
        if (!atomic_load(&mouse->active) || epoch != atomic_load(&mouse->epoch)) return;
        mouse.profile.eventTime = NSProcessInfo.processInfo.systemUptime;
        action(mouse.profile);
    };
    if (mouse.handlerQueue == dispatch_get_main_queue() && pthread_main_np()) work();
    else dispatch_async(mouse.deliveryQueue, work);
}

BOOL mulg_controls_tft_mouse_move(float dx, float dy) {
    MulgMouseDevice *mouse = mouse_snapshot();
    if (!mouse || !isfinite(dx) || !isfinite(dy) || !mouse.profile.mouseMovedHandler) return NO;
    deliver(mouse, ^(MulgMouseProfile *profile) {
        GCMouseMoved callback = profile.mouseMovedHandler;
        if (callback) { callback(profile, dx, dy); atomic_fetch_add(&mouse->moves, 1); }
    });
    return YES;
}

static GCControllerButtonInput *button_for(MulgMouseProfile *profile, NSInteger button) {
    switch (button) {
        case 0: return profile.leftButton;
        case 1: return profile.rightButton;
        case 2: return profile.middleButton;
        case 3: case 4: return profile.auxiliaryButtons[button - 3];
        default: return nil;
    }
}
static void change_button(MulgMouseProfile *profile, GCControllerButtonInput *button, BOOL pressed) {
    if (button.isPressed == pressed) return;
    float value = pressed ? 1 : 0;
    [button setValue:value];
    GCControllerButtonValueChangedHandler changed = button.valueChangedHandler;
    GCControllerButtonValueChangedHandler transition = button.pressedChangedHandler;
    GCControllerButtonTouchedChangedHandler touched = button.touchedChangedHandler;
    if (changed) changed(button, value, pressed);
    if (transition) transition(button, value, pressed);
    if (touched) touched(button, value, pressed, pressed);
    if (profile.valueDidChangeHandler) profile.valueDidChangeHandler(profile, button);
}
BOOL mulg_controls_tft_mouse_button(NSInteger number, BOOL pressed) {
    MulgMouseDevice *mouse = mouse_snapshot();
    GCControllerButtonInput *button = mouse ? button_for(mouse.profile, number) : nil;
    if (!button || (!button.pressedChangedHandler && !button.valueChangedHandler
        && !button.touchedChangedHandler && !mouse.profile.valueDidChangeHandler)) return NO;
    deliver(mouse, ^(MulgMouseProfile *profile) {
        change_button(profile, button, pressed); atomic_fetch_add(&mouse->buttons, 1);
    });
    return YES;
}
BOOL mulg_controls_tft_mouse_scroll(float dx, float dy) {
    MulgMouseDevice *mouse = mouse_snapshot();
    if (!mouse || !isfinite(dx) || !isfinite(dy) || (!mouse.profile.scroll.valueChangedHandler && !mouse.profile.scroll.xAxis.valueChangedHandler
        && !mouse.profile.scroll.yAxis.valueChangedHandler && !mouse.profile.valueDidChangeHandler)) return NO;
    deliver(mouse, ^(MulgMouseProfile *profile) {
        // The element's public storage is normalized, but the callback preserves wheel deltas.
        [profile.scroll setValueForXAxis:fmaxf(-1, fminf(1, dx)) yAxis:fmaxf(-1, fminf(1, dy))];
        GCControllerDirectionPadValueChangedHandler callback = profile.scroll.valueChangedHandler;
        if (callback) callback(profile.scroll, dx, dy);
        if (profile.scroll.xAxis.valueChangedHandler) profile.scroll.xAxis.valueChangedHandler(profile.scroll.xAxis, dx);
        if (profile.scroll.yAxis.valueChangedHandler) profile.scroll.yAxis.valueChangedHandler(profile.scroll.yAxis, dy);
        if (profile.valueDidChangeHandler) profile.valueDidChangeHandler(profile, profile.scroll);
        atomic_fetch_add(&mouse->scrolls, 1);
        [profile.scroll setValueForXAxis:0 yAxis:0];
    });
    return YES;
}

void mulg_controls_cancel_tft_mouse(void) {
    MulgMouseDevice *mouse = mouse_snapshot();
    if (!mouse) return;
    atomic_fetch_add(&mouse->epoch, 1); // Pending presses cannot escape after focus/editing changes.
    deliver(mouse, ^(MulgMouseProfile *profile) {
        for (NSInteger number = 0; number < 5; number++) change_button(profile, button_for(profile, number), NO);
    });
}
void mulg_controls_stop_tft_mouse(void) {
    os_unfair_lock_lock(&virtual_mouse_lock);
    MulgMouseDevice *mouse = virtual_mouse; virtual_mouse = nil;
    os_unfair_lock_unlock(&virtual_mouse_lock);
    if (mouse) { atomic_store(&mouse->active, NO); atomic_fetch_add(&mouse->epoch, 1); }
}
NSDictionary *mulg_controls_tft_mouse_report(void) {
    MulgMouseDevice *mouse = mouse_snapshot();
    if (!mouse) return @{@"active": @NO};
    return @{@"active": @YES, @"motionHandler": @(mouse.profile.mouseMovedHandler != nil),
        @"leftButtonHandler": @(mouse.profile.leftButton.pressedChangedHandler != nil || mouse.profile.leftButton.valueChangedHandler != nil),
        @"movementCallbacks": @(atomic_load(&mouse->moves)), @"buttonCallbacks": @(atomic_load(&mouse->buttons)),
        @"scrollCallbacks": @(atomic_load(&mouse->scrolls))};
}
