// Sources/SwiftStateTree/GameCore/GameCommand.swift

/// Command enum that can be shared between WebSocket and REST APIs
public enum GameCommand: Sendable {
    case join(playerID: PlayerID, name: String)
    case leave(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
}

