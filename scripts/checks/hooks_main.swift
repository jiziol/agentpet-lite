import Foundation
@main struct HookChecks {
    static func main() {
        do { _ = try HookOwnershipScenarios.runAll() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
