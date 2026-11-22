#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdatomic.h>
typedef id (*NewPipeline)(id, SEL, id, NSError **) __attribute__((ns_returns_retained));
typedef void (*NewPipelineAsync)(id, SEL, id, id);
static __thread int in_pipeline_hook;
typedef enum { PipelineRender } PipelineKind;
static BOOL throwing = YES;
static id with_archive(id device, id descriptor, BOOL *addedLookup) { if (addedLookup) *addedLookup = NO; return nil; }
static void record_pipeline(id descriptor, PipelineKind kind, id pipeline) {}
static void note_archive_fallback(NSError *error) {}
static int game_builds;
static void game_build_seen(void) {}
static void game_build_began(void) { game_builds++; }
static void game_build_ended(void) { game_builds--; }
static id __attribute__((ns_returns_retained)) native_sync(id device, SEL selector, id descriptor, NSError **error) {
    if (throwing) @throw [NSException exceptionWithName:@"GameProbe" reason:@"Expected probe failure" userInfo:nil];
    return [NSObject new];
}
static void native_async(id device, SEL selector, id descriptor, MTLNewRenderPipelineStateCompletionHandler handler) {
    if (throwing) @throw [NSException exceptionWithName:@"GameProbe" reason:@"Expected probe failure" userInfo:nil];
    if (handler) handler((id)[NSObject new], nil);
}
#define ORIGINAL(device, command, replacement) (command == @selector(async) ? (IMP)native_async : (IMP)native_sync)
// __PRODUCTION__
int main(void) { @autoreleasepool {
    @try { (void)mulg_render_pipeline(nil, @selector(sync), nil, NULL); } @catch (NSException *error) {}
    assert(in_pipeline_hook == 0); assert(game_builds == 0);
    @try { mulg_render_pipeline_async(nil, @selector(async), nil, nil); } @catch (NSException *error) {}
    assert(in_pipeline_hook == 0); assert(game_builds == 0);
    @try { mulg_render_pipeline_async(nil, @selector(async), nil, ^(id pipeline, NSError *error) {}); }
    @catch (NSException *error) {}
    assert(in_pipeline_hook == 0 && game_builds == 0);
    throwing = NO;
    assert(mulg_render_pipeline(nil, @selector(sync), nil, NULL) != nil);
    assert(in_pipeline_hook == 0); assert(game_builds == 0);
    __block BOOL called = NO;
    @try { mulg_render_pipeline_async(nil, @selector(async), nil, ^(id pipeline, NSError *error) {
        called = YES;
        @throw [NSException exceptionWithName:@"GameCallback" reason:@"Expected callback exception" userInfo:nil];
    }); } @catch (NSException *error) {}
    assert(called && in_pipeline_hook == 0 && game_builds == 0);
    puts("PASS: native shader exceptions propagate while restoring the per-thread hook guard");
} }
