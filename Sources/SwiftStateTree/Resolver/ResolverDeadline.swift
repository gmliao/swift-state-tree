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

    /// The deadline from `environment`: `nil` when disabled.
    static func parse(environment: [String: String]) -> Duration? {
        let milliseconds = EnvHelpers.getEnvInt(key: EnvKeys.Runtime.resolverTimeoutMs, defaultValue: 5000, environment: environment)
        switch milliseconds {
        case 0: return nil
        case ..<0: return .milliseconds(5000)
        default: return .milliseconds(milliseconds)
        }
    }

    /// Tests only: replaces `configured` for resolver groups run in this task and its children;
    /// `.zero` disables the deadline.
    @TaskLocal package static var overrideForTesting: Duration?

    /// Tests only: the metrics resolver groups in this task report to, instead of `shared`.
    @TaskLocal package static var metricsForTesting: ResolverDeadlineMetrics?

    /// The deadline in effect for a group started now.
    static var current: Duration? {
        guard let override = overrideForTesting else { return configured }
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
        /// Resolver groups that ran past their deadline.
        public var timeouts: Int
        /// A gauge: resolver groups their caller stopped waiting for (at the deadline, or when
        /// the caller was cancelled) whose task is still running, as with a resolver that ignores
        /// cancellation. It goes down when the task ends, so one that never ends shows.
        public var abandoned: Int
        /// OnLeave inputs dropped because their resolvers failed or timed out.
        public var onLeaveDropped: Int
    }

    private let lock = NSLock()
    private var counts = Snapshot(timeouts: 0, abandoned: 0, onLeaveDropped: 0)

    package init() {}

    public var snapshot: Snapshot {
        lock.withLock { counts }
    }

    func noteTimedOut() {
        lock.withLock {
            counts.timeouts += 1
            counts.abandoned += 1
        }
    }

    /// The caller was cancelled before the group finished: abandoned, not timed out.
    func noteCallerCancelled() {
        lock.withLock { counts.abandoned += 1 }
    }

    func noteAbandonedEnded() {
        lock.withLock { counts.abandoned -= 1 }
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
        let outcome = lock.withLock { () -> Result<LandContext, any Error>? in
            if outcome == nil { self.continuation = continuation }
            return outcome
        }
        if let outcome { continuation.resume(with: outcome) }
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
    @discardableResult
    func settle(_ result: Result<LandContext, any Error>, onWin: () -> Void = {}) -> Bool {
        let (continuation, timer, won) = lock.withLock { () -> (CheckedContinuation<LandContext, any Error>?, Task<Void, Never>?, Bool) in
            guard outcome == nil else { return (nil, nil, false) }
            outcome = result
            defer {
                self.continuation = nil
                self.timer = nil
            }
            return (self.continuation, self.timer, true)
        }
        guard won else { return false }
        timer?.cancel()
        onWin()
        continuation?.resume(with: result)
        return true
    }
}
