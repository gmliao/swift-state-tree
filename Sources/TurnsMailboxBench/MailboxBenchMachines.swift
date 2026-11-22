// The two machines of TurnsMailboxBench: one that takes mail, and the same machine with
// `Mail == Never`.

import Foundation
import SwiftStateTurns

@PlainData
struct MailBenchMachine: TurnMachine {
    enum Input: Sendable {
        case setup
        case emit
        case callNoop
    }

    typealias Effect = Never
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias Mail = Int

    var counter: Int

    mutating func handle(_ input: Input, _ turn: inout Turn<MailBenchMachine>) {
        switch input {
        case .setup:
            turn.start(0)
        case .emit:
            turn.emit(counter, for: 0)
        case .callNoop:
            if let caller = turn.input { turn.reply(to: caller, .success(counter)) }
        }
    }

    mutating func handleMail(_ mail: Int, _ turn: inout MailTurn<MailBenchMachine>) {
        counter &+= mail
    }
}

actor MailBenchActor: TurnActor {
    let core: TurnCore<MailBenchMachine>
    nonisolated let mailbox: TurnMailbox<Int>?
    var flushed = 0

    init() {
        let core = TurnCore(MailBenchMachine(counter: 0), queueLimit: 1 << 20, maxReleasesPerBatch: 1 << 20, clock: MailboxBenchClock())
        self.core = core
        self.mailbox = core.mailbox
    }

    @concurrent nonisolated func perform(_ effect: Never) async -> MailBenchMachine.Input? {}

    func flush(_ outputs: consuming [Int]) {
        flushed &+= outputs.count
    }

    func setUp() { send(.setup) }

    /// `mail-emit`: `n` emits inside one actor job, the mailbox empty.
    func emitMany(_ n: Int) -> Int {
        for _ in 0 ..< n { send(.emit) }
        return flushed
    }
}

/// `MailBenchMachine` without mail: the mailbox-off side.
@PlainData
struct MailboxOffBenchMachine: TurnMachine {
    typealias Input = MailBenchMachine.Input
    typealias Effect = Never
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int

    var counter: Int

    mutating func handle(_ input: Input, _ turn: inout Turn<MailboxOffBenchMachine>) {
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

actor MailboxOffBenchActor: TurnActor {
    let core = TurnCore(MailboxOffBenchMachine(counter: 0), queueLimit: 1 << 20, maxReleasesPerBatch: 1 << 20, clock: MailboxBenchClock())
    var flushed = 0

    @concurrent nonisolated func perform(_ effect: Never) async -> MailboxOffBenchMachine.Input? {}

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
struct MailboxBenchClock: TurnClock {
    var now: TurnInstant { TurnInstant(ContinuousClock.now) }

    func sleep(until instant: TurnInstant) async {
        fatalError("TurnsMailboxBench: no machine here arms a timer or a deadline")
    }
}
