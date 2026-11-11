import Foundation
import Darwin

/// GUI file watchers and native transports share one process descriptor budget.
/// Raise only this process's soft limit; keep the inherited hard limit intact.
enum AppFileDescriptorBudget {
    @discardableResult
    static func prepare() throws -> rlim_t {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let target = min(rlim_t(4096), limits.rlim_max)
        guard limits.rlim_cur < target else { return limits.rlim_cur }
        limits.rlim_cur = target
        guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return limits.rlim_cur
    }
}
