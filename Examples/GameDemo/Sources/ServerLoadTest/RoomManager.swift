// Sources/ServerLoadTest/RoomManager.swift
//
// Actor for thread-safe room and player management.

import SwiftStateTree

// MARK: - Player State

struct PlayerState: Sendable {
    let sessionID: SessionID
    let roomIndex: Int
    let playerIndexInRoom: Int
    var hasJoined: Bool = false
}

// MARK: - Room State

struct RoomState: Sendable {
    let roomIndex: Int
    var players: [PlayerState] = []
    var isActive: Bool = false

    var playerCount: Int { players.count }
    var hasSpace: Bool { playerCount < 5 }
    var joinedPlayers: [PlayerState] { players.filter { $0.hasJoined } }
}

// MARK: - Room Manager Actor

actor RoomManager {
    private var rooms: [Int: RoomState] = [:]
    private var nextAvailableRoomIndex = 0
    let maxRooms: Int
    let maxPlayersPerRoom: Int

    init(maxRooms: Int, maxPlayersPerRoom: Int) {
        self.maxRooms = maxRooms
        self.maxPlayersPerRoom = maxPlayersPerRoom
    }

    /// Find or create a room for a new player
    func assignPlayer() -> (roomIndex: Int, playerIndexInRoom: Int, sessionID: SessionID)? {
        // First, try to find an existing room with available space
        for (roomIndex, var room) in rooms {
            if room.hasSpace, roomIndex < maxRooms {
                let playerIndexInRoom = room.playerCount
                let sessionID = SessionID("s-\(roomIndex)-\(playerIndexInRoom)")
                let player = PlayerState(
                    sessionID: sessionID,
                    roomIndex: roomIndex,
                    playerIndexInRoom: playerIndexInRoom,
                    hasJoined: false
                )
                room.players.append(player)
                room.isActive = true
                rooms[roomIndex] = room
                return (roomIndex: roomIndex, playerIndexInRoom: playerIndexInRoom, sessionID: sessionID)
            }
        }

        // No room with space found, create a new room
        if nextAvailableRoomIndex < maxRooms {
            let roomIndex = nextAvailableRoomIndex
            nextAvailableRoomIndex += 1
            let sessionID = SessionID("s-\(roomIndex)-0")
            let player = PlayerState(
                sessionID: sessionID,
                roomIndex: roomIndex,
                playerIndexInRoom: 0,
                hasJoined: false
            )
            let newRoom = RoomState(roomIndex: roomIndex, players: [player], isActive: true)
            rooms[roomIndex] = newRoom
            return (roomIndex: roomIndex, playerIndexInRoom: 0, sessionID: sessionID)
        }

        // All rooms are full
        return nil
    }

    /// Mark a player as successfully joined
    func markPlayerJoined(sessionID: SessionID) {
        for (roomIndex, var room) in rooms {
            if let playerIndex = room.players.firstIndex(where: { $0.sessionID == sessionID }) {
                room.players[playerIndex].hasJoined = true
                rooms[roomIndex] = room
                return
            }
        }
    }

    /// Get all assigned sessions (regardless of join status)
    func getAllAssignedSessions() -> [SessionID] {
        var all: [SessionID] = []
        for room in rooms.values {
            all.append(contentsOf: room.players.map { $0.sessionID })
        }
        return all
    }

    /// Get all sessions that have successfully joined
    func getJoinedSessions() -> [SessionID] {
        var joined: [SessionID] = []
        for room in rooms.values {
            joined.append(contentsOf: room.joinedPlayers.map { $0.sessionID })
        }
        return joined
    }

    /// Get active room count
    func getActiveRoomCount() -> Int {
        rooms.values.filter { $0.isActive }.count
    }

    /// Remove a session
    func removeSession(_ sessionID: SessionID) {
        for (roomIndex, var room) in rooms {
            if let playerIndex = room.players.firstIndex(where: { $0.sessionID == sessionID }) {
                room.players.remove(at: playerIndex)
                if room.players.isEmpty {
                    room.isActive = false
                }
                rooms[roomIndex] = room
                return
            }
        }
    }
}
