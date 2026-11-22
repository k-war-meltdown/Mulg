//
//  MulgTouchInjection.m
//  controls module: turns key and mouse actions into touches the game sees as real.
//
//  Ported from upstream PTFakeMetaTouch.m, UITouch-KIFAdditions.m and IOHIDEvent+KIF.m
//  (PTFakeTouch by PugaTang; KIF by Square, Inc.; FakeTouch by Watanabe Toshinori), with:
//  - the touch slot chosen under the lock (upstream read the slot count before locking);
//  - no category methods on UITouch (plain functions instead, so nothing can collide);
//  - at most 64 live touches enforced instead of assumed.
//
//  Delivery: desired contact state is batched into immutable main-run-loop snapshots.
//  Each contact has a unique lifetime token, its own UIKit owner and ordered transitions.
//

#import "MulgControlsHooks.h"
#include <TargetConditionals.h>

static __thread uint64_t input_arrival;
static __thread BOOL input_queued;
static void (^delivery_handler)(uint64_t, uint64_t);

void mulg_touch_set_input_timestamp(uint64_t arrival) {
    input_arrival = arrival;
    input_queued = NO;
}
BOOL mulg_touch_input_was_queued(void) { return input_queued; }
void mulg_touch_set_delivery_handler(void (^handler)(uint64_t, uint64_t)) {
    delivery_handler = [handler copy];
}
static void (^begin_handler)(NSInteger);  // main thread only
void mulg_touch_set_begin_handler(void (^handler)(NSInteger)) {
    begin_handler = [handler copy];
}

#if TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#include <math.h>
#include <dlfcn.h>
#include <objc/runtime.h>

// MARK: Private UIKit and IOKit interfaces (as upstream declared them)

typedef struct __IOHIDEvent *IOHIDEventRef;

@interface UITouch (MulgPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setIsTap:(BOOL)isTap;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)touchPhase;
- (void)setGestureView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)firstTouchForView;
- (void)_setHidEvent:(IOHIDEventRef)event;
@end

@interface UIEvent (MulgPrivate)
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_clearTouches;
- (void)_setHIDEvent:(IOHIDEventRef)event;
@end

@interface UIApplication (MulgPrivate)
- (UIEvent *)_touchesEvent;
@end

#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator, AbsoluteTime timeStamp, uint32_t type,
                                             uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
                                             IOHIDFloat x, IOHIDFloat y, IOHIDFloat z, IOHIDFloat tipPressure,
                                             IOHIDFloat barrelPressure, Boolean range, Boolean touch, uint32_t options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(CFAllocatorRef allocator, AbsoluteTime timeStamp,
                                                              uint32_t index, uint32_t identity, uint32_t eventMask,
                                                              IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
                                                              IOHIDFloat tipPressure, IOHIDFloat twist,
                                                              IOHIDFloat minorRadius, IOHIDFloat majorRadius,
                                                              IOHIDFloat quality, IOHIDFloat density,
                                                              IOHIDFloat irregularity, Boolean range, Boolean touch,
                                                              uint32_t options);
void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef childEvent);
void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int value);

static __typeof__(IOHIDEventCreateDigitizerEvent) *create_hand;
static __typeof__(IOHIDEventCreateDigitizerFingerEventWithQuality) *create_finger;
static __typeof__(IOHIDEventAppendEvent) *append_event;
static __typeof__(IOHIDEventSetIntegerValue) *set_integer;
static BOOL touch_accepts_tap_count;
static BOOL event_accepts_hid;
#define IOHIDEventCreateDigitizerEvent create_hand
#define IOHIDEventCreateDigitizerFingerEventWithQuality create_finger
#define IOHIDEventAppendEvent append_event
#define IOHIDEventSetIntegerValue set_integer

