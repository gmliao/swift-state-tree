// Sources/SwiftStateTree/Resolver/ResolverDeadline.swift
//
// The deadline on a resolver group (#104). Resolvers are user code, usually calling an
// external service, and they run inside the keeper's join, leave and action paths: a stalled
// one stalls its caller and everything queued behind it (the land's membership queue, the
// session's inbound chain). The deadline turns a stall into the error a failing resolver
// already gives, so every caller keeps its existing failure path.

import Foundation

/// The deadline on one resolver group (`ResolverExecutor.executeResolvers`).
public enum ResolverDeadline {
    /// `RESOLVER_TIMEOUT_MS` (default 5000), read once; `nil` when 0 (disabled). A negative or
    /// non-integer value gives the default.
    public static let configured: Duration? = parse(environment: ProcessInfo.processInfo.environment)

    /// `RESOLVER_INIT_TIMEOUT_MS` (default 30000), the deadline on the OnInitialize resolvers,
    /// read once; `nil` when 0 (disabled). A negative or non-integer value gives the default.
    public static let configuredInit: Duration? = parseInit(environment: ProcessInfo.processInfo.environment)

    /// The deadline from `environment`: `nil` when disabled.
    static func parse(environment: [String: String]) -> Duration? {
        milliseconds(EnvKeys.Runtime.resolverTimeoutMs, default: 5000, environment: environment)
    }

    /// The OnInitialize deadline from `environment`: `nil` when disabled.
    static func parseInit(environment: [String: String]) -> Duration? {
        milliseconds(EnvKeys.Runtime.resolverInitTimeoutMs, default: 30_000, environment: environment)
    }

    private static func milliseconds(_ key: String, default defaultValue: Int, environment: [String: String]) -> Duration? {
        let milliseconds = EnvHelpers.getEnvInt(key: key, defaultValue: defaultValue, environment: environment)
        switch milliseconds {
        case 0: return nil
        case ..<0: return .milliseconds(defaultValue)
        default: return .milliseconds(milliseconds)
        }
    }

    /// Tests only: replaces `configured` for resolver groups run in this task and its children;
    /// `.zero` disables the deadline.
    @TaskLocal package static var overrideForTesting: Duration?

    /// Tests only: replaces `configuredInit` for initializations started in this task; `.zero`
    /// disables the deadline.
    @TaskLocal package static var initOverrideForTesting: Duration?

    /// Tests only: the metrics resolver groups in this task report to, instead of `shared`.
    @TaskLocal package static var metricsForTesting: ResolverDeadlineMetrics?

    /// Tests only: called (synchronously) in the group's caller just before it waits on the
    /// race, so a test can land a cancellation from another thread before the wait begins.
    @TaskLocal package static var beforeRaceWaitForTesting: (@Sendable () -> Void)?

    /// Tests only: called (synchronously) by the call that settled the race, after the
    /// outcome is published and before that call returns.
    @TaskLocal package static var afterRaceSettledForTesting: (@Sendable () -> Void)?

    /// Tests only: awaited by the task that delivers the group's result, after the group has
    /// ended and before that task settles the race, so a test can hold the delivery past the
    /// deadline (#448).
    @TaskLocal package static var beforeResultDeliveryForTesting: (@Sendable () async -> Void)?

    /// Tests only: awaited by the deadline's timer once the deadline has passed, before it reads
    /// which resolvers are still running (#448).
    @TaskLocal package static var deadlinePassedForTesting: (@Sendable () async -> Void)?

    /// Tests only: awaited once an abandoned group's task has ended, before its abandonment's
    /// end transition (`ResolverAbandonment.noteEnded`), on both abandoned paths (the deadline
    /// and the caller's cancellation), so a test can hold the end (#364).
    @TaskLocal package static var abandonedGroupEndedForTesting: (@Sendable () async -> Void)?

    /// The deadline in effect for a group started now.
    static var current: Duration? {
        guard let override = overrideForTesting else { return configured }
        return override == .zero ? nil : override
    }

