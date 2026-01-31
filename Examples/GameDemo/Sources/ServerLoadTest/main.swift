// Sources/ServerLoadTest/main.swift
//
// ServerLoadTest entry point and orchestration.
// Uses ClientSimulator for async client operations.

import Foundation
import GameContent
import Logging
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

// MARK: - Main Entry Point

func runServerLoadTest() async throws {
    let config = parseArguments()
    let logger = createGameLogger(scope: "ServerLoadTest", logLevel: config.logLevel)

    if config.rooms == 0 || config.playersPerRoom == 0 {
        print("Nothing to do: rooms=\(config.rooms), playersPerRoom=\(config.playersPerRoom)")
        return
    }

    // Force MessagePack for phase1
    let transportEncoding: TransportEncodingConfig = .messagepack

    // Extract pathHashes from schema
    let landDef = HeroDefense.makeLand()
    let schema = SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
    let pathHashes = schema.lands[config.landType]?.pathHashes

    let serverConfig = LandServerConfiguration(
        logger: logger,
        jwtConfig: nil,
        jwtValidator: nil,
        allowGuestMode: true,
        allowAutoCreateOnJoin: true,
        transportEncoding: transportEncoding,
        enableLiveStateHashRecording: false,
        pathHashes: pathHashes,
        eventHashes: nil,
        clientEventHashes: nil,
        servicesFactory: { _, _ in
            var services = LandServices()
            let configProvider = DefaultGameConfigProvider()
            let configService = GameConfigProviderService(provider: configProvider)
            services.register(configService, as: GameConfigProviderService.self)
            return services
        }
    )

    let server = try await LandServer<HeroDefenseState>.create(
        configuration: serverConfig,
        landFactory: { _ in landDef },
        initialStateFactory: { _ in HeroDefenseState() },
        createGuestSession: nil,
        lobbyIDs: []
    )

    guard let transport = server.transport else {
        throw NSError(domain: "ServerLoadTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "LandServer did not provide transport"])
    }

    // Create shared components
    let traffic = TrafficCounter()
    let roomManager = RoomManager(maxRooms: config.rooms, maxPlayersPerRoom: config.playersPerRoom)
    let messageKindRecorder: MessageKindRecorder? = (config.rooms == 1) ? MessageKindRecorder() : nil

    // Create message factories
    let joinCodec = TransportEncoding.json.makeCodec()
    let messagePackCodec = TransportEncoding.messagepack.makeCodec()

    let makeJoinData: @Sendable (Int, Int) throws -> Data = { roomIndex, playerIndexInRoom in
        let requestID = "join-\(roomIndex)-\(playerIndexInRoom)"
        let instanceId = "room-\(roomIndex)"
        let playerID = "p-\(roomIndex)-\(playerIndexInRoom)"
        let payload = TransportJoinPayload(
            requestID: requestID,
            landType: config.landType,
            landInstanceId: instanceId,
            playerID: playerID,
            deviceID: nil,
            metadata: nil
        )
        let message = TransportMessage(
            kind: .join,
            payload: .join(payload)
        )
        return try joinCodec.encode(message)
    }

    let makeClientEventData: @Sendable (Int) throws -> Data = { second in
        let target = Position2(x: Float(100 + (second % 100)), y: Float(100 + (second % 50)))
        let event = MoveToEvent(target: target)
        let anyClientEvent = AnyClientEvent(event)
        let eventMessage = TransportMessage(
            kind: .event,
            payload: .event(.fromClient(event: anyClientEvent))
        )
        return try messagePackCodec.encode(eventMessage)
    }

    // Create ClientSimulator
    let clientSimulator = ClientSimulator(
        config: config,
        roomManager: roomManager,
        traffic: traffic,
        transport: transport,
        makeJoinData: makeJoinData,
        makeClientEventData: makeClientEventData,
        messageKindRecorder: messageKindRecorder
    )

    // Start client simulation in background task
    let clientTask = Task {
        await clientSimulator.run()
    }

    // Main loop: sample traffic every second (runs independently)
    let steadySeconds = config.durationSeconds
    let totalSeconds = config.totalSeconds
    var seconds: [SecondSample] = []
    seconds.reserveCapacity(totalSeconds + 10)
    var lastTraffic = await traffic.snapshot()

    func logProgress(sample: SecondSample) {
        let sentKB = Double(sample.sentBytesPerSecond) / 1024.0
        let recvKB = Double(sample.recvBytesPerSecond) / 1024.0
        let message = "t=\(sample.t)/\(totalSeconds) rooms=\(sample.roomsCreated)/\(sample.roomsTarget) players=\(sample.playersActiveExpected) " +
            "sent=\(String(format: "%.1f", sentKB))KB/s recv=\(String(format: "%.1f", recvKB))KB/s " +
            "msgsOut=\(sample.sentMessagesPerSecond)/s msgsIn=\(sample.recvMessagesPerSecond)/s"
        logger.info(Logger.Message(stringLiteral: message))
    }

    for t in 0 ..< totalSeconds {
        // Get current state from room manager
        let connectedSessions = await roomManager.getJoinedSessions()
        let activeRoomCount = await roomManager.getActiveRoomCount()

        // Traffic snapshot
        let nowTraffic = await traffic.snapshot()
        let sentDeltaBytes = nowTraffic.sentBytes - lastTraffic.sentBytes
        let recvDeltaBytes = nowTraffic.recvBytes - lastTraffic.recvBytes
        let sentDeltaMsgs = nowTraffic.sentMessages - lastTraffic.sentMessages
        let recvDeltaMsgs = nowTraffic.recvMessages - lastTraffic.recvMessages
        lastTraffic = nowTraffic

        // Performance metrics
        let tickIntervalMs = 50.0
        let syncIntervalMs = 100.0
        let ticksPerSecond = 1000.0 / tickIntervalMs
        let syncsPerSecond = 1000.0 / syncIntervalMs
        let estimatedTicksPerSecond = Double(activeRoomCount) * ticksPerSecond
        let estimatedSyncsPerSecond = Double(activeRoomCount) * syncsPerSecond
        let estimatedUpdatesPerSecond = estimatedTicksPerSecond + estimatedSyncsPerSecond

        let sample = SecondSample(
            t: t,
            roomsTarget: config.rooms,
            roomsCreated: activeRoomCount,
            roomsActiveExpected: Int(ceil(Double(connectedSessions.count) / Double(config.playersPerRoom))),
            playersActiveExpected: connectedSessions.count,
            actionsSentThisSecond: await clientSimulator.getAndResetActionCount(),
            sentBytesPerSecond: sentDeltaBytes,
            recvBytesPerSecond: recvDeltaBytes,
            sentMessagesPerSecond: sentDeltaMsgs,
            recvMessagesPerSecond: recvDeltaMsgs,
            processCPUSeconds: nil,
            processRSSBytes: nil,
            avgMessageSize: nowTraffic.avgMessageSize,
            estimatedTicksPerSecond: estimatedTicksPerSecond,
            estimatedSyncsPerSecond: estimatedSyncsPerSecond,
            estimatedUpdatesPerSecond: estimatedUpdatesPerSecond
        )
        seconds.append(sample)
        logProgress(sample: sample)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // Stop client simulation
    await clientSimulator.stop()
    clientTask.cancel()

    // Final cleanup
    if let landManager = server.landManager {
        await landManager.shutdownAllLands()
    }
    try? await transport.stop()
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // Generate summary and save results
    let finalTraffic = await traffic.snapshot()
    let finalActiveRoomCount = await roomManager.getActiveRoomCount()

    let summary = LoadTestSummary(
        totalSeconds: totalSeconds,
        rampUpSeconds: config.rampUpSeconds,
        steadySeconds: steadySeconds,
        rampDownSeconds: config.rampDownSeconds,
        roomsTarget: config.rooms,
        roomsCreated: finalActiveRoomCount,
        playersCreated: config.totalPlayers,
        totalSentBytes: finalTraffic.sentBytes,
        totalReceivedBytes: finalTraffic.recvBytes,
        totalSentMessages: finalTraffic.sentMessages,
        totalReceivedMessages: finalTraffic.recvMessages,
        peakRSSBytes: nil,
        endRSSBytes: nil
    )

    func getPhase(for t: Int) -> String {
        if t < config.rampUpSeconds {
            return "ramp-up"
        } else if t < (config.rampUpSeconds + steadySeconds) {
            return "steady"
        } else {
            return "ramp-down"
        }
    }

    let results: [String: Any] = [
        "seconds": seconds.map { sample in
            [
                "t": sample.t,
                "phase": getPhase(for: sample.t),
                "roomsTarget": sample.roomsTarget,
                "roomsCreated": sample.roomsCreated,
                "roomsActiveExpected": sample.roomsActiveExpected,
                "playersActiveExpected": sample.playersActiveExpected,
                "actionsSentThisSecond": sample.actionsSentThisSecond,
                "sentBytesPerSecond": sample.sentBytesPerSecond,
                "recvBytesPerSecond": sample.recvBytesPerSecond,
                "sentMessagesPerSecond": sample.sentMessagesPerSecond,
                "recvMessagesPerSecond": sample.recvMessagesPerSecond,
                "avgMessageSize": sample.avgMessageSize,
                "estimatedTicksPerSecond": sample.estimatedTicksPerSecond,
                "estimatedSyncsPerSecond": sample.estimatedSyncsPerSecond,
                "estimatedUpdatesPerSecond": sample.estimatedUpdatesPerSecond,
            ] as [String: Any]
        },
        "summary": [
            "totalSeconds": summary.totalSeconds,
            "rampUpSeconds": summary.rampUpSeconds,
            "steadySeconds": summary.steadySeconds,
            "rampDownSeconds": summary.rampDownSeconds,
            "roomsTarget": summary.roomsTarget,
            "roomsCreated": summary.roomsCreated,
            "playersCreated": summary.playersCreated,
            "totalSentBytes": summary.totalSentBytes,
            "totalSentMessages": summary.totalSentMessages,
            "avgSentBytesPerSecond": summary.avgSentBytesPerSecond,
            "avgSentMessagesPerSecond": summary.avgSentMessagesPerSecond,
            "avgRecvBytesPerSecond": summary.avgRecvBytesPerSecond,
            "avgRecvMessagesPerSecond": summary.avgRecvMessagesPerSecond,
        ] as [String: Any],
    ]

    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
    let filename = "server-loadtest-messagepack-rooms\(config.rooms)-ppr\(config.playersPerRoom)-steady\(steadySeconds)s-\(timestamp).json"

    saveResultsToJSON(
        results,
        filename: filename,
        loadTestConfig: [
            "phase": 1,
            "description": "No-WebSocket load test using WebSocketTransport with in-process connections; MessagePack for steady-state messages; JSON-only join handshake; re-evaluation recording DISABLED",
            "landType": config.landType,
            "rooms": config.rooms,
            "playersPerRoom": config.playersPerRoom,
            "totalSeconds": totalSeconds,
            "rampUpSeconds": config.rampUpSeconds,
            "steadySeconds": steadySeconds,
            "rampDownSeconds": config.rampDownSeconds,
            "actionsPerPlayerPerSecond": config.actionsPerPlayerPerSecond,
            "tui": config.tui,
            "logLevel": String(describing: config.logLevel),
            "transportEncoding": [
                "message": "messagepack",
                "stateUpdate": "opcodeMessagePack",
            ],
            "enableLiveStateHashRecording": false,
        ]
    )

    if let messageKindRecorder {
        let kindSummary = await messageKindRecorder.summary()
        let kindFilename = "message-kinds-rooms\(config.rooms)-ppr\(config.playersPerRoom)-\(timestamp).json"
        let kindURL = getResultsDirectory().appendingPathComponent(kindFilename)
        if let data = try? JSONSerialization.data(withJSONObject: kindSummary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: kindURL)
            print("Message kind breakdown (egress) saved to: \(kindURL.path)")
        }
    }
}

// Top-level entry point
try await runServerLoadTest()
