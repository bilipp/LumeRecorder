import Foundation
import Logging
import LumeRecorderKit
import ServiceLifecycle

/// Domain errors the HTTP layer maps onto status codes.
public enum RecorderError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case notFound
    case concurrencyLimit
    case insufficientStorage
    case notPlayable
}

/// Owns every recording's lifecycle: waiting for the start, admission
/// (concurrency + disk), one ffmpeg attempt at a time with retries and
/// backoff, graceful stop at the end, finalization and restart recovery.
///
/// Invariants:
/// - A recording holds a concurrency slot from admission until finalization,
///   including while it backs off between attempts.
/// - The stream URL is handed to the launcher and nowhere else; anything
///   logged or stored as `failureReason` goes through `Redactor`.
public actor RecordingScheduler: Service {
    public struct Options: Sendable {
        public var maxConcurrent: Int
        public var minFreeBytes: Int64
        public var maxRecordingDuration: TimeInterval = 12 * 3600
        public var retryInitialDelay: TimeInterval = 2
        public var retryMaxDelay: TimeInterval = 30
        /// After SIGINT, how long ffmpeg gets to finalize before SIGTERM.
        public var interruptGracePeriod: TimeInterval = 10
        /// After SIGTERM, how long before SIGKILL.
        public var terminateGracePeriod: TimeInterval = 3
        /// Don't start a new attempt with less than this much time left.
        public var minimumAttemptDuration: TimeInterval = 3
        /// An attempt that ran at least this long resets the backoff.
        public var backoffResetAfter: TimeInterval = 60
        /// An attempt that exits within this long without any segment on disk
        /// counts as a quick failure.
        public var quickExitThreshold: TimeInterval = 2
        /// After this many quick failures in a row, with nothing captured yet,
        /// the recording fails as `source_unavailable` instead of retrying for
        /// the whole window. `0` disables the check.
        public var sourceUnavailableAfterQuickExits = 5

        public init(maxConcurrent: Int, minFreeBytes: Int64) {
            self.maxConcurrent = maxConcurrent
            self.minFreeBytes = minFreeBytes
        }
    }

    public enum FailureReason {
        public static let concurrencyLimit = "concurrency_limit"
        public static let insufficientStorage = "insufficient_storage"
        public static let missed = "missed"
        public static let interrupted = "interrupted"
        public static let noSegments = "no_segments"
        public static let sourceUnavailable = "source_unavailable"
    }

    private enum Phase {
        /// Scheduled; sleeping until the start time.
        case waiting
        /// Admitted: holds a slot (running ffmpeg or backing off).
        case active
    }

    private struct Job {
        var phase: Phase
        var task: Task<Void, Never>?
        var process: (any RecordingProcess)?
        var stopRequested = false
        var deleted = false
    }

    public nonisolated let options: Options
    private let store: RecorderStore
    private let launcher: any RecordingProcessLauncher
    private let disk: any DiskSpaceProviding
    private let now: NowProvider
    private let logger: Logger

    private var jobs: [UUID: Job] = [:]
    /// "deviceID:key" → recording id; checked synchronously so two concurrent
    /// requests with one key can't both create.
    private var idempotencyIndex: [String: UUID] = [:]
    private var recovered = false
    private var shuttingDown = false

    public init(
        store: RecorderStore,
        launcher: any RecordingProcessLauncher,
        options: Options,
        disk: any DiskSpaceProviding = FileSystemDiskSpace(),
        now: @escaping NowProvider = { Date() },
        logger: Logger = Logger(label: "lume-recorder.scheduler")
    ) {
        self.store = store
        self.launcher = launcher
        self.options = options
        self.disk = disk
        self.now = now
        self.logger = logger
    }

    // MARK: Service

    /// Recovers persisted state, then waits for graceful shutdown and stops
    /// every ffmpeg process (rows stay `recording` and resume next start).
    public func run() async throws {
        await recover()
        try? await gracefulShutdown()
        await shutdown()
    }

    // MARK: Recovery

    /// Reconciles persisted rows with reality after a (re)start. Idempotent.
    public func recover() async {
        guard !recovered else { return }
        recovered = true
        let current = now()
        for record in await store.recordings() {
            if let key = record.idempotencyKey, let device = record.createdByDeviceID {
                idempotencyIndex[Self.indexKey(device, key)] = record.id
            }
            switch record.status {
            case .recording:
                if record.end > current {
                    logger.info("Resuming recording \(record.id) after restart")
                    startJob(record.id, phase: .active, resume: true)
                } else {
                    await finalize(record.id, stderrTail: nil, reasonIfEmpty: FailureReason.interrupted)
                }
            case .scheduled:
                if record.end <= current {
                    logger.info("Recording \(record.id) was missed while the server was down")
                    _ = try? await store.update(record.id) { [current] in
                        $0.status = .failed
                        $0.failureReason = FailureReason.missed
                        $0.finishedAt = current
                    }
                } else {
                    startJob(record.id, phase: .waiting, resume: false)
                }
            default:
                break
            }
        }
    }

    // MARK: Commands

    /// Validates, deduplicates (per device + idempotency key) and schedules a
    /// recording. Returns the record and whether it was newly created.
    public func create(
        _ request: CreateRecordingRequest,
        deviceID: UUID?,
        idempotencyKey: String?
    ) async throws -> (record: RecordingRecord, created: Bool) {
        let key = idempotencyKey?.trimmingCharacters(in: .whitespaces)
        if let key, !key.isEmpty, let deviceID,
           let existingID = idempotencyIndex[Self.indexKey(deviceID, key)],
           let existing = await store.recording(existingID) {
            return (existing, false)
        }

        let current = now()
        try validate(request, now: current)
        let startsNow = request.start <= current

        // Admission for immediate starts, then reserve synchronously (no
        // suspension between the check and the reservation).
        if startsNow {
            try admit()
        }
        let record = RecordingRecord(
            streamURL: request.streamURL,
            title: request.title.trimmingCharacters(in: .whitespacesAndNewlines),
            channelName: request.channelName,
            channelLogoURL: request.channelLogoURL,
            programmeDescription: request.programmeDescription,
            sourceRef: request.sourceRef,
            start: request.start,
            end: request.end,
            status: startsNow ? .recording : .scheduled,
            createdAt: current,
            startedAt: startsNow ? current : nil,
            createdByDeviceID: deviceID,
            idempotencyKey: (key?.isEmpty ?? true) ? nil : key
        )
        if let key = record.idempotencyKey, let deviceID {
            idempotencyIndex[Self.indexKey(deviceID, key)] = record.id
        }
        jobs[record.id] = Job(phase: startsNow ? .active : .waiting)
        do {
            try await store.insert(record)
        } catch {
            jobs[record.id] = nil
            if let key = record.idempotencyKey, let deviceID { idempotencyIndex[Self.indexKey(deviceID, key)] = nil }
            throw error
        }
        logger.info("Recording \(record.id) \"\(record.title)\" \(startsNow ? "starting now" : "scheduled for \(LumeRecorderCoding.formatDate(record.start))")")
        startJob(record.id, phase: startsNow ? .active : .waiting, resume: startsNow)
        return (record, true)
    }

    /// Scheduled → `cancelled`; recording → graceful stop → `completed`
    /// (or `failed` if nothing was captured). Finished recordings are returned unchanged.
    public func stop(_ id: UUID) async throws -> RecordingRecord {
        guard let record = await store.recording(id) else { throw RecorderError.notFound }
        guard let job = jobs[id] else {
            if record.status == .scheduled {
                return try await markCancelled(id) ?? record
            }
            return record
        }
        switch job.phase {
        case .waiting:
            jobs[id]?.stopRequested = true
            job.task?.cancel()
            jobs[id] = nil
            logger.info("Recording \(id) cancelled before it started")
            return try await markCancelled(id) ?? record
        case .active:
            jobs[id]?.stopRequested = true
            if let process = job.process {
                await Self.stopGracefully(process, options: options)
            } else {
                job.task?.cancel()
            }
            await job.task?.value
            logger.info("Recording \(id) stopped on request")
            return await store.recording(id) ?? record
        }
    }

    /// Stops if needed, then deletes the media and the record.
    public func delete(_ id: UUID) async throws {
        guard let record = await store.recording(id) else { throw RecorderError.notFound }
        if let job = jobs[id] {
            jobs[id]?.stopRequested = true
            jobs[id]?.deleted = true
            if let process = job.process {
                await Self.stopGracefully(process, options: options)
            } else {
                job.task?.cancel()
            }
            await job.task?.value
            jobs[id] = nil
        }
        try? FileManager.default.removeItem(at: store.mediaDirectory(for: id))
        try await store.removeRecording(id)
        if let key = record.idempotencyKey, let device = record.createdByDeviceID {
            idempotencyIndex[Self.indexKey(device, key)] = nil
        }
        logger.info("Recording \(id) deleted")
    }

    /// Stops all processes without finalizing; rows stay `recording` so they
    /// resume as a new attempt on the next start.
    public func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        let snapshot = jobs
        await withTaskGroup(of: Void.self) { group in
            for (_, job) in snapshot {
                if let process = job.process {
                    group.addTask { [options] in await Self.stopGracefully(process, options: options) }
                } else {
                    job.task?.cancel()
                }
            }
        }
        for (_, job) in snapshot {
            await job.task?.value
        }
        jobs.removeAll()
    }

    // MARK: Queries

    public var activeCount: Int {
        jobs.values.count { $0.phase == .active }
    }

    public func diskSpace() -> DiskSpace? {
        disk.space(at: store.recordingsDirectory)
    }

    // MARK: Job lifecycle

    private func startJob(_ id: UUID, phase: Phase, resume: Bool) {
        if jobs[id] == nil { jobs[id] = Job(phase: phase) }
        jobs[id]?.task = Task { [weak self] in
            await self?.runJob(id, resume: resume)
        }
    }

    private func runJob(_ id: UUID, resume: Bool) async {
        if !resume {
            guard let record = await store.recording(id) else { return }
            let delay = record.start.timeIntervalSince(now())
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return // cancelled (stop/delete/shutdown)
                }
            }
            guard let job = jobs[id], !job.stopRequested, !shuttingDown else { return }
            if job.phase == .waiting {
                do {
                    try admit()
                } catch {
                    let reason = error as? RecorderError == .concurrencyLimit
                        ? FailureReason.concurrencyLimit : FailureReason.insufficientStorage
                    jobs[id] = nil
                    logger.warning("Recording \(id) failed to start: \(reason)")
                    let current = now()
                    _ = try? await store.update(id) {
                        $0.status = .failed
                        $0.failureReason = reason
                        $0.finishedAt = current
                    }
                    return
                }
                jobs[id]?.phase = .active
            }
            let current = now()
            _ = try? await store.update(id) {
                $0.status = .recording
                $0.startedAt = $0.startedAt ?? current
            }
            logger.info("Recording \(id) started")
        }
        await recordLoop(id)
    }

    private func recordLoop(_ id: UUID) async {
        var backoff = options.retryInitialDelay
        var lastStderr: String?
        let directory = store.mediaDirectory(for: id)
        /// nil until ffmpeg's stderr says otherwise: the URL decides.
        var hlsInput: Bool?
        var quickExits = 0
        var giveUpReason: String?

        while true {
            guard let record = await store.recording(id),
                  let job = jobs[id], !job.stopRequested, !shuttingDown
            else { break }
            let remaining = record.end.timeIntervalSince(now())
            guard remaining >= options.minimumAttemptDuration else { break }
            if Self.mediaCoversWindow(record: record, directory: directory) { break }

            let attempt = record.attempts + 1
            _ = try? await store.update(id) { $0.attempts = attempt }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let spec = RecordingAttemptSpec(
                recordingID: id,
                streamURL: record.streamURL,
                outputDirectory: directory,
                attempt: attempt,
                maxDuration: remaining,
                hlsInput: hlsInput
            )

            // Re-check after the suspensions above: a stop may have arrived.
            guard jobs[id]?.stopRequested == false, !shuttingDown else { break }
            let attemptStart = now()
            do {
                let process = try launcher.launch(spec)
                jobs[id]?.process = process
                logger.info("Recording \(id) attempt \(attempt) running (\(Int(remaining)) s left)")
                let endTimer = Task { [options] in
                    do {
                        try await Task.sleep(for: .seconds(remaining))
                    } catch {
                        return
                    }
                    await Self.stopGracefully(process, options: options)
                }
                let status = await process.waitForExit()
                endTimer.cancel()
                jobs[id]?.process = nil
                lastStderr = process.stderrTail()
                logger.info("Recording \(id) attempt \(attempt) exited with status \(status)")
                if status != 0, let tail = lastStderr, !tail.isEmpty {
                    logger.debug("Recording \(id) ffmpeg: \(Redactor.redact(tail, streamURL: record.streamURL))")
                    if FFmpegArguments.isHLSExtensionMismatch(tail) {
                        hlsInput = true
                    } else if FFmpegArguments.isUnknownExtensionPickyOption(tail) {
                        hlsInput = false
                    }
                }
                // A source that never produced anything and keeps dying at open
                // is unavailable; don't hammer it for the whole window.
                let quick = now().timeIntervalSince(attemptStart) < options.quickExitThreshold
                let stopped = jobs[id]?.stopRequested != false || shuttingDown
                if quick, !stopped, MediaInspector.stats(in: directory).segmentCount == 0 {
                    quickExits += 1
                } else {
                    quickExits = 0
                }
                if options.sourceUnavailableAfterQuickExits > 0, quickExits >= options.sourceUnavailableAfterQuickExits {
                    giveUpReason = Self.failureReason(
                        fromStderr: lastStderr,
                        streamURL: record.streamURL,
                        prefix: FailureReason.sourceUnavailable
                    )
                    logger.warning("Recording \(id) source unavailable after \(quickExits) immediate exits; giving up")
                    break
                }
            } catch {
                lastStderr = String(describing: error)
                logger.error("Recording \(id) attempt \(attempt) couldn't launch: \(Redactor.redact(String(describing: error), streamURL: record.streamURL))")
            }

            guard let after = jobs[id], !after.stopRequested, !shuttingDown else { break }
            let timeLeft = record.end.timeIntervalSince(now())
            if timeLeft < options.minimumAttemptDuration { break }
            if Self.mediaCoversWindow(record: record, directory: directory) { break }

            // Early exit: back off, then retry with a new attempt (ffmpeg's
            // append_list adds the #EXT-X-DISCONTINUITY).
            if now().timeIntervalSince(attemptStart) >= options.backoffResetAfter {
                backoff = options.retryInitialDelay
            }
            let delay = min(backoff, timeLeft)
            logger.warning("Recording \(id) source ended early; retrying in \(Int(delay.rounded())) s")
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                break
            }
            backoff = min(backoff * 2, options.retryMaxDelay)
        }

        let job = jobs[id]
        if shuttingDown || job?.deleted == true {
            return
        }
        await finalize(id, stderrTail: lastStderr, reasonIfEmpty: giveUpReason)
        jobs[id] = nil
    }

    /// Writes the terminal state: `completed` if any segment exists (with
    /// `#EXT-X-ENDLIST` guaranteed), else `failed` with `reasonIfEmpty` or a
    /// redacted `no_segments` reason.
    private func finalize(_ id: UUID, stderrTail: String?, reasonIfEmpty: String?) async {
        guard let record = await store.recording(id) else { return }
        let directory = store.mediaDirectory(for: id)
        let playlist = directory.appendingPathComponent(PlaybackSigner.playlistName)
        do {
            try HLSPlaylist.ensureEndList(at: playlist)
        } catch {
            logger.warning("Recording \(id): couldn't append #EXT-X-ENDLIST: \(error)")
        }
        let stats = MediaInspector.stats(in: directory)
        let current = now()
        if stats.segmentCount > 0 {
            _ = try? await store.update(id) {
                $0.status = .completed
                $0.failureReason = nil
                $0.finishedAt = current
                $0.durationSeconds = stats.durationSeconds
                $0.sizeBytes = stats.sizeBytes
            }
            logger.info("Recording \(id) completed: \(Int(stats.durationSeconds)) s, \(stats.sizeBytes) bytes")
        } else {
            let reason = reasonIfEmpty ?? Self.failureReason(fromStderr: stderrTail, streamURL: record.streamURL)
            _ = try? await store.update(id) {
                $0.status = .failed
                $0.failureReason = reason
                $0.finishedAt = current
                $0.durationSeconds = 0
                $0.sizeBytes = stats.sizeBytes
            }
            logger.warning("Recording \(id) failed: \(reason)")
        }
    }

    private func markCancelled(_ id: UUID) async throws -> RecordingRecord? {
        let current = now()
        return try await store.update(id) {
            $0.status = .cancelled
            $0.finishedAt = current
        }
    }

    // MARK: Helpers

    private func admit() throws {
        guard activeCount < options.maxConcurrent else { throw RecorderError.concurrencyLimit }
        if let space = disk.space(at: store.recordingsDirectory), space.freeBytes < options.minFreeBytes {
            throw RecorderError.insufficientStorage
        }
    }

    private func validate(_ request: CreateRecordingRequest, now: Date) throws {
        guard let scheme = request.streamURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = request.streamURL.host, !host.isEmpty
        else { throw RecorderError.invalidRequest("streamURL must be an http or https URL") }
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RecorderError.invalidRequest("title must not be empty") }
        guard title.count <= 500 else { throw RecorderError.invalidRequest("title is too long") }
        guard (request.programmeDescription?.count ?? 0) <= 10000 else {
            throw RecorderError.invalidRequest("programmeDescription is too long")
        }
        guard (request.sourceRef?.count ?? 0) <= 2048 else { throw RecorderError.invalidRequest("sourceRef is too long") }
        guard request.end > request.start else { throw RecorderError.invalidRequest("end must be after start") }
        guard request.end > now else { throw RecorderError.invalidRequest("end must be in the future") }
        guard request.end.timeIntervalSince(request.start) <= options.maxRecordingDuration else {
            throw RecorderError.invalidRequest("a recording can be at most \(Int(options.maxRecordingDuration / 3600)) hours long")
        }
    }

    private static func indexKey(_ device: UUID, _ key: String) -> String {
        "\(device.uuidString):\(key)"
    }

    /// True once the media already covers the whole window — a VOD-style
    /// source that ran ahead of the clock is done, not "dropped".
    private static func mediaCoversWindow(record: RecordingRecord, directory: URL) -> Bool {
        let window = record.end.timeIntervalSince(record.startedAt ?? record.start)
        let stats = MediaInspector.stats(in: directory)
        let tolerance = min(2, window * 0.1)
        return stats.segmentCount > 0 && stats.durationSeconds >= window - tolerance
    }

    static func failureReason(
        fromStderr stderr: String?,
        streamURL: URL,
        prefix: String = FailureReason.noSegments
    ) -> String {
        guard let stderr else { return prefix }
        let lines = Redactor.redact(stderr, streamURL: streamURL)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return prefix }
        var detail = lines.suffix(3).joined(separator: " | ")
        if detail.count > 400 { detail = String(detail.suffix(400)) }
        return "\(prefix): \(detail)"
    }

    /// SIGINT → wait → SIGTERM → wait → SIGKILL, then wait for the exit.
    static func stopGracefully(_ process: any RecordingProcess, options: Options) async {
        process.interrupt()
        if await waitForExit(process, timeout: options.interruptGracePeriod) { return }
        process.terminate()
        if await waitForExit(process, timeout: options.terminateGracePeriod) { return }
        process.kill()
        _ = await process.waitForExit()
    }

    /// Races the exit against a timeout without leaking a blocked waiter.
    private static func waitForExit(_ process: any RecordingProcess, timeout: TimeInterval) async -> Bool {
        let gate = ExitGate()
        let waiter = Task {
            _ = await process.waitForExit()
            gate.open()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if gate.isOpen { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = waiter
        return gate.isOpen
    }
}

/// A thread-safe one-way flag.
private final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool { lock.withLock { opened } }

    func open() { lock.withLock { opened = true } }
}