    /// The OnInitialize deadline in effect for an initialization started now.
    static var currentInit: Duration? {
        guard let override = initOverrideForTesting else { return configuredInit }
        return override == .zero ? nil : override
    }

    /// The metrics a group started now reports to.
    static var metrics: ResolverDeadlineMetrics {
        metricsForTesting ?? .shared
    }
}

/// Process-wide counts of resolver deadlines (#104).
public final class ResolverDeadlineMetrics: @unchecked Sendable {
    /// The process's metrics. The transport profiler reads them.
    public static let shared = ResolverDeadlineMetrics()

    /// A point-in-time copy.
    public struct Snapshot: Sendable, Equatable {
        /// Resolver groups that ran past their deadline (OnInitialize's excluded).
        public var timeouts: Int
        /// OnInitialize resolver groups that ran past `RESOLVER_INIT_TIMEOUT_MS`: each failed its
        /// land's initialization.
        public var initTimeouts: Int
        /// OnInitialize resolver groups that threw, with `.failLand` (#238): each failed its land's
        /// initialization. Timeouts aren't counted here.
        public var initFailures: Int
        /// A gauge: resolver groups their caller stopped waiting for (at the deadline, or when
        /// the caller was cancelled) whose task is still running, as with a resolver that ignores
        /// cancellation. It goes down when the task ends, so one that never ends shows. Every
        /// kind counts, and groups no land owns too.
        public var abandoned: Int
        /// OnLeave inputs dropped because their resolvers failed or timed out.
        public var onLeaveDropped: Int
        /// A gauge: abandoned action jobs whose resolvers' task still runs (a subset of
        /// `abandoned`: actions only, not joins, leaves or OnInitialize). Capped by
        /// `RESOLVER_ABANDONED_ACTIONS_MAX`.
        public var abandonedActions: Int
        /// Actions rejected at intake by the per-session in-flight cap.
        public var inFlightLimitRejections: Int
        /// Actions rejected at intake by the abandoned-action cap.
        public var abandonedLimitRejections: Int
        /// Gauges, like `abandonedActions`, for the other kinds of a land's groups (#364):
        /// CanJoin, OnJoin, OnLeave and OnInitialize resolvers. Reported, not capped.
        public var abandonedCanJoin: Int
        public var abandonedOnJoin: Int
        public var abandonedOnLeave: Int
        public var abandonedOnInitialize: Int
        /// Actions rejected at intake by the per-land abandoned-action cap (#364).
        public var landAbandonedLimitRejections: Int

        public init(
            timeouts: Int,
            initTimeouts: Int = 0,
            initFailures: Int = 0,
            abandoned: Int,
            onLeaveDropped: Int,
            abandonedActions: Int = 0,
            inFlightLimitRejections: Int = 0,
            abandonedLimitRejections: Int = 0,
            abandonedCanJoin: Int = 0,
            abandonedOnJoin: Int = 0,
            abandonedOnLeave: Int = 0,
            abandonedOnInitialize: Int = 0,
            landAbandonedLimitRejections: Int = 0
        ) {
            self.timeouts = timeouts
            self.initTimeouts = initTimeouts
            self.initFailures = initFailures
            self.abandoned = abandoned
            self.onLeaveDropped = onLeaveDropped
            self.abandonedActions = abandonedActions
            self.inFlightLimitRejections = inFlightLimitRejections
            self.abandonedLimitRejections = abandonedLimitRejections
            self.abandonedCanJoin = abandonedCanJoin
            self.abandonedOnJoin = abandonedOnJoin
            self.abandonedOnLeave = abandonedOnLeave
            self.abandonedOnInitialize = abandonedOnInitialize
            self.landAbandonedLimitRejections = landAbandonedLimitRejections
        }
    }

    /// A leaf lock: an abandonment's transition calls in under its own lock, and nothing is
    /// called while this one is held.
    private let lock = NSLock()
    private var counts = Snapshot(timeouts: 0, abandoned: 0, onLeaveDropped: 0)

    package init() {}

