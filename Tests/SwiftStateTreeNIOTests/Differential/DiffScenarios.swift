// Tests/SwiftStateTreeNIOTests/Differential/DiffScenarios.swift
//
// The first scenario set (#555, plan §8).

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
            .tick,
        ],
        outcomes: ["join-A": .reply, "bump-1": .reply],
        lifecycle: ["p1": [.join, .leave]]
    ),
]
#endif
