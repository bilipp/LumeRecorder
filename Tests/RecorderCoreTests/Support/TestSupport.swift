import Foundation
@testable import RecorderCore

// MARK: - Temp directories

func makeTempDirectory(_ label: String = #function) -> URL {
    let safe = label.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lume-recorder-tests", isDirectory: true)
        .appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Polls `condition` until it holds or `timeout` elapses.
func eventually(timeout: TimeInterval = 10, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return await condition()
}

/// Whole-second dates survive the millisecond wire format unchanged.
func wholeSecond(_ date: Date = Date()) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
}

// MARK: - Clock

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date()) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var provider: NowProvider { { [self] in now } }
}

// MARK: - Disk

struct FakeDisk: DiskSpaceProviding {
    var freeBytes: Int64 = 500_000_000_000
    var totalBytes: Int64 = 1_000_000_000_000

    func space(at url: URL) -> DiskSpace? {
        DiskSpace(freeBytes: freeBytes, totalBytes: totalBytes)
    }
}

// MARK: - Fake recorder process

/// Scripted stand-in for ffmpeg. It writes an HLS playlist + dummy segments
/// into the recording directory the way ffmpeg's `append_list` does.
final class FakeProcess: RecordingProcess, @unchecked Sendable {
    enum Behavior: Sendable {
        /// Writes a segment every `interval` until signalled; SIGINT finalizes.
        case runUntilSignalled(interval: TimeInterval = 0.1)
        /// Writes `segments` segments, then exits with `status`.
        case exitAfter(TimeInterval, segments: Int, status: Int32, stderr: String = "")
        /// Writes segments but ignores SIGINT (exercises SIGTERM escalation).
        case ignoreInterrupt(interval: TimeInterval = 0.1)
    }

    let spec: RecordingAttemptSpec
    private let behavior: Behavior
    private let lock = NSLock()
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var stderr = ""
    private(set) var signals: [String] = []
    private var segmentIndex = 0
    private var writer: Task<Void, Never>?

    init(spec: RecordingAttemptSpec, behavior: Behavior) {
        self.spec = spec
        self.behavior = behavior
        segmentIndex = Self.existingSegmentCount(in: spec.outputDirectory)
        startWriting()
    }

    var receivedSignals: [String] { lock.withLock { signals } }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                continuation.resume(returning: exitStatus)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func interrupt() {
        record("INT")
        if case .ignoreInterrupt = behavior { return }
        exit(status: 255, writeEndList: true)
    }

    func terminate() {
        record("TERM")
        exit(status: 143, writeEndList: false)
    }

    func kill() {
        record("KILL")
        exit(status: 137, writeEndList: false)
    }

    func stderrTail() -> String {
        lock.withLock { stderr }
    }

    private func record(_ signal: String) {
        lock.withLock { signals.append(signal) }
    }

    private func startWriting() {
        switch behavior {
        case let .runUntilSignalled(interval), let .ignoreInterrupt(interval):
            appendSegment(discontinuity: true)
            writer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard let self, !self.hasExited else { return }
                    self.appendSegment(discontinuity: false)
                }
            }
        case let .exitAfter(delay, segments, status, stderr):
            for index in 0 ..< segments { appendSegment(discontinuity: index == 0) }
            lock.withLock { self.stderr = stderr }
            writer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.exit(status: status, writeEndList: segments > 0)
            }
        }
    }

    private var hasExited: Bool { lock.withLock { exitStatus != nil } }

    private func appendSegment(discontinuity: Bool) {
        let directory = spec.outputDirectory
        let name = String(format: "a%d_%05d.ts", spec.attempt, segmentIndex)
        segmentIndex += 1
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data(repeating: 0x47, count: 188 * 10))
        let playlistURL = directory.appendingPathComponent("index.m3u8")
        var text = (try? String(contentsOf: playlistURL, encoding: .utf8))
            ?? "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
        text = HLSPlaylist.removingEndList(text)
        if !text.hasSuffix("\n") { text += "\n" }
        if discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
        text += "#EXTINF:0.100000,\n\(name)\n"
        try? text.write(to: playlistURL, atomically: true, encoding: .utf8)
    }

    private func exit(status: Int32, writeEndList: Bool) {
        lock.lock()
        guard exitStatus == nil else {
            lock.unlock()
            return
        }
        exitStatus = status
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        writer?.cancel()
        if writeEndList {
            _ = try? HLSPlaylist.ensureEndList(at: spec.outputDirectory.appendingPathComponent("index.m3u8"))
        }
        for waiter in pending {
            waiter.resume(returning: status)
        }
    }

    private static func existingSegmentCount(in directory: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count { $0.hasSuffix(".ts") }
    }
}

/// Hands out `FakeProcess`es; behaviors are consumed per launch, the last repeats.
final class FakeLauncher: RecordingProcessLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var behaviors: [FakeProcess.Behavior]
    private var launched: [FakeProcess] = []

    init(_ behaviors: [FakeProcess.Behavior] = [.runUntilSignalled()]) {
        self.behaviors = behaviors
    }

    func launch(_ spec: RecordingAttemptSpec) throws -> any RecordingProcess {
        lock.lock()
        let behavior = behaviors.count > 1 ? behaviors.removeFirst() : behaviors[0]
        lock.unlock()
        let process = FakeProcess(spec: spec, behavior: behavior)
        lock.withLock { launched.append(process) }
        return process
    }

    var processes: [FakeProcess] { lock.withLock { launched } }
    var specs: [RecordingAttemptSpec] { processes.map(\.spec) }
}

// MARK: - Scheduler factory

func fastOptions(maxConcurrent: Int = 4, minFreeBytes: Int64 = 0) -> RecordingScheduler.Options {
    var options = RecordingScheduler.Options(maxConcurrent: maxConcurrent, minFreeBytes: minFreeBytes)
    options.retryInitialDelay = 0.05
    options.retryMaxDelay = 0.2
    options.interruptGracePeriod = 0.5
    options.terminateGracePeriod = 0.3
    options.minimumAttemptDuration = 0.2
    return options
}
