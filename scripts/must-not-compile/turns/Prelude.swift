// Shared by every snippet in this directory (`scripts/check-must-not-compile.sh`).
import SwiftStateTurns

struct SnippetClock: TurnClock {
    var now: TurnInstant { TurnInstant(nanoseconds: 0) }
    func sleep(until instant: TurnInstant) async {}
}

func snippetCore<M: TurnMachine>(_ machine: M) -> TurnCore<M> {
    TurnCore(machine, parkedLimit: 8, segmentBudget: 8, clock: SnippetClock())
}

final class Collaborator: Sendable {
    func callOut() {}
}

actor Peer {}
