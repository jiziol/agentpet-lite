import Foundation
@main struct ArchiveChecks {
    static func main() {
        do { _ = try ArchiveReliabilityScenarios.runAll() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
