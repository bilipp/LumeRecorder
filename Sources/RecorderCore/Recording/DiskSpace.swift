import Foundation

/// Free/total bytes of the volume holding a path.
public struct DiskSpace: Sendable, Hashable {
    public var freeBytes: Int64
    public var totalBytes: Int64

    public init(freeBytes: Int64, totalBytes: Int64) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }
}

public protocol DiskSpaceProviding: Sendable {
    func space(at url: URL) -> DiskSpace?
}

/// `statvfs` via `FileManager.attributesOfFileSystem` (works on Linux too).
public struct FileSystemDiskSpace: DiskSpaceProviding {
    public init() {}

    public func space(at url: URL) -> DiskSpace? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value
        else { return nil }
        return DiskSpace(freeBytes: free, totalBytes: total)
    }
}