    public var snapshot: Snapshot {
        lock.withLock { counts }
    }

    /// A group ran past its deadline. The abandoned gauges move with the group's abandonment.
    func noteTimedOut() {
        lock.withLock { counts.timeouts += 1 }
    }

    func noteInitTimedOut() {
        lock.withLock { counts.initTimeouts += 1 }
    }

    func noteInitFailed() {
        lock.withLock { counts.initFailures += 1 }
    }

    /// An abandonment's begin transition (`ResolverAbandonment.noteBegan`), only.
    func noteAbandonedBegan(_ kind: ResolverAbandonment.Kind?) {
        lock.withLock { Self.adjust(&counts, kind, by: 1) }
    }

    /// An abandonment's end transition (`ResolverAbandonment.noteEnded`), only.
    func noteAbandonedEnded(_ kind: ResolverAbandonment.Kind?) {
        lock.withLock { Self.adjust(&counts, kind, by: -1) }
    }

    private static func adjust(_ counts: inout Snapshot, _ kind: ResolverAbandonment.Kind?, by delta: Int) {
        counts.abandoned += delta
        switch kind {
        case .action: counts.abandonedActions += delta
        case .canJoin: counts.abandonedCanJoin += delta
        case .onJoin: counts.abandonedOnJoin += delta
        case .onLeave: counts.abandonedOnLeave += delta
        case .onInitialize: counts.abandonedOnInitialize += delta
        case nil: break
        }
    }

    func noteLandAbandonedLimitRejection() {
        lock.withLock { counts.landAbandonedLimitRejections += 1 }
    }

    func noteInFlightLimitRejection() {
        lock.withLock { counts.inFlightLimitRejections += 1 }
    }

    func noteAbandonedLimitRejection() {
        lock.withLock { counts.abandonedLimitRejections += 1 }
    }

    func noteOnLeaveDropped() {
        lock.withLock { counts.onLeaveDropped += 1 }
    }
}

/// One race between a resolver group and its deadline, settled exactly once.
final class ResolverDeadlineRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LandContext, any Error>?
    /// The result, once settled; kept for a continuation installed after the race settled
    /// (a caller cancelled before the race began).
    private var outcome: Result<LandContext, any Error>?
    private var timer: Task<Void, Never>?
    /// Resolvers not finished yet, by name (for the timeout's error).
    private var running: [String]

    init(names: [String]) {
        running = names
    }

    /// Installs the continuation; resumes it at once if the race already settled.
    func install(_ continuation: CheckedContinuation<LandContext, any Error>) {
        let settledOutcome = lock.withLock { () -> Result<LandContext, any Error>? in
            if self.outcome == nil { self.continuation = continuation }
            return self.outcome
        }
        if let settledOutcome { continuation.resume(with: settledOutcome) }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        let settled = lock.withLock { () -> Bool in
            if outcome == nil { self.timer = timer }
            return outcome != nil
        }
        if settled { timer.cancel() }
    }

    func resolverFinished(_ name: String) {
        lock.withLock {
            if let index = running.firstIndex(of: name) { running.remove(at: index) }
        }
    }

    var stillRunning: [String] {
        lock.withLock { running }
    }

    /// Settles the race with `result`, running `onWin` first if this call settles it. Returns
    /// whether it did.
    ///
    /// `onWin` runs under the lock, before the outcome is published: a wait that begins after
    /// (`install`) sees the outcome only once `onWin` has run, whichever thread settled.
    @discardableResult
    func settle(_ result: Result<LandContext, any Error>, onWin: () -> Void = {}) -> Bool {
        let (continuation, timer, won) = lock.withLock { () -> (CheckedContinuation<LandContext, any Error>?, Task<Void, Never>?, Bool) in
            guard outcome == nil else { return (nil, nil, false) }
            onWin()
            outcome = result
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return (self.continuation, self.timer, true)
        }
        guard won else { return false }
        ResolverDeadline.afterRaceSettledForTesting?()
        timer?.cancel()
        continuation?.resume(with: result)
        return true
    }
}
