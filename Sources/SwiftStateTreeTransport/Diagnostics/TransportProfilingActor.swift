// Sources/SwiftStateTreeTransport/Diagnostics/TransportProfilingActor.swift
//
// Low-overhead transport profiling actor. Outputs JSONL every second with
// counters, latency percentiles, and actor lag. Uses atomic counters to avoid
// hot-path actor hops; latency samples are fire-and-forget with sampling.

import Atomics
import Foundation
import SwiftStateTree

/// Lock-free counters for transport profiling. Adapters call increment methods
/// directly; no actor hop required.
public final class TransportProfilerCounters: Sendable {
    private let actions = ManagedAtomic<Int>(0)
    private let stateUpdates = ManagedAtomic<Int>(0)
    private let messagesReceived = ManagedAtomic<Int>(0)
    private let bytesReceived = ManagedAtomic<Int64>(0)
    private let disconnects = ManagedAtomic<Int>(0)
    private let errors = ManagedAtomic<Int>(0)
    private let syncFailedPlans = ManagedAtomic<Int>(0)
    private let syncDroppedUpdates = ManagedAtomic<Int>(0)
    private let syncCycles = ManagedAtomic<Int>(0)
    private let syncSkipsBacklog = ManagedAtomic<Int>(0)
    private let syncSkipsBusy = ManagedAtomic<Int>(0)
    private let syncDeferredTurns = ManagedAtomic<Int>(0)
    private let syncJoinTicks = ManagedAtomic<Int>(0)
    /// Folds in the low 32 bits, overdue folds in the high bits: one increment and one exchange
    /// per fold, so a window never splits a fold (overdue ≤ folds in every window).
    private let syncFoldBits = ManagedAtomic<Int>(0)
    private static let overdueFoldUnit = 1 << 32
    private let connectedSessions = ManagedAtomic<Int>(0)
    private let joinedSessions = ManagedAtomic<Int>(0)

    init() {}

