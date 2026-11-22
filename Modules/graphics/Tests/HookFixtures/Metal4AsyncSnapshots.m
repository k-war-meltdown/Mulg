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

static int descriptorCopies, linkingCopies, optionsCopies, nativeCalls;
static id lookupArchive, nativePipeline;
static NSError *lookupError;
static NSMutableArray *nativeTasks;
static id seenDescriptor, seenLinking, seenOptions;
static NSUInteger seenDescriptorValue, seenLinkingValue, seenOptionsValue;
static NSArray *seenArchives;
static void (^pending)(id, NSError *);

@interface SnapshotValue : NSObject <NSCopying>
@property(nonatomic) NSUInteger value;
@property(nonatomic) BOOL linking;
@end
@implementation SnapshotValue
- (id)copyWithZone:(NSZone *)zone {
    if (self.linking) linkingCopies++; else descriptorCopies++;
    SnapshotValue *copy = [SnapshotValue new]; copy.value = self.value; copy.linking = self.linking;
    return copy;
}
@end

@interface SnapshotOptions : NSObject <NSCopying>
@property(nonatomic) NSUInteger value;
@property(nonatomic, copy) NSArray *lookupArchives;
@end
@implementation SnapshotOptions
- (id)copyWithZone:(NSZone *)zone {
    optionsCopies++;
    SnapshotOptions *copy = [SnapshotOptions new]; copy.value = self.value; copy.lookupArchives = self.lookupArchives;
    return copy;
}
@end

static id __attribute__((ns_returns_retained)) native_build(SnapshotValue *descriptor, SnapshotValue *linking,
                                                           SnapshotOptions *options, void (^handler)(id, NSError *)) {
    nativeCalls++;
    seenDescriptor = descriptor; seenLinking = linking; seenOptions = options;
    seenDescriptorValue = descriptor.value; seenLinkingValue = linking.value; seenOptionsValue = options.value;
    seenArchives = options.lookupArchives;
    id task = [NSObject new]; [nativeTasks addObject:task];
    if ([options.lookupArchives containsObject:lookupArchive]) {
        pending = [handler copy]; // Native asynchronous completion, after caller reuse.
    } else if (handler) handler(nativePipeline, nil);
    return task;
}

@interface SnapshotCompiler : NSObject
@property(nonatomic, strong) id device;
@end
@implementation SnapshotCompiler
- (id)newRenderPipelineStateWithDescriptor:(id)descriptor compilerTaskOptions:(id)options
                        completionHandler:(void (^)(id, NSError *))handler {
    return native_build(descriptor, nil, options, handler);
}
- (id)newRenderPipelineStateWithDescriptor:(id)descriptor dynamicLinkingDescriptor:(id)linking
                      compilerTaskOptions:(id)options completionHandler:(void (^)(id, NSError *))handler {
    return native_build(descriptor, linking, options, handler);
}
@end

static void reset(void) {
    descriptorCopies = linkingCopies = optionsCopies = nativeCalls = 0;
    [nativeTasks removeAllObjects]; pending = nil;
    seenDescriptor = seenLinking = seenOptions = nil; seenArchives = nil;
}

int main(void) { @autoreleasepool {
    SnapshotCompiler *compiler = [SnapshotCompiler new]; compiler.device = [NSObject new];
    shader4_device = (id)compiler.device;
    lookupArchive = [NSObject new]; shader4_lookups = @[lookupArchive];
    id gameArchive = [NSObject new];
    nativeTasks = [NSMutableArray new]; nativePipeline = [NSObject new];
    lookupError = [NSError errorWithDomain:@"fixture.lookup" code:9 userInfo:nil];
    assert(hook(SnapshotCompiler.class, @selector(newRenderPipelineStateWithDescriptor:compilerTaskOptions:completionHandler:),
        (IMP)mulg_compiler_build_async, NULL, @encode(id), @[@(@encode(id)), @(@encode(id)), @"@?"]));
    assert(hook(SnapshotCompiler.class,
        @selector(newRenderPipelineStateWithDescriptor:dynamicLinkingDescriptor:compilerTaskOptions:completionHandler:),
        (IMP)mulg_compiler_linked_build_async, NULL, @encode(id), @[@(@encode(id)), @(@encode(id)), @(@encode(id)), @"@?"]));
    for (int linked = 0; linked < 2; linked++) {
        SnapshotValue *descriptor = [SnapshotValue new]; descriptor.value = 17;
        SnapshotValue *linking = [SnapshotValue new]; linking.value = 23; linking.linking = YES;
        SnapshotOptions *options = [SnapshotOptions new]; options.value = 41; options.lookupArchives = @[gameArchive];
        id (^invoke)(void (^)(id, NSError *)) = ^id(void (^handler)(id, NSError *)) {
            return linked ? [compiler newRenderPipelineStateWithDescriptor:descriptor dynamicLinkingDescriptor:linking
                compilerTaskOptions:options completionHandler:handler]
                : [compiler newRenderPipelineStateWithDescriptor:descriptor compilerTaskOptions:options completionHandler:handler];
        };

        reset();
        id task = invoke(nil);
        assert(nativeCalls == 1 && task == nativeTasks.firstObject && pending == nil);
        assert(seenDescriptor == descriptor && seenLinking == (linked ? linking : nil));
        assert((seenOptions != options && [seenArchives isEqual:@[gameArchive, lookupArchive]]));
        assert([options.lookupArchives isEqual:@[gameArchive]]);
        // One options copy still adds lookup archives. Retry-only descriptor,
        // linking and second options snapshots must not exist without a callback.
        assert(descriptorCopies == 0 && linkingCopies == 0 && optionsCopies == 1);

        reset(); __block int callbacks = 0;
        task = invoke(^(id pipeline, NSError *error) { assert(pipeline == nativePipeline && error == nil); callbacks++; });
        assert(task == nativeTasks.firstObject && nativeCalls == 1 && callbacks == 0 && pending != nil);
        assert(descriptorCopies == 1 && linkingCopies == linked && optionsCopies == 2);
        descriptor.value = 99; linking.value = 101; options.value = 1002; options.lookupArchives = @[];
        void (^completion)(id, NSError *) = pending; pending = nil;
        completion(nil, lookupError);
        assert(callbacks == 1 && nativeCalls == 2 && task == nativeTasks.firstObject);
        assert(seenDescriptor != descriptor && seenOptions != options);
        assert(seenDescriptorValue == 17 && seenLinkingValue == (linked ? 23 : 0) && seenOptionsValue == 41);
        assert([seenArchives isEqual:@[gameArchive]]);
        if (linked) assert(seenLinking != linking);
        assert(descriptor.value == 99 && linking.value == 101 && options.value == 1002);

        // A game-owned lookup must not create snapshots or trigger an optional
        // fallback that removes the archive the caller explicitly requested.
        reset(); callbacks = 0; options.lookupArchives = @[gameArchive, lookupArchive];
        task = invoke(^(id pipeline, NSError *error) { assert(pipeline == nil && error == lookupError); callbacks++; });
        assert(task == nativeTasks.firstObject && nativeCalls == 1 && pending != nil);
        assert(seenOptions == options && descriptorCopies == 0 && linkingCopies == 0 && optionsCopies == 0);
        completion = pending; pending = nil; completion(nil, lookupError);
        assert(callbacks == 1 && nativeCalls == 1);
    }
    puts("PASS: nil callbacks keep lookup without retry snapshots; callbacks retain native task and fallback values");
} return 0; }
