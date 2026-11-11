// Examples/GameDemo/Sources/EncodingBenchmark/RouterJoin.swift
//
// `--join-through-router on`: the hero-defense multi-room runner's rooms are joined the way a
// server joins them. The lands live in a `LandManager` behind a `LandRouter` and a real
// `WebSocketTransport`. Each player is a session with a fake connection, and its join and its
// acks go through the transport's inbound path. Row addressing (`--row-addressing on`) takes
// effect only for joins through a router, so this is the only path that can measure it.
//
// The measured loop is the default path's: `stepTickOnce`, `syncNow` and `MeasuredSync` on each
// land's keeper and adapter, with the loops off (`LandManager`'s `autoStartLoops: false`). What
// differs is around it: after each drain the transport's session queues are flushed, so every
// connection holds its frames before they are read, and each connection then acks its last
// sync sequence. Both are outside the timed spans.
//
// The bytes are per connection: a frame for several sessions (a broadcast) is counted once per
// session, as the wire carries it. The default path counts each frame the adapter hands its
// transport once. The two paths' bytes are not comparable.

import Foundation
import GameContent
import LoadTestPacing
import Logging
import SwiftStateTree
@_spi(Diagnostics) import SwiftStateTreeTransport

/// The router path's options, set once from the command line.
struct RouterJoinConfig: Sendable {
    /// `--row-addressing on`: the lands' encoding has `rowAddressing` on.
    let rowAddressing: Bool
    /// The lands' sync-lag policy (`SyncLagPolicy.fromEnvironment()`, as a server's): the lands run
    /// as hosted, with the sync sequence and lag tracking, so every connection acks.
    let syncLag: SyncLagPolicy
}

enum RouterJoin {
    /// Set by `main` before any run when `--join-through-router on` is given.
    nonisolated(unsafe) static var config: RouterJoinConfig?

    /// Steps the join phase may take before the run fails: each joiner needs its JoinResponse
    /// and its firstSync, which come within a couple of steps. Past it, a join was refused or lost.
    static let maxJoinSteps = 20

    /// A run's encoding on the router path: the format's, with row addressing when asked. The
    /// land manager adds the sync sequence (it runs its lands as hosted).
    static func encoding(_ format: EncodingFormat, rowAddressing: Bool) -> TransportEncodingConfig {
        format.transportEncodingConfig.withRowAddressing(rowAddressing)
    }
}

/// One benchmark session's connection. Every frame the transport's drain hands it goes to its
/// room's `CountingTransport` as a frame for this session (counted, and captured with target
/// `s:<session>`). It notes whether its JoinResponse and firstSync have arrived and its last sync
/// sequence (for the acks), and any close the server sent it.
final class BenchmarkConnection: WebSocketConnection, @unchecked Sendable {
    let sessionID: SessionID
    private let room: CountingTransport
    private let lock = NSLock()
    private var framesReceived = 0
    private var firstSyncReceived = false
    private var lastSeq: UInt64?
    private var serverClose: UInt16?

    init(sessionID: SessionID, room: CountingTransport) {
        self.sessionID = sessionID
        self.room = room
    }

    func send(_ data: Data) async throws {
        let op = SyncSequencePeek.stateOp(data)
        let seq = SyncSequencePeek.seq(data)
        lock.withLock {
            framesReceived += 1
            // A joiner's first state update is its firstSync (op 1); a resync (op 3) is one too.
            if op == 1 || op == 3 { firstSyncReceived = true }
            if let seq, seq > lastSeq ?? 0 { lastSeq = seq }
        }
        await room.send(data, to: .session(sessionID))
    }

    func close() async throws {
        lock.withLock { if serverClose == nil { serverClose = 1000 } }
    }

    func close(with close: SessionClose) async throws {
        lock.withLock { if serverClose == nil { serverClose = close.code } }
    }

    /// The JoinResponse (the first frame a joiner gets) and its firstSync have both arrived.
    var joined: Bool {
        lock.withLock { framesReceived >= 2 && firstSyncReceived }
    }

    var lastSyncSequence: UInt64? {
        lock.withLock { lastSeq }
    }

    /// The close code the server sent, if it closed this connection.
    var closedByServer: UInt16? {
        lock.withLock { serverClose }
    }
}

/// The transport's delegate on the router path: the router, with each session's client ID
/// recorded at connect. The transport assigns a random one, and a keeper takes a player's input
/// only from the client it joined with, so the benchmark's injected moves need it.
final class ClientIDRecorder: TransportDelegate, @unchecked Sendable {
    private let router: LandRouter<HeroDefenseState>
    private let lock = NSLock()
    private var clientIDs: [SessionID: ClientID] = [:]

    init(router: LandRouter<HeroDefenseState>) {
        self.router = router
    }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {
        lock.withLock { clientIDs[sessionID] = clientID }
        await router.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    }

    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        await router.onDisconnect(sessionID: sessionID, clientID: clientID)
    }

    func onMessage(_ message: Data, from sessionID: SessionID) async {
        await router.onMessage(message, from: sessionID)
    }

    func clientID(_ sessionID: SessionID) -> ClientID? {
        lock.withLock { clientIDs[sessionID] }
    }
}

