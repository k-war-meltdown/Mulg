#import <MulgEngineHooks.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <pthread.h>

int main(void) { @autoreleasepool {
    __block int touches = 0;
    mulg_engine_set_frame_start_handler(^{ assert(pthread_main_np()); touches++; });
    mulg_engine_set_frame_start_delay(0.05);
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block id captured;
    BOOL drew = mulg_engine_display_link_callback(NO, ^{
        id context = mulg_engine_frame_start_context(); assert(context != nil);
        captured = context;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            double start = CACurrentMediaTime();
            mulg_engine_frame_presented_in_context(context);
            assert(CACurrentMediaTime() - start < 0.03);
            dispatch_semaphore_signal(completed);
        });
        assert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    });
    assert(drew && touches == 1 && mulg_engine_frame_start_context() == nil);
    double start = CACurrentMediaTime(); mulg_engine_frame_presented();
    assert(CACurrentMediaTime() - start >= 0.04 && touches == 1);
    start = CACurrentMediaTime(); mulg_engine_frame_presented_in_context(captured);
    assert(CACurrentMediaTime() - start >= 0.04 && touches == 1); // After callback exit, submission owns the wait.
    start = CACurrentMediaTime(); mulg_engine_frame_presented_in_context(captured);
    assert(CACurrentMediaTime() - start < 0.03); // A second submission cannot repeat it.

    mulg_engine_set_frame_start_delay(0);
    __block id driven;
    __block id nestedDriven;
    mulg_engine_display_link_callback(YES, ^{
        driven = mulg_engine_frame_start_context();
        // Feedback can arrive after entry. That display-link still owns the next wait.
        mulg_engine_set_frame_start_delay(0.05);
        mulg_engine_display_link_callback(YES, ^{
            nestedDriven = mulg_engine_frame_start_context();
            assert(nestedDriven != driven); // Separate render proof, shared wait ownership.
        });
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double begin = CACurrentMediaTime();
        mulg_engine_frame_presented_in_context(driven);
        assert(CACurrentMediaTime() - begin < 0.03); // Late worker commit cannot sleep again.
        begin = CACurrentMediaTime(); mulg_engine_frame_presented_in_context(nestedDriven);
        assert(CACurrentMediaTime() - begin < 0.03);
        dispatch_semaphore_signal(completed);
    });
    assert(dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    mulg_engine_set_frame_start_delay(0); mulg_engine_set_frame_start_handler(nil);
    puts("PASS: display-link thread handoff records rendering, suppresses duplicate wait and keeps touch delivery at callback entry");
} }
