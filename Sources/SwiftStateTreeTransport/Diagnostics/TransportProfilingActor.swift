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
    private let pongTimeoutCloses = ManagedAtomic<Int>(0)
    private let closeFrameTimeouts = ManagedAtomic<Int>(0)
    private let errors = ManagedAtomic<Int>(0)
    private let syncFailedPlans = ManagedAtomic<Int>(0)
    private let syncDroppedUpdates = ManagedAtomic<Int>(0)
    private let syncCycles = ManagedAtomic<Int>(0)
    private let syncSkipsBacklog = ManagedAtomic<Int>(0)
    private let syncSkipsBusy = ManagedAtomic<Int>(0)
    private let syncDeferredTurns = ManagedAtomic<Int>(0)
    private let syncJoinTicks = ManagedAtomic<Int>(0)
    /// Folded tick turns, packed so a window never splits one: folds in bits 0–20, overdue
    /// folds in 21–41, late folds in 42–62 (#232). One increment per fold and one exchange per
    /// window, so overdue ≤ folds and late ≤ folds in every window. Each field holds up to
    /// 2,097,151 per window (about 200,000 lands at 10 folds/s in a 1 s window); a field past
    /// that carries into the next one.
    private let syncFoldBits = ManagedAtomic<Int>(0)
    static let foldFieldBits = 21
    private static let foldFieldMask = (1 << foldFieldBits) - 1
    private static let overdueFoldUnit = 1 << foldFieldBits
    private static let lateFoldUnit = 1 << (2 * foldFieldBits)
    /// The largest folded tick turn lateness in the window, µs (0 when none was positive).
    /// Exchanged before `syncFoldBits`, so it can belong to a fold counted in the next window.
    private let syncFoldTickLatenessMaxUs = ManagedAtomic<Int>(0)
    private let connectedSessions = ManagedAtomic<Int>(0)
    // Send backlog (#61), per window: the largest outbound-buffer sample, unwritable episodes
    // started, and the longest one that ended; plus a gauge of sessions unwritable right now.
    private let sendBufferedBytesMax = ManagedAtomic<Int>(0)
    private let sendUnwritableEpisodes = ManagedAtomic<Int>(0)
    private let sendUnwritableLongestMs = ManagedAtomic<Int>(0)
    private let sendUnwritableSessions = ManagedAtomic<Int>(0)
    private let sendBacklogCloses = ManagedAtomic<Int>(0)
    private let inboundQueuedMessagesMax = ManagedAtomic<Int>(0)
    private let inboundQueuedBytesMax = ManagedAtomic<Int>(0)
    private let inboundReadPauses = ManagedAtomic<Int>(0)
    private let inboundPausedLongestMs = ManagedAtomic<Int>(0)
    private let inboundPausedSessions = ManagedAtomic<Int>(0)
    private let joinedSessions = ManagedAtomic<Int>(0)
    // Sync phase times, per window, in nanoseconds: snapshot extraction, the broadcast diff and
    // the per-player diffs of each timed sync plan, how many plans were timed, and how many of
    // those were on the combined path.
    private let syncExtractNanos = ManagedAtomic<Int>(0)
    private let syncBroadcastNanos = ManagedAtomic<Int>(0)
    private let syncPerPlayerNanos = ManagedAtomic<Int>(0)
    private let syncTimedPlans = ManagedAtomic<Int>(0)
    private let syncCombinedPlans = ManagedAtomic<Int>(0)

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

    /// A WebSocket session closed because a keepalive ping went unanswered (NIO hosting).
    public func incrementPongTimeoutCloses(by delta: Int = 1) {
        pongTimeoutCloses.wrappingIncrement(by: delta, ordering: .relaxed)
    }

    /// A session's outbound buffer held `bytes` after a write (NIO hosting).
    public func noteSendBufferedBytes(_ bytes: Int) {
        Self.storeMax(bytes, in: sendBufferedBytesMax)
    }

    /// A session's channel became unwritable (NIO hosting).
    public func noteSendUnwritableEpisodeStarted() {
        sendUnwritableEpisodes.wrappingIncrement(ordering: .relaxed)
        sendUnwritableSessions.wrappingIncrement(ordering: .relaxed)
    }

    /// A session's channel became writable again, or the session ended while unwritable.
    public func noteSendUnwritableEpisodeEnded(durationMs: Int) {
        sendUnwritableSessions.wrappingDecrement(ordering: .relaxed)
        Self.storeMax(durationMs, in: sendUnwritableLongestMs)
    }

    /// A session had `messages` (`bytes`) read but not yet delivered to the transport (NIO
    /// hosting, #113).
    public func noteInboundQueued(messages: Int, bytes: Int) {
        Self.storeMax(messages, in: inboundQueuedMessagesMax)
        Self.storeMax(bytes, in: inboundQueuedBytesMax)
    }

    /// A session stopped being read at its inbound backlog bound (#113).
    public func noteInboundReadPauseStarted() {
        inboundReadPauses.wrappingIncrement(ordering: .relaxed)
        inboundPausedSessions.wrappingIncrement(ordering: .relaxed)
    }

    /// A session is read again, or ended while paused.
    public func noteInboundReadPauseEnded(durationMs: Int) {
        inboundPausedSessions.wrappingDecrement(ordering: .relaxed)
        Self.storeMax(durationMs, in: inboundPausedLongestMs)
    }

    /// One sync plan's phase times. Encoding and the full views of joiners and unsynced
    /// recipients are in none of them; extraction yields the broadcast and per-player snapshots
    /// in one call, so it is not split between the two. `combined`: a plan without merged
    /// broadcast frames, whose per-player time includes folding the broadcast diff into each
    /// player's update.
    func addSyncPhaseTimes(extract: Duration, broadcast: Duration, perPlayer: Duration, combined: Bool) {
        syncExtractNanos.wrappingIncrement(by: Self.nanoseconds(extract), ordering: .relaxed)
        syncBroadcastNanos.wrappingIncrement(by: Self.nanoseconds(broadcast), ordering: .relaxed)
        syncPerPlayerNanos.wrappingIncrement(by: Self.nanoseconds(perPlayer), ordering: .relaxed)
        syncTimedPlans.wrappingIncrement(ordering: .relaxed)
        if combined { syncCombinedPlans.wrappingIncrement(ordering: .relaxed) }
    }

    struct SyncPhaseTimesWindow: Equatable {
        var extractMs: Double
        var broadcastMs: Double
        var perPlayerMs: Double
        var plans: Int
        /// Of `plans`: plans on the combined path (no merged broadcast frames).
        var combinedPlans: Int
    }

    /// Takes and resets one window's sync phase sums.
    func takeAndResetSyncPhaseTimes() -> SyncPhaseTimesWindow {
        SyncPhaseTimesWindow(
            extractMs: Double(syncExtractNanos.exchange(0, ordering: .relaxed)) / 1e6,
            broadcastMs: Double(syncBroadcastNanos.exchange(0, ordering: .relaxed)) / 1e6,
            perPlayerMs: Double(syncPerPlayerNanos.exchange(0, ordering: .relaxed)) / 1e6,
            plans: syncTimedPlans.exchange(0, ordering: .relaxed),
            combinedPlans: syncCombinedPlans.exchange(0, ordering: .relaxed)
        )
    }

    private static func nanoseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
    }

    /// A session was closed by the send backlog bound (4008, NIO hosting).
    public func incrementSendBacklogCloses() {
        sendBacklogCloses.wrappingIncrement(ordering: .relaxed)
    }

    struct SendBacklogWindow: Equatable {
        var bufferedBytesMax: Int
        var unwritableEpisodes: Int
        var unwritableLongestMs: Int
        /// A gauge, not reset: sessions unwritable when the window was taken.
        var unwritableSessions: Int
        /// Sessions closed by the send backlog bound in the window.
        var backlogCloses: Int
    }

    struct InboundBacklogWindow: Equatable {
        var queuedMessagesMax: Int
        var queuedBytesMax: Int
        var readPauses: Int
        var pausedLongestMs: Int
        /// A gauge, not reset: sessions not being read when the window was taken.
        var pausedSessions: Int
    }

    /// Takes and resets one window's inbound-backlog counters.
    func takeAndResetInboundBacklog() -> InboundBacklogWindow {
        InboundBacklogWindow(
            queuedMessagesMax: inboundQueuedMessagesMax.exchange(0, ordering: .relaxed),
            queuedBytesMax: inboundQueuedBytesMax.exchange(0, ordering: .relaxed),
            readPauses: inboundReadPauses.exchange(0, ordering: .relaxed),
            pausedLongestMs: inboundPausedLongestMs.exchange(0, ordering: .relaxed),
            pausedSessions: inboundPausedSessions.load(ordering: .relaxed)
        )
    }

    /// Takes and resets one window's send-backlog counters.
    func takeAndResetSendBacklog() -> SendBacklogWindow {
        SendBacklogWindow(
            bufferedBytesMax: sendBufferedBytesMax.exchange(0, ordering: .relaxed),
            unwritableEpisodes: sendUnwritableEpisodes.exchange(0, ordering: .relaxed),
            unwritableLongestMs: sendUnwritableLongestMs.exchange(0, ordering: .relaxed),
            unwritableSessions: sendUnwritableSessions.load(ordering: .relaxed),
            backlogCloses: sendBacklogCloses.exchange(0, ordering: .relaxed)
        )
    }

    private static func storeMax(_ value: Int, in atomic: ManagedAtomic<Int>) {
        var current = atomic.load(ordering: .relaxed)
        while value > current {
            let (exchanged, original) = atomic.compareExchange(expected: current, desired: value, ordering: .relaxed)
            if exchanged { return }
            current = original
        }
    }

    /// Takes and resets the pong-timeout close count of one window.
    func takeAndResetPongTimeoutCloses() -> Int {
        pongTimeoutCloses.exchange(0, ordering: .relaxed)
    }

    /// A server close whose close frame wasn't written in time, so the channel was closed
    /// without it (NIO hosting, #229).
    public func incrementCloseFrameTimeouts() {
        closeFrameTimeouts.wrappingIncrement(ordering: .relaxed)
    }

    /// Takes and resets the close-frame timeout count of one window.
    func takeAndResetCloseFrameTimeouts() -> Int {
        closeFrameTimeouts.exchange(0, ordering: .relaxed)
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

    /// A tick turn carrying a folded sync started (once per such turn, #232): counts the fold,
    /// whether it was overdue at the fold and whether the turn started late, and keeps the
    /// largest lateness.
    func recordSyncFold(_ fold: InTurnSyncFold) {
        var increment = 1
        if fold.overdueAtFold { increment += Self.overdueFoldUnit }
        if fold.isLate { increment += Self.lateFoldUnit }
        syncFoldBits.wrappingIncrement(by: increment, ordering: .relaxed)
        let lateness = fold.tickLateness.components
        let micros = lateness.seconds * 1_000_000 + lateness.attoseconds / 1_000_000_000_000
        if micros > 0 { Self.storeMax(Int(micros), in: syncFoldTickLatenessMaxUs) }
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
        /// Of `folds`: those whose tick deadline had passed at the fold (mostly the loop race).
        var overdueFolds: Int
        /// Of `folds`: those whose tick turn started later than the coincident window (#232).
        var lateFolds: Int
        /// The largest folded tick turn lateness, µs.
        var foldTickLatenessMaxUs: Int
        /// Tick turns that ran the sync phase for ready joins only (not folds).
        var joinTicks: Int
    }

    func takeAndResetSync() -> SyncWindow {
        let latenessMax = syncFoldTickLatenessMaxUs.exchange(0, ordering: .relaxed)
        let folds = syncFoldBits.exchange(0, ordering: .relaxed)
        return SyncWindow(
            cycles: syncCycles.exchange(0, ordering: .relaxed),
            skipsBacklog: syncSkipsBacklog.exchange(0, ordering: .relaxed),
            skipsBusy: syncSkipsBusy.exchange(0, ordering: .relaxed),
            deferredTurns: syncDeferredTurns.exchange(0, ordering: .relaxed),
            folds: folds & Self.foldFieldMask,
            overdueFolds: (folds >> Self.foldFieldBits) & Self.foldFieldMask,
            lateFolds: (folds >> (2 * Self.foldFieldBits)) & Self.foldFieldMask,
            foldTickLatenessMaxUs: latenessMax,
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
    /// The deadline counts at the last tick (#104): they are process-wide totals, and each
    /// interval reports what changed since.
    private var lastResolverDeadlines = ResolverDeadlineMetrics.Snapshot(timeouts: 0, abandoned: 0, onLeaveDropped: 0)
    private var lastJoinTimeouts: [JoinTimeoutPhase: Int] = [:]

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
        let pongTimeoutCloses = counters.takeAndResetPongTimeoutCloses()
        let closeFrameTimeouts = counters.takeAndResetCloseFrameTimeouts()
        let send = counters.takeAndResetSendBacklog()
        let inbound = counters.takeAndResetInboundBacklog()
        let phases = counters.takeAndResetSyncPhaseTimes()
        let decodeP = decodeSampler.flush()
        let handleP = handleSampler.flush()
        let encodeP = encodeSampler.flush()
        let sendP = sendSampler.flush()
        let deadlines = deadlineCounters()

        var obj: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970 * 1000),
            "lag_ms": rounded(lagMs),
            "counters": [
                "actions": stats.actions,
                "stateUpdates": stats.stateUpdates,
                "messagesReceived": stats.messagesReceived,
                "bytesReceived": stats.bytesReceived,
                "disconnects": stats.disconnects,
                "pongTimeoutCloses": pongTimeoutCloses,
                "closeFrameTimeouts": closeFrameTimeouts,
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
                "syncLateFolds": sync.lateFolds,
                "syncFoldTickLatenessMaxUs": sync.foldTickLatenessMaxUs,
                "syncJoinTicks": sync.joinTicks,
                "sendBufferedBytesMax": send.bufferedBytesMax,
                "sendUnwritableEpisodes": send.unwritableEpisodes,
                "sendUnwritableLongestMs": send.unwritableLongestMs,
                "sendUnwritableSessions": send.unwritableSessions,
                "sendBacklogCloses": send.backlogCloses,
                "inboundQueuedMessagesMax": inbound.queuedMessagesMax,
                "inboundQueuedBytesMax": inbound.queuedBytesMax,
                "inboundReadPauses": inbound.readPauses,
                "inboundPausedLongestMs": inbound.pausedLongestMs,
                "inboundPausedSessions": inbound.pausedSessions,
            ].merging(deadlines) { current, _ in current } as [String: Any],
        ]
        if phases.plans > 0 {
            // Sums over the window's timed sync plans; the broadcast share of the diff work is
            // broadcast / (broadcast + perPlayer), with extraction reported apart.
            for (key, ms) in [("sync_extract_ms", phases.extractMs), ("sync_broadcast_ms", phases.broadcastMs), ("sync_perplayer_ms", phases.perPlayerMs)] {
                obj[key] = ["sum": rounded(ms), "plans": phases.plans, "mean": rounded(ms / Double(phases.plans))]
            }
            obj["sync_combined_plans"] = phases.combinedPlans
        }
        if decodeP.count > 0 { obj["decode_ms"] = decodeP.toJSONObject() }
        if handleP.count > 0 { obj["handle_ms"] = handleP.toJSONObject() }
        if encodeP.count > 0 { obj["encode_ms"] = encodeP.toJSONObject() }
        if sendP.count > 0 { obj["send_ms"] = sendP.toJSONObject() }

        writeJSONL(obj)
    }

    /// The interval's resolver and join deadline counters (#104): timeouts and drops since the
    /// last tick, and `abandonedResolvers`, a gauge (a resolver task that never ends shows).
    private func deadlineCounters() -> [String: Any] {
        let resolvers = ResolverDeadlineMetrics.shared.snapshot
        let joins = JoinTimeoutMetrics.shared.snapshot
        defer {
            lastResolverDeadlines = resolvers
            lastJoinTimeouts = joins
        }
        var counters: [String: Any] = [
            "resolverTimeouts": resolvers.timeouts - lastResolverDeadlines.timeouts,
            "resolverInitTimeouts": resolvers.initTimeouts - lastResolverDeadlines.initTimeouts,
            "abandonedResolvers": resolvers.abandoned,
            "onLeaveDropped": resolvers.onLeaveDropped - lastResolverDeadlines.onLeaveDropped,
        ]
        for phase in JoinTimeoutPhase.allCases {
            counters[Self.joinTimeoutsKey(phase)] = joins[phase, default: 0] - lastJoinTimeouts[phase, default: 0]
        }
        return counters
    }

    /// `joinTimeoutsLandLookup`, `joinTimeoutsAdmission`, `joinTimeoutsFlip`.
    static func joinTimeoutsKey(_ phase: JoinTimeoutPhase) -> String {
        let name = phase.rawValue
        return "joinTimeouts" + name.prefix(1).uppercased() + name.dropFirst()
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
