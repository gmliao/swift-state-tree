// Sources/SwiftStateTree/Resolver/ActionJobLimits.swift
//
// The caps on action jobs (a tick land's actions whose resolvers run off the caller's wait):
// per session in flight, abandoned per land, and abandoned process-wide.

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

    /// `RESOLVER_ABANDONED_ACTIONS_MAX_PER_LAND` (default 32), read once; `nil` when 0. A
    /// negative or non-integer value gives the default (#364).
    public static let configuredAbandonedActionsPerLand: Int? =
        parse(EnvKeys.Runtime.resolverAbandonedActionsMaxPerLand, default: 32, environment: ProcessInfo.processInfo.environment)

    /// Tests only: replaces `configuredInFlightPerSession` for actions submitted in this task;
    /// 0 removes the cap.
    @TaskLocal package static var inFlightPerSessionOverrideForTesting: Int?

    /// Tests only: replaces `configuredAbandonedActions` for actions submitted in this task;
    /// 0 removes the cap.
    @TaskLocal package static var abandonedActionsOverrideForTesting: Int?

    /// Tests only: replaces `configuredAbandonedActionsPerLand` for actions submitted in this
    /// task; 0 removes the cap.
    @TaskLocal package static var abandonedActionsPerLandOverrideForTesting: Int?

    /// The per-session cap in effect for an action submitted now.
    static var inFlightPerSession: Int? {
        guard let override = inFlightPerSessionOverrideForTesting else { return configuredInFlightPerSession }
        return override == 0 ? nil : override
    }

    /// The per-land abandoned-action cap in effect for an action submitted now.
    static var abandonedActionsPerLand: Int? {
        guard let override = abandonedActionsPerLandOverrideForTesting else { return configuredAbandonedActionsPerLand }
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
    /// `limit` abandoned action resolver groups are still running in this land (#364). Only
    /// actions count: abandoned join, leave and OnInitialize groups are reported, not capped.
    case landAbandonedResolverLimit(limit: Int)

    public var description: String {
        switch self {
        case .inFlightLimit(let limit):
            return "action rejected: in-flight limit reached (\(limit) per session)"
        case .abandonedResolverLimit(let limit):
            return "action rejected: abandoned-resolver limit reached (\(limit) in the process)"
        case .landAbandonedResolverLimit(let limit):
            return "action rejected: abandoned-resolver limit reached (\(limit) in this land)"
        }
    }
}
