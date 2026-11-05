// Sources/SwiftStateTreeTransport/TransportAdapter+Outbound.swift
//
// Every frame the adapter sends goes through its ordered OutboundWriter (#60), addressed to
// single sessions of this land (#84).

import Foundation
import SwiftStateTree
import Logging

extension TransportAdapter {
    /// Enqueues `data` for `sessionID`, in issue order with every other frame of this adapter.
    ///
    /// Used by `LandRouter` for frames of a session that joined this land (the join response and
    /// later errors), so they cannot overtake or trail this land's state frames.
    public func enqueueOutbound(_ data: Data, to sessionID: SessionID) {
        enqueueFrames([sessionFrame(data, to: sessionID)])
    }

    /// Enqueues `data` once per session, in the given order.
    func enqueueOutbound(_ data: Data, toSessions sessionIDs: [SessionID]) {
        guard !sessionIDs.isEmpty else { return }
        enqueueFrames(sessionIDs.map { sessionFrame(data, to: $0) })
    }

    /// Enqueues pre-built frames as one writer element (a sync phase's commit enqueues all its
    /// frames in one call, tagged `isSyncCycle` for the back-pressure rule unless it is a
    /// joiner's firstSync). Frames for an ended session (see `endedSessions`) are dropped here.
    func enqueueFrames(_ frames: [SessionFrame], isSyncCycle: Bool = false) {
        let live = endedSessions.isEmpty ? frames : frames.filter { !endedSessions.contains($0.sessionID) }
        guard !live.isEmpty else { return }
        writeElement(live, isSyncCycle: isSyncCycle)
    }

    /// Hands one element to the writer. When the writer drops it over its ceiling, every session
    /// it addressed is ended and disconnected: those clients missed frames that later diffs
    /// assume they have, so they must rejoin and get a fresh firstSync (#61 adds a per-session
    /// policy).
    func writeElement(_ frames: [SessionFrame], isSyncCycle: Bool = false) {
        guard outboundWriter.enqueue(frames, isSyncCycle: isSyncCycle) == .droppedOverCeiling else { return }
        var addressed: [SessionID] = []
        var seen = Set<SessionID>()
        for frame in frames where seen.insert(frame.sessionID).inserted {
            addressed.append(frame.sessionID)
        }
        outboundCeilingDisconnects += addressed.count
        outboundLogger.error("Disconnecting sessions after an outbound frame drop (writer ceiling)", metadata: [
            "landID": .string(landIDForOutbound),
            "sessions": .string(addressed.map(\.rawValue).joined(separator: ",")),
            "serverInitiatedDisconnectsTotal": .stringConvertible(outboundCeilingDisconnects),
        ])
        let transport = self.transport
        if !transport.supportsCloseSession, !warnedNoCloseSession {
            warnedNoCloseSession = true
            outboundLogger.warning("Transport cannot close sessions: the ended sessions stay connected but get no frames until they reconnect", metadata: [
                "landID": .string(landIDForOutbound),
                "transport": .string(String(describing: type(of: transport))),
            ])
        }
        for sessionID in addressed {
            endedSessions.insert(sessionID)
            Task { await transport.closeSession(sessionID) }
        }
    }

    /// A frame for `sessionID`, stamped with the connection generation recorded for it.
    func sessionFrame(_ data: Data, to sessionID: SessionID) -> SessionFrame {
        SessionFrame(data: data, sessionID: sessionID, connectionGeneration: connectionGenerations[sessionID])
    }

    /// The sessions of this land a transport target addresses. The writer only carries single
    /// sessions; group targets are resolved from this adapter's membership, never by the shared
    /// transport (whose `.broadcast` and player map span every land on it, #84).
    func sessionIDs(for target: EventTarget) -> [SessionID] {
        switch target {
        case .session(let sessionID):
            // A join that completes in a turn gets nothing before its JoinResponse, which is a
            // frame of its flip (#69). Its targeted events until then are not delivered (#69
            // follow-up keeps them for after its firstSync); they are counted.
            guard !isJoiningInTurn(sessionID) else {
                noteEventsDroppedForJoiningSessions(1)
                return []
            }
            return [sessionID]
        case .player(let playerID):
            let sessions = membershipSessionIDs(for: playerID)
            let joined = sessions.filter { !isJoining($0) }
            noteEventsDroppedForJoiningSessions(sessions.count - joined.count)
            return joined
        case .broadcast:
            return joinedSessionIDs().filter { !isJoining($0) }
        case .broadcastExcept(let excluded):
            return joinedSessionIDs().filter { $0 != excluded && !isJoining($0) }
        }
    }

