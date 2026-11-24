// expect: compiles
// The blocks of docs/core/land-dsl.md § "Helpers and `@Land`" (and its zh-TW copy), verbatim
// between the markers, with the typealias form the page gives inline (#771 D-Q3, D-Q5). Change a
// block here first, then copy it to both pages.
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: Int] = [:]

    init() {}
}

// docs block 1
@LandDSL<GameState, NoServices>
func joinRules() -> [LandNode] {
    OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
}

let land = Land("game", using: GameState.self) {
    joinRules()
    Rules { joinRules() }
}
// end docs block 1

typealias GameDSL = LandDSL<GameState, NoServices>

@GameDSL func joinRulesShort() -> [LandNode] {
    OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
}

// docs block 2
@Land(GameState.self)
struct GameLand {
    static var body: [LandNode] {
        Rules {
            OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
        }
    }
}

let definition = GameLand.definition
// end docs block 2
