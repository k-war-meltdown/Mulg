#import "MulgEngineHooks.h"
#import <objc/message.h>
#include <TargetConditionals.h>
#include <stdlib.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIApplication.h>
#import <UIKit/UIScene.h>
#endif

// UIKit's lifecycle notifications also drive UIKitMacHelper's private state machine.
// Broadcasting a fallback foreground notification moves that state machine ahead of the
// real scene transition, so the next native foreground notification asserts and aborts.
// Keep native registrations and delivery intact. Remember only callbacks implemented in
// the game's images, and send fallback events directly to those callbacks.

@interface MulgLifecycleObserver : NSObject
@property(nonatomic, weak) NSNotificationCenter *center;
@property(nonatomic, weak) id observer;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, weak) id filteredObject;
@property(nonatomic) BOOL hasObjectFilter;
@property(nonatomic) SEL selector;
@property(nonatomic, strong) NSOperationQueue *queue;
@property(nonatomic, copy) void (^block)(NSNotification *);
@property(nonatomic) BOOL cancelled;
@property(nonatomic, weak) NSOperation *lastQueuedDelivery;
- (void)deliver:(NSNotification *)notification;
- (void)enqueue:(NSNotification *)notification;
@end

static BOOL game_callback(Class cls, SEL selector, IMP implementation) {
    if (mulg_engine_is_game_caller((const void *)implementation)) return YES;
    // Lifecycle policy wrappers remain game-owned for fallback dispatch and tracking.
    IMP original = mulg_swizzle_original(cls, selector, implementation);
    return original && mulg_engine_is_game_caller((const void *)original);
}

@implementation MulgLifecycleObserver
- (void)enqueue:(NSNotification *)notification {
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{ [self deliver:notification]; }];
    @synchronized (self) {
        if (_cancelled) return;
        // Concurrent observer queues may otherwise deliver background before an
        // earlier foreground callback finishes, leaving the engine in stale state.
        NSOperation *previous = _lastQueuedDelivery;
        if (previous && !previous.finished) [operation addDependency:previous];
        _lastQueuedDelivery = operation;
    }
    [_queue addOperation:operation];
}
- (void)deliver:(NSNotification *)notification {
    id target;
    void (^block)(NSNotification *);
    @synchronized (self) {
        if (_cancelled) return;
        target = _observer;
        block = _block;
    }
    if (!target) return;
    if (block) {
        block(notification);
    } else if ([target respondsToSelector:_selector]) {
        // Recheck ownership in case another plugin changed the callback after registration.
        IMP implementation = class_getMethodImplementation(object_getClass(target), _selector);
        if (game_callback(object_getClass(target), _selector, implementation)) {
            ((void (*)(id, SEL, NSNotification *))objc_msgSend)(target, _selector, notification);
        }
    }
}
@end

static NSMutableArray<MulgLifecycleObserver *> *gameObservers;
static IMP originalAddSelector, originalAddBlock, originalRemove, originalRemoveMatching;
static MulgGameNotificationTransform gameNotificationTransform;

BOOL mulg_engine_set_game_notification_transform(MulgGameNotificationTransform transform) {
    if (transform && !mulg_engine_install_lifecycle_notifications()) return NO;
    @synchronized ([MulgLifecycleObserver class]) { gameNotificationTransform = [transform copy]; }
    return YES;
}