    /// Whether the writer still holds a sync cycle element (state frames) that has not been
    /// handed to the transport. The sync back-pressure rule: a new state cycle waits while this
    /// is true. Event and action-response elements are not counted, so an event-heavy land never
    /// suppresses its own state syncs.
    /// After teardown (`finish`) it is false: later frames are dropped anyway, and a sync
    /// request must not be deferred behind elements that will never drain.
    var hasPendingStateElement: Bool {
        !outboundWriter.isFinished && outboundWriter.backlog.syncCycleElements > 0
    }

    /// Queued frames of the outbound writer (tests and diagnostics).
    func outboundBacklog() -> OutboundBacklog {
        outboundWriter.backlog
    }

    /// Sessions disconnected by the server after a writer ceiling drop (tests and diagnostics).
    func outboundCeilingDisconnectCount() -> Int {
        outboundCeilingDisconnects
    }

    /// Waits until every frame enqueued so far was handed to the transport, or `timeout`
    /// passes. Returns whether the backlog drained. For tests and diagnostics: a sync cycle
    /// never waits for the writer. Only covers frames enqueued so far: a follow-up cycle that
    /// has not run yet enqueues later, so wait for its frames before asserting exact counts.
    /// Not a supported API: a benchmark uses it to count bytes only after they were handed over.
    @_spi(Diagnostics) public func waitForOutboundDrain(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while outboundWriter.backlog.elements > 0 {
            guard ContinuousClock.now < deadline else { return false }
            try? await safeTaskSleep(for: .milliseconds(1))
        }
        return true
    }
}

/// Sync cycles an adapter skipped before `beginSync`.
public struct SyncSkipCounts: Sendable, Equatable {
    /// Another cycle was in flight (`LandKeeper.beginSync` rejected the request).
    public var busy = 0
    /// The writer still held a sync cycle element from an earlier cycle (back-pressure).
    public var outboundBacklog = 0

    public init(busy: Int = 0, outboundBacklog: Int = 0) {
        self.busy = busy
        self.outboundBacklog = outboundBacklog
    }
}

/// Recently ended sessions of one adapter: frames for them are dropped, also unstamped ones, so
/// a late frame for an ended connection (an action response, an error) never reaches a later
/// connection that reuses the `SessionID`. Bounded: late frames follow the end within moments,
/// so only the most recent `capacity` sessions are kept, and the insertion log is compacted
/// when stale entries (from `remove` and re-insert of a reused `SessionID`) pile up.
struct EndedSessionSet {
    /// Session → insertion sequence; eviction only removes the entry it inserted.
    private var members: [SessionID: UInt64] = [:]
    private var order: [(sessionID: SessionID, seq: UInt64)] = []
    private var head = 0
    private var nextSeq: UInt64 = 0
    let capacity: Int

    init(capacity: Int = 4096) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { members.isEmpty }

    func contains(_ sessionID: SessionID) -> Bool {
        members[sessionID] != nil
    }

    mutating func insert(_ sessionID: SessionID) {
        guard members[sessionID] == nil else { return }
        nextSeq += 1
        members[sessionID] = nextSeq
        order.append((sessionID, nextSeq))
        while members.count > capacity, head < order.count {
            let oldest = order[head]
            head += 1
            if members[oldest.sessionID] == oldest.seq {
                members.removeValue(forKey: oldest.sessionID)
            }
        }
        if head >= capacity {
            order.removeFirst(head)
            head = 0
        }
        // Without evictions (members stay under capacity) a SessionID that is removed and
        // inserted again leaves its old entry behind: drop entries no longer in `members`.
        if order.count - head > 2 * capacity {
            order = order[head...].filter { members[$0.sessionID] == $0.seq }
            head = 0
        }
    }

    /// Length of the insertion log (tests).
    var orderCount: Int { order.count - head }

    /// The session joined again (a new connection registered under the same `SessionID`).
    mutating func remove(_ sessionID: SessionID) {
        members.removeValue(forKey: sessionID)
    }
}
