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

    /// The core's own stop, never the runtime's exclusivity check: release builds don't have
    /// that check on the core's state, so the core's message is what must stop each overlap.
    static func expectCoreStop(_ result: ExitTest.Result?, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = standardError(result)
        #expect(text.contains(message), sourceLocation: sourceLocation)
        #expect(!text.contains("Simultaneous accesses"), sourceLocation: sourceLocation)
    }

    @Test("reading the machine from inside its own step stops the process")
    func readInsideStep() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.readFromInsideStep()
        }
        Self.expectCoreStop(result, "TurnCore: the machine was read from inside its own step")
    }

    @Test("a step entered from inside read stops the process")
    func stepInsideRead() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.sendFromInsideRead()
        }
        Self.expectCoreStop(result, "TurnCore: a step was entered while a read is open")
    }

    @Test("a step entered from an outer read's body after a nested read returned stops the process")
    func stepInsideOuterReadAfterNestedRead() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.sendFromOuterReadAfterNestedRead()
        }
        Self.expectCoreStop(result, "TurnCore: a step was entered while a read is open")
    }

    @Test("query from inside read stops the process")
    func queryInsideRead() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.queryFromInsideRead()
        }
        Self.expectCoreStop(result, "TurnCore: a step was entered while a read is open")
    }

    @Test("query from an outer read's body after a nested read returned stops the process")
    func queryInsideOuterReadAfterNestedRead() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.queryFromOuterReadAfterNestedRead()
        }
        Self.expectCoreStop(result, "TurnCore: a step was entered while a read is open")
    }

    @Test("query from inside a nested read stops the process")
    func queryInsideNestedRead() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.queryFromNestedRead()
        }
        Self.expectCoreStop(result, "TurnCore: a step was entered while a read is open")
    }

    /// The cells that don't stop leave the borrow state at 0. (A step can't be entered directly
    /// from inside a step through the API: a `send` there is deferred, as this checks, and a
    /// `query` there stops, above.)
    @Test("the borrow state is back to 0 after nested reads, a step, a query and a send made inside a step")
    func borrowStateReturnsToZero() async {
        let demo = DemoActor()
        #expect(await demo.borrowState == 0)
        #expect(await demo.nestedReads() == 2)
        #expect(await demo.borrowState == 0)
        await demo.send(.ping)
        #expect(await demo.borrowState == 0)
        _ = await demo.query(.steps)
        #expect(await demo.borrowState == 0)
        await demo.sendFromInsideStep()
        #expect(await demo.borrowState == 0)
        #expect(await demo.snapshot().log.suffix(3) == ["hook start", "hook end", "queued"])
    }

    @Test("query from inside a step stops the process")
    func askInsideStep() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.askFromInsideStep()
        }
        Self.expectCoreStop(result, "TurnCore: query was called from inside a step")
    }

    @Test("a class as the machine stops the process when the core is made")
    func classMachine() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            _ = TurnCore(ClassMachine(), queueLimit: 1, maxReleasesPerBatch: 1, clock: TestClock(fixture: Fixture()))
        }
        Self.expectCoreStop(result, "TurnCore: the machine must be a value type")
    }

    // "A step entered from inside a step" has no test here: every public entry that could
    // start one from inside a step either queues (`send`, `sendAndWait`) or stops first with its own
    // message (`read`, `query`), so the core's own guard in its step entry can't be reached from
    // outside the module.
}
