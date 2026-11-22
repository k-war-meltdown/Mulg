import Foundation
import Darwin

@main struct ShutdownDeadlineFixture {
    static func main() {
        let watchdog = ShutdownWatchdog(deadline: 0.08) { _exit(75) }
        if CommandLine.arguments.last == "completed" {
            watchdog.cancel()
            Thread.sleep(forTimeInterval: 0.16)
            exit(0)
        }
        // Model each synchronous delegate/native callback; the calling thread cannot progress.
        withExtendedLifetime(watchdog) { Thread.sleep(forTimeInterval: 60) }
        exit(76)
    }
}
