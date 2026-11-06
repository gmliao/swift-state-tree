// Sources/ServerLoadTest/main.swift
//
// ServerLoadTest entry point and orchestration.
// Uses ClientSimulator for async client operations.

import Foundation
import GameContent
import LoadTestPacing
import Logging
import ProfileRecorderServer
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeNIO
import SwiftStateTreeTransport

// MARK: - Main Entry Point

func runServerLoadTest() async throws {
    let config = parseArguments()
    let logger = createGameLogger(scope: "ServerLoadTest", logLevel: config.logLevel)

    // Run Swift Profile Recorder in background only when it is configured (e.g. for Instruments):
    // reading its configuration starts NIO's singleton event-loop group (see ProfileRecorderEnvKeys).
    if ProfileRecorderEnvKeys.isConfigured {
        Task {
            do {
                let configuration = try await ProfileRecorderServerConfiguration.parseFromEnvironment()
                await ProfileRecorderServer(configuration: configuration).runIgnoringFailures(logger: logger)
            } catch {
                logger.warning("Profile recorder not started: \(error)")
            }
        }
    }

    if config.rooms == 0 || config.playersPerRoom == 0 {
        print("Nothing to do: rooms=\(config.rooms), playersPerRoom=\(config.playersPerRoom)")
        return
    }
    if config.recordDir != nil, !config.record {
        print("--record-dir needs --record on")
        exit(2)
    }
    if config.recordDir != nil, config.rampDownSeconds > 0 {
        // Ramp-down empties rooms, and an empty hero-defense land is removed after 5 s.
        print("--record-dir needs --ramp-down-seconds 0, so every room's record is still there to read")
        exit(2)
    }

    // TRANSPORT_ENCODING (default messagepack); the join handshake stays JSON.
    let encodingName = EnvHelpers.getEnvString(key: ServerLoadTestEnvKeys.transportEncoding, defaultValue: "messagepack")
    let transportEncoding = resolveTransportEncoding(rawValue: encodingName)

    // Extract pathHashes from schema
    let landDef = HeroDefense.makeLand()
    let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
    let pathHashes = schema.lands[config.landType]?.pathHashes

    let nioServerConfig = NIOLandServerConfiguration(
        logger: logger,
        allowAutoCreateOnJoin: true,
        transportEncoding: transportEncoding,
        enableLiveStateHashRecording: config.record,
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

    let transport = WebSocketTransport(logger: logger)
    let server = try NIOLandServer<HeroDefenseState>(
        landType: config.landType,
        landFactory: { _ in landDef },
        initialStateFactory: { _ in HeroDefenseState() },
        configuration: nioServerConfig,
        transport: transport
    )
    await transport.setDelegate(server.landRouter)

    // Create shared components
    let traffic = TrafficCounter()
    let roomManager = RoomManager(maxRooms: config.rooms, maxPlayersPerRoom: config.playersPerRoom)
    let messageKindRecorder: MessageKindRecorder? = (config.rooms == 1) ? MessageKindRecorder() : nil
    let streamDump = try config.streamDir.map { try StreamDump(directory: $0) }

    // Create message factories
    let joinCodec = TransportEncoding.json.makeCodec()
    let clientCodec = transportEncoding.message.makeCodec()

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
        return try clientCodec.encode(eventMessage)
    }

    // Create ClientSimulator
    let clientSimulator = ClientSimulator(
        config: config,
        roomManager: roomManager,
        traffic: traffic,
        transport: transport,
        makeJoinData: makeJoinData,
        makeClientEventData: makeClientEventData,
        messageKindRecorder: messageKindRecorder,
        streamDump: streamDump
    )

    // Generator and sampler share one origin and deadline-based seconds: second t of the
    // generator is [origin + t, origin + t + 1), and sample t is taken at its end.
    let origin = ContinuousClock.now + .milliseconds(100)
    let clientTask = Task {
        await clientSimulator.run(origin: origin)
    }

    // Main loop: sample traffic every second (runs independently)
    let steadySeconds = config.durationSeconds
    let totalSeconds = config.totalSeconds
    var seconds: [SecondSample] = []
    seconds.reserveCapacity(totalSeconds + 10)
    var lastTraffic = await traffic.snapshot()
    var lastActionsSent = 0
    var lastActionsCompleted = 0
    var actionsCompletedPerSecond: [Int] = []

    func logProgress(sample: SecondSample, pacing: (late: Int, skipped: Int, inFlight: Int)?) {
        let sentKB = Double(sample.sentBytesPerSecond) / 1024.0
        let recvKB = Double(sample.recvBytesPerSecond) / 1024.0
        let message = "t=\(sample.t)/\(totalSeconds) rooms=\(sample.roomsCreated)/\(sample.roomsTarget) players=\(sample.playersActiveExpected) " +
            "sent=\(String(format: "%.1f", sentKB))KB/s recv=\(String(format: "%.1f", recvKB))KB/s " +
            "msgsOut=\(sample.sentMessagesPerSecond)/s msgsIn=\(sample.recvMessagesPerSecond)/s" +
            (pacing.map { " late=\($0.late) skipped=\($0.skipped) inFlight=\($0.inFlight)" } ?? "")
        if let pacing, pacing.late > 0 || pacing.skipped > 0 {
            logger.warning(Logger.Message(stringLiteral: message))
        } else {
            logger.info(Logger.Message(stringLiteral: message))
        }
    }

    for t in 0 ..< totalSeconds {
        // Sample t covers second t: taken at its deadline, not one sleep after the last sample.
        await LoadTestPacing.sleep(until: origin + .seconds(t + 1))

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
        // Delta of the cumulative count, so a sample never catches 0 or 2 periods' sends.
        let actionsSent = await clientSimulator.totalActionsSent
        let actionsSentThisSecond = actionsSent - lastActionsSent
        lastActionsSent = actionsSent
        let actionsCompleted = await clientSimulator.totalActionsCompleted
        actionsCompletedPerSecond.append(actionsCompleted - lastActionsCompleted)
        lastActionsCompleted = actionsCompleted

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
            actionsSentThisSecond: actionsSentThisSecond,
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
        // Running totals so far (the current second's stats land once its sends are issued).
        let pacing: (late: Int, skipped: Int, inFlight: Int)? = config.pacing == .legacy ? nil : (
            late: await clientSimulator.lateSecondsSoFar,
            skipped: await clientSimulator.skippedByCapSoFar,
            inFlight: await clientSimulator.inFlight.current
        )
        logProgress(sample: sample, pacing: pacing)
    }

    // Stop client simulation and let started sends finish, so the pacing stats are complete.
    await clientSimulator.stop()
    await clientTask.value
    let periodStats = await clientSimulator.periodStats
    let statsBySecond = Dictionary(periodStats.map { ($0.period, $0) }, uniquingKeysWith: { first, _ in first })
    let peakInFlight = await clientSimulator.inFlight.peak
    let totalActionsSent = await clientSimulator.totalActionsSent
    let totalActionsCompleted = await clientSimulator.totalActionsCompleted
    // One pacing line for the run; a warning when the generator fell behind or hit the cap.
    if config.pacing != .legacy {
        let lateSeconds = periodStats.filter(\.late).count
        let skipped = periodStats.reduce(0) { $0 + $1.skippedByCap }
        let maxLagMs = periodStats.map { LoadTestPacing.milliseconds($0.startLag) }.max() ?? 0
        let line = "pacing \(config.pacing.rawValue): lateSeconds=\(lateSeconds) skippedByCap=\(skipped) " +
            "maxInFlight=\(config.maxInFlight) peakInFlight=\(peakInFlight) maxStartLagMs=\(String(format: "%.1f", maxLagMs))"
        if lateSeconds > 0 || skipped > 0 {
            logger.warning(Logger.Message(stringLiteral: line))
        } else {
            logger.info(Logger.Message(stringLiteral: line))
        }
    } else {
        logger.info("pacing legacy: legacy generator, deadline sampler; no per-second pacing stats")
    }

    // Re-evaluation records, read while every room is still there (--ramp-down-seconds 0).
    var recordsWritten = 0
    var recordBytes = 0
    if let recordDir = config.recordDir {
        let dir = URL(fileURLWithPath: recordDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for room in 0 ..< config.rooms {
            let landID = LandID(landType: config.landType, instanceId: "room-\(room)")
            do {
                guard let data = try await server.getReevaluationRecord(landID: landID) else {
                    logger.warning("No re-evaluation record", metadata: ["landID": .string(landID.rawValue)])
                    continue
                }
                try data.write(to: dir.appendingPathComponent("room-\(room).json"))
                recordsWritten += 1
                recordBytes += data.count
            } catch {
                logger.warning("Re-evaluation record not written", metadata: [
                    "landID": .string(landID.rawValue), "error": .string(String(describing: error)),
                ])
            }
        }
        logger.info("Re-evaluation records written", metadata: [
            "dir": .string(dir.path), "rooms": .stringConvertible(recordsWritten), "bytes": .stringConvertible(recordBytes),
        ])
    }

    // Final cleanup
    await server.landManager.shutdownAllLands()
    try? await transport.stop()
    try? await safeTaskSleep(for: .seconds(2))

    // Generate summary and save results
    let finalTraffic = await traffic.snapshot()
    let perSession = await traffic.receivedPerSession()
    let streamFiles = await streamDump?.closeAll()
    let streamFailures = await streamDump?.failures ?? 0
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
        "seconds": seconds.map { sample -> [String: Any] in
            var entry: [String: Any] = [
                "t": sample.t,
                "phase": getPhase(for: sample.t),
                "roomsTarget": sample.roomsTarget,
                "roomsCreated": sample.roomsCreated,
                "roomsActiveExpected": sample.roomsActiveExpected,
                "playersActiveExpected": sample.playersActiveExpected,
                "actionsSentThisSecond": sample.actionsSentThisSecond,
                "actionsCompletedThisSecond": sample.t < actionsCompletedPerSecond.count ? actionsCompletedPerSecond[sample.t] : 0,
                "sentBytesPerSecond": sample.sentBytesPerSecond,
                "recvBytesPerSecond": sample.recvBytesPerSecond,
                "sentMessagesPerSecond": sample.sentMessagesPerSecond,
                "recvMessagesPerSecond": sample.recvMessagesPerSecond,
                "avgMessageSize": sample.avgMessageSize,
                "estimatedTicksPerSecond": sample.estimatedTicksPerSecond,
                "estimatedSyncsPerSecond": sample.estimatedSyncsPerSecond,
                "estimatedUpdatesPerSecond": sample.estimatedUpdatesPerSecond,
            ]
            // Pacing stats for the generator's second t (spread and aligned modes).
            if let stats = statsBySecond[sample.t] {
                entry["pacing"] = [
                    "startLagMs": LoadTestPacing.milliseconds(stats.startLag),
                    "inFlightAtDeadline": stats.inFlightAtDeadline,
                    "planned": stats.planned,
                    "started": stats.started,
                    "skippedByCap": stats.skippedByCap,
                    "late": stats.late,
                ] as [String: Any]
            }
            return entry
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
            // Bytes the server sent, per session and per room-minute (#61 E1: the sync stream).
            "receivedBytesPerSession": perSession.map {
                ["sessions": $0.sessions, "min": $0.min, "median": $0.median, "max": $0.max] as [String: Any]
            } ?? [:],
            "receivedBytesPerRoomMinute": Double(finalTraffic.recvBytes) / Double(max(1, config.rooms))
                / (Double(max(1, totalSeconds)) / 60),
            "record": [
                "enabled": config.record,
                "roomsWritten": recordsWritten,
                "bytes": recordBytes,
                "streamFiles": streamFiles ?? 0,
                "streamWriteFailures": streamFailures,
            ] as [String: Any],
            "totalActionsSent": totalActionsSent,
            "totalActionsCompleted": totalActionsCompleted,
            // Legacy mode has no per-second pacing stats, so only the mode is reported for it.
            "pacing": config.pacing == .legacy ? ["mode": config.pacing.rawValue] as [String: Any] : [
                "mode": config.pacing.rawValue,
                "maxInFlight": config.maxInFlight,
                "peakInFlight": peakInFlight,
                "lateSeconds": periodStats.filter(\.late).count,
                "skippedByCap": periodStats.reduce(0) { $0 + $1.skippedByCap },
                "maxStartLagMs": periodStats.map { LoadTestPacing.milliseconds($0.startLag) }.max() ?? 0,
            ] as [String: Any],
        ] as [String: Any],
    ]

    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
    let filename = "server-loadtest-\(transportEncoding.message.rawValue)-record\(config.record ? "on" : "off")-rooms\(config.rooms)-ppr\(config.playersPerRoom)-steady\(steadySeconds)s-\(timestamp).json"

    saveResultsToJSON(
        results,
        filename: filename,
        loadTestConfig: [
            "phase": 1,
            "description": "No-WebSocket load test using WebSocketTransport with in-process connections; TRANSPORT_ENCODING for steady-state messages (default messagepack); JSON-only join handshake; re-evaluation recording per --record",
            "record": config.record ? "on" : "off",
            "recordDir": config.recordDir ?? NSNull(),
            "streamDir": config.streamDir ?? NSNull(),
            "tickIntervalMs": GameConfig.TICK_INTERVAL_MS,
            // Ticks between one player's inputs.
            "inputCadenceTicks": Double(1000 / GameConfig.TICK_INTERVAL_MS) / Double(max(1, config.actionsPerPlayerPerSecond)),
            "landType": config.landType,
            "rooms": config.rooms,
            "playersPerRoom": config.playersPerRoom,
            "totalSeconds": totalSeconds,
            "rampUpSeconds": config.rampUpSeconds,
            "steadySeconds": steadySeconds,
            "rampDownSeconds": config.rampDownSeconds,
            "actionsPerPlayerPerSecond": config.actionsPerPlayerPerSecond,
            "pacing": config.pacing.rawValue,
            "maxInFlight": config.maxInFlight,
            "tui": config.tui,
            "logLevel": String(describing: config.logLevel),
            "transportEncoding": [
                "message": transportEncoding.message.rawValue,
                "stateUpdate": transportEncoding.stateUpdate.rawValue,
            ],
            "enableLiveStateHashRecording": config.record,
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
