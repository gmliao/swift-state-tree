import Testing
@_spi(Diagnostics) import SwiftStateTree
@testable import GameContent

/// Each GameDemo land's fields on the typed sync tables, which are the default: a field that
/// starts taking the snapshot fallback breaks its pin, so it shows up in review. Nothing is
/// on them today.
@Suite("GameDemo lands' sync table fallback lists")
struct SyncTableFallbackPinTests {
    @Test("Hero Defense")
    func heroDefense() {
        expectNoFallback(HeroDefenseState.self)
    }

    @Test("The visibility test land, with per-player entities and broadcast only")
    func visibility() {
        expectNoFallback(VisibilityTestState.self)
        expectNoFallback(VisibilityTestBroadcastState.self)
    }

    @Test("The card game")
    func cardGame() {
        expectNoFallback(CardGameState.self)
    }

    @Test("The resolver test land")
    func resolverTest() {
        expectNoFallback(ResolverTestState.self)
    }
}

private func expectNoFallback<State: StateNodeProtocol>(_ type: State.Type, sourceLocation: SourceLocation = #_sourceLocation) {
    let fields = syncTableFallbackFieldDescriptions(of: type)
    #expect(fields.isEmpty, "\(State.self): \(fields)", sourceLocation: sourceLocation)
}
