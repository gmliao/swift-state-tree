// Shared by every snippet in this directory (`scripts/check-must-not-compile.sh`).
import SwiftStateTurns

struct SnippetClock: TurnClock {
    var now: TurnInstant { TurnInstant(nanoseconds: 0) }
    func sleep(until instant: TurnInstant) async {}
}

func snippetCore<M: TurnMachine & PlainData>(_ machine: M) -> TurnCore<M> where M.Behavior == Void {
    TurnCore(machine, queueLimit: 8, maxReleasesPerBatch: 8, clock: SnippetClock())
}

final class Collaborator: Sendable {
    func callOut() {}
}

actor Peer {}