/// Runs inside mulg_touch_is_available's dispatch_once. NSMethodSignature throws on encodings it cannot
/// parse; an exception leaving the once block would crash the game or hang the next caller. A private
/// UIKit method that changed that way only switches touch injection off.
static BOOL method_matches(Class cls, NSString *name, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method) return NO;
    const char *types = method_getTypeEncoding(method);
    if (types == NULL) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
        if (signature == nil || strcmp(signature.methodReturnType, result) != 0
            || signature.numberOfArguments != arguments.count + 2) return NO;
        for (NSUInteger i = 0; i < arguments.count; i++) {
            const char *type = [signature getArgumentTypeAtIndex:i + 2];
            const char *expected = arguments[i].UTF8String;
            if (type == NULL || expected == NULL) return NO;
            // Opaque HID pointer layouts may differ, but the calling convention must stay a pointer.
            if (expected[0] == '^' ? type[0] != '^' : strcmp(type, expected) != 0) return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

BOOL mulg_touch_is_available(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *scope = RTLD_DEFAULT;
        create_hand = dlsym(scope, "IOHIDEventCreateDigitizerEvent");
        create_finger = dlsym(scope, "IOHIDEventCreateDigitizerFingerEventWithQuality");
        append_event = dlsym(scope, "IOHIDEventAppendEvent");
        set_integer = dlsym(scope, "IOHIDEventSetIntegerValue");
        available = create_hand && create_finger && append_event && set_integer;
        NSString *boolean = @(@encode(BOOL));
        NSArray *touchMethods = @[
            @[@"setWindow:", @[@"@"]], @[@"setView:", @[@"@"]], @[@"setIsTap:", @[boolean]],
            @[@"setTimestamp:", @[@"d"]], @[@"setPhase:", @[@(@encode(UITouchPhase))]],
            @[@"_setLocationInWindow:resetPrevious:", @[@(@encode(CGPoint)), boolean]],
            @[@"_setIsFirstTouchForView:", @[boolean]], @[@"_setHidEvent:", @[@"^"]]
        ];
        for (NSArray *entry in touchMethods) available &= method_matches(UITouch.class, entry[0], "v", entry[1]);
        touch_accepts_tap_count = method_matches(UITouch.class, @"setTapCount:", "v", @[@(@encode(NSUInteger))]);
        available &= method_matches(UIApplication.class, @"_touchesEvent", "@", @[]);
        Class touchesEvent = NSClassFromString(@"UITouchesEvent") ?: UIEvent.class;
        available &= method_matches(touchesEvent, @"_clearTouches", "v", @[]);
        available &= method_matches(touchesEvent, @"_addTouch:forDelayedDelivery:", "v", @[@"@", boolean]);
        event_accepts_hid = method_matches(touchesEvent, @"_setHIDEvent:", "v", @[@"^"]);
    });
    return available;
}

enum {
    kMulgDigitizerTransducerHand = 3,
    kMulgDigitizerEventRange = 1 << 0,
    kMulgDigitizerEventTouch = 1 << 1,
    kMulgDigitizerEventPosition = 1 << 2,
    kMulgEventTypeDigitizer = 11,
};
/// kIOHIDEventFieldDigitizerIsDisplayIntegrated: field 25 of the digitizer event type.
static const uint32_t kMulgFieldDigitizerIsDisplayIntegrated = (kMulgEventTypeDigitizer << 16) + 25;

// MARK: HID events

static AbsoluteTime mulg_now(void) {
    uint64_t now = mach_absolute_time();
    AbsoluteTime time;
    time.hi = (UInt32)(now >> 32);
    time.lo = (UInt32)now;
    return time;
}

