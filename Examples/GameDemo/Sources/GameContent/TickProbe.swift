import Foundation
import SwiftStateTree

/// Server-side tick timing for resolver-test: the gap between consecutive tick handler starts of
/// one land, on the monotonic clock, merged over every land into a histogram written as JSONL.
/// It also counts each applied `CallServiceAction`'s tick advance (the ticks that passed while
/// its resolver ran): the action's response never reaches the client, since a land with a tick
/// handler acknowledges an action once its resolvers finish, before the handler runs.
///
/// It is outside the state: a land notes its ticks through `ctx.services`, and a land without a
/// probe (re-evaluation registers none) notes nothing, so records and replays don't change.
public enum TickProbeEnvKeys {
    /// The JSONL file the probe appends to. Unset: no probe.
    public static let path = "RESOLVER_TEST_TICK_PROBE_PATH"
    /// Window length in ms, 100...60000. Default 1000.
    public static let intervalMs = "RESOLVER_TEST_TICK_PROBE_INTERVAL_MS"
}

/// Gaps in 1 ms buckets: bucket `i` counts gaps in `[i, i + 1)` ms, the last one every gap of
/// `overflowMs` or more.
public struct TickGapHistogram: Sendable, Equatable, Codable {
    public static let bucketWidthUs = 1000
    public static let overflowMs = 1000

    /// Tick handler starts, a land's first included (it has no gap).
    public var ticks = 0
    /// Gap counts by bucket (ms, as a string key), only the non-empty ones.
    public var buckets: [String: Int] = [:]
    public var maxGapUs: Int64 = 0
    /// Applied actions by their tick advance (ticks, as a string key).
    public var tickAdvances: [String: Int] = [:]

    public init() {}

    public var gaps: Int { buckets.values.reduce(0, +) }

    mutating func add(gapUs: Int64) {
        let bucket = Int(min(max(0, gapUs) / Int64(Self.bucketWidthUs), Int64(Self.overflowMs)))
        buckets[String(bucket), default: 0] += 1
        maxGapUs = max(maxGapUs, gapUs)
    }

    mutating func merge(_ other: TickGapHistogram) {
        ticks += other.ticks
        for (bucket, count) in other.buckets { buckets[bucket, default: 0] += count }
        for (advance, count) in other.tickAdvances { tickAdvances[advance, default: 0] += count }
        maxGapUs = max(maxGapUs, other.maxGapUs)
    }

    /// The bucket (its lower bound, ms) holding quantile `q` of the gaps, or nil without gaps.
    public func quantileMs(_ q: Double) -> Int? {
        let total = gaps
        guard total > 0 else { return nil }
        let rank = max(1, Int((q * Double(total)).rounded(.up)))
        var seen = 0
        for bucket in buckets.keys.compactMap(Int.init).sorted() {
            seen += buckets[String(bucket)] ?? 0
            if seen >= rank { return bucket }
        }
        return nil
    }
}

/// The process's gaps since the last window was taken.
public final class TickProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var window = TickGapHistogram()

    public init() {}

    func note(ticks: Int, gapUs: Int64?) {
        lock.lock()
        defer { lock.unlock() }
        window.ticks += ticks
        if let gapUs { window.add(gapUs: gapUs) }
    }

    func note(tickAdvance: Int64) {
        lock.lock()
        defer { lock.unlock() }
        window.tickAdvances[String(max(0, tickAdvance)), default: 0] += 1
    }

    /// The window so far, and a new empty one.
    public func takeWindow() -> TickGapHistogram {
        lock.lock()
        defer { lock.unlock() }
        let taken = window
        window = TickGapHistogram()
        return taken
    }
}

