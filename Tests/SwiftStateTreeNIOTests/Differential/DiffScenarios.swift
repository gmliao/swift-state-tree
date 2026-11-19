// Tests/SwiftStateTreeNIOTests/Differential/DiffScenarios.swift
//
// The first scenario set (#555, plan §8). Each names its cells, its steps, every request's
// outcome and the record's lifecycle; the oracle checks them in every run.
//
// Notes the steps rely on:
// - A disconnect is awaited through the router's forwards: the router hands it to the adapter
//   in a task of its own, and a step that didn't wait would let the leave share the next
//   input's pass, or miss the tick and be dropped by the stop (#512). A supersede's server
//   close forwards a disconnect too, so the runner waits for all of them, not a count.
// - The loops are off, so every applied change reaches the clients through the runner's sync
//   cycle: a tick land's step is a tick then a sync, a tickless land's the input's drain then a
//   sync.

#if DEBUG
import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// The witness client of a single-player race row: B joins and settles before the race and
/// stays, so the live checkpoint has a client, and B's frames show what A's race leaked.
let witnessJoins: [DiffStep] = [.connect("B", session: "s-b"), .join("B", player: "pb")]

/// A disconnect of A while its join is held at a router hold, for the router rows: the router
/// is free at the hold and nothing of A's join is queued, so the forward completes under it.
func routerRow(_ name: String, hold: LandRouterHoldPoint, cells: DiffCellRule, joinReply: DiffOutcome,
               joinReplyIn: @escaping @Sendable (DiffCell) -> DiffOutcome? = { _ in nil }, admitted: Bool) -> DiffScenario {
    DiffScenario(
        name: name,
        cells: cells,
        steps: witnessJoins + [
            .connect("A", session: "s-a"),
            .arm(.router(hold)),
            .startJoin("A", player: "pa"),
            .reach(.router(hold)),
            .disconnect("A"),
            .release(.router(hold)),
            .awaitJoin("A"),
            .liveCheckpoint,
            .disconnect("B"),
        ],
        outcomes: ["join-B": .reply, "join-A": joinReply],
        outcomesByCell: { cell in joinReplyIn(cell).map { ["join-A": $0] } ?? [:] },
        lifecycle: ["pb": [.join, .leave]].merging(admitted ? ["pa": [.join, .leave]] : [:]) { a, _ in a }
    )
}

typealias DiffJoinKey = TransportAdapter<DiffState>.JoinAttemptKey

/// A's first join after the witness's: the router numbers join attempts across its sessions,
/// from 1, so the witness B's is 1 and A's is 2.
let attemptA1 = DiffJoinKey(sessionID: SessionID("s-a"), attempt: 2)

func expect(_ condition: Bool, _ what: @autoclosure () -> String) throws {
    guard condition else { throw DiffRunFailure(what()) }
}

