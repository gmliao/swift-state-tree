// Sources/SwiftStateTree/Resolver/ActionJobLimits.swift
//
// The caps on action jobs (a tick land's actions whose resolvers run off the caller's wait):
// per session in flight, and abandoned process-wide.

import Foundation

/// The configured caps on action jobs; `nil` means no cap.
public enum ActionJobLimits {
    /// `ACTION_IN_FLIGHT_MAX_PER_SESSION` (default 8), read once; `nil` when 0. A negative or
    /// non-integer value gives the default.
    public static let configuredInFlightPerSession: Int? =
        parse(EnvKeys.Runtime.actionInFlightMaxPerSession, default: 8, environment: ProcessInfo.processInfo.environment)

    /// `RESOLVER_ABANDONED_ACTIONS_MAX` (default 256), read once; `nil` when 0. A negative or
    /// non-integer value gives the default.
    public static let configuredAbandonedActions: Int? =
        parse(EnvKeys.Runtime.resolverAbandonedActionsMax, default: 256, environment: ProcessInfo.processInfo.environment)

    static func parse(_ key: String, default defaultValue: Int, environment: [String: String]) -> Int? {
        let value = EnvHelpers.getEnvInt(key: key, defaultValue: defaultValue, environment: environment)
        switch value {
        case 0: return nil
        case ..<0: return defaultValue
        default: return value
        }
    }

    /// Tests only: replaces `configuredInFlightPerSession` for actions submitted in this task;
    /// 0 removes the cap.
    @TaskLocal package static var inFlightPerSessionOverrideForTesting: Int?

    /// Tests only: replaces `configuredAbandonedActions` for actions submitted in this task;
    /// 0 removes the cap.
    @TaskLocal package static var abandonedActionsOverrideForTesting: Int?

    /// The per-session cap in effect for an action submitted now.
    static var inFlightPerSession: Int? {
        guard let override = inFlightPerSessionOverrideForTesting else { return configuredInFlightPerSession }
        return override == 0 ? nil : override
    }

    /// The process-wide abandoned-action cap in effect for an action submitted now.
    static var abandonedActions: Int? {
        guard let override = abandonedActionsOverrideForTesting else { return configuredAbandonedActions }
        return override == 0 ? nil : override
    }
}

/// Why an action was rejected at intake by an action-job cap. Sent to the client as
/// `ACTION_HANDLER_ERROR` with this description as the message.
public enum ActionLimitRejection: Error, Sendable, Equatable, CustomStringConvertible {
    /// The session already has `limit` action jobs in flight.
    case inFlightLimit(limit: Int)
    /// `limit` abandoned action jobs are still running in the process.
    case abandonedResolverLimit(limit: Int)

    public var description: String {
        switch self {
        case .inFlightLimit(let limit):
            return "action rejected: in-flight limit reached (\(limit) per session)"
        case .abandonedResolverLimit(let limit):
            return "action rejected: abandoned-resolver limit reached (\(limit) in the process)"
        }
    }
}

/// One action job's abandonment: its caller stopped waiting (the deadline, or a cancellation)
/// while its resolvers' task still runs. `began` and `ended` are called by the executor, at most
/// once each and in that order; they keep the process-wide abandoned-action gauge.
package final class ActionAbandonment: @unchecked Sendable {
    private let lock = NSLock()
    private var began = false
    private var ended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let metrics: ResolverDeadlineMetrics
    /// Called once, after `ended`.
    private let onEnded: @Sendable () -> Void

    package init(metrics: ResolverDeadlineMetrics, onEnded: @escaping @Sendable () -> Void) {
        self.metrics = metrics
        self.onEnded = onEnded
    }

    func noteBegan() {
        lock.withLock { began = true }
        metrics.noteActionAbandoned()
    }

    func noteEnded() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            ended = true
            defer { waiters = [] }
            return waiters
        }
        metrics.noteActionAbandonedEnded()
        toResume.forEach { $0.resume() }
        onEnded()
    }

    /// Abandoned and still running.
    package var isRunning: Bool {
        lock.withLock { began && !ended }
    }

    /// Returns once the abandoned task ended, or at once if it isn't running (tests).
    package func waitUntilEnded() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                guard began && !ended else { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
}
