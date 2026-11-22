#import "MulgIntegrationsHooks.h"
#import <MulgEngineHooks.h>
#import <TargetConditionals.h>
#include <stdatomic.h>

#if TARGET_OS_MACCATALYST || TARGET_OS_IOS
#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>

static atomic_bool enabled = false;
// These blocks are published and used on main only.
static NSObject * (^gameAnchor)(void);
static void (^reportEvent)(NSString *, NSString *, NSString *, NSInteger);
static char presentationKey, delegateKey, attemptKey;
static NSLock *sessionLock;
static NSMutableDictionary<NSUUID *, ASWebAuthenticationSession *> *sessions;
static id webSchemeInit(id self, SEL cmd, NSURL *url, NSString *scheme, ASWebAuthenticationSessionCompletionHandler completion);
static id webCallbackInit(id self, SEL cmd, NSURL *url, ASWebAuthenticationSessionCallback *callback, ASWebAuthenticationSessionCompletionHandler completion);

static void emit(NSString *provider, NSString *state, NSError *error) {
    if (!atomic_load(&enabled)) return;
    NSString *domain = nil;
    if ([error.domain isEqual:ASAuthorizationErrorDomain]
        || [error.domain isEqual:ASWebAuthenticationSessionErrorDomain]) domain = error.domain;
    NSInteger code = error.code;
    void (^deliver)(void) = ^{
        if (atomic_load(&enabled) && reportEvent) reportEvent(provider, state, domain, code);
    };
    if (NSThread.isMainThread) deliver(); else dispatch_async(dispatch_get_main_queue(), deliver);
}

static BOOL validAnchor(UIWindow *window) {
    return NSThread.isMainThread && [window isKindOfClass:UIWindow.class] && !window.hidden && !CGRectIsEmpty(window.bounds)
        && window.windowScene && window.windowScene.activationState != UISceneActivationStateBackground
        && window.windowScene.activationState != UISceneActivationStateUnattached;
}

static UIWindow *fallbackAnchor(void) {
    if (!NSThread.isMainThread) return nil;
    UIWindow *window = (UIWindow *)(gameAnchor ? gameAnchor() : nil);
    if (validAnchor(window)) return window;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow && validAnchor(candidate)) return candidate;
        }
    }
    return nil; // Let AuthenticationServices report the original presentation failure.
}

@interface MulgLoginPresentation : NSObject <ASWebAuthenticationPresentationContextProviding,
                                            ASAuthorizationControllerPresentationContextProviding>
@property(nonatomic, weak) id original;
@end
@implementation MulgLoginPresentation
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    UIWindow *window = nil;
    if ([self.original respondsToSelector:_cmd]) window = [self.original presentationAnchorForWebAuthenticationSession:session];
    return validAnchor(window) ? window : fallbackAnchor();
}
- (ASPresentationAnchor)presentationAnchorForAuthorizationController:(ASAuthorizationController *)controller {
    UIWindow *window = nil;
    if ([self.original respondsToSelector:_cmd]) window = [self.original presentationAnchorForAuthorizationController:controller];
    return validAnchor(window) ? window : fallbackAnchor();
}
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [self.original respondsToSelector:selector]; }
- (id)forwardingTargetForSelector:(SEL)selector { return [self.original respondsToSelector:selector] ? self.original : [super forwardingTargetForSelector:selector]; }
@end

