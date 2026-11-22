// The two machines of TurnsLaneBench: one that takes lane reports, and the same machine with
// `LaneReport == Never`.

import Foundation
import SwiftStateTurns

@PlainData
struct ReportBenchMachine: TurnMachine {
    enum Input: Sendable {
        case setup
        case emit
        case callNoop
    }

    typealias Effect = Never
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias LaneReport = Int

    var counter: Int

    mutating func handle(_ input: Input, _ turn: inout Turn<ReportBenchMachine>) {
        switch input {
        case .setup:
            turn.start(0)
        case .emit:
            turn.emit(counter, for: 0)
        case .callNoop:
            if let caller = turn.input { turn.reply(to: caller, .success(counter)) }
        }
    }

    mutating func handleReport(_ report: Int, _ turn: inout ReportTurn<ReportBenchMachine>) {
        counter &+= report
    }
}

actor ReportBenchActor: TurnActor {
    let core: TurnCore<ReportBenchMachine>
    nonisolated let lane: TurnLane<Int>?
    var flushed = 0

    init() {
        let core = TurnCore(ReportBenchMachine(counter: 0), queueLimit: 1 << 20, maxReleasesPerBatch: 1 << 20, clock: LaneBenchClock())
        self.core = core
        self.lane = core.lane
    }

    @concurrent nonisolated func perform(_ effect: Never) async -> ReportBenchMachine.Input? {}

    func flush(_ outputs: consuming [Int]) {
        flushed &+= outputs.count
    }

    func setUp() { send(.setup) }

    /// `report-emit`: `n` emits inside one actor job, the lane empty.
    func emitMany(_ n: Int) -> Int {
        for _ in 0 ..< n { send(.emit) }
        return flushed
    }
}

/// `ReportBenchMachine` without reports: the lane-off side.
@PlainData
struct LaneOffBenchMachine: TurnMachine {
    typealias Input = ReportBenchMachine.Input
    typealias Effect = Never
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int

    var counter: Int

    mutating func handle(_ input: Input, _ turn: inout Turn<LaneOffBenchMachine>) {
        switch input {
        case .setup:
            turn.start(0)
        case .emit:
            turn.emit(counter, for: 0)
        case .callNoop:
            if let caller = turn.input { turn.reply(to: caller, .success(counter)) }
        }
    }
}

actor LaneOffBenchActor: TurnActor {
    let core = TurnCore(LaneOffBenchMachine(counter: 0), queueLimit: 1 << 20, maxReleasesPerBatch: 1 << 20, clock: LaneBenchClock())
    var flushed = 0

    @concurrent nonisolated func perform(_ effect: Never) async -> LaneOffBenchMachine.Input? {}

    func flush(_ outputs: consuming [Int]) {
        flushed &+= outputs.count
    }

    func setUp() { send(.setup) }

    func emitMany(_ n: Int) -> Int {
        for _ in 0 ..< n { send(.emit) }
        return flushed
    }
}

/// The bench's clock. Neither machine arms a timer or a deadline, so the core never sleeps on it.
struct LaneBenchClock: TurnClock {
    var now: TurnInstant { TurnInstant(ContinuousClock.now) }

    func sleep(until instant: TurnInstant) async {
        fatalError("TurnsLaneBench: no machine here arms a timer or a deadline")
    }
}
