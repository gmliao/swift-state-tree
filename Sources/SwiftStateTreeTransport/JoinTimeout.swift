// Sources/SwiftStateTreeTransport/JoinTimeout.swift
//
// The end-to-end join budget (#104). A join's land lookup, its wait in the land's membership
// queue, the keeper's join and, for an in-turn join, its flip together take at most
// `JOIN_TIMEOUT_MS` from the join request. The router times out the phases before the
// admission; the adapter's flip waiter gets what is left of the budget.

import Foundation
import Logging
import SwiftStateTree

/// The join budget, read once from the environment.
enum JoinTimeoutConfig {
    /// `JOIN_TIMEOUT_MS` (default 12000, below the CLI's 15 s join timeout so the client hears
    /// the error first); `nil` when 0 (disabled). A negative or non-integer value gives the
    /// default.
    static let budget: Duration? = parseBudget(environment: ProcessInfo.processInfo.environment)

    /// `JOIN_FLIP_TIMEOUT_MS`, deprecated: when set, it still caps the flip wait inside the
    /// budget. `nil` when unset.
    static let deprecatedFlipTimeout: Duration? = parseDeprecatedFlipTimeout(environment: ProcessInfo.processInfo.environment)

    static func parseBudget(environment: [String: String]) -> Duration? {
        let milliseconds = EnvHelpers.getEnvInt(key: TransportEnvKeys.joinTimeoutMs, defaultValue: 12_000, environment: environment)
        switch milliseconds {
        case 0: return nil
        case ..<0: return .milliseconds(12_000)
        default: return .milliseconds(milliseconds)
        }
    }

    static func parseDeprecatedFlipTimeout(environment: [String: String]) -> Duration? {
        guard environment[TransportEnvKeys.joinFlipTimeoutMs] != nil else { return nil }
        let milliseconds = EnvHelpers.getEnvInt(key: TransportEnvKeys.joinFlipTimeoutMs, defaultValue: 10_000, environment: environment)
        return .milliseconds(max(1, milliseconds))
    }

    private static let deprecationWarned = NSLock()
    nonisolated(unsafe) private static var didWarnDeprecation = false

    /// Logs once per process that `JOIN_FLIP_TIMEOUT_MS` is deprecated, if it is set.
    static func warnIfDeprecatedKeySet(_ logger: Logger) {
        guard deprecatedFlipTimeout != nil else { return }
        let first = deprecationWarned.withLock { () -> Bool in
            defer { didWarnDeprecation = true }
            return !didWarnDeprecation
        }
        guard first else { return }
        logger.warning("JOIN_FLIP_TIMEOUT_MS is deprecated and will be removed: set JOIN_TIMEOUT_MS, the end-to-end join budget (it now only caps the flip wait inside that budget)")
    }

    /// How long an in-turn join admitted now waits for its flip: what is left of the budget,
    /// capped by the deprecated key. `nil`: no deadline.
    static func flipWait(
        deadline: ContinuousClock.Instant?,
        now: ContinuousClock.Instant = .now,
        cap: Duration? = deprecatedFlipTimeout
    ) -> Duration? {
        let remaining = deadline.map { max(.zero, $0 - now) }
        switch (remaining, cap) {
        case let (remaining?, cap?): return min(remaining, cap)
        case let (remaining?, nil): return remaining
        case let (nil, cap): return cap
        }
    }
}

/// The phase a join was in when its budget ran out (#104).
public enum JoinTimeoutPhase: String, Sendable, CaseIterable {
    /// Looking up the land, or creating it.
    case landLookup
    /// Bound to the land, before the adapter admitted it: the land's membership queue and the
    /// keeper's join (CanJoin, its resolvers, OnJoin's resolvers).
    case admission
    /// Admitted in a turn, waiting for its flip (#69).
    case flip

    /// The phase as the client's error and the log name it.
    var phrase: String {
        switch self {
        case .landLookup: "during land lookup"
        case .admission: "waiting for admission"
        case .flip: "waiting for the flip"
        }
    }

    /// The error message the client gets.
    var message: String { "Join timed out \(phrase)" }
}

/// Process-wide counts of timed-out joins, by phase (#104). The transport profiler reads them.
public final class JoinTimeoutMetrics: @unchecked Sendable {
    public static let shared = JoinTimeoutMetrics()

    private let lock = NSLock()
    private var counts: [JoinTimeoutPhase: Int] = [:]

    package init() {}

    /// Timed-out joins so far, by phase (every phase present).
    public var snapshot: [JoinTimeoutPhase: Int] {
        lock.withLock {
            Dictionary(uniqueKeysWithValues: JoinTimeoutPhase.allCases.map { ($0, counts[$0, default: 0]) })
        }
    }

    func noteTimedOut(_ phase: JoinTimeoutPhase) {
        lock.withLock { counts[phase, default: 0] += 1 }
    }
}
