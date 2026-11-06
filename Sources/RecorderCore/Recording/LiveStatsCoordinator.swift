import Foundation

/// Duration and size of a recording's media on disk.
/// Coordinates disk inspection of active recordings to:
/// 1. Coalesce concurrent requests into a single-flight scan.
/// 2. Cache stats for an explicit short freshness bound (avoiding repetitive full directory scans).
/// 3. Offload blocking disk I/O onto a dedicated executor so Hummingbird and cooperative threads remain responsive.
/// 4. Invalidate / update on append, retry, stop, delete, and finalization.
public actor LiveStatsCoordinator {
    public typealias Inspector = @Sendable (URL) -> MediaStats

    public struct Options: Sendable {
        public var freshness: TimeInterval

        public init(freshness: TimeInterval = 2.0) {
            self.freshness = freshness
        }
    }

    private struct Entry: Sendable {
        var stats: MediaStats
        var recordedAt: Date
    }

    private struct InFlightScan {
        let scanID: UUID
        let task: Task<MediaStats, Never>
    }

    private var cache: [UUID: Entry] = [:]
    private var inFlight: [UUID: InFlightScan] = [:]
    private var generations: [UUID: Int] = [:]

    public let freshness: TimeInterval
    private let now: NowProvider
    private let ioQueue: DispatchQueue
    private let inspector: Inspector

    public private(set) var totalScans: Int = 0
    public private(set) var scansByID: [UUID: Int] = [:]

    public init(
        freshness: TimeInterval = 2.0,
        now: @escaping NowProvider = { Date() },
        ioQueue: DispatchQueue = DispatchQueue(
            label: "com.lume.recorder.live-stats-io",
            qos: .utility,
            attributes: .concurrent
        ),
        inspector: @escaping Inspector = { MediaInspector.stats(in: $0) }
    ) {
        self.freshness = freshness
        self.now = now
        self.ioQueue = ioQueue
        self.inspector = inspector
    }

    /// Returns stats for the active recording in `directory`.
    /// Concurrent callers for the same `id` share an in-flight scan.
    /// Subsequent callers within `freshness` receive the cached stats.
    public func stats(for id: UUID, in directory: URL) async -> MediaStats {
        let currentTime = now()

        // 1. Fresh cache hit
        if let entry = cache[id], currentTime.timeIntervalSince(entry.recordedAt) < freshness {
            return entry.stats
        }

        // 2. Coalesce onto in-flight scan
        if let existing = inFlight[id] {
            return await existing.task.value
        }

        // 3. Initiate single-flight scan on dedicated I/O executor
        let gen = generations[id, default: 0]
        let scanID = UUID()
        totalScans += 1
        scansByID[id, default: 0] += 1

        let queue = ioQueue
        let inspect = inspector
        let task = Task<MediaStats, Never> {
            await withCheckedContinuation { continuation in
                queue.async {
                    let s = inspect(directory)
                    continuation.resume(returning: s)
                }
            }
        }

        inFlight[id] = InFlightScan(scanID: scanID, task: task)
        let result = await task.value

        // Clean up in-flight pointer if it wasn't superseded
        if inFlight[id]?.scanID == scanID {
            inFlight.removeValue(forKey: id)
        }

        // Only cache if this recording wasn't invalidated during the scan
        if generations[id, default: 0] == gen {
            cache[id] = Entry(stats: result, recordedAt: now())
        }

        return result
    }

    /// Read cached stats without triggering an inspection.
    public func cachedStats(for id: UUID) -> MediaStats? {
        guard let entry = cache[id], now().timeIntervalSince(entry.recordedAt) < freshness else {
            return nil
        }
        return entry.stats
    }

    /// Directly updates cached stats (e.g. from an authoritative inspection).
    public func update(_ id: UUID, stats: MediaStats) {
        generations[id, default: 0] += 1
        cache[id] = Entry(stats: stats, recordedAt: now())
    }

    /// Invalidates cached stats and cancels any in-flight scan for `id`.
    /// Called on retry, stop, delete, and finalization.
    public func invalidate(_ id: UUID) {
        generations[id, default: 0] += 1
        cache.removeValue(forKey: id)
        if let scan = inFlight.removeValue(forKey: id) {
            scan.task.cancel()
        }
    }

    /// Notifies that media was appended; invalidates cache so the next poll refreshes.
    public func didAppendSegment(for id: UUID) {
        invalidate(id)
    }

    /// Returns the number of disk scans executed for `id`.
    public func scanCount(for id: UUID) -> Int {
        scansByID[id] ?? 0
    }

    /// Returns the total number of scans executed across all recordings.
    public func totalScanCount() -> Int {
        totalScans
    }

    /// Resets all scan counters (for testing).
    public func resetScanCounts() {
        totalScans = 0
        scansByID.removeAll()
    }

    /// Discards all cached entries and in-flight scans.
    public func reset() {
        cache.removeAll()
        for (_, scan) in inFlight {
            scan.task.cancel()
        }
        inFlight.removeAll()
        generations.removeAll()
    }
}
