#import <MulgEngineHooks.h>
#include <assert.h>
BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
IMP mulg_swizzle_original(Class cls, SEL selector, IMP replacement) { return NULL; }
MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner, Class cls, SEL selector, IMP replacement,
    IMP *previous, const char *returnType, NSArray<NSString *> *arguments) { return MulgSwizzleResultMethodMissing; }
BOOL mulg_engine_keeps_game_active(void) { return NO; }
#include "../../Sources/MulgEngineHooks/MulgLifecycleNotifications.m"

int main(void) { @autoreleasepool {
    NSNotificationCenter *center = [NSNotificationCenter new];
    NSObject *observer = [NSObject new], *object = [NSObject new];
    MulgLifecycleObserver *entry = [MulgLifecycleObserver new];
    entry.center = center; entry.observer = observer; // Wildcard name and object.
    remember_observer(entry);
    forget_observer(center, observer, @"specific", nil);
    assert(entry.cancelled && gameObservers.count == 0);
    entry = [MulgLifecycleObserver new];
    entry.center = center; entry.observer = observer; entry.name = @"specific";
    remember_observer(entry);
    forget_observer(center, observer, @"specific", object);
    assert(entry.cancelled && gameObservers.count == 0);
    entry = [MulgLifecycleObserver new];
    entry.center = center; entry.observer = observer; entry.name = @"other";
    entry.filteredObject = object; entry.hasObjectFilter = YES;
    remember_observer(entry);
    forget_observer(center, observer, @"specific", object);
    assert(!entry.cancelled && gameObservers.count == 1);
    forget_observer(center, observer, nil, nil);
    assert(entry.cancelled && gameObservers.count == 0);
    puts("PASS: removed wildcard lifecycle registrations cannot fire again; unrelated registrations survive");
} }
