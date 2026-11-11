import Foundation
@main struct SocketChecks {
    static func main() {
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "fd-pressure-unprepared": try descriptorPressure(prepared: false)
            case "fd-pressure-prepared": try descriptorPressure(prepared: true)
            case "fd-hard-cap", "fd-keep-higher":
                var before = rlimit(), after = rlimit()
                guard getrlimit(RLIMIT_NOFILE, &before) == 0 else { throw SocketError.configure(errno) }
                let actual = try AppFileDescriptorBudget.prepare()
                guard getrlimit(RLIMIT_NOFILE, &after) == 0,
                      after.rlim_max == before.rlim_max, actual == before.rlim_cur else {
                    throw SocketTransportScenarios.Failure(description: "budget changed inherited hard cap or lowered existing soft limit")
                }
                print("PASS: descriptor budget respects inherited limits")
            default: print("PASS: \(try SocketTransportScenarios.runAll()) socket transport checks (not the full XCTest suite)")
            }
        }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    /// Each pressure case runs in its own child with an inherited 256-FD limit.
    /// Real descriptors and temporary sockets reproduce startup starvation.
    static func descriptorPressure(prepared: Bool) throws {
        signal(SIGPIPE, SIG_IGN)
        if prepared { try AppFileDescriptorBudget.prepare() }
        let events = SocketTransportScenarios.Events()
        let primaryPath = SocketTransportScenarios.path(), compatibilityPath = SocketTransportScenarios.path()
        let primary = EventSocketServer(path: primaryPath), compatibility = EventSocketServer(path: compatibilityPath)
        defer { primary.stop(); compatibility.stop() }
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors { close(descriptor) } }
        for _ in 0..<300 {
            let descriptor = open("/dev/null", O_RDONLY)
            guard descriptor >= 0 else { break }
            descriptors.append(descriptor)
        }
        if !prepared {
            do {
                try primary.start { events.append($0) }
                throw SocketTransportScenarios.Failure(description: "unprepared baseline unexpectedly survived descriptor exhaustion")
            } catch SocketError.create(let code) where code == EMFILE {
                print("PASS: unprepared baseline reproduces socket create(EMFILE)")
                return
            }
        }
        guard descriptors.count == 300 else {
            throw SocketTransportScenarios.Failure(description: "prepared process could not hold watcher descriptor pressure")
        }
        try primary.start { events.append($0) }
        try compatibility.start { events.append($0) }
        let first = try SocketTransportScenarios.Peer(primaryPath)
        let second = try SocketTransportScenarios.Peer(compatibilityPath)
        guard first.send(try SocketTransportScenarios.line("primary-pressure")),
              second.send(try SocketTransportScenarios.line("compatibility-pressure")), events.wait(2),
              Set(events.all.map(\.sessionId)) == ["primary-pressure", "compatibility-pressure"] else {
            throw SocketTransportScenarios.Failure(description: "event delivery failed under watcher descriptor pressure")
        }
        print("PASS: primary and compatibility sockets deliver under 300 held descriptors")
    }
}
