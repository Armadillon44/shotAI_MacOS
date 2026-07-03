import Foundation

/// Atomic file write, ported from `shotAI-original/src/main/atomic-write.ts`:
/// write a sibling `.tmp` file, then `rename(2)` over the destination — POSIX
/// rename atomically replaces, so a crash/power-loss mid-write can't corrupt the
/// target (the manifest is the highest-churn user-data file). The Windows
/// EPERM-retry loop doesn't apply on macOS and is intentionally dropped.
public func writeFileAtomic(_ data: Data, to path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tmp = "\(path).\(getpid()).tmp"
    try data.write(to: URL(fileURLWithPath: tmp))
    if rename(tmp, path) != 0 {
        let err = errno
        try? FileManager.default.removeItem(atPath: tmp) // never leave a stray .tmp
        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
}
