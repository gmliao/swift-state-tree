// Sources/SwiftStateTree/GameCore/GameState.swift

public struct PlayerID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct GameState: Sendable {
    public var players: [PlayerID: PlayerState]

    public init(players: [PlayerID: PlayerState] = [:]) {
        self.players = players
    }
}

public struct PlayerState: Sendable {
    public var name: String
    public var hp: Int

    public init(name: String, hp: Int = 100) {
        self.name = name
        self.hp = hp
    }
}