int mulg_engine_install_lifecycle_delegate_hooks(void) {
#if TARGET_OS_IPHONE
    int count = objc_getClassList(NULL, 0);
    static int checkedClassCount;
    if (count <= 0 || count == checkedClassCount) return 0;
    Class __unsafe_unretained *classes = (Class __unsafe_unretained *)calloc((size_t)count, sizeof(Class));
    if (!classes) return 0;
    int found = objc_getClassList(classes, count);
    int installed = 0;
    SEL selectors[] = {
        sel_registerName("applicationWillResignActive:"),
        sel_registerName("applicationDidEnterBackground:"),
        sel_registerName("sceneWillResignActive:"),
        sel_registerName("sceneDidEnterBackground:")
    };
    for (int index = 0; index < count && index < found; index++) {
        Class cls = classes[index];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int method = 0; method < methodCount; method++) {
            SEL selector = method_getName(methods[method]);
            BOOL suspend = NO;
            for (NSUInteger target = 0; target < sizeof(selectors) / sizeof(selectors[0]); target++) {
                suspend |= selector == selectors[target];
            }
            if (!suspend) continue;
            IMP original = method_getImplementation(methods[method]);
            if (!mulg_engine_is_game_caller((const void *)original)) continue;
            // Inspect registered metadata only; no game +initialize during runtime startup.
            // UIKit retains its own lifecycle. A game told it is still active must not enter
            // its synchronous suspend/wait path, which can stop the main input run loop.
            IMP replacement = imp_implementationWithBlock(^(id delegate, id object) {
                if (mulg_engine_keeps_game_active()) return;
                ((void (*)(id, SEL, id))original)(delegate, selector, object);
            });
            if (mulg_swizzle_checked_owned("engine", cls, selector, replacement, NULL,
                    @encode(void), @[@"@"]) == MulgSwizzleResultReplaced) installed++;
            else imp_removeBlock(replacement);
        }
        free(methods);
    }
    free(classes);
    if (found <= count) checkedClassCount = found;
    return installed;
#else
    return 0;
#endif
}

void mulg_engine_call_game_lifecycle_delegate(id delegate, SEL selector, id object) {
    if (!delegate || ![delegate respondsToSelector:selector]) return;
    IMP implementation = class_getMethodImplementation(object_getClass(delegate), selector);
    if (game_callback(object_getClass(delegate), selector, implementation)) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, selector, object);
    }
}

static BOOL lifecycle_name(NSString *name) {
#if TARGET_OS_IPHONE
    static NSArray<NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification,
                  UIApplicationWillEnterForegroundNotification, UIApplicationDidBecomeActiveNotification,
                  UISceneWillDeactivateNotification, UISceneDidEnterBackgroundNotification,
                  UISceneWillEnterForegroundNotification, UISceneDidActivateNotification,
                  UISceneDidDisconnectNotification];
    });
    return [names containsObject:name];
#else
    return NO; // There is no UIKit lifecycle in the native macOS host.
#endif
}

static BOOL alive(MulgLifecycleObserver *entry) {
    return entry.center && entry.observer && (!entry.hasObjectFilter || entry.filteredObject);
}

static void remember_observer(MulgLifecycleObserver *entry) {
    @synchronized ([MulgLifecycleObserver class]) {
        if (!gameObservers) gameObservers = [NSMutableArray array];
        NSIndexSet *stale = [gameObservers indexesOfObjectsPassingTest:^BOOL(MulgLifecycleObserver *item, NSUInteger index, BOOL *stop) {
            return !alive(item);
        }];
        [gameObservers removeObjectsAtIndexes:stale];
        [gameObservers addObject:entry];
    }
}

static void add_selector(NSNotificationCenter *center, SEL cmd, id observer, SEL selector, NSString *name, id object) {
    ((void (*)(id, SEL, id, SEL, NSString *, id))originalAddSelector)(center, cmd, observer, selector, name, object);
    if ((name && !lifecycle_name(name)) || !observer || !selector) return;
    IMP callback = class_getMethodImplementation(object_getClass(observer), selector);
    if (!game_callback(object_getClass(observer), selector, callback)) return;
    MulgLifecycleObserver *entry = [MulgLifecycleObserver new];
    entry.center = center; entry.observer = observer; entry.selector = selector;
    entry.name = name; entry.filteredObject = object; entry.hasObjectFilter = object != nil;
    remember_observer(entry);
}

// The public Blocks ABI prefix locates the callback's image. Registration caller checks
// alone are insufficient: a game's interception of addObserver can also register Apple code.
typedef struct {
    void *isa;
    int flags, reserved;
    void (*invoke)(void *, ...);
} MulgLifecycleBlockLayout;

