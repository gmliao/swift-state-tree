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
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

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
            // A2's join supersedes A: A's queued frames reach it before its close.
            .flushOutbound,
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
              joinReplyIn: { $0.land == .tickless ? .reply : nil }, admitted: true),
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
            .arm(.keeper(.leave)),
            .release(.keeper(.join)),
            // The leave runs once the join returns. The join's sync-only turn queued B's update:
            // the writer hands it off first, or the leave's sync (tickless in-turn) would find it
            // and defer for back-pressure into a sync-only turn (#676).
            .reach(.keeper(.leave)),
            .flushOutbound,
            .release(.keeper(.leave)),
            // The leave's turn goes before the next step's sync cycle (#676); on a tick land the
            // leave is only queued, for the next tick.
            .awaitDisconnectForwards,
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
        cells: .all,
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
            // The writer hands off what A's flip queued before the leave's in-turn sync (#676).
            .flushOutbound,
            .release(.keeper(.leave)),
            // The rest of the leave goes before the next step's sync cycle (#676).
            .awaitDisconnectForwards,
            .awaitJoin("A"),
            .settleDisconnects,
            .liveCheckpoint,
            .disconnect("B"),
        ],
        outcomes: ["join-B": .reply, "join-A": .none],
        lifecycle: ["pb": [.join, .leave], "pa": [.join, .leave]]
    ),    // A stale action reply after a leave: A's answer is held across A2's join and A2's own
    // pending action. A's request gets nothing on A or A2; A2 gets its reply.
    // An answer and the runner's sync aren't ordered by anything with the loops off (nor, in
    // production, by anything but timing: #658), so the row pins each order as its own row.
    staleActionReplyRow("stale-action-reply", answerFirst: true),
    staleActionReplyRow("stale-action-reply-diff-first", answerFirst: false),
    // #548: a teardown while the keeper's join holds. The ticket is issued at admission, after
    // the hold, so on main A's admission after the teardown yields a current ticket: the bug,
    // which the golden records. The branch's outcome is the #548 expected difference.
    DiffScenario(
        name: "teardown-during-keeper-join",
        cells: .all,
        steps: witnessJoins + [
            .connect("A", session: "s-a"),
            .arm(.keeper(.join)),
            .startJoin("A", player: "pa"),
            .reach(.keeper(.join)),
            .check("the teardown ran") { run in
                await run.adapter.endSessionTicketsForTeardown()
                try expect(await run.adapter.teardownTicketEnds == 1, "teardownTicketEnds isn't 1")
            },
            .arm(.router(.afterAdmit)),
            .release(.keeper(.join)),
            .reach(.router(.afterAdmit)),
            // Recorded, not asserted: on main it is true (#548), and the branch's fix makes it
            // false, which its #548 expected difference names. A check would fail the run there.
            .note("A has a current ticket after the teardown") { run in
                var current = false
                if let ticket = await run.adapter.sessionTicketForTesting(SessionID("s-a")) {
                    current = await run.adapter.ticketIsCurrentForTesting(ticket)
                }
                return .bool(current)
            },
            .release(.router(.afterAdmit)),
            .awaitJoin("A"),
            .connect("A2", session: "s-a2"),
            .flushOutbound,
            .join("A2", player: "pa"),
            .bump("A2", requestID: "bump-a2", amount: 1),
            .liveCheckpoint,
            .disconnect("A2"),
            .disconnect("B"),
        ],
        // join-A is recorded, not judged: on main A is admitted after the teardown (#548), and
        // the branch's fix refuses it; its frames carry the answer either way.
        // So is pa's lifecycle: [join, leave, join, leave] on main, A's and A2's; the fix
        // drops A's pair.
        outcomes: ["join-B": .reply, "join-A": .recorded(issue: "#548"), "join-A2": .reply, "bump-a2": .reply],
        lifecycle: ["pb": [.join, .leave]],
        recordedLifecycle: ["pa": "#548"]
    ),
    // In-turn: a phase the writer's backlog defers completes a ready join through the
    // writer-drain retry (#546 L2a), and only through it. B's join is made ready and held at
    // `joinSyncRequested`, before its own sync request; on a tick land the tick that applies
    // B's OnJoin is stepped while B is held at keeperJoinReturned, on a tickless one the drain
    // is awaited. The writer is held (the back-pressure override, which the retry's drain wait
    // also waits on); the sync's phase defers. The harness's own waits would wait for the held
    // retry, so B's frames are awaited on its connection, with its own request still held.
    // Mutant: drop the writer-drain retry's turn; B's frames never come.
    DiffScenario(
        name: "join-during-writer-backlog",
        cells: .all,
        steps: [
            .connect("A", session: "s-a"),
            .join("A", player: "pa"),
            .flushOutbound,
            .bumpUnsynced("A", requestID: "bump-a", amount: 1),
            .connect("B", session: "s-b"),
            .arm(.adapter(.keeperJoinReturned)),
            .arm(.adapter(.joinSyncRequested)),
            .startJoin("B", player: "pb"),
            .reach(.adapter(.keeperJoinReturned)),
            .tickUnsynced,
            .check("B's OnJoin drain is idle") { run in await run.keeper.waitForInputDrainIdleForTesting() },
            .release(.adapter(.keeperJoinReturned)),
            .reach(.adapter(.joinSyncRequested)),
            .check("hold the writer") { run in
                await run.adapter.setWriterBackPressureOverrideForTesting { true }
            },
            .check("the sync's phase defers") { run in
                let backlog = await run.adapter.syncSkipCounts().outboundBacklog
                let outcome = await run.adapter.syncNowReportingOutcome()
                try expect(outcome == .deferredBackPressure, "the phase's outcome is \(outcome)")
                let after = await run.adapter.syncSkipCounts().outboundBacklog
                try expect(after == backlog + 1, "the backlog skips went from \(backlog) to \(after)")
                let frames = await (try run.attempt("B")).connection.messages
                let responses = frames.filter { if case .joinResponse = $0.payload { true } else { false } }
                try expect(responses.isEmpty, "B has a JoinResponse while the writer is held")
            },
            .check("release the writer: the retry flips B") { run in
                await run.adapter.setWriterBackPressureOverrideForTesting(nil)
                let connection = try run.attempt("B").connection
                let joined = await connection.waitUntilFrames { messages in
                    messages.contains { if case .joinResponse = $0.payload { true } else { false } }
                }
                try expect(joined, "B got no JoinResponse after the writer drained")
                // The JoinResponse and the firstSync go out in the same phase, which flips B. The
                // text check reads JSON frames only.
                await run.router.waitForNoPendingFlipForTesting()
                if run.cell.encoding == .json {
                    try expect(await connection.waitForFirstSync(), "B got no firstSync after the writer drained")
                }
            },
            .release(.adapter(.joinSyncRequested)),
            .awaitJoin("B"),
            .liveCheckpoint,
            .check("one JoinResponse and one firstSync for B") { run in
                let connection = try run.attempt("B").connection
                let messages = await connection.messages
                let responses = messages.filter { if case .joinResponse = $0.payload { true } else { false } }.count
                try expect(responses == 1, "B has \(responses) JoinResponse(s)")
                // The text check reads JSON frames only; the goldens hold every cell's frames.
                if run.cell.encoding == .json {
                    let firstSyncs = await connection.frames.filter {
                        String(decoding: $0, as: UTF8.self).contains("\"firstSync\"")
                    }.count
                    try expect(firstSyncs == 1, "B has \(firstSyncs) firstSync(s)")
                }
            },
            .disconnect("B"),
            .disconnect("A"),
        ],
        outcomes: ["join-A": .reply, "join-B": .reply, "bump-a": .reply],
        lifecycle: ["pa": [.join, .leave], "pb": [.join, .leave]]
    ),
    // A land stop with players connected: the stop's per-session tasks are held at
    // `stopLeave`, before their leaves queue; A's is released first, so B's leave queues behind
    // A's. The stop is then held after its sessions' leaves were submitted and before the
    // keeper's shutdown, where a tick land steps the tick that applies them (the shutdown
    // drops a tick land's queued leaves, #512), so OnLeave runs A, then B.
    DiffScenario(
        name: "land-stop",
        cells: .all,
        steps: [
            .connect("A", session: "s-a"),
            .join("A", player: "pa"),
            .connect("B", session: "s-b"),
            .join("B", player: "pb"),
            .bump("B", requestID: "bump-b", amount: 1),
            .liveCheckpoint,
            .arm(.router(.stopLeave(SessionID("s-a")))),
            .arm(.router(.stopLeave(SessionID("s-b")))),
            .observe(.adapter(.membershipQueued)),
            .arm(.stopSessionsClosed),
            .startStop,
            .reach(.router(.stopLeave(SessionID("s-a")))),
            .reach(.router(.stopLeave(SessionID("s-b")))),
            .check("neither leave is queued") { run in
                let queued = run.holds.gate(.adapter(.membershipQueued))?.arrivalCount ?? -1
                try expect(queued == 0, "\(queued) membership operation(s) queued before the releases")
            },
            .release(.router(.stopLeave(SessionID("s-a")))),
            .reach(.adapter(.membershipQueued)),
            .release(.router(.stopLeave(SessionID("s-b")))),
            .reach(.adapter(.membershipQueued), count: 2),
            .reach(.stopSessionsClosed),
            .tick,
            .release(.stopSessionsClosed),
            .awaitStop,
        ],
        outcomes: ["join-A": .reply, "join-B": .reply, "bump-b": .reply],
        lifecycle: ["pa": [.join, .leave], "pb": [.join, .leave]]
    ),
]