static MulgLoginPresentation *presentation(id owner, id original) {
    MulgLoginPresentation *proxy = objc_getAssociatedObject(owner, &presentationKey);
    if (proxy && original == proxy) return proxy;
    proxy = [MulgLoginPresentation new];
    proxy.original = original;
    objc_setAssociatedObject(owner, &presentationKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return proxy;
}

@interface MulgLoginDelegate : NSObject <ASAuthorizationControllerDelegate>
@property(nonatomic, weak) id<ASAuthorizationControllerDelegate> original;
@property(nonatomic, copy) NSString *provider;
@end
@implementation MulgLoginDelegate
- (void)authorizationController:(ASAuthorizationController *)controller didCompleteWithAuthorization:(ASAuthorization *)authorization {
    NSString *provider = self.provider;
    id<ASAuthorizationControllerDelegate> original = self.original;
    if ([original respondsToSelector:_cmd]) [original authorizationController:controller didCompleteWithAuthorization:authorization];
    emit(provider, @"completed", nil);
}
- (void)authorizationController:(ASAuthorizationController *)controller didCompleteWithError:(NSError *)error {
    BOOL cancelled = [error.domain isEqual:ASAuthorizationErrorDomain] && error.code == ASAuthorizationErrorCanceled;
    NSString *provider = self.provider;
    id<ASAuthorizationControllerDelegate> original = self.original;
    if ([original respondsToSelector:_cmd]) [original authorizationController:controller didCompleteWithError:error];
    emit(provider, cancelled ? @"cancelled" : @"failed", error);
}
- (BOOL)respondsToSelector:(SEL)selector { return [super respondsToSelector:selector] || [self.original respondsToSelector:selector]; }
- (id)forwardingTargetForSelector:(SEL)selector { return [self.original respondsToSelector:selector] ? self.original : [super forwardingTargetForSelector:selector]; }
@end

static void prepareAuthorization(ASAuthorizationController *controller) {
    if (!NSThread.isMainThread) return;
    BOOL apple = NO;
    for (ASAuthorizationRequest *request in controller.authorizationRequests) {
        if ([request isKindOfClass:ASAuthorizationAppleIDRequest.class]) apple = YES;
    }
    controller.presentationContextProvider = presentation(controller, controller.presentationContextProvider);
    MulgLoginDelegate *proxy = objc_getAssociatedObject(controller, &delegateKey);
    if (!proxy || controller.delegate != proxy) {
        proxy = [MulgLoginDelegate new];
        proxy.original = controller.delegate;
        objc_setAssociatedObject(controller, &delegateKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        controller.delegate = proxy;
    }
    proxy.provider = apple ? @"apple" : @"native";
    emit(proxy.provider, @"requested", nil);
}

static void perform(ASAuthorizationController *self, SEL cmd) {
    IMP original = mulg_swizzle_original(object_getClass(self), cmd, (IMP)perform);
    if (atomic_load(&enabled) && mulg_engine_is_game_caller(__builtin_return_address(0))) prepareAuthorization(self);
    if (original) ((void (*)(id, SEL))original)(self, cmd);
}
static void performOptions(ASAuthorizationController *self, SEL cmd, ASAuthorizationControllerRequestOptions options) {
    IMP original = mulg_swizzle_original(object_getClass(self), cmd, (IMP)performOptions);
    if (atomic_load(&enabled) && mulg_engine_is_game_caller(__builtin_return_address(0))) prepareAuthorization(self);
    if (original) ((void (*)(id, SEL, ASAuthorizationControllerRequestOptions))original)(self, cmd, options);
}

// Releasing a session may invoke native cleanup; never run that cleanup under our lock.
static void releaseSession(NSUUID *token) {
    if (!token) return;
    ASWebAuthenticationSession * __attribute__((objc_precise_lifetime)) retired;
    [sessionLock lock];
    retired = sessions[token];
    [sessions removeObjectForKey:token];
    [sessionLock unlock];
    (void)retired;
}
static void finishWeb(NSUUID *token, NSError *error) {
    releaseSession(token);
    BOOL cancelled = [error.domain isEqual:ASWebAuthenticationSessionErrorDomain] && error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin;
    BOOL presentationFailed = [error.domain isEqual:ASWebAuthenticationSessionErrorDomain]
        && (error.code == ASWebAuthenticationSessionErrorCodePresentationContextNotProvided
            || error.code == ASWebAuthenticationSessionErrorCodePresentationContextInvalid);
    emit(@"web", error ? (cancelled ? @"cancelled" : presentationFailed ? @"presentationFailed" : @"failed") : @"completed", error);
}
static id webInit(id self, SEL cmd, NSURL *url, id callback, ASWebAuthenticationSessionCompletionHandler completion) {
    IMP replacement = sel_isEqual(cmd, @selector(initWithURL:callbackURLScheme:completionHandler:)) ? (IMP)webSchemeInit : (IMP)webCallbackInit;
    IMP original = mulg_swizzle_original(object_getClass(self), cmd, replacement);
    if (!original) return nil;
    if (!atomic_load(&enabled) || !completion) return ((id (*)(id, SEL, NSURL *, id, ASWebAuthenticationSessionCompletionHandler))original)(self, cmd, url, callback, completion);
    NSUUID *token = [NSUUID UUID];
    id result = ((id (*)(id, SEL, NSURL *, id, ASWebAuthenticationSessionCompletionHandler))original)(self, cmd, url, callback, ^(NSURL *returnedURL, NSError *error) {
        completion(returnedURL, error); // Same URL, error and native callback queue.
        finishWeb(token, error); // Keep the session alive through delivery to the SDK.
    });
    if (result) objc_setAssociatedObject(result, &attemptKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}
static id webSchemeInit(id self, SEL cmd, NSURL *url, NSString *scheme, ASWebAuthenticationSessionCompletionHandler completion) {
    if (!mulg_engine_is_game_caller(__builtin_return_address(0))) {
        IMP original = mulg_swizzle_original(object_getClass(self), cmd, (IMP)webSchemeInit);
        return original ? ((id (*)(id, SEL, NSURL *, id, ASWebAuthenticationSessionCompletionHandler))original)(self, cmd, url, scheme, completion) : nil;
    }
    return webInit(self, cmd, url, scheme, completion);
}
static id webCallbackInit(id self, SEL cmd, NSURL *url, ASWebAuthenticationSessionCallback *callback, ASWebAuthenticationSessionCompletionHandler completion) {
    if (!mulg_engine_is_game_caller(__builtin_return_address(0))) {
        IMP original = mulg_swizzle_original(object_getClass(self), cmd, (IMP)webCallbackInit);
        return original ? ((id (*)(id, SEL, NSURL *, id, ASWebAuthenticationSessionCompletionHandler))original)(self, cmd, url, callback, completion) : nil;
    }
    return webInit(self, cmd, url, callback, completion);
}
static void prepareWeb(ASWebAuthenticationSession *session) {
    if (NSThread.isMainThread) session.presentationContextProvider = presentation(session, session.presentationContextProvider);
}
static BOOL webCanStart(ASWebAuthenticationSession *self, SEL cmd) {
    IMP original = mulg_swizzle_original(object_getClass(self), cmd, (IMP)webCanStart);
    if (atomic_load(&enabled) && mulg_engine_is_game_caller(__builtin_return_address(0))) prepareWeb(self);
    return original ? ((BOOL (*)(id, SEL))original)(self, cmd) : NO;
}
static BOOL webStart(ASWebAuthenticationSession *self, SEL cmd) {
    IMP original = mulg_swizzle_original(object_getClass(self), cmd, (IMP)webStart);
    BOOL owned = atomic_load(&enabled) && mulg_engine_is_game_caller(__builtin_return_address(0));
    NSUUID *token = owned ? objc_getAssociatedObject(self, &attemptKey) : nil;
    BOOL retained = NO;
    if (owned) {
        prepareWeb(self);
        if (token) {
            [sessionLock lock];
            retained = sessions[token] == nil;
            if (retained) sessions[token] = self;
            [sessionLock unlock];
        }
        emit(@"web", @"requested", nil);
    }
    BOOL started = original ? ((BOOL (*)(id, SEL))original)(self, cmd) : NO;
    if (!started && owned) {
        if (retained) releaseSession(token);
        emit(@"web", @"startRejected", nil);
    }
    return started;
}
static void webCancel(ASWebAuthenticationSession *self, SEL cmd) {
    IMP original = mulg_swizzle_original(object_getClass(self), cmd, (IMP)webCancel);
    NSUUID *token = objc_getAssociatedObject(self, &attemptKey);
    if (original) ((void (*)(id, SEL))original)(self, cmd);
    releaseSession(token);
}

NSArray<NSString *> *mulg_authentication_install(NSObject *(^anchor)(void), void (^event)(NSString *, NSString *, NSString *, NSInteger)) {
    if (!NSThread.isMainThread) return @[];
    gameAnchor = [anchor copy]; reportEvent = [event copy];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sessionLock = [NSLock new]; sessions = [NSMutableDictionary new]; });
    atomic_store(&enabled, true);
    NSMutableArray<NSString *> *installed = [NSMutableArray new];
    void (^hook)(Class, SEL, IMP, const char *, NSArray<NSString *> *) = ^(Class cls, SEL selector, IMP imp, const char *result, NSArray<NSString *> *arguments) {
        if (mulg_swizzle_checked_owned("integrations", cls, selector, imp, NULL, result, arguments) == MulgSwizzleResultReplaced) {
            [installed addObject:[NSString stringWithFormat:@"%@.%@", NSStringFromClass(cls), NSStringFromSelector(selector)]];
        }
    };
    hook(ASAuthorizationController.class, @selector(performRequests), (IMP)perform, @encode(void), @[]);
    hook(ASAuthorizationController.class, @selector(performRequestsWithOptions:), (IMP)performOptions, @encode(void), @[@(@encode(ASAuthorizationControllerRequestOptions))]);
    hook(ASWebAuthenticationSession.class, @selector(initWithURL:callbackURLScheme:completionHandler:), (IMP)webSchemeInit, @encode(id), @[@"@", @"@", @"@?"]);
    hook(ASWebAuthenticationSession.class, @selector(initWithURL:callback:completionHandler:), (IMP)webCallbackInit, @encode(id), @[@"@", @"@", @"@?"]);
    hook(ASWebAuthenticationSession.class, @selector(canStart), (IMP)webCanStart, @encode(BOOL), @[]);
    hook(ASWebAuthenticationSession.class, @selector(start), (IMP)webStart, @encode(BOOL), @[]);
    hook(ASWebAuthenticationSession.class, @selector(cancel), (IMP)webCancel, @encode(void), @[]);
    return installed;
}
void mulg_authentication_disable(void) {
    atomic_store(&enabled, false);
    // In-flight callbacks still reach the game; changing mode does not cancel login.
}
#else
NSArray<NSString *> *mulg_authentication_install(NSObject *(^anchor)(void), void (^event)(NSString *, NSString *, NSString *, NSInteger)) { return @[]; }
void mulg_authentication_disable(void) {}
#endif
