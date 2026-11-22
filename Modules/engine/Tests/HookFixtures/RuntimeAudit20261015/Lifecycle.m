#import <MulgEngineHooks.h>
#include <assert.h>
BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
IMP mulg_swizzle_original(Class cls, SEL selector, IMP replacement) { return NULL; }
MulgSwizzleResult mulg_swizzle_checked_owned(const char *owner, Class cls, SEL selector, IMP replacement,
    IMP *previous, const char *returnType, NSArray<NSString *> *arguments) { return MulgSwizzleResultMethodMissing; }
BOOL mulg_engine_keeps_game_active(void) { return NO; }
// __PRODUCTION__
int main(void) { @autoreleasepool {
    NSOperationQueue *queue = [NSOperationQueue new]; queue.suspended = YES; queue.maxConcurrentOperationCount = 4;
    NSObject *token = [NSObject new];
    MulgLifecycleObserver *entry = [MulgLifecycleObserver new];
    entry.center = NSNotificationCenter.defaultCenter; entry.observer = token; entry.queue = queue;
    NSMutableArray *events = [NSMutableArray new];
    entry.block = ^(NSNotification *note) { @synchronized (events) { [events addObject:note.name]; } };
    remember_observer(entry);
    mulg_engine_notify_game_lifecycle(@"foreground", nil);
    mulg_engine_notify_game_lifecycle(@"active", nil);
    mulg_engine_notify_game_lifecycle(@"background", nil);
    NSUInteger dependent = 0;
    for (NSOperation *operation in queue.operations) if (operation.dependencies.count) dependent++;
    assert(dependent == 2); // A pending predecessor must finish before either newer transition.
    queue.suspended = NO; [queue waitUntilAllOperationsAreFinished];
    assert(([events isEqual:@[@"foreground", @"active", @"background"]]));
    queue.suspended = YES;
    mulg_engine_notify_game_lifecycle(@"cancelled", nil);
    forget_observer(entry.center, token, nil, nil);
    queue.suspended = NO; [queue waitUntilAllOperationsAreFinished];
    assert(events.count == 3);
    puts("PASS: concurrent observer queues preserve lifecycle order and cancellation");
} }
