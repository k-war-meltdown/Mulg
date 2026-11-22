#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <assert.h>
BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
void mulg_engine_set_frame_start_delay(double delay) {}
void mulg_engine_frame_presented(void) {}
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) {}
#import <Metal/Metal.h>
#define MTLCopyAllDevices() @[]
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices

// Mulg's archive adds compile again through the driver; they must never overlap the game's own
// pipeline builds (Endfield 1.6.3 shader warm-up crash, 2026-10-17).
static _Atomic(int) added, overlapping, buildCalls;
static BOOL failWithArchive, failNative;
static id expectedNativeDescriptor;
@interface QuietArchive : NSObject
@property(nonatomic, strong) id device;
@end
@implementation QuietArchive
- (BOOL)addRenderPipelineFunctionsWithDescriptor:(id)descriptor error:(NSError **)error {
    if (atomic_load(&game_pipeline_builds) > 0) atomic_fetch_add(&overlapping, 1);
    atomic_fetch_add(&added, 1);
    return YES;
}
@end
@interface QuietDevice : NSObject
@property(nonatomic, strong) NSMutableArray *pending;
@end
@implementation QuietDevice
- (id)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error {
    atomic_fetch_add(&buildCalls, 1);
    if (failNative) {
        assert(descriptor == expectedNativeDescriptor);
        if (error) *error = [NSError errorWithDomain:@"native" code:7 userInfo:nil];
        return nil;
    }
    return [NSObject new];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor
                           completionHandler:(void (^)(id, NSError *))handler {
    atomic_fetch_add(&buildCalls, 1);
    if (failNative) {
        assert(descriptor == expectedNativeDescriptor);
        handler(nil, [NSError errorWithDomain:@"native" code:7 userInfo:nil]); return;
    }
    BOOL withArchive = [descriptor.binaryArchives containsObject:shader_lookup];
    if (failWithArchive && withArchive) { handler(nil, [NSError errorWithDomain:@"archive" code:1 userInfo:nil]); return; }
    [self.pending addObject:[handler copy]];  // finished later, like a real background compile
}
@end

static void finish(QuietDevice *device) {
    NSArray *handlers = [device.pending copy];
    [device.pending removeAllObjects];
    for (void (^handler)(id, NSError *) in handlers) handler([NSObject new], nil);
}
static void settle(double seconds) { [NSThread sleepForTimeInterval:seconds]; }

int main(void) { @autoreleasepool {
    archive_quiet_nanoseconds = 100 * NSEC_PER_MSEC;
    QuietDevice *device = [QuietDevice new]; device.pending = [NSMutableArray array];
    QuietArchive *archive = [QuietArchive new]; archive.device = device;
    shader_record = (id)archive;
    shader_queue = shader_archive_queue("fixture.quiet");
    dispatch_queue_set_specific(shader_queue, &shader_queue_key, &shader_queue_key, NULL);
    atomic_store(&shader_ready, true); install_shader_device(device.class);
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];

    // A synchronous build is recorded only after the game has been quiet for the whole period.
    assert([(id)device newRenderPipelineStateWithDescriptor:descriptor error:NULL]);
    assert(atomic_load(&game_pipeline_builds) == 0);
    settle(0.03); assert(atomic_load(&added) == 0);
    settle(0.3); assert(atomic_load(&added) == 1);

    // While one asynchronous build is still compiling, finished builds wait.
    [(id)device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id p, NSError *e) { assert(p); }];
    [(id)device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id p, NSError *e) { assert(p); }];
    assert(atomic_load(&game_pipeline_builds) == 2);
    void (^first)(id, NSError *) = device.pending.firstObject; [device.pending removeObjectAtIndex:0];
    first([NSObject new], nil);
    settle(0.4); assert(atomic_load(&added) == 1);  // the other build is still in flight
    finish(device);
    assert(atomic_load(&game_pipeline_builds) == 0);
    settle(0.4); assert(atomic_load(&added) == 3);

    // A recording-only snapshot did not change compilation. Native failures
    // must propagate once, without repeating the identical failed work.
    failNative = YES; expectedNativeDescriptor = descriptor;
    int buildsBefore = atomic_load(&buildCalls);
    NSError *nativeError = nil;
    assert(![(id)device newRenderPipelineStateWithDescriptor:descriptor error:&nativeError]);
    assert([nativeError.domain isEqual:@"native"] && nativeError.code == 7);
    assert(atomic_load(&buildCalls) == buildsBefore + 1 && atomic_load(&game_pipeline_builds) == 0);
    __block int nativeCallbacks = 0;
    [(id)device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id p, NSError *e) {
        assert(!p && [e.domain isEqual:@"native"] && e.code == 7); nativeCallbacks++;
    }];
    assert(nativeCallbacks == 1 && atomic_load(&buildCalls) == buildsBefore + 2);
    assert(atomic_load(&game_pipeline_builds) == 0);
    failNative = NO;

    // Do not append a lookup archive the game already attached, or retry its
    // intentional request without that archive when it fails.
    shader_lookup = (id)archive; failWithArchive = YES;
    descriptor.binaryArchives = @[(id)archive];
    BOOL appended = YES;
    id unchangedArchives = with_archive((id)device, descriptor, &appended);
    assert(!appended && [unchangedArchives binaryArchives].count == 1);
    buildsBefore = atomic_load(&buildCalls);
    __block int originalArchiveCallbacks = 0;
    [(id)device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id p, NSError *e) {
        assert(!p && [e.domain isEqual:@"archive"]); originalArchiveCallbacks++;
    }];
    assert(originalArchiveCallbacks == 1 && atomic_load(&buildCalls) == buildsBefore + 1);
    assert(atomic_load(&game_pipeline_builds) == 0);
    descriptor.binaryArchives = @[];

    // A failed build with the lookup archive is retried natively and still ends exactly once.
    shader_lookup = (id)archive; failWithArchive = YES;
    buildsBefore = atomic_load(&buildCalls);
    __block int callbacks = 0;
    [(id)device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id p, NSError *e) { assert(p && !e); callbacks++; }];
    assert(atomic_load(&game_pipeline_builds) == 1 && device.pending.count == 1);
    finish(device);
    assert(callbacks == 1 && atomic_load(&game_pipeline_builds) == 0);
    assert(atomic_load(&buildCalls) == buildsBefore + 2);
    shader_lookup = nil; failWithArchive = NO;

    // Quitting during endless compilation never waits for quiet: queued adds give up at once.
    dispatch_sync(shader_queue, ^{ shader_saved_generation = shader_generation; });  // nothing left to save
    [(id)device newRenderPipelineStateWithDescriptor:descriptor error:NULL];
    [(id)device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id p, NSError *e) {}];
    int before = atomic_load(&added);
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    save_shader_archive_at_exit();
    assert(CFAbsoluteTimeGetCurrent() - start < 1.0);
    dispatch_sync(shader_queue, ^{});
    assert(atomic_load(&added) == before);
    assert(atomic_load(&overlapping) == 0);
    puts("PASS: archive adds wait for quiet game compilation, retries balance, quitting never waits");
    return 0;
} }
