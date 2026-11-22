#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import Testing

@Suite("Bounded virtual motion")
struct MotionDeliveryTests {
    @Test func suspendedQueuesDoNotAccumulateOrDeliverAfterStop() throws {
        let module = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let hooks = module.appendingPathComponent("Sources/MulgControlsHooks")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("fixture.m"), executable = folder.appendingPathComponent("fixture")
        try Data("""
            #include "MulgMotionHooks.m"
            #include <assert.h>
            #include <stdatomic.h>
            #include <unistd.h>
            static _Atomic(int) captures, delivered;
            static char key;
            static void wait_for_samples(void) {
                for (int i = 0; i < 1000 && atomic_load(&captures) < 4; i++) usleep(1000);
                assert(atomic_load(&captures) >= 4);
            }
            int main(void) { @autoreleasepool {
                NSObject *manager = [NSObject new]; NSOperationQueue *queue = [NSOperationQueue new]; queue.suspended = YES;
                mulg_motion_configure(YES);
                start_timer(manager, &key, 0.01, queue, ^id{ return @(atomic_fetch_add(&captures, 1) + 1); }, ^(id sample) { atomic_fetch_add(&delivered, 1); });
                wait_for_samples(); assert(queue.operationCount == 1);
                stop_timer(manager, &key);
                queue.suspended = NO; [queue waitUntilAllOperationsAreFinished];
                assert(atomic_load(&delivered) == 0 && mulg_clock_users == 0);
                queue.suspended = YES; atomic_store(&captures, 0);
                start_timer(manager, &key, 0.01, queue, ^id{ return @(atomic_fetch_add(&captures, 1) + 1); }, ^(id sample) {
                    assert([sample intValue] >= 4); atomic_fetch_add(&delivered, 1); stop_timer(manager, &key);
                });
                wait_for_samples(); assert(queue.operationCount == 1);
                queue.suspended = NO; [queue waitUntilAllOperationsAreFinished];
                assert(atomic_load(&delivered) == 1 && mulg_clock_users == 0);
                queue.suspended = YES; atomic_store(&captures, 0);
                start_timer(manager, &key, 0.01, queue, ^id{ return @(atomic_fetch_add(&captures, 1) + 1); }, ^(id sample) { atomic_fetch_add(&delivered, 1); });
                wait_for_samples(); mulg_motion_configure(NO);
                queue.suspended = NO; [queue waitUntilAllOperationsAreFinished];
                assert(atomic_load(&delivered) == 1 && mulg_clock_users == 0);
                assert(objc_getAssociatedObject(manager, &kMotionActiveKey) == nil);
                mulg_motion_configure(YES);
                start_timer(manager, &kGyroTimerKey, 1, nil, ^id{ return nil; }, ^(id sample) {});
                start_timer(manager, &kMotionTimerKey, 1, nil, ^id{ return nil; }, ^(id sample) {});
                stop_timer(manager, &kGyroTimerKey);
                assert(objc_getAssociatedObject(manager, &kGyroActiveKey) == nil);
                assert(objc_getAssociatedObject(manager, &kMotionActiveKey) != nil && mulg_clock_users == 1);
                stop_timer(manager, &kMotionTimerKey);
                assert(mulg_clock_users == 0);
                return 0;
            } }
            """.utf8).write(to: source)
        func run(_ path: String, _ args: [String]) throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = args
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }
        let built = try run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-fblocks", "-I", hooks.path,
            "-I", hooks.appendingPathComponent("include").path, source.path, hooks.appendingPathComponent("MulgMotionMath.m").path,
            "-framework", "Foundation", "-framework", "CoreGraphics", "-o", executable.path])
        try #require(built.0 == 0, Comment(rawValue: built.1))
        let result = try run(executable.path, [])
        #expect(result.0 == 0, Comment(rawValue: result.1))
    }
}
#endif
