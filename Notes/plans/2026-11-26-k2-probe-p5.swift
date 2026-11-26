// Notes/plans/2026-11-26-k2-probe-p5.swift
//
// P5 (K2 draft 6, MF1): a re-entry through the facade during a core step is refused, with no
// crash, by a predicate the core owns; the running step sees the refusal after its port call
// returns and applies the failure to its own borrowed model.
//
// Self-contained: `ProbeCore` copies TurnCore's borrow rule (TurnCore.swift:115-129: 0 unused,
// -1 a step writing; a read inside a step stops) and adds the proposed package accessor
// `isStepping`. Two step drivers: a facade entry, and one the live actor starts itself (a
// timer, a deferred send), so the predicate can't be a facade-side counter.
//
// Run (Mac or Linux):  swiftc -swift-version 6 -parse-as-library -Onone p5.swift -o p5 && ./p5
//                      swiftc -swift-version 6 -parse-as-library -O     p5.swift -o p5o && ./p5o
// Expected, both builds: exit 0, and
//   control: accepted=1 violations=0 failed=false
//   facade step: refused=1 violations=1 failed=true gateCloses=1 borrows=0
//   core-driven step: refused=1 violations=2 failed=true gateCloses=2 borrows=0
//   done

struct ProbeModel { var accepted = 0; var failed = false }

/// The trip record: written by the refusing entry, read by the running step after a call out.
/// On the shared executor only, so plain fields (the keeper's #865 sentinel is the same shape).
final class ReentrySentinel: @unchecked Sendable {
    var violations = 0
    var closingGate = false
    var gateCloses = 0
}

final class ProbeCore: @unchecked Sendable {
    var machine = ProbeModel()
    var borrows = 0
    /// The proposed package accessor: a step is writing the machine.
    var isStepping: Bool { borrows < 0 }
    func step<R>(_ body: (inout ProbeModel) -> R) -> R {
        precondition(borrows == 0, "ProbeCore: a step inside a step or a read")
        borrows = -1
        defer { borrows = 0 }
        return body(&machine)
    }
}

/// A port whose synchronous call reaches back into the keeper through the facade.
final class CallbackPort: @unchecked Sendable {
    weak var facade: ProbeFacade?
    func runSyncPhase() {
        guard let facade else { return }
        facade.assumeIsolated { $0.submitSyncStream() }
    }
}

actor LiveLandTurns {
    let core = ProbeCore()
    let sentinel = ReentrySentinel()
    let port = CallbackPort()
    /// Installed once, at the end of the facade's init (draft 4 §3, P3).
    nonisolated(unsafe) weak var facade: ProbeFacade?

    /// A step: one call out, then the check `callOut` makes after the port returns.
    func stepWithCallOut() {
        core.step { m in
            let before = sentinel.violations
            port.runSyncPhase()
            if sentinel.violations != before {
                // The failure lands in the step's own borrowed model, never through the facade.
                m.failed = true
                return
            }
            m.accepted += 1
        }
    }

    /// A step the core starts itself (a timer), not through any facade entry.
    func coreDrivenStep() { stepWithCallOut() }

    func borrowsNow() -> Int { core.borrows }
    func readModel() -> ProbeModel { precondition(!core.isStepping); return core.machine }
}

actor ProbeFacade {
    let live: LiveLandTurns
    nonisolated var unownedExecutor: UnownedSerialExecutor { live.unownedExecutor }

    init(live: LiveLandTurns) {
        self.live = live
        live.facade = self
        live.port.facade = self
    }

    /// An adapter-facing entry: refused, changing nothing, while a core step writes the model.
    func submitSyncStream() {
        let refused = live.assumeIsolated { live -> Bool in
            guard live.core.isStepping else { return false }
            let s = live.sentinel
            s.violations += 1
            if !s.closingGate {
                s.closingGate = true
                defer { s.closingGate = false }
                s.gateCloses += 1 // the gate's close, direct, with the recursion guard
            }
            return true
        }
        if refused { Self.refusedCount += 1; return }
        live.assumeIsolated { $0.core.step { m in m.accepted += 1 } }
    }
    nonisolated(unsafe) static var refusedCount = 0

    func entryStep() { live.assumeIsolated { $0.stepWithCallOut() } }
}

@main struct P5 {
    static func main() async {
        // Control: the entry outside a step is accepted.
        let live0 = LiveLandTurns()
        let facade0 = ProbeFacade(live: live0)
        await facade0.submitSyncStream()
        let m0 = await live0.readModel()
        print("control: accepted=\(m0.accepted) violations=\(live0.sentinel.violations) failed=\(m0.failed)")

        // A step entered through the facade, whose port calls back through the facade.
        let live = LiveLandTurns()
        let facade = ProbeFacade(live: live)
        await facade.entryStep()
        var m = await live.readModel()
        let b1 = await live.borrowsNow()
        print("facade step: refused=\(ProbeFacade.refusedCount) violations=\(live.sentinel.violations) failed=\(m.failed) gateCloses=\(live.sentinel.gateCloses) borrows=\(b1)")

        // A step the live actor starts itself: the same refusal, from the core's predicate.
        ProbeFacade.refusedCount = 0
        await live.coreDrivenStep()
        m = await live.readModel()
        let b2 = await live.borrowsNow()
        print("core-driven step: refused=\(ProbeFacade.refusedCount) violations=\(live.sentinel.violations) failed=\(m.failed) gateCloses=\(live.sentinel.gateCloses) borrows=\(b2)")
        withExtendedLifetime((facade0, facade)) {}
        print("done")
    }
}
