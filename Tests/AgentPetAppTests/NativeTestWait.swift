import Foundation

/// Wait for a native callback/layout condition, rather than inferring it from
/// a sleep. A busy run-loop turn may outlast the requested run(until:) date.
@MainActor
enum NativeTestWait {
    static func until(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}
