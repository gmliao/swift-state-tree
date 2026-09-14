// Sources/SwiftStateTreeTransport/SyncStrategy.swift
//
// Selects what a regular sync cycle sends to each recipient.

import Foundation

/// What `TransportAdapter` sends on every `syncNow()` / broadcast-only sync.
///
/// - `delta`: only fields that changed since the previous sync (today's behaviour).
/// - `fullSnapshot`: the recipient's complete visible view every sync, even when
///   nothing changed. Exists as a controlled baseline for measuring the delta
///   strategy; it is not a production mode.
///
/// Late-join initial sync always sends a full snapshot regardless of this setting.
public enum SyncStrategy: String, Sendable, CaseIterable {
    case delta
    case fullSnapshot = "full-snapshot"

    /// Parse a raw env value. Case-insensitive, whitespace-trimmed; unknown or
    /// empty values return `defaultValue`.
    public static func parse(_ raw: String?, default defaultValue: SyncStrategy) -> SyncStrategy {
        guard let raw else { return defaultValue }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SyncStrategy(rawValue: normalized) ?? defaultValue
    }

    /// Environment variable that overrides the init default (`SYNC_STRATEGY`).
    /// Public so tools outside the module (e.g. benchmarks) can set it without
    /// reaching into the internal `TransportEnvKeys`.
    public static let environmentKey = "SYNC_STRATEGY"
}
