// The machine the bench runs: one input per measured operation.

import SwiftStateTurns

@PlainData
struct BenchMachine: TurnMachine {
    enum Input: Sendable {
        case setup
        case noop
        case emit
        case issueEnd
        case now
        case takeHold
        case held
        case lookup
        case releaseHold
        /// A hold request kept with others (`park-64`): many deadlines live at once.
        case takeKept
        /// Cancels every kept request, in one step.
        case releaseKept
        case request
        case done
        case callNoop
    }

    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int

    var counter: Int
    var holding: RequestID?
    var kept: [RequestID]
    var ticks: Int64
    var table: [Int: Int]

    static func make() -> BenchMachine {
        BenchMachine(counter: 0, holding: nil, kept: [], ticks: 0, table: Dictionary(uniqueKeysWithValues: (0 ..< 64).map { ($0, $0) }))
    }

    func inputPolicy(for input: Input) -> InputPolicy<Int> {
        switch input {
        case .held: .normal(waitsFor: 1, belongsTo: nil)
        case .lookup: .normal(waitsFor: 2, belongsTo: nil)
        case .releaseHold, .releaseKept, .done: .control
        default: .normal(waitsFor: nil, belongsTo: nil)
        }
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<BenchMachine>) {
        switch input {
        case .setup:
            turn.start(0)
        case .noop, .held, .lookup, .done:
            counter &+= 1
        case .emit:
            turn.emit(counter, for: 0)
        case .issueEnd:
            turn.start(2)
            turn.end(2)
        case .now:
            ticks &+= turn.now.nanoseconds
        case .takeHold:
            holding = turn.request(0, for: 0, holding: .untilRequestCloses(1, deadline: .seconds(3600)))
        case .releaseHold:
            if let id = holding {
                turn.cancel(id)
                holding = nil
            }
        case .takeKept:
            if let id = turn.request(0, for: 0, holding: .untilRequestCloses(1, deadline: .seconds(3600))) { kept.append(id) }
        case .releaseKept:
            for id in kept { turn.cancel(id) }
            kept.removeAll(keepingCapacity: true)
        case .request:
            if let caller = turn.input {
                let id = turn.request(1, for: 0)
                turn.reply(to: caller, .success(counter), after: id)
            }
        case .callNoop:
            if let caller = turn.input { turn.reply(to: caller, .success(counter)) }
        }
    }
}
