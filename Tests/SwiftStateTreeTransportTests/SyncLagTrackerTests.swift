import Testing
@testable import SwiftStateTreeTransport

/// The lag fixtures of the sync-lag design (#332): a controllable clock, no hold points.
@Suite("Sync lag: the per-session decisions")
struct SyncLagTrackerTests {
    let policy = SyncLagPolicy.default
    let t0 = ContinuousClock.now

    func at(_ seconds: Double) -> ContinuousClock.Instant {
        t0 + .milliseconds(Int64(seconds * 1000))
    }

    /// A session whose firstSync (seq 1) committed at t0 and was acked at once.
    func live() -> SyncLagSession {
        var session = SyncLagSession(firstSyncSeq: 1, committedAt: t0)
        session.ack(1, at: t0)
        return session
    }

    /// Commits one frame every 100 ms in `[from, to)`, starting at `seq`; returns the next seq.
    @discardableResult
    func commitFrames(_ session: inout SyncLagSession, from: Double, to: Double, seq: UInt64) -> UInt64 {
        var seq = seq
        var time = from
        while time < to - 1e-9 {
            session.committed(seq, at: at(time))
            seq += 1
            time += 0.1
        }
        return seq
    }

    /// Classifies every 250 ms from `from` to `to`, as plans would, applying each decision; a resync
    /// commits a snapshot with the next sequence at once. Returns the decisions with their times.
    func runChecks(
        _ session: inout SyncLagSession, from: Double, to: Double,
        each: (inout SyncLagSession, Double) -> Void = { _, _ in }
    ) -> [(Double, SyncLagDecision)] {
        var out: [(Double, SyncLagDecision)] = []
        var time = from
        while time <= to + 1e-9 {
            each(&session, time)
            let decision = session.decide(now: at(time), policy: policy)
            if decision != .none {
                out.append((time, decision))
                if decision == .resync {
                    session.resynced(snapshotSeq: 1_000 + UInt64(time * 100), at: at(time), policy: policy)
                } else {
                    session.apply(decision)
                }
            }
            time += 0.25
        }
        return out
    }

    @Test("A slow reader acking its old value is resynced past 3 s, never pending or unresponsive")
    func slowReader() {
        var session = live()
        commitFrames(&session, from: 0.1, to: 3.6, seq: 2)
        let decisions = runChecks(&session, from: 0.25, to: 3.5) { session, time in
            if time.truncatingRemainder(dividingBy: 1) == 0 { session.ack(1, at: at(time)) }
        }
        #expect(decisions.count == 1)
        #expect(decisions.first?.1 == .resync)
        #expect((decisions.first?.0 ?? 0) > 3.0 && (decisions.first?.0 ?? 0) <= 3.35)
        #expect(session.phase == .live)
        #expect(session.unackedCount == 1, "the FIFO restarted with the snapshot")
        #expect(session.resyncCount(now: at(3.5), policy: policy) == 1)
    }

    @Test("A 2.5 s silence with frames acked up to its start: no decision")
    func shortSilence() {
        var session = live()
        commitFrames(&session, from: 0.1, to: 6, seq: 2)
        session.ack(10, at: at(1.0))
        // Silent from 1.0 to 3.5, then acks everything at 3.5.
        let decisions = runChecks(&session, from: 1.25, to: 6) { session, time in
            if time >= 3.5 { session.ack(UInt64(time * 10), at: at(time)) }
        }
        #expect(decisions.isEmpty)
        #expect(session.phase == .live)
    }

    @Test("Elevator: silent 5 s, pending at 3 s, resynced at the first check after the acks resume")
    func elevator() {
        var session = live()
        commitFrames(&session, from: 0.1, to: 0.15, seq: 2)  // frame 2, never acked before the silence
        var decisions = runChecks(&session, from: 0.25, to: 5.0)
        #expect(decisions.map(\.1) == [.markPending])
        #expect(session.phase == .resyncPending)
        // Acks resume and ack everything received: still a resync, whatever the lag.
        session.ack(2, at: at(5.1))
        decisions = runChecks(&session, from: 5.25, to: 5.25)
        #expect(decisions.map(\.1) == [.resync])
        #expect(session.phase == .live)
    }

    @Test("Silent 11 s: pending from 3 s, unresponsive at 10 s")
    func longSilence() {
        var session = live()
        session.committed(2, at: at(0.1))
        let decisions = runChecks(&session, from: 0.25, to: 11)
        #expect(decisions.map(\.1) == [.markPending, .close(SessionClose.Code.unresponsive)])
        #expect((decisions.last?.0 ?? 0) > 10.0 && (decisions.last?.0 ?? 0) <= 10.35)
        #expect(session.phase == .closing)
    }

    @Test("The third resync within 60 s is a slow-consumer close")
    func thirdResync() {
        var session = live()
        var seq: UInt64 = 2
        var results: [SyncLagDecision] = []
        for round in 0..<3 {
            let base = Double(round) * 10
            if round > 0 {
                session.ack(seq, at: at(base + 0.1))  // the previous round's snapshot
                seq += 1
            }
            seq = commitFrames(&session, from: base + 0.2, to: base + 3.8, seq: seq)
            session.ack(seq - 36, at: at(base + 3.4))  // acks stay fresh, lag past 3 s
            let decision = session.decide(now: at(base + 3.5), policy: policy)
            results.append(decision)
            if decision == .resync {
                session.resynced(snapshotSeq: seq, at: at(base + 3.5), policy: policy)
            } else {
                session.apply(decision)
            }
        }
        #expect(results == [.resync, .resync, .close(SessionClose.Code.slowConsumer)])
    }

