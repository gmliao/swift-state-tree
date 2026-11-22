// expect: compiles
import SwiftStateTurns

// The control for report-arms-after-batch: a report's handler arms an `afterWork` follow-up,
// runs an effect and emits, through its ReportTurn.
enum Slot: Hashable, Sendable { case next }

@PlainData
struct Mach: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias FollowUpSlot = Slot
    typealias LaneReport = Int
    var seen: Int
    mutating func handle(_ input: Int, _ turn: inout Turn<Mach>) {}
    mutating func handleReport(_ report: Int, _ turn: inout ReportTurn<Mach>) {
        seen = report
        turn.followUp(report, .next, of: 1, afterWork: report, deadline: .seconds(5))
        turn.run(report)
        turn.emit(report, for: 1)
    }
}

actor MachActor: TurnActor {
    let core: TurnCore<Mach>
    nonisolated let lane: TurnLane<Int>?
    init() {
        let core = snippetCore(Mach(seen: 0))
        self.core = core
        self.lane = core.lane
    }
    @concurrent nonisolated func perform(_ effect: Int) async -> Int? { effect }
    func flush(_ outputs: consuming [Int]) {}
}