/// One land's probe: the previous tick handler start. Registered per land by `ResolverTest.makeServices`.
public final class TickProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let recorder: TickProbeRecorder
    private var previousStart: ContinuousClock.Instant?

    public init(recorder: TickProbeRecorder) {
        self.recorder = recorder
    }

    /// Called first thing in the land's Tick handler.
    public func noteTickStart(at now: ContinuousClock.Instant = .now) {
        lock.lock()
        let previous = previousStart
        previousStart = now
        lock.unlock()
        recorder.note(ticks: 1, gapUs: previous.map { microseconds(now - $0) })
    }

    /// Called by an applied `CallServiceAction` with its tick advance.
    public func noteTickAdvance(_ ticks: Int64) {
        recorder.note(tickAdvance: ticks)
    }

    private func microseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}

/// One JSONL line per window `(fromTs, ts]`: `ts` (ms since epoch on the server's wall clock,
/// when the window was taken, as the transport profiler's lines), `fromTs` the previous line's
/// `ts` (the writer's start for the first), the window's histogram and its bucket width. `ticks`
/// exceeds `gaps` by the lands whose first tick fell in the window. `tickAdvances`: the window's
/// applied actions by tick advance. `writeFailures`: earlier lines that couldn't be written, over
/// the writer's life.
public struct TickProbeLine: Codable, Equatable, Sendable {
    public var fromTs: Int
    public var ts: Int
    public var writeFailures: Int
    public var ticks: Int
    public var gaps: Int
    public var maxGapUs: Int64
    public var bucketWidthUs: Int
    public var overflowMs: Int
    public var buckets: [String: Int]
    public var tickAdvances: [String: Int]

    public init(fromTs: Int, ts: Int, window: TickGapHistogram, writeFailures: Int = 0) {
        self.fromTs = fromTs
        self.ts = ts
        self.writeFailures = writeFailures
        self.ticks = window.ticks
        self.gaps = window.gaps
        self.maxGapUs = window.maxGapUs
        self.bucketWidthUs = TickGapHistogram.bucketWidthUs
        self.overflowMs = TickGapHistogram.overflowMs
        self.buckets = window.buckets
        self.tickAdvances = window.tickAdvances
    }
}

public struct TickProbeSettingsError: Error, CustomStringConvertible {
    public let description: String
}

/// Appends a line per window to the probe's file, from start until the process ends.
public enum TickProbeWriter {
    public static let intervalRange = 100...60_000

    /// The recorder to register when `RESOLVER_TEST_TICK_PROBE_PATH` is set (its writer started),
    /// or nil. Throws on a bad interval or a file that can't be opened.
    public static func startFromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> TickProbeRecorder? {
        guard let path = environment[TickProbeEnvKeys.path], !path.isEmpty else { return nil }
        var intervalMs = 1000
        if let raw = environment[TickProbeEnvKeys.intervalMs] {
            guard let value = Int(raw), intervalRange.contains(value) else {
                throw TickProbeSettingsError(description: "\(TickProbeEnvKeys.intervalMs)=\(raw): expected an integer in \(intervalRange)")
            }
            intervalMs = value
        }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw TickProbeSettingsError(description: "\(TickProbeEnvKeys.path)=\(path): can't create the file")
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw TickProbeSettingsError(description: "\(TickProbeEnvKeys.path)=\(path): can't open the file")
        }
        handle.seekToEndOfFile()
        let recorder = TickProbeRecorder()
        // The window starts now: ticks before this aren't in any line.
        _ = recorder.takeWindow()
        let startTs = Int(Date().timeIntervalSince1970 * 1000)
        Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var fromTs = startTs
            var writeFailures = 0
            while !Task.isCancelled {
                try? await safeTaskSleep(for: .milliseconds(intervalMs))
                let ts = Int(Date().timeIntervalSince1970 * 1000)
                let line = TickProbeLine(fromTs: fromTs, ts: ts, window: recorder.takeWindow(), writeFailures: writeFailures)
                fromTs = ts
                do {
                    var data = try encoder.encode(line)
                    data.append(0x0A)
                    // Throws on a write error (a full disk) instead of raising an exception.
                    try handle.write(contentsOf: data)
                } catch {
                    writeFailures += 1
                    FileHandle.standardError.write(Data("tick probe: line not written (\(error))\n".utf8))
                }
            }
        }
        return recorder
    }
}
