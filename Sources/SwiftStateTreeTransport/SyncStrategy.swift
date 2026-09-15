// Sources/SwiftStateTreeTransport/SyncStrategy.swift
//
// Selects what a regular sync cycle sends to each recipient.

import Foundation

/// What `TransportAdapter` sends on every `syncNow()` / broadcast-only sync.
///
/// - `delta`: only fields that changed since the previous sync (today's behaviour).
/// - `fullSnapshot`: the recipient's complete visible view every sync, even when
///   nothing changed. Exists as a controlled baseline for measuring the delta
///   strategy; it is not a production mode. Full-snapshot mode expresses the view
///   as `.set` patches, so a per-player field whose filtered value becomes `nil`
///   for a still-connected player (e.g. a visibility policy hiding it) produces no
///   patch at all, whereas delta mode would send an explicit `.delete` for that
///   field; this asymmetry does not arise in the hero-defense workload.
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

    /// Whether `raw` names a known case, after the same trim+lowercase normalisation
    /// `parse` applies. An empty string (after trimming) is treated as "not provided"
    /// rather than "unrecognised" and returns `false`; callers that want to warn only
    /// on an actual typo (as opposed to an unset/blank env var) should skip empty
    /// values themselves before deciding whether to warn.
    public static func isRecognised(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SyncStrategy(rawValue: normalized) != nil
    }

    /// Environment variable that overrides the init default (`SYNC_STRATEGY`).
    /// Public so tools outside the module (e.g. benchmarks) can set it without
    /// reaching into the internal `TransportEnvKeys`.
    public static let environmentKey = "SYNC_STRATEGY"
}
