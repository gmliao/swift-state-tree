// expect: compiles
// The blocks of docs/core/land-dsl.md § "Helpers and `@Land`" (and its zh-TW copy), verbatim
// between the markers, with the typealias form the page gives inline (#771 D-Q3, D-Q5, #794).
// Change a block here first, then copy it to both pages.
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: Int] = [:]

    init() {}
}

@StateNodeBuilder
struct LobbyState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: Int] = [:]

    @Sync(.broadcast)
    var open: Bool = true

    init() {}
}

struct LobbyServices: Sendable {}

// docs block 1
@LandDSL<GameState, NoServices>
func joinRules() -> LandRules<GameState, NoServices> {
    OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
}

let land = Land("game", using: GameState.self) {
    joinRules()
    Rules { joinRules() }
}
// end docs block 1

typealias GameDSL = LandDSL<GameState, NoServices>
typealias GameRules = LandRules<GameState, NoServices>

@GameDSL func joinRulesShort() -> GameRules {
    OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
}

// docs block 2
protocol HasPlayers: StateNodeProtocol {
    var players: [PlayerID: Int] { get set }
}

@LandDSL<S, Svc>
func leaveRules<S: HasPlayers, Svc: Sendable>() -> LandRules<S, Svc> {
    OnLeave { state, ctx in state.players[ctx.playerID] = nil }
}

let game = Land("game", using: GameState.self) { leaveRules() }
let lobby = Land("lobby", using: LobbyState.self, services: LobbyServices.self) { leaveRules() }
// end docs block 2

extension GameState: HasPlayers {}
extension LobbyState: HasPlayers {}

// docs block 3
@Land(GameState.self)
struct GameLand {
    static var body: LandRules<GameState, NoServices> {
        Rules {
            OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
        }
    }
}

let definition = GameLand.definition
// end docs block 3
