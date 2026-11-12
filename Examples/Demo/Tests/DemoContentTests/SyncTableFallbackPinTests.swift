import Testing
@_spi(Diagnostics) import SwiftStateTree
@testable import DemoContent

/// Each Demo land's fields on the typed sync tables, which are the default: a field that starts
/// taking the snapshot fallback breaks its pin, so it shows up in review. Nothing is on them
/// today.
@Suite("Demo lands' sync table fallback lists")
struct SyncTableFallbackPinTests {
    @Test("The cookie game")
    func cookie() {
        expectNoFallback(CookieGameState.self)
    }

    @Test("The counter")
    func counter() {
        expectNoFallback(CounterState.self)
    }

    @Test("The deterministic math demo")
    func deterministicMath() {
        expectNoFallback(DeterministicMathDemoState.self)
    }
}

private func expectNoFallback<State: StateNodeProtocol>(_ type: State.Type, sourceLocation: SourceLocation = #_sourceLocation) {
    let fields = syncTableFallbackFieldDescriptions(of: type)
    #expect(fields.isEmpty, "\(State.self): \(fields)", sourceLocation: sourceLocation)
}
