// Examples/GameDemo/Sources/EncodingBenchmark/ViewCapture.swift
//
// `--capture-views <dir>`: the input of the reconstruction-equals-projection gate. For the first
// `--capture-rooms` rooms of each hero-defense multi-room run, it writes every frame each room's
// transport sends, with its target, and after every sync each player's projection (the synced
// fields the server says that player should see). `ws-loadtest`'s `verify-views` rebuilds every
// recipient's state from its frames with the TypeScript SDK, as a client does, and compares it
// with the projection after every sync.
//
// A capture pass computes a projection per player per sync, so its timings aren't measurements.

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import GameContent

/// One captured frame: the bytes the adapter handed to the transport, and to whom.
struct CapturedFrame: Sendable {
    /// `s:<sessionID>`, `p:<playerID>`, `*` (broadcast) or `!<sessionID>` (broadcast except).
    let target: String
    let data: Data
}

/// Where and how much to capture; set once from the command line.
struct ViewCaptureConfig: Sendable {
    let directory: URL
    let rooms: Int
}

enum ViewCapture {
    /// Set by `main` before any run when `--capture-views` is given.
    nonisolated(unsafe) static var config: ViewCaptureConfig?

    static func target(_ target: SwiftStateTreeTransport.EventTarget) -> String {
        switch target {
        case .session(let id): return "s:\(id.rawValue)"
        case .player(let id): return "p:\(id.rawValue)"
        case .broadcast: return "*"
        case .broadcastExcept(let id): return "!\(id.rawValue)"
        }
    }
}

/// Writes one NDJSON file per captured room: a header line, then one line per checkpoint.
final class ViewCaptureWriter: @unchecked Sendable {
    private let handles: [FileHandle]
    private let rooms: [HeroDefenseRoomContext]
    private let players: [[(session: SessionID, player: PlayerID)]]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Writes each captured room's header. Returns nil when capture is off. The rooms' transports
    /// capture from their creation (`CountingTransport(capturing:)`), so the joins' first syncs
    /// are in the first checkpoint.
    static func start(
        config: ViewCaptureConfig?,
        label: String,
        format: EncodingFormat,
        schema: ProtocolSchema,
        rooms: [HeroDefenseRoomContext],
        playersPerRoom: Int,
        cell: [String: Any]
    ) async throws -> ViewCaptureWriter? {
        guard let config else { return nil }
        let captured = Array(rooms.prefix(config.rooms))
        let directory = config.directory.appendingPathComponent(label, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let schemaJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema))
        let encoding = format.transportEncodingConfig
        // Provenance: the decode timer requires its SDK to come from this commit.
        let commit = runCommandCaptureStdout(["git", "rev-parse", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty `git status` comes back as nil (the helper treats no output as failure): with a
        // commit, that means a clean tree.
        let porcelain = runCommandCaptureStdout(["git", "status", "--porcelain", "--untracked-files=no"])
        let dirty: Bool? = commit == nil ? nil : !(porcelain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let environment = ProcessInfo.processInfo.environment
        let settings: [String: Any] = Dictionary(uniqueKeysWithValues: [
            SyncStrategy.environmentKey, DirtyTrackingMode.enableKey, DirtyTrackingMode.autoKey,
            DirtyTrackingMode.modeKey, DynamicKeyCompressionMode.environmentKey, "USE_SNAPSHOT_FOR_SYNC",
        ].compactMap { key in environment[key].map { (key, $0 as Any) } })
        var handles: [FileHandle] = []
        var players: [[(session: SessionID, player: PlayerID)]] = []
        for (roomIndex, room) in captured.enumerated() {
            let url = directory.appendingPathComponent("room-\(roomIndex).ndjson")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            let roomPlayers = (0 ..< playersPerRoom).map {
                (session: SessionID("room\(roomIndex)-session-\($0)"), player: PlayerID("room\(roomIndex)-player-\($0)"))
            }
            let header: [String: Any] = [
                "landID": room.landID.stringValue,
                "format": format.rawValue,
                "message": encoding.message.rawValue,
                "stateUpdate": encoding.stateUpdate.rawValue,
                "syncStrategy": ProcessInfo.processInfo.environment[SyncStrategy.environmentKey] ?? SyncStrategy.delta.rawValue,
                "sessions": Dictionary(uniqueKeysWithValues: roomPlayers.map { ($0.session.rawValue, $0.player.rawValue) }),
                "schema": schemaJSON,
                "git": ["commit": commit as Any, "dirty": dirty as Any],
                "cell": cell.merging(["capturedRooms": captured.count, "environment": settings]) { current, _ in current },
            ]
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) + Data("\n".utf8))
            handles.append(handle)
            players.append(roomPlayers)
        }
        return ViewCaptureWriter(handles: handles, rooms: captured, players: players)
    }

    private init(handles: [FileHandle], rooms: [HeroDefenseRoomContext], players: [[(session: SessionID, player: PlayerID)]]) {
        self.handles = handles
        self.rooms = rooms
        self.players = players
    }

    /// After a sync and the writer's drain: the frames sent since the last checkpoint, and each
    /// player's projection of the state now.
    func checkpoint(sync: Int) async throws {
        let engine = SyncEngine(for: HeroDefenseState.self)
        for (index, room) in rooms.enumerated() {
            let frames = await room.transport.takeCaptured()
            let state = await room.keeper.currentState()
            var projections: [String: Any] = [:]
            for (_, player) in players[index] {
                let values = try engine.snapshot(for: player, from: state, mode: .all).values
                projections[player.rawValue] = try JSONSerialization.jsonObject(with: encoder.encode(values))
            }
            let line: [String: Any] = [
                "sync": sync,
                "frames": frames.map { ["to": $0.target, "data": $0.data.base64EncodedString()] },
                "projections": projections,
            ]
            try handles[index].write(contentsOf: JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) + Data("\n".utf8))
        }
    }

    func close() throws {
        for handle in handles {
            try handle.close()
        }
    }
}
