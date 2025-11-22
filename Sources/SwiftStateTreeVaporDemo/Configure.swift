// Sources/SwiftStateTreeVaporDemo/Configure.swift

import Vapor
import SwiftStateTree

/// Simple room manager (stored in Application lifecycle)
final class RoomManager: @unchecked Sendable {
    private var rooms: [String: RoomActor] = [:]

    func room(for id: String) -> RoomActor {
        if let existing = rooms[id] {
            return existing
        }
        let room = RoomActor(roomID: id)
        rooms[id] = room
        return room
    }
}

func configure(_ app: Application) throws {
    app.storage[RoomManagerKey.self] = RoomManager()
    try routes(app)
}

// Vapor Storage Key
private struct RoomManagerKey: StorageKey {
    typealias Value = RoomManager
}

extension Application {
    var roomManager: RoomManager {
        guard let manager = storage[RoomManagerKey.self] else {
            let new = RoomManager()
            storage[RoomManagerKey.self] = new
            return new
        }
        return manager
    }
}

