// expect: compiles
import SwiftStateTurns

// The control: a plain machine, a holding request with its deadline, and an actor.
@PlainData
struct Counter: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    var total: Int
    var seen: [Int: String]
    var pending: Set<RequestID>

    mutating func handle(_ input: Int, _ turn: inout Turn<Counter>) {
        total += input
        turn.issue(1)
        if let id = turn.request(input, for: 1, holding: .untilRequestCloses(1, deadline: .seconds(5))) {
            pending.insert(id)
        }
        turn.emit(total, for: 1)
    }
}

actor CounterActor: TurnActor {
    let core = snippetCore(Counter(total: 0, seen: [:], pending: []))
    @concurrent nonisolated func perform(_ effect: Int) async -> Int? { effect }
    func flush(_ outputs: consuming [Int]) {}
}