static id add_block(NSNotificationCenter *center, SEL cmd, NSString *name, id object,
                    NSOperationQueue *queue, void (^block)(NSNotification *)) {
    const MulgLifecycleBlockLayout *layout = (__bridge const void *)block;
    BOOL game = block && mulg_engine_is_game_caller((const void *)layout->invoke);
    MulgGameNotificationTransform transform = nil;
    if (game) {
        @synchronized ([MulgLifecycleObserver class]) { transform = gameNotificationTransform; }
    }
    MulgNotificationHandler delivered = game && transform ? transform(name, block) : block;
    id token = ((id (*)(id, SEL, NSString *, id, NSOperationQueue *, id))originalAddBlock)(center, cmd, name, object, queue, delivered);
    if (!game) return token;
    if (!block || !token || (name && !lifecycle_name(name))) return token;
    MulgLifecycleObserver *entry = [MulgLifecycleObserver new];
    entry.center = center; entry.observer = token; entry.block = block; entry.queue = queue;
    entry.name = name; entry.filteredObject = object; entry.hasObjectFilter = object != nil;
    remember_observer(entry);
    return token;
}

static void forget_observer(NSNotificationCenter *center, id observer, NSString *name, id object) {
    @synchronized ([MulgLifecycleObserver class]) {
        NSIndexSet *removed = [gameObservers indexesOfObjectsPassingTest:^BOOL(MulgLifecycleObserver *entry, NSUInteger index, BOOL *stop) {
            BOOL matches = entry.center == center && entry.observer == observer
                && (!name || !entry.name || [entry.name isEqualToString:name])
                && (!object || !entry.hasObjectFilter || entry.filteredObject == object);
            if (matches) { @synchronized (entry) { entry.cancelled = YES; } }
            return matches || !alive(entry);
        }];
        [gameObservers removeObjectsAtIndexes:removed];
    }
}

static void remove_observer(NSNotificationCenter *center, SEL cmd, id observer) {
    forget_observer(center, observer, nil, nil);
    ((void (*)(id, SEL, id))originalRemove)(center, cmd, observer);
}

static void remove_matching(NSNotificationCenter *center, SEL cmd, id observer, NSString *name, id object) {
    forget_observer(center, observer, name, object);
    ((void (*)(id, SEL, id, NSString *, id))originalRemoveMatching)(center, cmd, observer, name, object);
}

BOOL mulg_engine_install_lifecycle_notifications(void) {
    // Removal must be hooked before remembering registrations, including block tokens.
    Class cls = [NSNotificationCenter class];
    MulgSwizzleResult remove = mulg_swizzle_checked_owned("engine", cls, @selector(removeObserver:),
        (IMP)remove_observer, &originalRemove, @encode(void), @[@"@"]);
    MulgSwizzleResult matching = mulg_swizzle_checked_owned("engine", cls, @selector(removeObserver:name:object:),
        (IMP)remove_matching, &originalRemoveMatching, @encode(void), @[@"@", @"@", @"@"]);
    if (remove != MulgSwizzleResultReplaced || matching != MulgSwizzleResultReplaced) return NO;
    MulgSwizzleResult selector = mulg_swizzle_checked_owned("engine", cls, @selector(addObserver:selector:name:object:),
        (IMP)add_selector, &originalAddSelector, @encode(void), @[@"@", @":", @"@", @"@"]);
    MulgSwizzleResult block = mulg_swizzle_checked_owned("engine", cls, @selector(addObserverForName:object:queue:usingBlock:),
        (IMP)add_block, &originalAddBlock, @encode(id), @[@"@", @"@", @"@", @"@?"]);
    return selector == MulgSwizzleResultReplaced && block == MulgSwizzleResultReplaced;
}

void mulg_engine_notify_game_lifecycle(NSNotificationName name, id object) {
    if (!lifecycle_name(name)) return;
    NSArray<MulgLifecycleObserver *> *snapshot;
    @synchronized ([MulgLifecycleObserver class]) { snapshot = [gameObservers copy]; }
    NSNotification *notification = [NSNotification notificationWithName:name object:object
        userInfo:@{@"MulgSyntheticLifecycle": @YES}];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (MulgLifecycleObserver *entry in snapshot) {
        if (entry.center != center || !alive(entry) || (entry.name && ![entry.name isEqualToString:name])
            || (entry.hasObjectFilter && entry.filteredObject != object)) continue;
        if (!entry.queue || entry.queue == [NSOperationQueue currentQueue]
            || (entry.queue == [NSOperationQueue mainQueue] && [NSThread isMainThread])) {
            [entry deliver:notification];
        } else {
            [entry enqueue:notification];
        }
    }
}
