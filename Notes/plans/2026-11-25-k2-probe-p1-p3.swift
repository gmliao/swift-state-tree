// K2 plan probes P1-P3 (Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md, section 12).
// Typecheck against the built SwiftStateTurns and SwiftStateTree modules, from the repository root:
//   swift build
//   swiftc -typecheck -swift-version 6 -I .build/debug -package-name SwiftStateTree \
//       Notes/plans/2026-11-25-k2-probe-p1-p3.swift; echo "exit=$?"     # expect exit=0
// P1's negative case: change `where State: PlainData` below to `where State: Hashable`; expect
//   exit=1 and "type 'ProbeLive<State>' does not conform to protocol 'TurnActor'".
// P1: a generic keeper model whose PlainData conformance is conditional on State satisfies
//     TurnActor's `M: TurnMachine & PlainData` inside a generic actor, with
//     Behavior = a generic behavior struct, and TurnCore.init(machine:behavior:...) accepts it.
// P2: a facade actor adopts the live actor's executor and forwards with `live.assumeIsolated`.
// P3: `nonisolated(unsafe) weak var` holds the facade identity on the live actor.
import SwiftStateTurns
import SwiftStateTree

struct ProbeModel<State: StateNodeProtocol> { var state: State; var count = 0 }
extension ProbeModel: PlainData where State: PlainData { static func _plainDataCheck() {} }
struct ProbeBehavior<State: StateNodeProtocol>: Sendable { let limit: Int }

extension ProbeModel: TurnMachine {
    typealias Input = Int
    typealias Effect = Int
    typealias Output = Int
    typealias Key = Int
    typealias Reply = Int
    typealias Behavior = ProbeBehavior<State>
    mutating func handle(_ input: Int, _ turn: inout Turn<Self>) { count += input }
}

struct ProbeClock: TurnClock {
    var now: TurnInstant { fatalError("not called") }
    func sleep(until instant: TurnInstant) async {}
}

actor ProbeLive<State: StateNodeProtocol>: TurnActor {
    typealias M = ProbeModel<State>
    let core: TurnCore<ProbeModel<State>>
    nonisolated(unsafe) weak var facade: AnyObject?          // P3
    init(state: State) {
        core = TurnCore(machine: ProbeModel(state: state), behavior: ProbeBehavior(limit: 8),
                        queueLimit: 8, maxReleasesPerBatch: 1, clock: ProbeClock())
    }
    @concurrent nonisolated func perform(_ effect: Int) async -> Int? { nil }
    func flush(_ outputs: consuming [Int]) {}
    func liveOnly() -> Int { 1 }
}

actor ProbeFacade<State: StateNodeProtocol> {                 // P2
    let live: ProbeLive<State>
    nonisolated var unownedExecutor: UnownedSerialExecutor { live.unownedExecutor }
    init(live: ProbeLive<State>) { self.live = live }
    func forward() -> Int { live.assumeIsolated { $0.liveOnly() } }
}