/// A's held action is answered after A disconnected and A2 (a fresh SessionID, #652) joined
/// as the same player: the stale answer reaches nobody. A2's own held action then ends with its
/// answer either before the sync that carries its state change (`answerFirst`) or after it,
/// with A2's answer held across that sync.
private func staleActionReplyRow(_ name: String, answerFirst: Bool) -> DiffScenario {
    let settle: [DiffStep] = answerFirst
        ? [.settleJobs]
        : [.settleJobsBeforeAnswers(heldAt: .adapter(.actionResponse)), .release(.adapter(.actionResponse))]
    // Armed again once A's answer is released (A's task already waits at the old gate). The
    // hook counts arrivals at the point from the start, so A2's answer is arrival 2.
    let holdA2: [DiffStep] = answerFirst ? [] : [.arm(.adapter(.actionResponse), arrival: 2)]
    return DiffScenario(
        name: name,
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
        ] + holdA2 + [
            // A's job was rejected at the leave; its resolver's end only releases it. The jobs
            // wait counts every job, so both gates open before the one settle.
            .openGate(2),
            .openGate(1),
        ] + settle + [
            .liveCheckpoint,
            .disconnect("A2"),
        ],
        outcomes: ["join-A": .reply, "held-a": .none, "join-A2": .reply, "held-a2": .reply],
        lifecycle: ["pa": [.join, .leave, .join, .leave]]
    )
}
#endif
