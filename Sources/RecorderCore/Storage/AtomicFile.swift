import Foundation
#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// Crash-safe file replacement: write a sibling temp file, flush it, then
/// `rename(2)` it over the target. Readers see either the old or the new file,
/// never a torn one.
enum AtomicFile {
    static let tempSuffix = ".tmp"

    static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)\(tempSuffix)")
        guard FileManager.default.createFile(
            atPath: temp.path,
            contents: data,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        if let handle = FileHandle(forUpdatingAtPath: temp.path) {
            try? handle.synchronize()
            try? handle.close()
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Removes temp files a crash left behind in `directory`.
    static func removeStaleTempFiles(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(tempSuffix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
