// `TurnInstant`'s arithmetic saturates at `Int64`'s range instead of wrapping (#791): a deadline
// meant as "never" stays at the far end instead of wrapping into the past, and a difference's
// sign always agrees with the instants' order.

import SwiftStateTree
@testable import SwiftStateTurns
import Testing

/// A machine that arms one timer at `now + duration` and logs when it fires.
@PlainData
struct FarTimerMachine: TurnMachine {
    enum Input: Sendable {
        case arm(seconds: Int64)
        case fired
    }

    enum Effect: Sendable {}

    enum Key: Hashable, Sendable {
        case timer
    }

    typealias Query = Void
    typealias Output = String
    typealias Reply = Int
    typealias Answer = Int

    var fired: Int = 0

    func inputPolicy(for input: Input) -> InputPolicy<Key> { .control }

    mutating func handle(_ input: Input, _ turn: inout Turn<FarTimerMachine>) {
        switch input {
        case .arm(let seconds):
            turn.start(.timer)
            turn.timer(at: turn.now + .seconds(seconds), for: .timer, .fired)
        case .fired:
            fired += 1
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<FarTimerMachine>) {}

    mutating func answer(_ query: Void, _ turn: inout Turn<FarTimerMachine>) -> Int { fired }
}

actor FarTimerActor: TurnActor {
    let core: TurnCore<FarTimerMachine>
    nonisolated let clock: TestClock

    init(fixture: Fixture) {
        let clock = TestClock(fixture: fixture)
        self.clock = clock
        core = TurnCore(FarTimerMachine(), queueLimit: 16, maxReleasesPerBatch: 4, clock: clock)
    }

    @concurrent nonisolated func perform(_ effect: FarTimerMachine.Effect) async -> FarTimerMachine.Input? {}

    func flush(_ outputs: consuming [String]) {}

    var sleeperTarget: TurnInstant? { core.sleeperTargetForTesting }
}

@Suite("TurnInstant arithmetic saturates instead of wrapping (#791)", .timeLimit(.minutes(1)))
struct TurnInstantSaturationTests {
    @Test("An instant plus a duration that overflows Int64 nanoseconds stays at the range's end")
    func plusSaturates() {
        #expect(TurnInstant(nanoseconds: .max - 1) + .nanoseconds(2) == TurnInstant(nanoseconds: .max))
        #expect(TurnInstant(nanoseconds: 1) + .seconds(Int64.max) == TurnInstant(nanoseconds: .max))
        // A negative instant plus a duration past Int64's range: the exact sum is past `.max`.
        #expect(TurnInstant(nanoseconds: -5) + (.seconds(Int64.max) + .seconds(1)) == TurnInstant(nanoseconds: .max))
        // A negative instant plus a duration just past Int64 nanoseconds: the exact sum is in
        // range, below `.max` (saturating the duration first would land 5 ns high).
        #expect(TurnInstant(nanoseconds: -5) + (.nanoseconds(Int64.max) + .nanoseconds(1)) == TurnInstant(nanoseconds: .max - 4))
    }

    @Test("An instant plus a negative duration that underflows stays at the range's start")
    func plusNegativeSaturates() {
        #expect(TurnInstant(nanoseconds: .min + 1) + .nanoseconds(-2) == TurnInstant(nanoseconds: .min))
        #expect(TurnInstant(nanoseconds: -5) + (.seconds(Int64.min) - .seconds(1)) == TurnInstant(nanoseconds: .min))
        #expect(TurnInstant(nanoseconds: -1) + .seconds(Int64.min) == TurnInstant(nanoseconds: .min))
    }

    @Test("In range, the arithmetic is exact: whole nanoseconds, truncated toward zero")
    func inRangeIsExact() {
        #expect(TurnInstant(nanoseconds: 10) + .nanoseconds(-3) == TurnInstant(nanoseconds: 7))
        #expect(TurnInstant(nanoseconds: -3) - TurnInstant(nanoseconds: 4) == .nanoseconds(-7))
        #expect(TurnInstant(nanoseconds: .max) - TurnInstant(nanoseconds: .max) == .zero)
        #expect(TurnInstant(nanoseconds: 10) + (.nanoseconds(1) / 2) == TurnInstant(nanoseconds: 10))
    }

    @Test("A difference that overflows Int64 nanoseconds saturates, so its sign agrees with the order")
    func minusSaturates() {
        #expect(TurnInstant(nanoseconds: .max) - TurnInstant(nanoseconds: .min) == .nanoseconds(Int64.max))
        #expect(TurnInstant(nanoseconds: .min) - TurnInstant(nanoseconds: .max) == .nanoseconds(Int64.min))
        #expect(TurnInstant(nanoseconds: .max) - TurnInstant(nanoseconds: -1) == .nanoseconds(Int64.max))
    }

    @Test("A timer armed at now plus a duration past the range stays armed at the range's end and never fires")
    func farTimerNeverFires() async throws {
        try await withinTestHangBound {
            let a = FarTimerActor(fixture: Fixture())
            // A positive `now`: before #791, `now + .seconds(.max)` wrapped into the past.
            a.clock.advance(to: 1)
            await a.send(.arm(seconds: Int64.max))
            #expect(await a.waitForQuiescence())
            #expect(await a.sleeperTarget == TurnInstant(nanoseconds: .max), "the core sleeps until the range's end")
            // An hour later the timer still hasn't fired.
            a.clock.advance(to: 3601)
            #expect(await a.waitForQuiescence())
            #expect(await a.query(()) == 0, "the far timer fired")
        }
    }
}