/// A HID "hand" event with one finger per touch, whose flags match each touch's phase. Some
/// games check that the HID event agrees with UITouch.phase.
static char kContactIdentityKey;
static IOHIDEventRef mulg_hid_event(NSArray<UITouch *> *touches) CF_RETURNS_RETAINED {
    uint32_t handMask = 0;
    BOOL anyTouching = NO;
    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseBegan) handMask |= kMulgDigitizerEventRange | kMulgDigitizerEventTouch;
        else if (touch.phase == UITouchPhaseMoved) handMask |= kMulgDigitizerEventPosition;
        else if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) handMask |= kMulgDigitizerEventTouch;
        anyTouching |= touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled;
    }
    AbsoluteTime timestamp = mulg_now();
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, timestamp, kMulgDigitizerTransducerHand,
                                                        0, 0, handMask, 0, 0, 0, 0, 0, 0, anyTouching, anyTouching, 0);
    if (!hand) return NULL;
    IOHIDEventSetIntegerValue(hand, kMulgFieldDigitizerIsDisplayIntegrated, 1);
    for (UITouch *touch in touches) {
        uint32_t mask;
        Boolean touching;
        switch (touch.phase) {
            case UITouchPhaseMoved:
                mask = kMulgDigitizerEventPosition;
                touching = true;
                break;
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                mask = kMulgDigitizerEventTouch;
                touching = false;
                break;
            case UITouchPhaseStationary:
                mask = 0; // A held contact has no new position/range/touch transition.
                touching = true;
                break;
            default:
                mask = kMulgDigitizerEventRange | kMulgDigitizerEventTouch;
                touching = true;
                break;
        }
        CGPoint location = [touch locationInView:touch.window];
        uint32_t identity = [objc_getAssociatedObject(touch, &kContactIdentityKey) unsignedIntValue];
        IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
            kCFAllocatorDefault, timestamp, identity, identity, mask,
            (IOHIDFloat)location.x, (IOHIDFloat)location.y, 0, 0, 0, 5.0, 5.0, 1.0, 1.0, 1.0,
            touching, touching, 0);
        if (!finger) { CFRelease(hand); return NULL; }
        IOHIDEventSetIntegerValue(finger, kMulgFieldDigitizerIsDisplayIntegrated, 1);
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
    }
    return hand;
}

