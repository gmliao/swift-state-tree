// Sources/SwiftStateTree/GameCore/RoomActor.swift

/// Actor that manages GameState for a single room
public actor RoomActor {
    public let roomID: String
    private var state: GameState

    public init(roomID: String, initialState: GameState = GameState()) {
        self.roomID = roomID
        self.state = initialState
    }

    public func handle(_ command: GameCommand) {
        switch command {
        case let .join(playerID, name):
            state.players[playerID] = PlayerState(name: name)

        case let .leave(playerID):
            state.players.removeValue(forKey: playerID)

        case let .attack(attacker, target, damage):
            guard var targetState = state.players[target],
                  state.players[attacker] != nil
            else { return }

            targetState.hp -= damage
            state.players[target] = targetState
        }
    }

    public func snapshot() -> GameState {
        state
    }
}

