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
]
#endif
