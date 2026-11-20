// The follow-up benches (#702): arming and joining, and one `.afterBatch` follow-up armed and
// run. On a machine of their own, so `BenchMachine` keeps the default of no follow-ups and the
// existing benches measure what a machine without follow-ups pays.

import SwiftStateTurns

@PlainData
struct FollowUpBenchMachine: TurnMachine {
    enum Input: Sendable {
        case setup
        case arm
        case ran
    }

    enum FollowUpSlot: Hashable, Sendable {
        case only
    }

    typealias Effect = Never
    typealias Output = Never
    typealias Key = Int
    typealias Reply = Int

    var ran: Int

    mutating func handle(_ input: Input, _ turn: inout Turn<FollowUpBenchMachine>) {
        switch input {
        case .setup:
            turn.start(0)
        case .arm:
            turn.followUp(.ran, .only, of: 0, .afterBatch)
        case .ran:
            ran &+= 1
        }
    }
}

actor FollowUpBenchActor: TurnActor {
    let core = TurnCore(FollowUpBenchMachine(ran: 0), queueLimit: 1 << 20, maxReleasesPerBatch: 1 << 20, clock: BenchClock())

    @concurrent nonisolated func perform(_ effect: Never) async -> FollowUpBenchMachine.Input? {}

    func flush(_ outputs: consuming [Never]) {}

    func setUp() { send(.setup) }

    /// `follow-up-join`: `n` arms in one actor job. The first arms; the rest join it. The one
    /// follow-up runs in the next job, outside the measured loop's cost per operation.
    func armMany(_ n: Int) -> Int {
        for _ in 0 ..< n { send(.arm) }
        return core.read { $0.ran }
    }

    /// `follow-up`: one arm, then the wait until its job has stepped it.
    func armAndRun() async -> Int {
        send(.arm)
        await waitForQuiescence()
        return core.read { $0.ran }
    }
}

/// The same by hand: a pending flag, and a `Task` hop that runs the work once.
actor DirectFollowUpActor {
    var pending = false
    var ran = 0

    func armMany(_ n: Int) -> Int {
        for _ in 0 ..< n where !pending { pending = true }
        pending = false
        return ran
    }

    func armAndRun() async -> Int {
        if !pending {
            pending = true
            await Task { await self.runPending() }.value
        }
        return ran
    }

    func runPending() {
        guard pending else { return }
        pending = false
        ran &+= 1
    }
}
