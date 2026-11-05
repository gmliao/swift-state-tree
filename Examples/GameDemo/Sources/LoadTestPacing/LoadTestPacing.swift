// Sources/LoadTestPacing/LoadTestPacing.swift
//
// Pacing for the in-process load generator (ServerLoadTest): deadline-based loops and stable
// per-session send offsets, so a period's sends are spread over the period instead of arriving
// as one burst, and loops don't drift by their own work time.

import Foundation
import SwiftStateTree

public enum LoadTestPacing {
    /**
     * How a period's sends are placed.
     * - `spread` (default): each key at a stable offset inside the period, joins evenly spaced.
     * - `burst`: every send at the period start, the earlier pattern (still on deadline-based
     *   periods, so it no longer drifts by the work time).
     */
    public enum Mode: String, Sendable, CaseIterable {
        case spread
        case burst
    }

    /// Stable 32-bit hash: FNV-1a followed by the murmur3 finalizer (keys that differ only in
    /// their last characters still get well-spread values).
    public static func hash32(_ text: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            h ^= UInt32(byte)
            h = h &* 0x0100_0193
        }
        h ^= h >> 16
        h = h &* 0x85EB_CA6B
        h ^= h >> 13
        h = h &* 0xC2B2_AE35
        h ^= h >> 16
        return h
    }

    /// Stable offset in `[0, period)` for `key`.
    public static func offset(for key: String, period: Duration) -> Duration {
        period * (Double(hash32(key)) / 4_294_967_296.0)
    }

    /// One send in a period: when (from the period start) and for which key index.
    public struct Send: Sendable, Equatable {
        public let offset: Duration
        public let index: Int
    }

    /// A period's sends for `keys`, `perKey` each, in time order. Key `i`'s sends are at
    /// `offset(key) + j · period / perKey`, wrapped into the period.
    /// With `.burst`, every send is at offset 0 (key order).
    public static func actionPlan(keys: [String], perKey: Int, period: Duration, mode: Mode = .spread) -> [Send] {
        guard perKey > 0, !keys.isEmpty else { return [] }
        if mode == .burst {
            return (0 ..< perKey).flatMap { _ in keys.indices.map { Send(offset: .zero, index: $0) } }
        }
        let step = period / perKey
        var sends: [Send] = []
        sends.reserveCapacity(keys.count * perKey)
        for (index, key) in keys.enumerated() {
            let base = offset(for: key, period: step)
            for j in 0 ..< perKey {
                sends.append(Send(offset: base + step * j, index: index))
            }
        }
        sends.sort { $0.offset < $1.offset || ($0.offset == $1.offset && $0.index < $1.index) }
        return sends
    }

    /// `count` joins spread evenly over the period, in order (all at offset 0 with `.burst`).
    public static func joinPlan(count: Int, period: Duration, mode: Mode = .spread) -> [Send] {
        guard count > 0 else { return [] }
        return (0 ..< count).map { Send(offset: mode == .burst ? .zero : period / count * $0, index: $0) }
    }

    /// Sleeps until `deadline`; returns at once if it has passed (a late loop catches up instead
    /// of shifting every later deadline).
    public static func sleep(until deadline: ContinuousClock.Instant) async {
        let remaining = deadline - ContinuousClock.now
        if remaining > .zero {
            try? await safeTaskSleep(for: remaining)
        }
    }

    /// Runs `plan` from `start`: each send starts at `start + offset` in its own child task, so
    /// a slow send doesn't delay the next one. Sends whose time has passed start at once.
    /// Returns when every send has finished.
    public static func run(
        _ plan: [Send],
        from start: ContinuousClock.Instant,
        send: @escaping @Sendable (Int) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for item in plan {
                await sleep(until: start + item.offset)
                group.addTask { await send(item.index) }
            }
        }
    }
}
