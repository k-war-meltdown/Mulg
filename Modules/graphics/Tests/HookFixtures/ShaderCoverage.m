#import <Foundation/Foundation.h>
#import <MulgEngineHooks.h>
#include <assert.h>
static BOOL gameCaller = YES;
BOOL mulg_engine_is_game_caller(const void *caller) { return gameCaller; }
void mulg_engine_set_frame_start_delay(double delay) {}
void mulg_engine_frame_presented(void) {}
id mulg_engine_frame_start_context(void) { return nil; }
void mulg_engine_frame_presented_in_context(id context) {}
#import <Metal/Metal.h>
#define MTLCopyAllDevices() @[]
#include "../../Sources/MulgGraphicsHooks/MulgGraphicsHooks.m"
#undef MTLCopyAllDevices

static int recorded, nativeCalls, lookupCalls, detected;
static BOOL lookupHit, failNative, nilHandler;
static BOOL throwNative, throwLookup;
static id reflectionValue;
static NSError *nativeError;
@interface CoverageFunction : NSObject
@property(nonatomic) BOOL fragment;
@end
@implementation CoverageFunction
- (MTLFunctionType)functionType { return self.fragment ? MTLFunctionTypeFragment : MTLFunctionTypeKernel; }
@end
@interface CoverageArchive : NSObject
@property(nonatomic, strong) id device;
@end
@implementation CoverageArchive
- (BOOL)addComputePipelineFunctionsWithDescriptor:(MTLComputePipelineDescriptor *)descriptor error:(NSError **)error {
    assert(descriptor.computeFunction != nil); recorded++; return YES;
}
@end
@interface CoverageCompiler : NSObject
@property(nonatomic, strong) id device;
@end
@implementation CoverageCompiler
- (id)newRenderPipelineStateBySpecializationWithDescriptor:(id)descriptor pipeline:(id)pipeline error:(NSError **)error {
    assert(pipeline == reflectionValue);
    if (failNative) { if (error) *error = nativeError; return nil; }
    return [NSObject new];
}
- (id)newRenderPipelineStateBySpecializationWithDescriptor:(id)descriptor pipeline:(id)pipeline completionHandler:(void (^)(id, NSError *))handler {
    assert(pipeline == reflectionValue);
    if (handler) handler(failNative ? nil : [NSObject new], failNative ? nativeError : nil);
    return [NSObject new];
}
@end
@interface CoverageDevice : NSObject @end
@implementation CoverageDevice
- (id)newComputePipelineStateWithFunction:(id)function error:(NSError **)error {
    nativeCalls++; if (failNative) { if (error) *error = nativeError; return nil; } return [NSObject new];
}
- (id)newComputePipelineStateWithFunction:(id)function options:(MTLPipelineOption)options reflection:(id *)reflection error:(NSError **)error {
    assert(options == MTLPipelineOptionBindingInfo || options == MTLPipelineOptionFailOnBinaryArchiveMiss);
    if (reflection) *reflection = reflectionValue;
    return [self newComputePipelineStateWithFunction:function error:error];
}
- (void)newComputePipelineStateWithFunction:(id)function completionHandler:(void (^)(id, NSError *))handler {
    if (throwNative) @throw [NSException exceptionWithName:@"NativeCompute" reason:nil userInfo:nil];
    nilHandler = handler == nil;
    id result = [self newComputePipelineStateWithFunction:function error:NULL];
    if (handler) handler(result, failNative ? nativeError : nil);
}
- (void)newComputePipelineStateWithFunction:(id)function options:(MTLPipelineOption)options completionHandler:(void (^)(id, id, NSError *))handler {
    if (throwNative) @throw [NSException exceptionWithName:@"NativeCompute" reason:nil userInfo:nil];
    nilHandler = handler == nil;
    id result = [self newComputePipelineStateWithFunction:function error:NULL];
    if (handler) handler(result, reflectionValue, failNative ? nativeError : nil);
}
- (id)newComputePipelineStateWithDescriptor:(id)descriptor options:(MTLPipelineOption)options reflection:(id *)reflection error:(NSError **)error {
    lookupCalls++; if (reflection) *reflection = lookupHit ? reflectionValue : @"wrong lookup reflection";
    return lookupHit ? [NSObject new] : nil;
}
- (void)newComputePipelineStateWithDescriptor:(id)descriptor options:(MTLPipelineOption)options completionHandler:(void (^)(id, id, NSError *))handler {
    if (throwLookup) @throw [NSException exceptionWithName:@"LookupCompute" reason:nil userInfo:nil];
    lookupCalls++; handler(lookupHit ? [NSObject new] : nil, reflectionValue, nil);
}
- (id)newCompilerWithDescriptor:(id)descriptor error:(NSError **)error { return [CoverageCompiler new]; }
@end
@interface CoverageDelegate : NSObject <MulgGraphicsDelegate> @end
@implementation CoverageDelegate
- (BOOL)upscale:(id)source into:(id)output commandBuffer:(id)buffer extendedRange:(BOOL)range { return YES; }
- (void)gameCreatedMetalFXObject:(NSString *)feature { detected++; }
- (void)layerUsesUnsupportedPresentPath:(CAMetalLayer *)layer {}
- (void)mainLayerCandidateChanged:(CAMetalLayer *)layer {}
- (void)framePresentedAtTime:(double)time {}
@end
static id __attribute__((ns_returns_retained)) makeFX(id descriptor, SEL selector, id device) {
    return failNative ? nil : [NSObject new];
}
static id __attribute__((ns_returns_retained)) makeFX4(id descriptor, SEL selector, id device, id compiler) {
    return makeFX(descriptor, selector, device);
}
int main(void) { @autoreleasepool {
    CoverageDevice *device = [CoverageDevice new]; id function = [CoverageFunction new];
    // Keep game archive order, deduplicate only Mulg's additions, and avoid
    // copying or retrying an options object whose archives already contain them.
    CoverageCompiler *lookupCompiler = [CoverageCompiler new]; lookupCompiler.device = device;
    id originalArchive = [NSObject new], oldLookup = [NSObject new], newLookup = [NSObject new];
    MTL4CompilerTaskOptions *gameOptions = [MTL4CompilerTaskOptions new];
    gameOptions.lookupArchives = @[originalArchive, oldLookup];
    shader4_device = (id)device; shader4_lookups = @[oldLookup, newLookup, newLookup];
    MTL4CompilerTaskOptions *merged = with_lookup((id)lookupCompiler, gameOptions);
    assert(merged != gameOptions && merged.lookupArchives.count == 3);
    assert([merged.lookupArchives isEqual:@[originalArchive, oldLookup, newLookup]]);
    assert(gameOptions.lookupArchives.count == 2);
    assert(with_lookup((id)lookupCompiler, merged) == merged);
    lookupCompiler.device = [NSObject new];
    assert(with_lookup((id)lookupCompiler, gameOptions) == gameOptions);
    shader4_device = nil; shader4_lookups = nil;
    nativeError = [NSError errorWithDomain:@"native" code:17 userInfo:nil]; reflectionValue = [NSObject new];
    CoverageArchive *archive = [CoverageArchive new]; archive.device = device;
    shader_record = (id)archive; shader_lookup = (id)archive;
    shader_queue = dispatch_queue_create("fixture.capture", DISPATCH_QUEUE_SERIAL);
    options_selectors[PipelineCompute] = @selector(newComputePipelineStateWithDescriptor:options:reflection:error:);
    options_async_selectors[PipelineCompute] = @selector(newComputePipelineStateWithDescriptor:options:completionHandler:);
    atomic_store(&shader_ready, true); install_shader_device(device.class);
    NSError *error = nil; id reflection = nil;
    assert([device newComputePipelineStateWithFunction:function error:&error] && error == nil);
    assert([device newComputePipelineStateWithFunction:function options:MTLPipelineOptionBindingInfo reflection:&reflection error:&error]);
    assert(reflection == reflectionValue && nativeCalls == 2 && lookupCalls == 2);
    __block int callbacks = 0;
    [device newComputePipelineStateWithFunction:function completionHandler:^(id pipeline, NSError *failure) { assert(pipeline && !failure); callbacks++; }];
    [device newComputePipelineStateWithFunction:function options:MTLPipelineOptionBindingInfo completionHandler:^(id pipeline, id reflected, NSError *failure) {
        assert(pipeline && reflected == reflectionValue && !failure); callbacks++;
    }];
    assert(callbacks == 2 && nativeCalls == 4);
    dispatch_sync(shader_queue, ^{}); assert(recorded == 4); // native methods calling each other never double-record
    lookupHit = YES;
    assert([device newComputePipelineStateWithFunction:function error:NULL]);
    assert(nativeCalls == 4);
    int lookups = lookupCalls;
    assert([device newComputePipelineStateWithFunction:function options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:NULL error:NULL]);
    assert(lookupCalls == lookups && nativeCalls == 5);
    lookupHit = NO; failNative = YES;
    assert(![device newComputePipelineStateWithFunction:function options:MTLPipelineOptionBindingInfo reflection:&reflection error:&error]);
    assert(error == nativeError && reflection == reflectionValue);
    [device newComputePipelineStateWithFunction:function completionHandler:^(id pipeline, NSError *failure) { assert(!pipeline && failure == nativeError); callbacks++; }];
    assert(callbacks == 3);
    [device newComputePipelineStateWithFunction:function completionHandler:nil]; assert(nilHandler);
    CoverageFunction *invalid = [CoverageFunction new]; invalid.fragment = YES; error = nil;
    assert(![device newComputePipelineStateWithFunction:invalid error:&error] && error == nativeError);
    dispatch_sync(shader_queue, ^{}); assert(recorded == 6);

    // Exceptions from initial native calls, lookup calls, retries or game
    // callbacks must release exactly one build and preserve the exception.
    atomic_store(&shader_capture_suspended, true); failNative = NO;
    for (int withOptions = 0; withOptions < 2; withOptions++) {
        void (^invoke)(void (^)(id, NSError *)) = ^(void (^handler)(id, NSError *)) {
            if (withOptions) {
                [device newComputePipelineStateWithFunction:function options:MTLPipelineOptionBindingInfo
                    completionHandler:handler ? ^(id pipeline, id reflection, NSError *error) { handler(pipeline, error); } : nil];
            } else [device newComputePipelineStateWithFunction:function completionHandler:handler];
        };
        for (int path = 0; path < 3; path++) {
            shader_lookup = path == 0 ? nil : (id)archive;
            lookupHit = NO; throwLookup = path == 1; throwNative = !throwLookup;
            BOOL caught = NO;
            @try { invoke(^(id pipeline, NSError *error) { assert(NO); }); }
            @catch (NSException *exception) {
                caught = YES; assert([exception.name isEqual:throwLookup ? @"LookupCompute" : @"NativeCompute"]);
            }
            assert(caught && atomic_load(&game_pipeline_builds) == 0 && in_pipeline_hook == 0);
        }
        throwLookup = NO; throwNative = YES;
        BOOL caught = NO;
        @try { invoke(nil); } @catch (NSException *exception) { caught = [exception.name isEqual:@"NativeCompute"]; }
        assert(caught && atomic_load(&game_pipeline_builds) == 0 && in_pipeline_hook == 0);
        throwNative = NO;
        for (int hit = 0; hit < 2; hit++) {
            shader_lookup = (id)archive; lookupHit = hit;
            __block int called = 0; caught = NO;
            @try { invoke(^(id pipeline, NSError *error) {
                assert(pipeline && !error); called++;
                @throw [NSException exceptionWithName:@"GameComputeCallback" reason:nil userInfo:nil];
            }); } @catch (NSException *exception) { caught = [exception.name isEqual:@"GameComputeCallback"]; }
            assert(caught && called == 1 && atomic_load(&game_pipeline_builds) == 0 && in_pipeline_hook == 0);
        }
    }

    shader4_queue = dispatch_queue_create("fixture.capture4", DISPATCH_QUEUE_SERIAL);
    shader4_device = (id)device; shader4_serializer = (id)[NSObject new]; atomic_store(&shader4_ready, true);
    assert(install_shader4_device(device.class));
    failNative = NO;
    CoverageCompiler *compiler = [device newCompilerWithDescriptor:nil error:NULL];
    assert([compiler newRenderPipelineStateBySpecializationWithDescriptor:nil pipeline:reflectionValue error:NULL]);
    __block int specialized = 0;
    id task = [compiler newRenderPipelineStateBySpecializationWithDescriptor:nil pipeline:reflectionValue completionHandler:^(id pipeline, NSError *failure) { assert(pipeline && !failure); specialized++; }];
    assert(task && specialized == 1);
    MTL4CompilerDescriptor *foreign = [MTL4CompilerDescriptor new]; foreign.pipelineDataSetSerializer = (id)[NSObject new];
    CoverageCompiler *uncaptured = [device newCompilerWithDescriptor:foreign error:NULL];
    assert([uncaptured newRenderPipelineStateBySpecializationWithDescriptor:nil pipeline:reflectionValue error:NULL]);
    failNative = YES; error = nil;
    assert(![compiler newRenderPipelineStateBySpecializationWithDescriptor:nil pipeline:reflectionValue error:&error] && error == nativeError);
    dispatch_sync(shader4_queue, ^{}); assert(shader4_generation == 2);

    CoverageDelegate *delegate = [CoverageDelegate new]; mulg_graphics_set_delegate(delegate);
    previous_fx_denoised = (IMP)makeFX; previous_fx4_denoised = (IMP)makeFX4;
    failNative = NO;
    assert(mulg_fx_denoised(nil, NULL, device)); assert(mulg_fx4_denoised(nil, NULL, device, compiler)); assert(detected == 2);
    mulg_graphics_begin_own_metalfx(); assert(mulg_fx_denoised(nil, NULL, device)); mulg_graphics_end_own_metalfx();
    gameCaller = NO; assert(mulg_fx4_denoised(nil, NULL, device, compiler));
    gameCaller = YES; failNative = YES; assert(!mulg_fx_denoised(nil, NULL, device)); assert(detected == 2);
    puts("PASS: compute capture/fallback/reflection, captured specialization and denoised MetalFX caller boundaries");
    return 0;
} }