let diffScenarios: [DiffScenario] = [
    DiffScenario(
        name: "join-act-leave",
        cells: .all,
        steps: [
            .connect("A", session: "s-a"),
            .join("A", player: "p1"),
            .bump("A", requestID: "bump-1", amount: 1),
            .liveCheckpoint,
            .disconnect("A"),
        ],
        outcomes: ["join-A": .reply, "bump-1": .reply],
        lifecycle: ["p1": [.join, .leave]]
    ),
    DiffScenario(
        name: "two-players",
        cells: .all,
        steps: [
            .connect("A", session: "s-a"),
            .join("A", player: "p1"),
            .connect("B", session: "s-b"),
            .join("B", player: "p2"),
            .bump("A", requestID: "bump-a", amount: 2),
            .bump("B", requestID: "bump-b", amount: 3),
            .tick,
            .liveCheckpoint,
            .disconnect("B"),
            .bump("A", requestID: "bump-a2", amount: 1),
            .disconnect("A"),
        ],
        outcomes: ["join-A": .reply, "join-B": .reply, "bump-a": .reply, "bump-b": .reply, "bump-a2": .reply],
        lifecycle: ["p1": [.join, .leave], "p2": [.join, .leave]]
    ),
    DiffScenario(
        name: "second-session",
        cells: .all,
        steps: [
            .connect("A", session: "s-a"),
            .join("A", player: "p1"),
            .connect("A2", session: "s-a2"),
            .join("A2", player: "p1"),
            .bump("A2", requestID: "bump-a2", amount: 1),
            .liveCheckpoint,
            .disconnect("A2"),
        ],
        outcomes: ["join-A": .reply, "join-A2": .reply, "bump-a2": .reply],
        lifecycle: ["p1": [.join, .leave, .join, .leave]]
    ),
    DiffScenario(
        name: "refused-joins",
        cells: .all,
        steps: [
            .connect("R", session: "s-r"),
            .refusedJoin("R", player: diffRefusedPlayer),
            .connect("A", session: "s-a"),
            .join("A", player: "p1"),
            .connect("B", session: "s-b"),
            .join("B", player: "p2"),
            .connect("C", session: "s-c"),
            .join("C", player: "p3"),
            .connect("D", session: "s-d"),
            .refusedJoin("D", player: "p4"),
            .bump("A", requestID: "bump-a", amount: 1),
            .liveCheckpoint,
            .disconnect("C"),
            .disconnect("B"),
            .disconnect("A"),
        ],
        outcomes: ["join-R": .error, "join-A": .reply, "join-B": .reply, "join-C": .reply, "join-D": .error, "bump-a": .reply],
        lifecycle: ["p1": [.join, .leave], "p2": [.join, .leave], "p3": [.join, .leave]]
    ),
    // The router returns before admission: no admission, no reply.
    routerRow("disconnect-before-admit", hold: .beforeAdmit, cells: .all, joinReply: .none, admitted: false),
    // After the router's admission step: admitted, then left. In-turn on a tickless land, the
    // admission has flipped the join and sent its reply before the router reaches the hold; on
    // a tick land the flip waits for the tick that applies OnJoin.
    routerRow("disconnect-after-admit", hold: .afterAdmit, cells: .all, joinReply: .none,
              joinReplyIn: { $0.sync == .inTurn && $0.land == .tickless ? .reply : nil }, admitted: true),
    // Only on the path without the in-turn flip: the reply goes to a removed session.
    routerRow("disconnect-sending-join-response", hold: .sendingJoinResponse, cells: .legacyOnly, joinReply: .none, admitted: true),
    // The reply was sent; the initial sync is for a player the leave removed.
    routerRow("disconnect-sending-initial-sync", hold: .sendingInitialSync, cells: .legacyOnly, joinReply: .reply, admitted: true),
    // The pre-admission case: the disconnect ends the attempt before it is queued, so the
    // queued join is refused as stale; neither OnJoin nor OnLeave runs.
    DiffScenario(
        name: "disconnect-before-keeper-admission",
        cells: .all,
        steps: witnessJoins + [
            .connect("A", session: "s-a"),
            .arm(.adapter(.admitJoinEntry)),
            .startJoin("A", player: "pa"),
            .reach(.adapter(.admitJoinEntry)),
            .disconnect("A"),
            .release(.adapter(.admitJoinEntry)),
            .awaitJoin("A"),
            .check("the attempt was refused as stale") { run in
                let refused = await run.adapter.staleJoinAttemptsRefused
                guard refused == 1 else { throw DiffRunFailure("staleJoinAttemptsRefused is \(refused)") }
            },
            .liveCheckpoint,
            .disconnect("B"),
        ],
        outcomes: ["join-B": .reply, "join-A": .none],
        lifecycle: ["pb": [.join, .leave]]
    ),
    // The disconnect queues behind the join held in the keeper: admitted, then left.
    DiffScenario(
        name: "disconnect-during-keeper-join",
        cells: .all,
        steps: witnessJoins + [
            .connect("A", session: "s-a"),
            .arm(.keeper(.join)),
            .startJoin("A", player: "pa"),
            .reach(.keeper(.join)),
            .observe(.adapter(.membershipQueued)),
            .startDisconnect("A"),
            .reach(.adapter(.membershipQueued)),
            .check("the leave waits behind the join") { run in
                let players = await run.keeper.currentState().players
                guard !players.contains("pa") else { throw DiffRunFailure("A is in the state while its join holds: \(players)") }
            },
            .release(.keeper(.join)),
            .awaitJoin("A"),
            .settleDisconnects,
            .liveCheckpoint,
            .disconnect("B"),
        ],
        // The transport removed A's queue when the disconnect started, so no reply reaches A.
        outcomes: ["join-B": .reply, "join-A": .none],
        lifecycle: ["pb": [.join, .leave], "pa": [.join, .leave]]
    ),
    // A disconnect at the in-turn registration: after the keeper's admission and before the
    // registration; then registered and not flipped; then the pre-leave checkpoint.
    // Prerequisites: the run captures the join commits, and while `keeperJoinReturned` holds
    // the runner waits for the keeper's input drain (a tick land steps the tick that applies
    // OnJoin there), so OnJoin's turn can't run after the registration and flip the join first.
    DiffScenario(
        name: "disconnect-at-registration",
        cells: .inTurnOnly,
        steps: witnessJoins + [
            .connect("A", session: "s-a"),
            .arm(.adapter(.keeperJoinReturned)),
            .startJoin("A", player: "pa"),
            .reach(.adapter(.keeperJoinReturned)),
            .tick,
            .check("OnJoin's drain is idle") { run in await run.keeper.waitForInputDrainIdleForTesting() },
            .check("admitted, not registered, not flipped") { run in
                try expect(await run.adapter.admittedNotRegisteredForTesting(SessionID("s-a")), "A isn't admitted-not-registered")
                try expect(await !run.adapter.joinFlippedForTesting(attemptA1), "A1 flipped before its registration")
            },
            .observe(.adapter(.membershipQueued)),
            .startDisconnect("A"),
            .reach(.adapter(.membershipQueued)),
            .arm(.adapter(.joinSyncRequested)),
            .release(.adapter(.keeperJoinReturned)),
            .reach(.adapter(.joinSyncRequested)),
            .check("registered, not flipped") { run in
                try expect(await !run.adapter.admittedNotRegisteredForTesting(SessionID("s-a")), "A isn't registered at joinSyncRequested")
                try expect(await !run.adapter.joinFlippedForTesting(attemptA1), "A1 flipped before its sync request")
            },
            .arm(.keeper(.leave)),
            .release(.adapter(.joinSyncRequested)),
            .reach(.keeper(.leave)),
            .check("flipped before the leave, OnLeave not run") { run in
                try expect(await run.adapter.joinFlippedForTesting(attemptA1), "A1 didn't flip before its leave")
                try expect(await run.keeper.currentState().players.contains("pa"), "OnLeave ran before the pre-leave checkpoint")
            },
            .release(.keeper(.leave)),
            .awaitJoin("A"),
            .settleDisconnects,
            .liveCheckpoint,
            .disconnect("B"),
        ],
        outcomes: ["join-B": .reply, "join-A": .none],
        lifecycle: ["pb": [.join, .leave], "pa": [.join, .leave]]
    ),    // A stale action reply after a leave: A's answer is held across A2's join and A2's own
    // pending action. A's request gets nothing on A or A2; A2 gets its reply.
    DiffScenario(
        name: "stale-action-reply",
        cells: .all,
        steps: [
            .connect("A", session: "s-a"),
            .join("A", player: "pa"),
            .arm(.adapter(.actionResponse), arrival: 1),
            .held("A", requestID: "held-a", key: 1),
            .disconnect("A"),
            .reach(.adapter(.actionResponse)),
            // A fresh SessionID, as the server mints one per connection: a router join on a
            // SessionID whose disconnect ran is refused as stale (`endedSessions`), so the
            // same-session reconnect stays with `staleAnswerAfterReconnect`.
            .connect("A2", session: "s-a2"),
            .join("A2", player: "pa"),
            .held("A2", requestID: "held-a2", key: 2),
            .release(.adapter(.actionResponse)),
            // A's job was rejected at the leave; its resolver's end only releases it. The jobs
            // wait counts every job, so both gates open before the one settle.
            .openGate(2),
            .openGate(1),
            .settleJobs,
            .liveCheckpoint,
            .disconnect("A2"),
        ],
        outcomes: ["join-A": .reply, "held-a": .none, "join-A2": .reply, "held-a2": .reply],
        lifecycle: ["pa": [.join, .leave, .join, .leave]]
    ),
]
#endif
