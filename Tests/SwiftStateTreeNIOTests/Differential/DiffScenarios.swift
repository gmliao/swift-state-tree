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
]
#endif