static UITouch *mulg_make_touch(CGPoint point, UIWindow *window, UIView *view, NSUInteger slot) {
    UITouch *touch = [[UITouch alloc] init];
    [touch setWindow:window];   // wipes other values, so it goes first
    if (touch_accepts_tap_count) [touch setTapCount:1];
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setView:view];
    [touch setPhase:UITouchPhaseBegan];
    // Always on a Mac: this is the branch upstream took for iOS apps on Mac.
    [touch _setIsFirstTouchForView:YES];
    [touch setIsTap:YES];
    [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
    if ([touch respondsToSelector:@selector(setGestureView:)]) {
        [touch setGestureView:view];
    }
    // Digitizer identity never aliases another contact in this process.
    objc_setAssociatedObject(touch, &kContactIdentityKey, @(slot + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return touch;
}

// MARK: Contact state and immutable delivery snapshots

/// Only the main thread owns this state. Input changes desired state, never a live UITouch.
/// A contact token is monotonically allocated and never aliases a newly created finger.
@interface MulgTouchContact : NSObject
@property NSInteger token;
@property (strong) UITouch *touch;
@property (strong) UIWindow *window;
@property (strong) UIView *view;
@property CGPoint beginPoint;
@property CGPoint desiredPoint;
@property CGPoint deliveredPoint;
@property BOOL beganDelivered;
@property BOOL beginInFlight;
@property BOOL movePending;
@property BOOL endPending;
@property UITouchPhase endPhase;
@property (strong) NSMutableSet<NSNumber *> *beginArrivals;
@property (strong) NSMutableSet<NSNumber *> *moveArrivals;
@property (strong) NSMutableSet<NSNumber *> *endArrivals;
@end
@implementation MulgTouchContact
@end

/// Captured before invoking game code: reentrant input cannot mutate an event being delivered.
@interface MulgTouchSample : NSObject
@property (strong) MulgTouchContact *contact;
@property CGPoint point;
@property UITouchPhase phase;
@property (strong) NSSet<NSNumber *> *arrivals;
@end
@implementation MulgTouchSample
@end

static NSMutableDictionary<NSNumber *, MulgTouchContact *> *mulg_contacts;
/// The last batches, for controls.json. Plain structs: delivery allocates nothing for diagnostics,
/// which are turned into dictionaries only when read (once a second).
enum { kHistoryBatches = 32, kHistoryContacts = 8 };
typedef struct {
    NSInteger token;
    UITouchPhase phase;
    CGPoint window, view, previousView;
} MulgHistoryContact;
typedef struct {
    uint64_t batch;
    NSTimeInterval uptime;
    NSUInteger count;  // contacts in the batch; the first kHistoryContacts are kept
    MulgHistoryContact contacts[kHistoryContacts];
} MulgHistoryBatch;
static MulgHistoryBatch mulg_history[kHistoryBatches];
static uint64_t mulg_history_total;
static CFRunLoopSourceRef mulg_source;
static NSInteger mulg_next_token = 1;
static BOOL mulg_delivering;
static uint64_t mulg_batch_count;
static uint64_t mulg_rejected_count;
static uint64_t mulg_coalesced_count;

static void mulg_signal(void) {
    if (!mulg_source) return;
    CFRunLoopSourceSignal(mulg_source);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static void record_arrival(NSMutableSet<NSNumber *> *arrivals) {
    input_queued = YES;
    if (input_arrival && delivery_handler && arrivals.count < 256) [arrivals addObject:@(input_arrival)];
}

static BOOL mulg_has_pending(void) {
    for (MulgTouchContact *contact in mulg_contacts.allValues) {
        if (!contact.beganDelivered || contact.movePending || contact.endPending) return YES;
    }
    return NO;
}

static BOOL mulg_begin_waits_for_end(MulgTouchContact *contact) {
    if (contact.beganDelivered) return NO;
    for (MulgTouchContact *other in mulg_contacts.allValues) {
        if (other != contact && other.view == contact.view && other.endPending && other.beganDelivered) return YES;
    }
    return NO;
}

static void mulg_deliver(void *info) {
    if (mulg_delivering || !mulg_has_pending()) return;
    mulg_delivering = YES;
    @try {
        NSMutableArray<MulgTouchSample *> *samples = [NSMutableArray array];
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        NSArray<NSNumber *> *tokens = [mulg_contacts.allKeys sortedArrayUsingSelector:@selector(compare:)];
        // Consume exactly one transition per contact. Began, moved and ended never collapse.
        for (NSNumber *token in tokens) {
            MulgTouchContact *contact = mulg_contacts[token];
            // Finish outgoing gestures before their replacements begin. A combined
            // old cancelled + new began event can retain a failed camera recognizer.
            if (mulg_begin_waits_for_end(contact)) continue;
            MulgTouchSample *sample = [MulgTouchSample new];
            sample.contact = contact;
            if (!contact.beganDelivered) {
                sample.phase = UITouchPhaseBegan;
                sample.point = contact.beginPoint;
                sample.arrivals = [contact.beginArrivals copy];
                [contact.beginArrivals removeAllObjects];
            } else if (contact.movePending) {
                sample.phase = UITouchPhaseMoved;
                sample.point = contact.desiredPoint;
                sample.arrivals = [contact.moveArrivals copy];
                [contact.moveArrivals removeAllObjects];
                contact.movePending = NO;
            } else if (contact.endPending) {
                sample.phase = contact.endPhase;
                sample.point = sample.phase == UITouchPhaseCancelled ? contact.deliveredPoint : contact.desiredPoint;
                sample.arrivals = [contact.endArrivals copy];
                [contact.endArrivals removeAllObjects];
            } else {
                sample.phase = UITouchPhaseStationary;
                sample.point = contact.deliveredPoint;
                sample.arrivals = [NSSet set];
            }
            [samples addObject:sample];
            if (![windows containsObject:contact.window]) [windows addObject:contact.window];
        }

        for (UIWindow *window in windows) {
            NSMutableArray<MulgTouchSample *> *group = [NSMutableArray arrayWithCapacity:samples.count];
            for (MulgTouchSample *sample in samples) {
                if (sample.contact.window == window && mulg_contacts[@(sample.contact.token)] == sample.contact) {
                    [group addObject:sample];
                }
            }
            BOOL changed = NO;
            for (MulgTouchSample *sample in group) changed |= sample.phase != UITouchPhaseStationary;
            if (!changed) continue;
            NSTimeInterval timestamp = NSProcessInfo.processInfo.systemUptime;
            UIEvent *event = [UIApplication.sharedApplication _touchesEvent];
            [event _clearTouches];
            NSMutableArray<UITouch *> *touches = [NSMutableArray array];
            NSMutableSet<NSNumber *> *arrivals = [NSMutableSet set];
            MulgHistoryBatch record = { .uptime = timestamp, .count = group.count };
            NSUInteger recorded = 0;
            for (MulgTouchSample *sample in group) {
                MulgTouchContact *contact = sample.contact;
                UITouch *touch = contact.touch;
                [touch setTimestamp:timestamp];
                // Previous location always means the last DELIVERED position, not the last
                // queued sample. Stationary fingers have zero delta in every event.
                BOOL reset = sample.phase == UITouchPhaseBegan || sample.phase == UITouchPhaseStationary;
                [touch _setLocationInWindow:sample.point resetPrevious:reset];
                [touch setPhase:sample.phase];
                if (sample.phase == UITouchPhaseBegan) contact.beginInFlight = YES;
                [event _addTouch:touch forDelayedDelivery:NO];
                [touches addObject:touch];
                [arrivals unionSet:sample.arrivals];
                if (recorded < kHistoryContacts) {
                    record.contacts[recorded++] = (MulgHistoryContact){ contact.token, sample.phase, sample.point,
                        [touch locationInView:contact.view], [touch previousLocationInView:contact.view] };
                }
            }
            // All fingers belong to the same digitizer hand snapshot, with stable identities.
            IOHIDEventRef hand = mulg_hid_event(touches);
            if (hand) {
                for (UITouch *touch in touches) [touch _setHidEvent:hand];
                if (event_accepts_hid) [event _setHIDEvent:hand];
                CFRelease(hand);
            }
            uint64_t delivered = mach_absolute_time();
            [UIApplication.sharedApplication sendEvent:event];
            mulg_batch_count++;
            for (MulgTouchSample *sample in group) {
                MulgTouchContact *contact = sample.contact;
                contact.deliveredPoint = sample.point;
                if (sample.phase == UITouchPhaseBegan) {
                    contact.beganDelivered = YES;
                    contact.beginInFlight = NO;
                    if (begin_handler) begin_handler(contact.token);
                }
                if (sample.phase == UITouchPhaseEnded || sample.phase == UITouchPhaseCancelled) {
                    [mulg_contacts removeObjectForKey:@(contact.token)];
                }
            }
            record.batch = mulg_batch_count;
            mulg_history[mulg_history_total++ % kHistoryBatches] = record;
            if (delivery_handler) {
                for (NSNumber *arrival in arrivals) delivery_handler(arrival.unsignedLongLongValue, delivered);
            }
        }
    } @finally {
        mulg_delivering = NO;
        if (mulg_has_pending()) mulg_signal();
    }
}

void mulg_touch_prepare(void) {
    if (!NSThread.isMainThread || !mulg_touch_is_available()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mulg_contacts = [NSMutableDictionary dictionary];
        CFRunLoopSourceContext context = {0};
        context.perform = mulg_deliver;
        mulg_source = CFRunLoopSourceCreate(NULL, -2, &context);
        CFRunLoopAddSource(CFRunLoopGetMain(), mulg_source, kCFRunLoopCommonModes);
    });
}

void mulg_touch_flush(void) {
    if (NSThread.isMainThread && mulg_source && !mulg_delivering) mulg_deliver(NULL);
}

NSInteger mulg_touch_inject(NSInteger touchID, CGPoint point, MulgTouchPhase phase, id window, id view) {
    if (!NSThread.isMainThread || !mulg_source || !isfinite(point.x) || !isfinite(point.y)) return -1;
    MulgTouchContact *contact;
    if (phase == MulgTouchPhaseBegan) {
        if (![window isKindOfClass:UIWindow.class] || mulg_contacts.count >= 64 || mulg_next_token >= UINT32_MAX) {
            mulg_rejected_count++;
            return -1;
        }
        contact = [MulgTouchContact new];
        contact.token = mulg_next_token++;
        contact.window = window;
        contact.view = view ?: window;
        contact.beginPoint = contact.desiredPoint = contact.deliveredPoint = point;
        contact.beginArrivals = [NSMutableSet set];
        contact.moveArrivals = [NSMutableSet set];
        contact.endArrivals = [NSMutableSet set];
        BOOL first = YES;
        for (MulgTouchContact *other in mulg_contacts.allValues) {
            if (other.view == contact.view && !other.endPending) { first = NO; break; }
        }
        contact.touch = mulg_make_touch(point, window, contact.view, (NSUInteger)contact.token - 1);
        [contact.touch _setIsFirstTouchForView:first];
        mulg_contacts[@(contact.token)] = contact;
        record_arrival(contact.beginArrivals);
    } else {
        contact = mulg_contacts[@(touchID)];
        if (!contact || contact.endPending) { mulg_rejected_count++; return -1; }
        if (phase == MulgTouchPhaseMoved) {
            if (CGPointEqualToPoint(point, contact.desiredPoint)) return touchID;
            if (contact.movePending) mulg_coalesced_count++;
            contact.desiredPoint = point;
            contact.movePending = YES;
            record_arrival(contact.moveArrivals);
        } else if (phase == MulgTouchPhaseEnded || phase == MulgTouchPhaseCancelled) {
            if (phase == MulgTouchPhaseCancelled && !contact.beganDelivered && !contact.beginInFlight) {
                // An origin discarded by resize/focus before delivery must never become a tap.
                [mulg_contacts removeObjectForKey:@(touchID)];
                input_queued = YES;
                return -1;
            }
            contact.endPending = YES;
            contact.endPhase = (UITouchPhase)phase;
            if (phase == MulgTouchPhaseEnded) contact.desiredPoint = point;
            if (phase == MulgTouchPhaseCancelled) {
                // Resizing/focus cancellation must not flush an obsolete camera delta.
                contact.movePending = NO;
                [contact.endArrivals unionSet:contact.moveArrivals];
                [contact.moveArrivals removeAllObjects];
            }
            record_arrival(contact.endArrivals);
        } else return touchID;
    }
    mulg_signal();
    return contact.endPending ? -1 : contact.token;
}

BOOL mulg_touch_begin_delivered(NSInteger touchID) {
    if (!NSThread.isMainThread) return NO;
    MulgTouchContact *contact = mulg_contacts[@(touchID)];
    return contact && contact.beganDelivered && !contact.endPending;
}

NSUInteger mulg_touch_live_count(void) {
    if (!NSThread.isMainThread) return 0;
    NSUInteger count = 0;
    for (MulgTouchContact *contact in mulg_contacts.allValues) if (!contact.endPending) count++;
    return count;
}

/// The recorded batches, oldest first, in the dictionaries controls.json has always shown.
static NSArray<NSDictionary *> *mulg_recent_batches(void) {
    NSMutableArray<NSDictionary *> *batches = [NSMutableArray arrayWithCapacity:kHistoryBatches];
    uint64_t first = mulg_history_total > kHistoryBatches ? mulg_history_total - kHistoryBatches : 0;
    for (uint64_t index = first; index < mulg_history_total; index++) {
        const MulgHistoryBatch *record = &mulg_history[index % kHistoryBatches];
        NSMutableArray<NSDictionary *> *contacts = [NSMutableArray arrayWithCapacity:record->count];
        for (NSUInteger i = 0; i < MIN(record->count, (NSUInteger)kHistoryContacts); i++) {
            const MulgHistoryContact *c = &record->contacts[i];
            [contacts addObject:@{@"id": @(c->token), @"phase": @(c->phase),
                @"windowX": @(c->window.x), @"windowY": @(c->window.y),
                @"viewX": @(c->view.x), @"viewY": @(c->view.y),
                @"previousViewX": @(c->previousView.x), @"previousViewY": @(c->previousView.y)}];
        }
        [batches addObject:@{@"batch": @(record->batch), @"uptime": @(record->uptime), @"contacts": contacts}];
    }
    return batches;
}

NSDictionary *mulg_touch_delivery_diagnostics(void) {
    if (!NSThread.isMainThread) return @{};
    return @{@"engine": @"snapshot-v2", @"batches": @(mulg_batch_count),
        @"rejected": @(mulg_rejected_count), @"coalescedMoves": @(mulg_coalesced_count),
        @"liveContacts": @(mulg_touch_live_count()), @"recentBatches": mulg_recent_batches()};
}

#else
void mulg_touch_prepare(void) {}
void mulg_touch_flush(void) {}
BOOL mulg_touch_is_available(void) { return NO; }
NSInteger mulg_touch_inject(NSInteger touchID, CGPoint point, MulgTouchPhase phase, id window, id view) { return -1; }
BOOL mulg_touch_begin_delivered(NSInteger touchID) { return NO; }
NSUInteger mulg_touch_live_count(void) { return 0; }
NSDictionary *mulg_touch_delivery_diagnostics(void) { return @{}; }
#endif
