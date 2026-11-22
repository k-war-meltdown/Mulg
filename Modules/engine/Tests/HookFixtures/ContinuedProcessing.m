#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <TargetConditionals.h>
#include <assert.h>
#include <pthread.h>
static BOOL gameCaller;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
@interface BGContinuedProcessingTaskRequest : NSObject @end
@implementation BGContinuedProcessingTaskRequest @end
@interface ContinuedSubclass : BGContinuedProcessingTaskRequest @end
@implementation ContinuedSubclass @end
@interface BGTaskScheduler : NSObject
@property(nonatomic) int nativeSubmits;
- (BOOL)submitTaskRequest:(id)request error:(NSError **)error;
- (void)submitTaskRequest:(id)request completionHandler:(void (^)(NSError *))handler;
@end
@implementation BGTaskScheduler
- (BOOL)submitTaskRequest:(id)request error:(NSError **)error { self.nativeSubmits++; if (error) *error = nil; return YES; }
- (void)submitTaskRequest:(id)request completionHandler:(void (^)(NSError *))handler { self.nativeSubmits++; if (handler) handler(nil); }
@end
#undef TARGET_OS_MACCATALYST
#define TARGET_OS_MACCATALYST 1
#include "../../Sources/MulgEngineHooks/MulgContinuedProcessing.m"
int main(void) { @autoreleasepool {
    assert(mulg_engine_install_continued_processing_hooks() == 2);
    assert(mulg_engine_install_continued_processing_hooks() == 2);
    BGTaskScheduler *scheduler = [BGTaskScheduler new];
    BGContinuedProcessingTaskRequest *request = [BGContinuedProcessingTaskRequest new];
    NSError *error = nil;
    assert([scheduler submitTaskRequest:request error:&error]); // Native caller still accepted.
    gameCaller = YES;
    assert(![scheduler submitTaskRequest:request error:&error]);
    assert(error.code == 1 && [error.domain isEqual:@"BGTaskSchedulerErrorDomain"]);
    assert(scheduler.nativeSubmits == 1);
    assert(![scheduler submitTaskRequest:[ContinuedSubclass new] error:NULL]);
    __block int completions = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [scheduler submitTaskRequest:request completionHandler:^(NSError *failure) {
        assert(failure.code == 1 && !pthread_main_np()); completions++;
        dispatch_semaphore_signal(done);
    }];
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(completions == 1 && scheduler.nativeSubmits == 1);
    [scheduler submitTaskRequest:request completionHandler:nil];
    NSObject *supported = [NSObject new];
    assert([scheduler submitTaskRequest:supported error:&error] && !error);
    [scheduler submitTaskRequest:supported completionHandler:^(NSError *failure) { assert(!failure); completions++; }];
    assert(scheduler.nativeSubmits == 3 && completions == 2);
    gameCaller = NO;
    [scheduler submitTaskRequest:request completionHandler:^(NSError *failure) { assert(!failure); completions++; }];
    assert(scheduler.nativeSubmits == 4 && completions == 3);
    assert(mulg_engine_unavailable_continued_tasks() == 4);
    puts("PASS: unsupported requests fail promptly; sync/async, null callbacks, subclasses, native callers and supported tasks");
} }
