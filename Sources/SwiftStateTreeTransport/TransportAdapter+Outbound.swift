// Sources/SwiftStateTreeTransport/TransportAdapter+Outbound.swift
//
// Every frame the adapter sends goes through its ordered OutboundWriter (#60), addressed to
// single sessions of this land (#84).

import Foundation
import SwiftStateTree

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

    /// Enqueues pre-built frames: into the running sync cycle's element when one is open (the
    /// cycle's frames become one writer element), otherwise as their own element.
    func enqueueFrames(_ frames: [SessionFrame]) {
        guard !frames.isEmpty else { return }
        if cycleFrames != nil {
            cycleFrames?.append(contentsOf: frames)
        } else {
            outboundWriter.enqueue(frames)
        }
    }

    /// A frame for `sessionID`, stamped with the connection generation recorded for it.
    func sessionFrame(_ data: Data, to sessionID: SessionID) -> SessionFrame {
        SessionFrame(data: data, sessionID: sessionID, connectionGeneration: connectionGenerations[sessionID])
    }

    /// Opens the element that collects one sync cycle's frames. Returns `false` when one is
    /// already open (the caller then must not close it).
    func beginCycleFrames() -> Bool {
        guard cycleFrames == nil else { return false }
        cycleFrames = []
        return true
    }

    /// Enqueues the open cycle's frames as one writer element and closes it.
    func endCycleFrames() {
        let frames = cycleFrames ?? []
        cycleFrames = nil
        if !frames.isEmpty {
            outboundWriter.enqueue(frames)
        }
    }

    /// The sessions of this land a transport target addresses. The writer only carries single
    /// sessions; group targets are resolved from this adapter's membership, never by the shared
    /// transport (whose `.broadcast` and player map span every land on it, #84).
    func sessionIDs(for target: EventTarget) -> [SessionID] {
        switch target {
        case .session(let sessionID):
            return [sessionID]
        case .player(let playerID):
            return membershipSessionIDs(for: playerID)
        case .broadcast:
            return joinedSessionIDs()
        case .broadcastExcept(let excluded):
            return joinedSessionIDs().filter { $0 != excluded }
        }
    }

    /// Queued frames of the outbound writer (tests and diagnostics).
    func outboundBacklog() -> OutboundBacklog {
        outboundWriter.backlog
    }

    /// Waits until every frame enqueued so far was handed to the transport, or `timeout`
    /// passes. Returns whether the backlog drained. For tests and diagnostics: a sync cycle
    /// never waits for the writer.
    @discardableResult
    func waitForOutboundDrain(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while outboundWriter.backlog.elements > 0 {
            guard ContinuousClock.now < deadline else { return false }
            try? await safeTaskSleep(for: .milliseconds(1))
        }
        return true
    }
}