    func incrementActions(by delta: Int = 1) {
        actions.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    func incrementStateUpdates(by delta: Int = 1) {
        stateUpdates.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    func incrementMessagesReceived(by delta: Int = 1) {
        messagesReceived.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    func addBytesReceived(_ delta: Int64) {
        bytesReceived.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    func incrementDisconnects(by delta: Int = 1) {
        disconnects.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    func incrementErrors(by delta: Int = 1) {
        errors.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    /// A sync plan failed (threw) and committed nothing.
    func incrementSyncFailedPlans(by delta: Int = 1) {
        syncFailedPlans.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    /// A sync plan dropped patches, updates or fields that did not encode or extract (data loss).
    func incrementSyncDroppedUpdates(by delta: Int = 1) {
        syncDroppedUpdates.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    /// A sync cycle committed its plan (both paths): the denominator of the rates below.
    func incrementSyncCycles() {
        syncCycles.wrappingIncrement(ordering: .relaxed)
    }

    /// A sync cycle was skipped: the writer still held an earlier cycle's element.
    func incrementSyncSkipsBacklog() {
        syncSkipsBacklog.wrappingIncrement(ordering: .relaxed)
    }

    /// A sync cycle was skipped: another cycle was in flight (legacy path).
    func incrementSyncSkipsBusy() {
        syncSkipsBusy.wrappingIncrement(ordering: .relaxed)
    }

    /// An in-turn sync phase was deferred by writer back-pressure. Each one is also a backlog skip:
    /// deferred turns are a subset of `syncSkipsBacklog` ("of which"), not a separate cause.
    func incrementSyncDeferredTurns() {
        syncDeferredTurns.wrappingIncrement(ordering: .relaxed)
    }

    /// A tick turn ran its sync phase only for ready joins (#69), with no sync due by the cadence:
    /// a turn with tick and sync work that is not a fold.
    func incrementSyncJoinTicks() {
        syncJoinTicks.wrappingIncrement(ordering: .relaxed)
    }

    /// In-turn sync folded a sync cycle into the next tick turn (once per cycle); `overdue` when
    /// that tick's deadline had already passed (the frame waits for a late tick, #174).
    func incrementSyncFolds(overdue: Bool) {
        syncFoldBits.wrappingIncrement(by: overdue ? 1 + Self.overdueFoldUnit : 1, ordering: .relaxed)
    }

    func setSessionCounts(connected: Int, joined: Int) {
        connectedSessions.store(connected, ordering: .relaxed)
        joinedSessions.store(joined, ordering: .relaxed)
    }

    /// The sync counters of one window (taken and reset with the others).
    struct SyncWindow {
        var cycles: Int
        var skipsBacklog: Int
        var skipsBusy: Int
        /// Of `skipsBacklog`: the in-turn deferrals.
        var deferredTurns: Int
        /// Sync cycles folded into a tick turn.
        var folds: Int
        /// Of `folds`: those whose tick was already overdue.
        var overdueFolds: Int
        /// Tick turns that ran the sync phase for ready joins only (not folds).
        var joinTicks: Int
    }

    func takeAndResetSync() -> SyncWindow {
        let folds = syncFoldBits.exchange(0, ordering: .relaxed)
        return SyncWindow(
            cycles: syncCycles.exchange(0, ordering: .relaxed),
            skipsBacklog: syncSkipsBacklog.exchange(0, ordering: .relaxed),
            skipsBusy: syncSkipsBusy.exchange(0, ordering: .relaxed),
            deferredTurns: syncDeferredTurns.exchange(0, ordering: .relaxed),
            folds: folds & (Self.overdueFoldUnit - 1),
            overdueFolds: folds >> 32,
            joinTicks: syncJoinTicks.exchange(0, ordering: .relaxed)
        )
    }

    func takeAndReset() -> (actions: Int, stateUpdates: Int, messagesReceived: Int, bytesReceived: Int64, disconnects: Int, errors: Int, syncFailedPlans: Int, syncDroppedUpdates: Int, connected: Int, joined: Int) {
        (
            actions.exchange(0, ordering: .relaxed),
            stateUpdates.exchange(0, ordering: .relaxed),
            messagesReceived.exchange(0, ordering: .relaxed),
            bytesReceived.exchange(0, ordering: .relaxed),
            disconnects.exchange(0, ordering: .relaxed),
            errors.exchange(0, ordering: .relaxed),
            syncFailedPlans.exchange(0, ordering: .relaxed),
            syncDroppedUpdates.exchange(0, ordering: .relaxed),
            connectedSessions.load(ordering: .relaxed),
            joinedSessions.load(ordering: .relaxed)
        )
    }
}

/// Transport profiling actor. Writes JSONL every interval with counters,
/// latency percentiles, and ticker lag. Shared across all TransportAdapters.
public actor TransportProfilingActor {
    private let config: TransportProfilingConfig
    private let counters: TransportProfilerCounters
    private var decodeSampler: LatencySampler
    private var handleSampler: LatencySampler
    private var encodeSampler: LatencySampler
    private var sendSampler: LatencySampler
    private var tickerTask: Task<Void, Never>?
    private var fileHandle: FileHandle?
    private let expectedIntervalMs: Int

    private nonisolated(unsafe) static var _shared: TransportProfilingActor?
    private static let lock = NSLock()

    /// Get or create the shared profiler. Call only when config.isEnabled.
    public static func shared(config: TransportProfilingConfig) -> TransportProfilingActor {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _shared {
            return existing
        }
        let instance = TransportProfilingActor(config: config)
        _shared = instance
        Task { await instance.startTicker() }
        return instance
    }

    private init(config: TransportProfilingConfig) {
        self.config = config
        self.counters = TransportProfilerCounters()
        self.decodeSampler = LatencySampler(maxSamples: config.maxSamplesPerInterval)
        self.handleSampler = LatencySampler(maxSamples: config.maxSamplesPerInterval)
        self.encodeSampler = LatencySampler(maxSamples: config.maxSamplesPerInterval)
        self.sendSampler = LatencySampler(maxSamples: config.maxSamplesPerInterval)
        self.expectedIntervalMs = config.intervalMs
        if let path = config.jsonlPath {
            self.fileHandle = Self.openFile(path: path)
        } else {
            self.fileHandle = nil
        }
    }

    private static func openFile(path: String) -> FileHandle? {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: path, contents: nil) || FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return try? FileHandle(forWritingTo: url)
    }

    /// Get lock-free counters for hot-path increments. No actor hop.
    public nonisolated func getCounters() -> TransportProfilerCounters {
        counters
    }

    /// Record decode latency (fire-and-forget). Caller should sample to reduce load.
    public func recordDecode(durationMs: Double, bytes: Int) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        decodeSampler.add(durationMs)
    }

    /// Record action/event handle latency (fire-and-forget).
    public func recordHandle(durationMs: Double) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        handleSampler.add(durationMs)
    }

    /// Record encode latency (fire-and-forget).
    public func recordEncode(durationMs: Double) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        encodeSampler.add(durationMs)
    }

    /// Record send latency (fire-and-forget).
    public func recordSend(durationMs: Double) {
        guard durationMs.isFinite, durationMs >= 0 else { return }
        sendSampler.add(durationMs)
    }

    private func startTicker() {
        let interval = Duration.milliseconds(expectedIntervalMs)
        tickerTask = Task { [weak self] in
            var lastTick = ContinuousClock.now
            while !Task.isCancelled {
                try? await safeTaskSleep(for: interval)
                guard let self else { break }
                let now = ContinuousClock.now
                let elapsed = now - lastTick
                let elapsedMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                let lagMs = elapsedMs - Double(self.expectedIntervalMs)
                await self.tick(lagMs: lagMs)
                lastTick = now
            }
        }
    }

    private func tick(lagMs: Double) {
        let stats = counters.takeAndReset()
        let sync = counters.takeAndResetSync()
        let decodeP = decodeSampler.flush()
        let handleP = handleSampler.flush()
        let encodeP = encodeSampler.flush()
        let sendP = sendSampler.flush()

        var obj: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "lag_ms": rounded(lagMs),
            "counters": [
                "actions": stats.actions,
                "stateUpdates": stats.stateUpdates,
                "messagesReceived": stats.messagesReceived,
                "bytesReceived": stats.bytesReceived,
                "disconnects": stats.disconnects,
                "errors": stats.errors,
                "syncFailedPlans": stats.syncFailedPlans,
                "syncDroppedUpdates": stats.syncDroppedUpdates,
                "connectedSessions": stats.connected,
                "joinedSessions": stats.joined,
                "syncCycles": sync.cycles,
                "syncSkipsBacklog": sync.skipsBacklog,
                "syncSkipsBusy": sync.skipsBusy,
                "syncDeferredTurns": sync.deferredTurns,
                "syncFolds": sync.folds,
                "syncOverdueFolds": sync.overdueFolds,
                "syncJoinTicks": sync.joinTicks,
            ] as [String: Any],
        ]
        if decodeP.count > 0 { obj["decode_ms"] = decodeP.toJSONObject() }
        if handleP.count > 0 { obj["handle_ms"] = handleP.toJSONObject() }
        if encodeP.count > 0 { obj["encode_ms"] = encodeP.toJSONObject() }
        if sendP.count > 0 { obj["send_ms"] = sendP.toJSONObject() }

        writeJSONL(obj)
    }

    private func writeJSONL(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let toWrite = line + "\n"
        if let dataToWrite = toWrite.data(using: .utf8), let fh = fileHandle {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: dataToWrite)
        }
    }

    private func rounded(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }
}
