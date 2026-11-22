#import "MulgEngineHooks.h"
#include <TargetConditionals.h>
#include <stdatomic.h>

static _Atomic(unsigned) unavailableRequests;
unsigned mulg_engine_unavailable_continued_tasks(void) { return atomic_load(&unavailableRequests); }

#if TARGET_OS_MACCATALYST
// The iOS SDK explicitly marks continued-processing requests unavailable on Catalyst.
// Converted iOS binaries can still instantiate them and receive an accepted/queued
// submission that never launches. Report the native unavailable contract instead of
// leaving a game waiting for a task launch. Ordinary supported task types stay native.
static IMP previousSubmit, previousSubmitAsync;

static BOOL unsupported_request(id request, const void *caller) {
    Class continued = objc_lookUpClass("BGContinuedProcessingTaskRequest");
    return continued && [request isKindOfClass:continued] && mulg_engine_is_game_caller(caller);
}
static NSError *unavailable_error(void) {
    atomic_fetch_add(&unavailableRequests, 1);
    // BGTaskSchedulerErrorCodeUnavailable == 1 in the public iOS SDK.
    return [NSError errorWithDomain:@"BGTaskSchedulerErrorDomain" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Continued background processing is unavailable on Mac Catalyst."}];
}
static BOOL submit(id scheduler, SEL selector, id request, NSError **error) {
    if (unsupported_request(request, __builtin_return_address(0))) {
        NSError *failure = unavailable_error();
        if (error) *error = failure;
        return NO;
    }
    return ((BOOL (*)(id, SEL, id, NSError **))previousSubmit)(scheduler, selector, request, error);
}
static void submit_async(id scheduler, SEL selector, id request, void (^completion)(NSError *)) {
    if (unsupported_request(request, __builtin_return_address(0))) {
        NSError *failure = unavailable_error();
        if (completion) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ completion(failure); });
        return;
    }
    ((void (*)(id, SEL, id, void (^)(NSError *)))previousSubmitAsync)(scheduler, selector, request, completion);
}
int mulg_engine_install_continued_processing_hooks(void) {
    Class scheduler = objc_lookUpClass("BGTaskScheduler");
    if (!scheduler) return 0; // Retried through the existing imagesChanged path.
    int count = 0;
    count += mulg_swizzle_checked_owned("engine", scheduler, sel_registerName("submitTaskRequest:error:"),
        (IMP)submit, &previousSubmit, @encode(BOOL), @[@"@", @"^@"]) == MulgSwizzleResultReplaced;
    SEL asynchronous = sel_registerName("submitTaskRequest:completionHandler:");
    if (class_getInstanceMethod(scheduler, asynchronous)) {
        count += mulg_swizzle_checked_owned("engine", scheduler, asynchronous, (IMP)submit_async,
            &previousSubmitAsync, "v", @[@"@", @"@?"]) == MulgSwizzleResultReplaced;
    }
    return count;
}
#else
int mulg_engine_install_continued_processing_hooks(void) { return 0; }
#endif
