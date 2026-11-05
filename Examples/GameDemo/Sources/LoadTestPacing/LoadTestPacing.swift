// Sources/LoadTestPacing/LoadTestPacing.swift
//
// Pacing for the in-process load generator (ServerLoadTest): deadline-based periods, stable
// per-session send offsets, and an explicit cap on sends in flight, so a period's sends are
// spread over the period, periods don't drift by their own work time, and a slow server shows
// up as recorded lateness and skipped sends instead of a silent stretch and a catch-up burst.

import Foundation
import SwiftStateTree

public enum LoadTestPacing {
    /**
     * Where a period's sends are placed.
     * - `spread`: each key at a stable offset inside the period, joins evenly spaced.
     * - `aligned`: every send at the period start (a once-per-period burst on deadline-based
     *   periods).
     */
    public enum Mode: String, Sendable, CaseIterable {
        case spread
        case aligned
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
    /// `offset(key) + j · period / perKey`. With `.aligned`, every send is at offset 0.
    public static func actionPlan(keys: [String], perKey: Int, period: Duration, mode: Mode = .spread) -> [Send] {
        guard perKey > 0, !keys.isEmpty else { return [] }
        if mode == .aligned {
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

    /// `count` joins spread evenly over the period, in order (all at offset 0 with `.aligned`).
    public static func joinPlan(count: Int, period: Duration, mode: Mode = .spread) -> [Send] {
        guard count > 0 else { return [] }
        return (0 ..< count).map { Send(offset: mode == .aligned ? .zero : period / count * $0, index: $0) }
    }

    /// Sleeps until `deadline`; returns at once if it has passed.
    public static func sleep(until deadline: ContinuousClock.Instant) async {
        let remaining = deadline - ContinuousClock.now
        if remaining > .zero {
            try? await safeTaskSleep(for: remaining)
        }
    }

    // MARK: - Periods with an in-flight cap

    /// An item to start `offset` after its period's deadline.
    public struct Scheduled<Item: Sendable>: Sendable {
        public let offset: Duration
        public let item: Item
        public init(offset: Duration, item: Item) {
            self.offset = offset
            self.item = item
        }
    }

    /// What happened in one period.
    public struct PeriodStats: Sendable, Equatable {
        public let period: Int
        /// When issuing started (after planning) minus the period's deadline.
        public let startLag: Duration
        /// Sends still running from earlier periods at the deadline.
        public let inFlightAtDeadline: Int
        public let planned: Int
        public let started: Int
        /// Planned sends not started because the in-flight cap was reached (dropped, not deferred).
        public let skippedByCap: Int
        /// `startLag` exceeded the late threshold.
        public let late: Bool
    }

    /// Counts sends in flight and refuses new ones at `cap`.
    public actor InFlightLimit {
        public let cap: Int
        public private(set) var current = 0
        public private(set) var peak = 0

        public init(cap: Int) {
            self.cap = max(1, cap)
        }

        public func tryAcquire() -> Bool {
            guard current < cap else { return false }
            current += 1
            peak = max(peak, current)
            return true
        }

        public func release() {
            current -= 1
        }
    }

    /**
     * Runs `count` periods of `period` from `origin`. Period `p` starts on its own deadline
     * `origin + p · period`, whether or not earlier periods' sends have finished: all sends run
     * in one long-lived task group, bounded by `limit`. `plan(p)` returns the period's sends; each
     * starts at `deadline + offset` (at once if that has passed) or, when `limit` is full, is
     * skipped and handed to `skipped`. `onPeriod` gets each period's stats once its sends are
     * issued. A period is late when its issuing started more than `lateAfter` (default a tenth
     * of the period) after its deadline. Cancelling the calling task stops the loop: no
     * further period or send starts. Returns when every started send has finished.
     */
    public static func runPeriods<Item: Sendable>(
        origin: ContinuousClock.Instant,
        period: Duration,
        count: Int,
        limit: InFlightLimit,
        lateAfter: Duration? = nil,
        shouldContinue: @escaping @Sendable () async -> Bool = { true },
        plan: @escaping @Sendable (Int) async -> [Scheduled<Item>],
        perform: @escaping @Sendable (Item) async -> Void,
        skipped: @escaping @Sendable (Item) async -> Void = { _ in },
        onPeriod: @escaping @Sendable (PeriodStats) async -> Void = { _ in }
    ) async {
        let lateThreshold = lateAfter ?? period / 10
        await withDiscardingTaskGroup { group in
            for p in 0 ..< count {
                guard !Task.isCancelled, await shouldContinue() else { break }
                let deadline = origin + period * p
                await sleep(until: deadline)
                // `sleep(until:)` returns early when cancelled; don't start the period then.
                if Task.isCancelled { break }
                let inFlight = await limit.current
                let items = await plan(p)
                let startLag = ContinuousClock.now - deadline
                var started = 0
                var skippedCount = 0
                for scheduled in items {
                    await sleep(until: deadline + scheduled.offset)
                    if Task.isCancelled { break }
                    if await limit.tryAcquire() {
                        started += 1
                        group.addTask {
                            await perform(scheduled.item)
                            await limit.release()
                        }
                    } else {
                        skippedCount += 1
                        await skipped(scheduled.item)
                    }
                }
                await onPeriod(PeriodStats(
                    period: p,
                    startLag: startLag,
                    inFlightAtDeadline: inFlight,
                    planned: items.count,
                    started: started,
                    skippedByCap: skippedCount,
                    late: startLag > lateThreshold
                ))
            }
        }
    }

    /// `d` in milliseconds.
    public static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
