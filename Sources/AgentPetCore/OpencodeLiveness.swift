import Foundation
import Darwin

public enum OpencodeLiveness {
    /// EPERM is alive; only ESRCH proves absence. Other errors are inconclusive.
    public static func processIsAlive(_ pid: Int32) -> Bool? {
        guard pid > 1 else { return nil }
        if let info = processInfo(pid), info.pbi_status == UInt32(SZOMB) { return false }
        if kill(pid, 0) == 0 { return true }
        if errno == EPERM { return true }
        return errno == ESRCH ? false : nil
    }

    /// Kernel birth time distinguishes a restored owner from a reused PID.
    public static func processStartedAt(_ pid: Int32) -> Date? {
        guard let info = processInfo(pid) else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    private static func processInfo(_ pid: Int32) -> proc_bsdinfo? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
}
