import Foundation
import AgentPetCore

/// Single binary, two roles:
/// - `agentpet hook ...` runs the lightweight CLI helper (issue #4).
/// - no arguments launches the menu bar app.
@main
struct AgentPetMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "identity", "integration", "login-item":
            IdentityCLI.run(args)
            return
        case "hook":
            HookCLI.run(arguments: Array(args.dropFirst()))
        case "migrate-retired-hooks":
            if args.count == 3, args[1] == "--rollback" {
                do { try HookInstaller.rollbackSettings(backup: args[2]); print("Retired Hook rollback complete") }
                catch { fputs("Retired Hook rollback refused: current configuration changed or backup invalid\n", stderr); exit(1) }
            } else if args.count == 1 || (args.count == 2 && args[1] == "--apply") {
                let reports = RetiredHookMigration.run(dryRun: args.count == 1)
                for report in reports {
                    print("\(report.kind.rawValue): \(report.status.rawValue) \(report.path)" + (report.backup.map { " backup=" + $0 } ?? ""))
                    if let diagnostic = report.diagnostic { print(diagnostic) }
                }
                if reports.contains(where: { $0.status == .failed }) { exit(1) }
            } else { fputs("usage: agentpet migrate-retired-hooks [--apply | --rollback BACKUP]\n", stderr); exit(2) }
            return
        case "run":
            RunCLI.run(arguments: Array(args.dropFirst()))
        default:
            do { try AppFileDescriptorBudget.prepare() }
            catch { fputs("AgentPet file descriptor budget unavailable: \(error)\n", stderr) }
            if AgentPetPaths.isLocal {
                guard LocalInstanceLock.acquire() else { return }
            }
            AgentPetApp.main()
        }
    }
}

private enum LocalInstanceLock {
    nonisolated(unsafe) private static var lock: AgentPetInstanceLock?
    static func acquire() -> Bool {
        let candidate = AgentPetInstanceLock()
        guard candidate.acquire(directories: [AgentPetPaths.baseDir] + [AgentPetPaths.migratedLocalDir].compactMap { $0 }) else { return false }
        lock = candidate
        return true
    }
}
