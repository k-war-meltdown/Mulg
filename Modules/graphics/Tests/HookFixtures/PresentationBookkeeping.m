#define main original_frame_fixture_main
#include "FrameSubmission.m"
#undef main
#import <objc/objc-sync.h>

@interface ResidencyLayer : CAMetalLayer
@property(nonatomic, strong) id fixtureSet;
@end
@implementation ResidencyLayer
- (id)residencySet { return self.fixtureSet; }
@end
@interface ResidencyQueue : AuditQueue4
@property(nonatomic) int adds, removes, waits;
@property(nonatomic) BOOL failAdd, failWait;
@property(nonatomic, weak) id lastDrawable;
@end
@implementation ResidencyQueue
- (void)addResidencySet:(id)set {
    if (self.failAdd) @throw [NSException exceptionWithName:@"AddFailure" reason:nil userInfo:nil];
    self.adds++;
}
- (void)removeResidencySet:(id)set { self.removes++; }
- (void)waitForDrawable:(id)drawable {
    self.waits++; self.lastDrawable = drawable;
    if (self.failWait) @throw [NSException exceptionWithName:@"WaitFailure" reason:nil userInfo:nil];
}
@end

int main(void) { @autoreleasepool {
    ResidencyQueue *queue = [ResidencyQueue new];
    assert(hook(queue.class, @selector(waitForDrawable:), (IMP)mulg_queue_wait_drawable,
        NULL, @encode(void), @[@(@encode(id))]));
    install_drawable(AuditDrawable.class);
    ResidencyLayer *layer = [ResidencyLayer layer];
    AuditDrawable *drawable = [AuditDrawable new]; drawable.layer = layer;
    // Stable capability and no-source waits must complete while another thread
    // owns the private bookkeeping locks, not merely reacquire a recursive lock.
    note_presentation_path(drawable, YES);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    id layerLock = mulg_lock(layer), queueLock = mulg_lock(queue);
    objc_sync_enter(layerLock); objc_sync_enter(queueLock);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        note_presentation_path(drawable, YES);
        [queue waitForDrawable:drawable];
        dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    objc_sync_exit(queueLock); objc_sync_exit(layerLock);
    assert(queue.waits == 1 && queue.lastDrawable == drawable);
    note_presentation_path(drawable, NO);
    assert(![objc_getAssociatedObject(layer, &kPresentationPathKey) boolValue]);
    note_presentation_path(drawable, YES);
    assert([objc_getAssociatedObject(layer, &kPresentationPathKey) boolValue]);

    atomic_store(&mulg_source_address, address(layer));
    layer.fixtureSet = [NSObject new];
    queue.failAdd = YES;
    @try { [queue waitForDrawable:drawable]; assert(NO); }
    @catch (NSException *e) { assert([e.name isEqual:@"AddFailure"]); }
    assert(atomic_load(&mulg_source_residency_queues) == 0);
    queue.failAdd = NO;
    [queue waitForDrawable:drawable]; [queue waitForDrawable:drawable];
    assert(queue.adds == 1 && atomic_load(&mulg_source_residency_queues) == 1);
    layer.fixtureSet = [NSObject new]; [queue waitForDrawable:drawable];
    assert(queue.adds == 2 && queue.removes == 1 && atomic_load(&mulg_source_residency_queues) == 1);
    atomic_store(&mulg_source_address, 0);
    [queue waitForDrawable:drawable];
    assert(queue.removes == 2 && atomic_load(&mulg_source_residency_queues) == 0);
    queue.failWait = YES;
    @try { [queue waitForDrawable:drawable]; assert(NO); }
    @catch (NSException *e) { assert([e.name isEqual:@"WaitFailure"]); }
    queue.failWait = NO;
    atomic_store(&mulg_source_address, address(layer));
    __weak id weakQueue;
    @autoreleasepool {
        ResidencyQueue *abandoned = [ResidencyQueue new]; weakQueue = abandoned;
        [abandoned waitForDrawable:drawable];
        assert(atomic_load(&mulg_source_residency_queues) == 1);
    }
    assert(!weakQueue && atomic_load(&mulg_source_residency_queues) == 0);
    atomic_store(&mulg_source_address, 0);
    puts("PASS: stable bookkeeping bypass, capability changes and balanced residency lifetimes");
} return 0; }