    @Test("A full view unacked for 10 s while acks stay fresh: slow consumer; within 10 s: exempt")
    func fullViewExemption() {
        // A join firstSync that takes 5 s while acks of nothing keep coming: no resync.
        var session = SyncLagSession(firstSyncSeq: 1, committedAt: t0)
        session.committed(2, at: at(0.1))
        var decisions = runChecks(&session, from: 0.25, to: 5) { session, time in
            if time.truncatingRemainder(dividingBy: 1) == 0 { session.ack(0, at: at(time)) }
        }
        #expect(decisions.isEmpty)
        session.ack(2, at: at(5.1))
        #expect(session.decide(now: at(5.25), policy: policy) == .none)

        // A snapshot never acked within 10 s, acks fresh: slow consumer.
        var snapshot = live()
        snapshot.resynced(snapshotSeq: 5, at: at(1.1), policy: policy)
        decisions = runChecks(&snapshot, from: 1.25, to: 11.5) { session, time in
            if time.truncatingRemainder(dividingBy: 1) == 0 { session.ack(4, at: at(time)) }
        }
        #expect(decisions.map(\.1) == [.close(SessionClose.Code.slowConsumer)])
        #expect((decisions.first?.0 ?? 0) > 11.1)
    }

    @Test("An idle land: no close without unacked frames; one frame after 30 s gets a full timeout")
    func idleLand() {
        var session = live()
        #expect(runChecks(&session, from: 0.25, to: 30).isEmpty)
        session.committed(2, at: at(30))
        session.ack(2, at: at(31))
        #expect(runChecks(&session, from: 30.25, to: 32).isEmpty)
        #expect(session.phase == .live)
    }

    @Test("A sparse land: a frame 5 s after the last acked one, acked within 1 s, is no lag")
    func sparseLand() {
        var session = live()
        session.committed(2, at: at(5))
        let decisions = runChecks(&session, from: 5.25, to: 7) { session, time in
            if time == 5.75 { session.ack(2, at: at(time)) }
        }
        #expect(decisions.isEmpty)
    }

    @Test("A busy land with only apply-path acks stays fresh")
    func applyPathAcks() {
        var session = live()
        var seq: UInt64 = 2
        var time = 0.1
        while time < 20 {
            session.committed(seq, at: at(time))
            // The client applies each frame 50 ms later and acks from the apply path once a second.
            if Int(time * 10) % 10 == 0 { session.ack(seq, at: at(time + 0.05)) }
            seq += 1
            time += 0.1
        }
        // Checked only at the end: lag is under a second.
        #expect(session.decide(now: at(20), policy: policy) == .none)
    }

    @Test("Between a resync's plan and its commit: an old ack changes the old FIFO; after the commit only the snapshot's ack pops it")
    func ackAroundSnapshot() {
        var session = live()
        session.committed(2, at: at(0.1))
        session.committed(3, at: at(0.2))
        #expect(session.decide(now: at(3.5), policy: policy) == .resync)
        // An ack after the plan classified the resync, before its commit.
        session.ack(2, at: at(3.55))
        #expect(session.unackedCount == 1)
        // The commit restarts the FIFO with the snapshot, whatever the ack changed.
        session.resynced(snapshotSeq: 9, at: at(3.6), policy: policy)
        #expect(session.unackedCount == 1)
        session.committed(10, at: at(3.7))
        // An ack older than the snapshot pops nothing, but refreshes lastAckAt.
        session.ack(3, at: at(3.8))
        #expect(session.unackedCount == 2)
        #expect(session.lastAckAt == at(3.8))
        // The snapshot's ack pops exactly the snapshot entry.
        session.ack(9, at: at(4.1))
        #expect(session.unackedCount == 1)
        #expect(session.phase == .live)
    }

    @Test("A co-session resynced alongside isn't counted; a closing session makes no decisions")
    func alongsideAndClosing() {
        var other = live()
        other.committed(2, at: at(0.1))
        other.resyncedAlongside(snapshotSeq: 5, at: at(1))
        #expect(other.phase == .live)
        #expect(other.unackedCount == 1)
        #expect(other.resyncCount(now: at(1), policy: policy) == 0)

        var closing = live()
        closing.committed(2, at: at(0.1))
        closing.apply(.close(SessionClose.Code.unresponsive))
        closing.ack(2, at: at(1.1))
        #expect(closing.unackedCount == 1, "acks are ignored once closing")
        #expect(closing.decide(now: at(30), policy: policy) == .none)
    }

    @Test("Frames committed while not live are ignored")
    func commitsWhileNotLive() {
        var session = live()
        session.committed(2, at: at(0.1))
        session.apply(.markPending)
        session.committed(3, at: at(3.6))
        #expect(session.unackedCount == 1)
    }
}
