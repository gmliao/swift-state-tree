import SwiftStateTurns
import Testing

/// The core's runtime stops. Each runs in a child process (an exit test), which must fail with
/// the core's message on its standard error. `fatalError` prints in release builds too.
@Suite("Turn core: runtime stops", .timeLimit(.minutes(1)))
struct RuntimeStopTests {
    static func standardError(_ result: ExitTest.Result?) -> String {
        guard let result else { return "" }
        return String(decoding: result.standardErrorContent, as: UTF8.self)
    }

    @Test("reading the machine from inside its own step stops the process")
    func readInsideStep() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.readFromInsideStep()
        }
        #expect(Self.standardError(result).contains("TurnCore: the machine was read from inside its own step"))
    }

    @Test("ask from inside a step stops the process")
    func askInsideStep() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.askFromInsideStep()
        }
        #expect(Self.standardError(result).contains("TurnCore: ask was called from inside a step"))
    }

    @Test("a class as the machine stops the process when the core is made")
    func classMachine() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = TurnCore(ClassMachine(), parkedLimit: 1, segmentBudget: 1, clock: TestClock(fixture: Fixture()))
        }
        #expect(Self.standardError(result).contains("TurnCore: the machine must be a value type"))
    }

    // "A step entered from inside a step" has no test here: every public entry that could
    // start one from inside a step either queues (`send`, `call`) or stops first with its own
    // message (`read`, `ask`), so the core's own guard in its step entry can't be reached from
    // outside the module.
}
