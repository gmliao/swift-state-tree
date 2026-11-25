// K2 plan probes P2 (run) and P4 (Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md,
// section 12): self-contained, no package import. Run it on Linux: `trap` mode crashes on purpose
// (an exclusivity trap), which opens a crash dialog on macOS.
//
// P2 (run): a facade actor that returns the live actor's `unownedExecutor` can forward with
//     `live.assumeIsolated` from its own isolated method without trapping.
// P4: the model is a stored property of the live actor. A step takes `&model` for its whole
//     body (the `withHandlerStep` shape). A handler that reaches back into the keeper
//     synchronously (through the facade and `assumeIsolated`) reads `model` during that access,
//     and the run-time exclusivity check traps, in -Onone and in -O.
//
// Build and run (Linux, Swift 6.4.3):
//   swiftc -swift-version 6 -Onone 2026-11-25-k2-probe-p2-p4.swift -o p-debug
//   swiftc -swift-version 6 -O     2026-11-25-k2-probe-p2-p4.swift -o p-release
//   ./p-debug control; echo "exit=$?"     # expect: "P2 forward: 3", "step done: state=1", exit=0
//   ./p-release control; echo "exit=$?"   # same
//   ./p-debug trap; echo "exit=$?"        # expect a trap, stderr containing
//       "Simultaneous accesses to 0x", "but modification requires exclusive access",
//       "Previous access (a modification) started at", "Current access (a read) started at";
//       exit=132 or 134 (SIGILL/SIGABRT), no "step done" line
//   ./p-release trap; echo "exit=$?"      # same trap text, non-zero exit (SE-0176: actor and
//                                          # class storage is checked at run time in -O too)

struct Model {
    var state = 0
    var players = [1, 2, 3]
}

actor Live {
    var model = Model()
    nonisolated(unsafe) weak var facade: Facade?

    func setFacade(_ f: Facade) { facade = f }
    func playerCount() -> Int { model.players.count }
    func currentState() -> Int { model.state }

    /// One inout access of the model for the whole step, as K1b-4's `withHandlerStep`.
    private func withStep(_ body: (inout Model) -> Void) { body(&model) }

    func step(reenter: Bool) {
        let facade = self.facade
        withStep { m in
            m.state += 1
            if reenter, let facade {
                // The handler calls back into its keeper synchronously: a read of `model`
                // while `&model` is held.
                m.state += facade.syncPlayerCount()
            }
        }
    }
}

actor Facade {
    let live: Live
    nonisolated var unownedExecutor: UnownedSerialExecutor { live.unownedExecutor }
    init(live: Live) { self.live = live }
    func forward() -> Int { live.assumeIsolated { $0.playerCount() } }
    nonisolated func syncPlayerCount() -> Int { live.assumeIsolated { $0.playerCount() } }
}

let mode = CommandLine.arguments.dropFirst().first ?? "control"
let live = Live()
let facade = Facade(live: live)
await live.setFacade(facade)
print("P2 forward: \(await facade.forward())")
await live.step(reenter: mode == "trap")
print("step done: state=\(await live.currentState())")