/// The router path's lands, router, transport and connections for one hero-defense run.
struct RouterRooms: Sendable {
    let transport: WebSocketTransport
    let manager: LandManager<HeroDefenseState>
    let router: LandRouter<HeroDefenseState>
    /// Per room, one connection per player, in player order.
    let connections: [[BenchmarkConnection]]
    /// Per room, each player's client ID as the transport assigned it, in player order.
    let clientIDs: [[ClientID]]
    /// The rooms' adapters, for the ack check after the run.
    let adapters: [TransportAdapter<HeroDefenseState>]
    /// Acks in MessagePack (the message encoding is MessagePack), else JSON.
    let binaryAcks: Bool
    /// The lands' `effectiveStateUpdateFeatures` (every room has the same).
    let stateUpdateFeatures: [String]

    /// Creates `roomCount` lands with the default path's IDs (`benchmark-<N>`), joins
    /// `playersPerRoom` players to each through the router, and steps until every joiner has its
    /// JoinResponse and firstSync. Returns the rooms for the measured loop. Exits the run if a join
    /// doesn't complete within `RouterJoin.maxJoinSteps` steps, naming the sessions.
    static func make(
        format: EncodingFormat,
        rowAddressing: Bool,
        syncLag: SyncLagPolicy,
        roomCount: Int,
        playersPerRoom: Int,
        makeServices: @escaping @Sendable () -> LandServices,
        pathHashes: [String: UInt32]?,
        captures: (Int) -> Bool,
        logger: Logger
    ) async -> (RouterRooms, [HeroDefenseRoomContext]) {
        let encoding = RouterJoin.encoding(format, rowAddressing: rowAddressing)
        let maxPlayers = max(10, playersPerRoom)
        let transport = WebSocketTransport(logger: logger)
        let registry: LandTypeRegistry<HeroDefenseState>
        do {
            registry = try LandTypeRegistry<HeroDefenseState>(
                landFactory: { _, _ in HeroDefense.makeLand(maxPlayers: maxPlayers) },
                initialStateFactory: { _, _ in HeroDefenseState() }
            )
        } catch {
            fatalError("--join-through-router: the land type registry refused hero-defense: \(error)")
        }
        let manager = LandManager<HeroDefenseState>(
            landFactory: { landID in registry.getLandDefinition(landType: landID.landType, landID: landID) },
            initialStateFactory: { landID in registry.initialStateFactory(landID.landType, landID) },
            servicesFactory: { _, _ in makeServices() },
            transport: transport,
            transportEncoding: encoding,
            pathHashes: pathHashes,
            enableLoopPhaseOffset: false,
            inTurnSync: true,
            autoStartLoops: false,
            syncLag: syncLag,
            logger: logger
        )
        let router = LandRouter<HeroDefenseState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            transportEncoding: encoding,
            logger: logger
        )
        let recorder = ClientIDRecorder(router: router)
        await transport.setDelegate(recorder)

        var rooms: [HeroDefenseRoomContext] = []
        var connections: [[BenchmarkConnection]] = []
        var allClientIDs: [[ClientID]] = []
        for roomIndex in 0 ..< roomCount {
            let landID = LandID(landType: "hero-defense", instanceId: "benchmark-\(roomIndex)")
            let container: LandContainer<HeroDefenseState>
            do {
                container = try await manager.getOrCreateLand(
                    landID: landID,
                    definition: registry.getLandDefinition(landType: landID.landType, landID: landID),
                    initialState: HeroDefenseState(),
                    metadata: [:]
                )
            } catch {
                fatalError("--join-through-router: room \(roomIndex)'s land wasn't created: \(error)")
            }
            let counting = CountingTransport(capturing: captures(roomIndex))
            var roomConnections: [BenchmarkConnection] = []
            for playerIndex in 0 ..< playersPerRoom {
                let sessionID = SessionID("room\(roomIndex)-session-\(playerIndex)")
                let connection = BenchmarkConnection(sessionID: sessionID, room: counting)
                await transport.handleConnection(sessionID: sessionID, connection: connection)
                let join = TransportMessage.join(
                    requestID: "join-\(playerIndex)",
                    landType: landID.landType,
                    landInstanceId: landID.instanceId,
                    playerID: "room\(roomIndex)-player-\(playerIndex)",
                    deviceID: "device-\(roomIndex)-\(playerIndex)",
                    metadata: StateUpdateFeature.joinMetadata
                )
                do {
                    await transport.handleIncomingMessage(sessionID: sessionID, data: try JSONEncoder().encode(join))
                } catch {
                    fatalError("--join-through-router: a join didn't encode: \(error)")
                }
                roomConnections.append(connection)
            }
            let clientIDs = roomConnections.map { connection -> ClientID in
                guard let clientID = recorder.clientID(connection.sessionID) else {
                    fatalError("--join-through-router: \(connection.sessionID.rawValue) connected without a client ID")
                }
                return clientID
            }
            rooms.append(HeroDefenseRoomContext(
                landID: landID, keeper: container.keeper, adapter: container.transportAdapter, transport: counting
            ))
            allClientIDs.append(clientIDs)
            connections.append(roomConnections)
        }

