#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Graphics hook ownership")
struct HookLifetimeTests {
    private func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test func originalDrawablesDevicesAndCompilerClassesKeepTheirOwnership() throws {
        let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let graphics = module.appendingPathComponent("Sources/MulgGraphicsHooks")
        let engine = module.deletingLastPathComponent().appendingPathComponent("engine/Sources/MulgEngineHooks")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("fixture.m"), executable = folder.appendingPathComponent("fixture")
        try Data("""
            #include "MulgGraphicsHooks.m"
            #include <assert.h>
            BOOL mulg_engine_is_game_caller(const void *caller) { return YES; }
            @interface FixtureDrawable : NSObject
            @property NSMutableArray *handlers;
            @property double presentedTime;
            @property CAMetalLayer *layer;
            @property id texture;
            - (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler;
            - (void)fire;
            - (void)present;
            - (void)presentAtTime:(double)time;
            - (void)presentAfterMinimumDuration:(double)duration;
            @end
            @implementation FixtureDrawable
            - (instancetype)init { if ((self = [super init])) _handlers = [NSMutableArray new]; return self; }
            - (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { [_handlers addObject:[handler copy]]; }
            - (void)fire { NSArray *all = [_handlers copy]; [_handlers removeAllObjects]; for (MTLDrawablePresentedHandler h in all) h((id)self); }
            - (void)present {}
            - (void)presentAtTime:(double)time {}
            - (void)presentAfterMinimumDuration:(double)duration {}
            @end
            static int pipelines;
            @interface FixturePipeline : NSObject @end
            @implementation FixturePipeline
            - (instancetype)init { if ((self = [super init])) pipelines++; return self; }
            - (void)dealloc { pipelines--; }
            @end
            @interface CompilerA : NSObject
            - (id)newComputePipelineStateWithDescriptor:(id)d compilerTaskOptions:(id)o error:(NSError **)e;
            @end
            @implementation CompilerA
            - (id)newComputePipelineStateWithDescriptor:(id)d compilerTaskOptions:(id)o error:(NSError **)e { return [FixturePipeline new]; }
            @end
            @interface CompilerB : CompilerA @end
            @implementation CompilerB
            - (id)newComputePipelineStateWithDescriptor:(id)d compilerTaskOptions:(id)o error:(NSError **)e { return [FixturePipeline new]; }
            @end
            @interface FactoryA : NSObject
            - (id)newCompilerWithDescriptor:(id)d error:(NSError **)e;
            @end
            @implementation FactoryA
            - (id)newCompilerWithDescriptor:(id)d error:(NSError **)e { return [CompilerA new]; }
            @end
            @interface FactoryB : FactoryA @end
            @implementation FactoryB
            - (id)newCompilerWithDescriptor:(id)d error:(NSError **)e { return [CompilerB new]; }
            @end
            @interface WrongFactory : NSObject
            - (id)newCompilerWithDescriptor:(NSUInteger)d error:(NSError **)e;
            @end
            @implementation WrongFactory
            - (id)newCompilerWithDescriptor:(NSUInteger)d error:(NSError **)e { return nil; }
            @end
            @interface FixtureQueue : NSObject
            @property id device;
            @property BOOL failBuffer;
            - (id)commandBuffer;
            - (void)waitForDrawable:(id)drawable;
            - (void)signalDrawable:(id)drawable;
            - (void)signalEvent:(id)event value:(uint64_t)value;
            @end
            @implementation FixtureQueue
            - (id)commandBuffer { return _failBuffer ? nil : [NSClassFromString(@"FixtureBuffer") new]; }
            - (void)waitForDrawable:(id)drawable {}
            - (void)signalDrawable:(id)drawable { assert(skip_present(drawable, @selector(presentAtTime:), 77)); }
            - (void)signalEvent:(id)event value:(uint64_t)value {}
            @end
            static int commits, presents;
            static double presentValue;
            @interface FixtureBuffer : NSObject
            - (void)commit;
            - (void)presentDrawable:(id)drawable;
            - (void)presentDrawable:(id)drawable atTime:(double)time;
            - (void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration;
            - (void)addCompletedHandler:(id)handler;
            - (void)encodeWaitForEvent:(id)event value:(uint64_t)value;
            @end
            @implementation FixtureBuffer
            - (void)commit { commits++; }
            - (void)presentDrawable:(id)drawable { presents++; }
            - (void)presentDrawable:(id)drawable atTime:(double)time { presents++; presentValue = time; }
            - (void)presentDrawable:(id)drawable afterMinimumDuration:(double)duration { presents++; presentValue = duration; }
            - (void)addCompletedHandler:(id)handler {}
            - (void)encodeWaitForEvent:(id)event value:(uint64_t)value {}
            @end
            static id acquire_after_retirement(id layer, SEL selector) {
                assert([objc_getAssociatedObject(layer, &kSourcePendingKey) count] == 1);
                return nil;
            }
            @interface FixtureDevice : NSObject
            @property BOOL failBuffer;
            - (id)newCommandQueue;
            - (id)newSharedEvent;
            @end
            @implementation FixtureDevice
            - (id)newCommandQueue { FixtureQueue *q = [FixtureQueue new]; q.device = self; q.failBuffer = self.failBuffer; return q; }
            - (id)newSharedEvent { return [NSObject new]; }
            @end
            @interface FixtureGraphicsDelegate : NSObject <MulgGraphicsDelegate>
            @property int encodes;
            @property int failures;
            @end
            @implementation FixtureGraphicsDelegate
            - (BOOL)upscale:(id)source into:(id)output commandBuffer:(id)buffer extendedRange:(BOOL)range { assert(buffer); self.encodes++; return YES; }
            - (void)layerUsesUnsupportedPresentPath:(id)layer { self.failures++; }
            - (void)mainLayerCandidateChanged:(id)layer {}
            - (void)gameCreatedMetalFXObject:(id)feature {}
            - (void)framePresentedAtTime:(double)time {}
            @end
            static id next_output;
            static id acquire_output(id layer, SEL selector) { return next_output; }
            int main(void) { @autoreleasepool {
                FixtureDrawable *replacement = [FixtureDrawable new]; replacement.presentedTime = 12.5;
                __weak FixtureDrawable *original;
                __block int called = 0;
                @autoreleasepool {
                    FixtureDrawable *game = [FixtureDrawable new]; original = game;
                    objc_setAssociatedObject(game, &kReplacementKey, replacement, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    forward_presented_handlers(@[^(id arg) { assert(arg == original); assert(mulg_presented_time(arg, @selector(presentedTime)) == 12.5); called++; }], (id)game, (id)replacement);
                }
                assert(original != nil);
                @autoreleasepool { [replacement fire]; }
                assert(called == 1 && original == nil);
                @autoreleasepool {
                    FixtureDrawable *game = [FixtureDrawable new], *output = [FixtureDrawable new]; original = game;
                    objc_setAssociatedObject(game, &kReplacementKey, output, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    forward_presented_handlers(@[^(id arg) { assert(false); }], (id)game, (id)output);
                    MulgPendingFrame *frame = [MulgPendingFrame new];
                    frame->_drawable = game; frame->_buffer = (id)[FixtureBuffer new];
                    objc_setAssociatedObject(game, &kPendingBufferKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    discard_pending(frame); discard_pending(frame);
                    assert(commits == 1 && objc_getAssociatedObject(game, &kReplacementKey) == nil);
                }
                assert(original == nil);
                CAMetalLayer *source = [CAMetalLayer layer], *destination = [CAMetalLayer layer];
                source.maximumDrawableCount = 3; destination.maximumDrawableCount = 2;
                assert(pending_budget(source, destination) == 1);
                objc_setAssociatedObject(source, &kWrappedSourceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSMutableArray *pending = [NSMutableArray new], *drawables = [NSMutableArray new];
                for (int i = 0; i < 2; i++) {
                    FixtureDrawable *game = [FixtureDrawable new], *output = [FixtureDrawable new]; game.layer = source;
                    MulgPendingFrame *frame = [MulgPendingFrame new]; frame->_drawable = game; frame->_buffer = (id)[FixtureBuffer new];
                    objc_setAssociatedObject(game, &kReplacementKey, output, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    objc_setAssociatedObject(game, &kPendingBufferKey, frame, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [drawables addObject:game]; [pending addObject:frame];
                }
                objc_setAssociatedObject(source, &kSourcePendingKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                mulg_source_layer = source; mulg_upscaling_layer = destination;
                atomic_store(&mulg_source_address, address(source));
                previous_next_drawable = (IMP)acquire_after_retirement;
                int before = commits;
                assert(mulg_next_drawable(source, @selector(nextDrawable)) == nil && commits == before + 1);
                // Detach commits/presents the remaining encoded frame. A late game present must
                // never show the hidden source or commit that buffer a second time.
                mulg_graphics_set_upscaling_layer(nil);
                assert(commits == before + 2 && presents == 1 && pending.count == 0);
                assert(skip_present(drawables.lastObject, @selector(presentAtTime:), 42));
                assert(commits == before + 2 && presents == 1);
                // A pending replacement is still honoured after the active source address changed.
                FixtureDrawable *oldFrame = [FixtureDrawable new]; oldFrame.layer = source;
                MulgPendingFrame *oldPending = [MulgPendingFrame new]; oldPending->_drawable = oldFrame; oldPending->_buffer = (id)[FixtureBuffer new];
                objc_setAssociatedObject(oldFrame, &kReplacementKey, [FixtureDrawable new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(oldFrame, &kPendingBufferKey, oldPending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                atomic_store(&mulg_source_address, address(destination));
                assert(skip_present(oldFrame, @selector(presentAtTime:), 42));
                assert(presentValue == 42 && presents == 2 && commits == before + 3);
                atomic_store(&mulg_source_address, 0);
                // Present from another thread can run as soon as native signal returns.
                // Here it runs synchronously inside that signal, before allocation/encoding.
                FixtureGraphicsDelegate *delegate = [FixtureGraphicsDelegate new]; mulg_graphics_set_delegate(delegate);
                assert(install_queue4(FixtureQueue.class) & MulgGraphicsHookMetal4Present);
                FixtureDevice *device = [FixtureDevice new]; FixtureQueue *queue = [device newCommandQueue];
                FixtureDrawable *early = [FixtureDrawable new]; early.layer = source;
                next_output = [FixtureDrawable new]; previous_next_drawable = (IMP)acquire_output;
                mulg_upscaling_layer = destination; mulg_source_layer = source;
                atomic_store(&mulg_source_address, address(source));
                before = commits; int shown = presents;
                [queue signalDrawable:early];
                assert(delegate.encodes == 1 && commits == before + 1 && presents == shown + 1 && presentValue == 77);
                assert(skip_present(early, @selector(present), 0) && commits == before + 1);
                FixtureDevice *failedDevice = [FixtureDevice new]; failedDevice.failBuffer = YES;
                FixtureQueue *failedQueue = [failedDevice newCommandQueue];
                FixtureDrawable *failed = [FixtureDrawable new]; failed.layer = source;
                [failedQueue signalDrawable:failed];
                assert(delegate.encodes == 1 && delegate.failures == 1 && commits == before + 1);
                assert(objc_getAssociatedObject(failed, &kPendingBufferKey) == nil);
                mulg_graphics_set_delegate(nil); mulg_source_layer = nil; mulg_upscaling_layer = nil;
                atomic_store(&mulg_source_address, 0);
                FixtureDevice *first = [FixtureDevice new], *second = [FixtureDevice new];
                id old = own_queue((id)first);
                assert(old == own_queue((id)first));
                assert(own_queue((id)second) != old && own_queue((id)second).device == (id)second);
                shader4_queue = dispatch_queue_create("fixture.shader", DISPATCH_QUEUE_SERIAL);
                atomic_store(&shader4_ready, true);
                assert(install_shader4_device([FactoryA class]));
                assert(!install_shader4_device([FactoryB class])); // Unsafe override stays native.
                assert(!install_shader4_device([WrongFactory class]));
                @autoreleasepool {
                    CompilerA *a = [[FactoryA new] newCompilerWithDescriptor:nil error:NULL];
                    CompilerA *b = [[FactoryB new] newCompilerWithDescriptor:nil error:NULL];
                    id firstPipeline = [a newComputePipelineStateWithDescriptor:nil compilerTaskOptions:nil error:NULL];
                    id secondPipeline = [b newComputePipelineStateWithDescriptor:nil compilerTaskOptions:nil error:NULL];
                    assert(firstPipeline != nil && secondPipeline != nil);
                }
                dispatch_sync(shader4_queue, ^{});
                assert(shader4_generation == 0 && pipelines == 0);
                return 0;
            } }
            """.utf8).write(to: source)
        let arguments = ["clang", "-fobjc-arc", "-fblocks", "-I", graphics.path, "-I", graphics.appendingPathComponent("include").path,
                         "-I", engine.appendingPathComponent("include").path, source.path,
                         graphics.appendingPathComponent("MulgRenderSurface.m").path, graphics.appendingPathComponent("MulgForcedResolution.m").path,
                         engine.appendingPathComponent("MulgMetalDeviceHooks.m").path,
                         engine.appendingPathComponent("MulgSwizzle.m").path, engine.appendingPathComponent("MulgSleepThrottle.m").path,
                         "-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore",
                         "-framework", "CoreGraphics", "-o", executable.path]
        let built = try run("/usr/bin/xcrun", arguments)
        try #require(built.0 == 0, Comment(rawValue: built.1))
        let result = try run(executable.path, [])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
#endif
