import Foundation
import SwiftStateTree

/// The thresholds of sync-lag tracking (#332). Every value is configurable; the defaults are the
/// design's. Tracking itself is on with `TransportEncodingConfig.syncSequence`.
public struct SyncLagPolicy: Sendable, Equatable {
    /// Lag past which a session whose acks still arrive is resynced in place.
    public var resyncAfter: Duration
    /// The resync, counted within `slowConsumerWindow`, that is a slow-consumer close instead.
    public var slowConsumerCount: Int
    public var slowConsumerWindow: Duration
    /// Stale acks for this long while frames are unacked close the session as unresponsive.
    public var ackTimeout: Duration
    /// Acks older than this are stale: they pause the resync decision.
    public var ackFreshness: Duration
    /// How long a terminal close waits for the client's close frame.
    public var closeGrace: Duration

    public init(
        resyncAfter: Duration = .seconds(3),
        slowConsumerCount: Int = 3,
        slowConsumerWindow: Duration = .seconds(60),
        ackTimeout: Duration = .seconds(10),
        ackFreshness: Duration = .seconds(2),
        closeGrace: Duration = .seconds(2)
    ) {
        self.resyncAfter = resyncAfter
        self.slowConsumerCount = slowConsumerCount
        self.slowConsumerWindow = slowConsumerWindow
        self.ackTimeout = ackTimeout
        self.ackFreshness = ackFreshness
        self.closeGrace = closeGrace
    }

    public static let `default` = SyncLagPolicy()

    /// The policy from the environment: `SYNC_LAG_RESYNC_MS`, `SYNC_LAG_SLOW_CONSUMER_COUNT`,
    /// `SYNC_LAG_SLOW_CONSUMER_WINDOW_MS`, `SYNC_ACK_TIMEOUT_MS`, `SYNC_ACK_FRESHNESS_MS` and
    /// `SYNC_LAG_CLOSE_GRACE_MS`. A missing, non-integer or non-positive value gives the default.
    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SyncLagPolicy {
        let defaults = SyncLagPolicy.default
        func milliseconds(_ key: String, _ fallback: Duration) -> Duration {
            let value = EnvHelpers.getEnvInt(key: key, defaultValue: 0, environment: environment)
            return value > 0 ? .milliseconds(value) : fallback
        }
        let count = EnvHelpers.getEnvInt(key: TransportEnvKeys.syncLagSlowConsumerCount, defaultValue: 0, environment: environment)
        return SyncLagPolicy(
            resyncAfter: milliseconds(TransportEnvKeys.syncLagResyncMs, defaults.resyncAfter),
            slowConsumerCount: count > 0 ? count : defaults.slowConsumerCount,
            slowConsumerWindow: milliseconds(TransportEnvKeys.syncLagSlowConsumerWindowMs, defaults.slowConsumerWindow),
            ackTimeout: milliseconds(TransportEnvKeys.syncAckTimeoutMs, defaults.ackTimeout),
            ackFreshness: milliseconds(TransportEnvKeys.syncAckFreshnessMs, defaults.ackFreshness),
            closeGrace: milliseconds(TransportEnvKeys.syncLagCloseGraceMs, defaults.closeGrace)
        )
    }
}

/// What one lag check decides for a session.
enum SyncLagDecision: Equatable, Sendable {
    case none
    /// Lag past `resyncAfter` with stale acks: stop planning frames, wait for fresh acks.
    case markPending
    /// Resync in place: the plan gives the session a fresh full view on its live connection.
    case resync
    /// A terminal close (`SessionClose.Code.slowConsumer` or `.unresponsive`).
    case close(UInt16)
}

/// One session's lag state (#332): the frames committed to it since its last ack, its last ack,
/// its phase and its resync times. A value type with no clock of its own, so every decision is a
/// function of its inputs. The sync plan classifies each recipient with `decide` and the commit
/// applies what the plan staged; the timer only reads it (D1). The adapter owns one per session
/// and mutates it only in synchronous segments.
struct SyncLagSession: Sendable {
    enum Phase: Equatable, Sendable {
        /// Frames are planned as usual.
        case live
        /// Lag passed `resyncAfter` while acks were stale: no frames, events dropped.
        case resyncPending
        /// A terminal close is under way: no decisions, acks ignored.
        case closing
    }

    struct Entry: Sendable {
        var seq: UInt64
        var committedAt: ContinuousClock.Instant
        /// A firstSync or a resync snapshot: exempt from `resyncAfter`.
        var isFullView: Bool
    }

    private(set) var unacked: [Entry]
    private(set) var lastAckAt: ContinuousClock.Instant
    private(set) var phase: Phase = .live
    private(set) var resyncTimes: [ContinuousClock.Instant] = []