        let set = RouterRooms(
            transport: transport, manager: manager, router: router, connections: connections,
            clientIDs: allClientIDs, adapters: rooms.map(\.adapter),
            binaryAcks: encoding.message == .messagepack,
            stateUpdateFeatures: rooms.first?.adapter.effectiveStateUpdateFeatures ?? []
        )
        // The joins complete in the lands' turns: step them until every joiner has its
        // JoinResponse and firstSync, reading the connections only after a drain and a flush.
        // Each step acks too (settle): a long join phase must not run past the ack timeout.
        var steps = 0
        while !set.connections.joined().allSatisfy(\.joined) {
            guard steps < RouterJoin.maxJoinSteps else {
                let missing = set.connections.joined().filter { !$0.joined }.map(\.sessionID.rawValue)
                print("Error: --join-through-router: \(missing.count) session(s) without a JoinResponse and firstSync after \(steps) steps: \(missing.prefix(10).joined(separator: ", "))")
                exit(1)
            }
            for room in rooms {
                await room.keeper.stepTickOnce()
                await room.adapter.syncNow()
            }
            await MeasuredSync.drain(rooms.map(\.adapter))
            await set.settle()
            steps += 1
        }
        await set.requireNoServerClose(during: "the joins")
        if rowAddressing, !set.stateUpdateFeatures.contains(StateUpdateFeature.rowAddressing) {
            print("Error: --row-addressing on, but the lands don't have row entries in effect (features: \(set.stateUpdateFeatures)); the server log says why")
            exit(1)
        }
        return (set, rooms)
    }

    /// After a drain: every frame queued so far is in its connection, then each connection acks
    /// its last sync sequence (outside the timed spans; the acks send nothing back).
    func settle() async {
        await transport.flushSessionQueues()
        for connection in connections.joined() {
            guard let seq = connection.lastSyncSequence else { continue }
            await transport.handleIncomingMessage(
                sessionID: connection.sessionID,
                data: SyncAckFrame.encode(seq: seq, binary: binaryAcks)
            )
        }
    }

    /// Exits the run if the server closed any connection (a sync-lag close, a row entry it
    /// couldn't encode): the counts would describe fewer sessions than the run says.
    func requireNoServerClose(during phase: String) async {
        let closed = connections.joined().compactMap { connection in
            connection.closedByServer.map { "\(connection.sessionID.rawValue) (\($0))" }
        }
        guard closed.isEmpty else {
            print("Error: --join-through-router: the server closed \(closed.count) connection(s) during \(phase): \(closed.prefix(10).joined(separator: ", "))")
            exit(1)
        }
    }

    /// After the results are taken: the lands shut down and the transport stops.
    func shutdown() async {
        await requireNoServerClose(during: "the run")
        await manager.shutdownAllLands()
        try? await transport.stop()
    }

    /// After the last settle: every ack was taken. Exits the run unless no ack was dropped and no
    /// session has a frame left unacked (the acks would be broken, e.g. in the wrong encoding).
    func requireAcksTaken() async -> (droppedAcks: Int, sessionsWithUnackedFrames: Int) {
        var dropped = 0
        var unacked = 0
        for adapter in adapters {
            let diagnostics = await adapter.syncLagAckDiagnostics()
            dropped += diagnostics.droppedAcks
            unacked += diagnostics.sessionsWithUnackedFrames
        }
        guard dropped == 0, unacked == 0 else {
            print("Error: --join-through-router: \(dropped) ack(s) dropped and \(unacked) session(s) with unacked frames after the last sync")
            exit(1)
        }
        return (dropped, unacked)
    }

    /// The router path's metadata for a result, after the run (it checks the acks).
    func metadata(rowAddressingRequested: Bool, syncLag: SyncLagPolicy) async -> [String: Any] {
        let acks = await requireAcksTaken()
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        return [
            "joinPath": "router",
            "transport": "WebSocketTransport",
            "syncAcks": "lastSequenceAfterEachSync",
            "bytesCounted": "perConnection",
            "rowAddressingRequested": rowAddressingRequested,
            "rowAddressingInEffect": stateUpdateFeatures.contains(StateUpdateFeature.rowAddressing),
            "stateUpdateFeatures": stateUpdateFeatures,
            // Sessions the server closed: 0 by construction, since the run exits on any close (a
            // sync-lag close would mean the acks didn't keep up).
            "serverCloses": 0,
            // Read from the adapters after the last settle; the run exits unless both are 0.
            "droppedAcks": acks.droppedAcks,
            "sessionsWithUnackedFrames": acks.sessionsWithUnackedFrames,
            "syncLagPolicy": [
                "resyncAfterMs": ms(syncLag.resyncAfter),
                "slowConsumerCount": syncLag.slowConsumerCount,
                "slowConsumerWindowMs": ms(syncLag.slowConsumerWindow),
                "ackTimeoutMs": ms(syncLag.ackTimeout),
                "ackFreshnessMs": ms(syncLag.ackFreshness),
                "closeGraceMs": ms(syncLag.closeGrace),
            ],
        ]
    }
}
