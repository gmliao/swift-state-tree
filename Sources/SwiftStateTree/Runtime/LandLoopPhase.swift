// Sources/SwiftStateTree/Runtime/LandLoopPhase.swift
//
// Per-land phase offset for the keeper's tick and sync loops.

import Foundation

/// Phase offset of a land's tick and sync loops.
///
/// Lands created together (a join ramp, a server start) would otherwise start their loops in
/// phase: every land's tick and sync cycle would run in the same few milliseconds of each
/// interval, keeping every thread of the cooperative pool busy and making each inbound message
/// that arrives in that burst wait. The keeper delays each loop's first iteration by this
/// offset and keeps the period, so lands spread over the interval.
///
/// The offset is FNV-1a 64 over the land ID's UTF-8 bytes modulo `min(interval, maxOffset)`:
/// the same land gets the same offset in every process (unlike `Hasher`, which is seeded per
/// process), and a slow loop (a 30 s game timer) is delayed by at most `maxOffset`, not by up
/// to a whole interval. It only shifts wall-clock timing; tick IDs, ordering and replay
/// (`stepTickOnce`, re-evaluation) are unaffected.
public enum LandLoopPhase {
    /// Upper bound of the offset. Burst alignment only matters for high-frequency loops.
    public static let maxOffset: Duration = .milliseconds(100)

    /// Offset in `[0, min(interval, maxOffset))` for `landID`. `.zero` for a non-positive interval.
    public static func offset(landID: String, interval: Duration) -> Duration {
        guard interval > .zero else { return .zero }
        // Bounded by maxOffset first, so the nanosecond conversion cannot overflow.
        let window = min(interval, maxOffset).components
        let nanoseconds = window.seconds * 1_000_000_000 + window.attoseconds / 1_000_000_000
        guard nanoseconds > 0 else { return .zero }
        let hash = DeterministicHash.fnv1a64(landID)
        return .nanoseconds(Int64(hash % UInt64(nanoseconds)))
    }

    /// Whether the offset is enabled by default: `true` unless `LAND_LOOP_PHASE_OFFSET` is false.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        EnvHelpers.getEnvBool(
            key: EnvKeys.Runtime.landLoopPhaseOffset,
            defaultValue: true,
            environment: environment
        )
    }
}