    /// Tracking starts when the session's firstSync commits: it is the FIFO's first entry, and
    /// the ack clock starts at its commit.
    init(firstSyncSeq: UInt64, committedAt: ContinuousClock.Instant) {
        unacked = [Entry(seq: firstSyncSeq, committedAt: committedAt, isFullView: true)]
        lastAckAt = committedAt
    }

    var unackedCount: Int { unacked.count }

    /// Whether frames may be planned for the session.
    var plansFrames: Bool { phase == .live }

    /// Whether events for the session are dropped (while pending; the resyncing plan drops its
    /// own consumed events too).
    var dropsEvents: Bool { phase == .resyncPending }

    /// A state-update frame committed to the session. Ignored unless live: no frame is planned
    /// otherwise, so one arriving here is a stale plan's.
    mutating func committed(_ seq: UInt64, at time: ContinuousClock.Instant) {
        guard phase == .live else { return }
        unacked.append(Entry(seq: seq, committedAt: time, isFullView: false))
    }

    /// The plan that resynced this session committed its snapshot: records the resync, and the
    /// FIFO restarts with the snapshot, a full view, in phase live.
    mutating func resynced(snapshotSeq seq: UInt64, at time: ContinuousClock.Instant, policy: SyncLagPolicy) {
        guard phase != .closing else { return }
        resyncTimes.removeAll { time - $0 >= policy.slowConsumerWindow }
        resyncTimes.append(time)
        restart(snapshotSeq: seq, at: time)
    }

    /// Another session of the same player was resynced in the same plan: the view is per player,
    /// so this one got the snapshot too. Its own count doesn't grow.
    mutating func resyncedAlongside(snapshotSeq seq: UInt64, at time: ContinuousClock.Instant) {
        guard phase != .closing else { return }
        restart(snapshotSeq: seq, at: time)
    }

    private mutating func restart(snapshotSeq seq: UInt64, at time: ContinuousClock.Instant) {
        unacked = [Entry(seq: seq, committedAt: time, isFullView: true)]
        phase = .live
    }

    /// An ack for `seq`: pops every entry at or before it. Every ack refreshes `lastAckAt`, one
    /// that pops nothing (an unchanged value) included. Ignored once closing.
    mutating func ack(_ seq: UInt64, at time: ContinuousClock.Instant) {
        guard phase != .closing else { return }
        lastAckAt = time
        if let firstKept = unacked.firstIndex(where: { $0.seq > seq }) {
            unacked.removeFirst(firstKept)
        } else {
            unacked.removeAll(keepingCapacity: true)
        }
    }

    /// The resyncs within `slowConsumerWindow` before `now`.
    func resyncCount(now: ContinuousClock.Instant, policy: SyncLagPolicy) -> Int {
        resyncTimes.filter { now - $0 < policy.slowConsumerWindow }.count
    }

    /// The check's decision, in the design's order (§ 3). Pure: `apply` makes it happen.
    func decide(now: ContinuousClock.Instant, policy: SyncLagPolicy) -> SyncLagDecision {
        guard phase != .closing else { return .none }
        let fresh = now - lastAckAt <= policy.ackFreshness
        if let first = unacked.first {
            // 1. Its own full view unacked for the ack timeout while it still reads: too slow.
            if first.isFullView, fresh, now - first.committedAt > policy.ackTimeout {
                return .close(SessionClose.Code.slowConsumer)
            }
            // 2. Stale acks for the ack timeout while frames are unacked.
            if now - max(lastAckAt, first.committedAt) > policy.ackTimeout {
                return .close(SessionClose.Code.unresponsive)
            }
            // 3. A full view is exempt from `resyncAfter`.
            if first.isFullView { return .none }
        }
        let lag = unacked.first.map { now - $0.committedAt } ?? .zero
        // 4. Lag past the threshold while the acks have paused: wait for them.
        if phase == .live, lag > policy.resyncAfter, !fresh {
            return .markPending
        }
        // 5. A resync, or the slow-consumer close it would be.
        if (phase == .resyncPending && fresh) || (phase == .live && lag > policy.resyncAfter) {
            if resyncCount(now: now, policy: policy) + 1 >= policy.slowConsumerCount {
                return .close(SessionClose.Code.slowConsumer)
            }
            return .resync
        }
        return .none
    }

    /// Applies a pending mark or a close. A resync is applied by `resynced` when its plan commits.
    mutating func apply(_ decision: SyncLagDecision) {
        switch decision {
        case .none, .resync:
            return
        case .markPending:
            phase = .resyncPending
        case .close:
            phase = .closing
        }
    }
}
