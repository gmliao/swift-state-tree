// Examples/GameDemo/Sources/ServerLoadTest/main.swift
//
// MessagePack server load test (Phase 1: no real WebSocket, focus on CPU architecture).
// Uses in-memory connections to isolate server-side performance.
// External monitoring (vmstat/pidstat) via shell script for CPU/RAM metrics.

import Foundation
import GameContent
import Logging
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - CLI

struct LoadTestConfig: Sendable {
    var landType: String = "hero-defense"
    var rooms: Int = 500
    var playersPerRoom: Int = 5
    var durationSeconds: Int = 30
    var rampUpSeconds: Int = 5
    var rampDownSeconds: Int = 5
    var actionsPerPlayerPerSecond: Int = 1
    var tui: Bool = false  // Deprecated: TUI removed, using Logger instead
    var logLevel: Logger.Level = .info  // Set to .info to show progress logs
}

func parseArguments() -> LoadTestConfig {
    var config = LoadTestConfig()
    var i = 1

    func readInt(_ arg: String) -> Int? { Int(arg) }
    func readBool(_ arg: String) -> Bool? {
        switch arg.lowercased() {
        case "1", "true", "yes", "y": return true
        case "0", "false", "no", "n": return false
        default: return nil
        }
    }

    while i < CommandLine.arguments.count {
        let arg = CommandLine.arguments[i]
        let next = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : nil

        switch arg {
        case "--rooms":
            if let next, let v = readInt(next) { config.rooms = v; i += 1 }
        case "--players-per-room":
            if let next, let v = readInt(next) { config.playersPerRoom = v; i += 1 }
        case "--duration-seconds":
            if let next, let v = readInt(next) { config.durationSeconds = v; i += 1 }
        case "--ramp-up-seconds":
            if let next, let v = readInt(next) { config.rampUpSeconds = v; i += 1 }
        case "--ramp-down-seconds":
            if let next, let v = readInt(next) { config.rampDownSeconds = v; i += 1 }
        case "--actions-per-player-per-second":
            if let next, let v = readInt(next) { config.actionsPerPlayerPerSecond = v; i += 1 }
        case "--tui":
            if let next, let v = readBool(next) { config.tui = v; i += 1 }
        case "--log-level":
            if let next {
                switch next.lowercased() {
                case "trace": config.logLevel = .trace
                case "debug": config.logLevel = .debug
                case "info": config.logLevel = .info
                case "notice": config.logLevel = .notice
                case "warning": config.logLevel = .warning
                case "error": config.logLevel = .error
                case "critical": config.logLevel = .critical
                default: break
                }
                i += 1
            }
        case "--help", "-h":
            printUsageAndExit()
        default:
            break
        }
        i += 1
    }

    return config
}

func printUsageAndExit() -> Never {
    print("""
    Usage: ServerLoadTest [options]

    Options:
      --rooms <count>                           Number of rooms (default: 500)
      --players-per-room <count>                 Players per room (default: 5)
      --duration-seconds <seconds>               Steady-state duration in seconds (default: 30)
      --ramp-up-seconds <seconds>                Ramp-up duration (default: 5)
      --ramp-down-seconds <seconds>              Ramp-down duration (default: 5)
      --actions-per-player-per-second <count>    Actions per player per second (default: 1)
      --tui <true|false>                         Enable TUI (deprecated, use logger instead) (default: false)
      --log-level <level>                        Log level: trace, debug, info, notice, warning, error, critical (default: info)
      --help, -h                                 Show this help message

    Examples:
      swift run -c release ServerLoadTest --rooms 500 --players-per-room 5 --duration-seconds 30
      swift run -c release ServerLoadTest --rooms 100 --players-per-room 10 --duration-seconds 60 --log-level debug
    """)
    exit(0)
}

// MARK: - Traffic Counter

actor TrafficCounter {
    private var sentBytes: Int = 0
    private var recvBytes: Int = 0
    private var sentMessages: Int = 0
    private var recvMessages: Int = 0

    func recordSent(bytes: Int) {
        sentBytes += bytes
        sentMessages += 1
    }

    func recordReceived(bytes: Int) {
        recvBytes += bytes
        recvMessages += 1
    }

    func snapshot() -> (sentBytes: Int, recvBytes: Int, sentMessages: Int, recvMessages: Int) {
        (sentBytes, recvBytes, sentMessages, recvMessages)
    }
}

struct CountingWebSocketConnection: WebSocketConnection, Sendable {
    let counter: TrafficCounter

    func send(_ data: Data) async throws {
        await counter.recordSent(bytes: data.count)
    }

    func close() async throws {}
}

// MARK: - Results

struct SecondSample: Sendable {
    let t: Int
    let roomsTarget: Int
    let roomsCreated: Int
    let roomsActiveExpected: Int
    let playersActiveExpected: Int
    let actionsSentThisSecond: Int
    let sentBytesPerSecond: Int
    let recvBytesPerSecond: Int
    let sentMessagesPerSecond: Int
    let recvMessagesPerSecond: Int
    let processCPUSeconds: Double?
    let processRSSBytes: UInt64?
}

struct LoadTestSummary: Sendable {
    let totalSeconds: Int
    let rampUpSeconds: Int
    let steadySeconds: Int
    let rampDownSeconds: Int
    let roomsTarget: Int
    let roomsCreated: Int
    let playersCreated: Int
    let totalSentBytes: Int
    let totalReceivedBytes: Int
    let totalSentMessages: Int
    let totalReceivedMessages: Int
    let peakRSSBytes: UInt64?
    let endRSSBytes: UInt64?

    var avgSentBytesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSentBytes) / Double(totalSeconds)
    }

    var avgRecvBytesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalReceivedBytes) / Double(totalSeconds)
    }

    var avgSentMessagesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalSentMessages) / Double(totalSeconds)
    }

    var avgRecvMessagesPerSecond: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalReceivedMessages) / Double(totalSeconds)
    }
}

// MARK: - System Utilities

func buildConfigurationName() -> String {
#if DEBUG
    return "debug"
#else
    return "release"
#endif
}

func runCommandCaptureStdout(_ arguments: [String]) -> String? {
    guard let executable = arguments.first else { return nil }
    let candidates = ["/usr/bin/\(executable)", "/bin/\(executable)", executable]
    for candidate in candidates {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: candidate)
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                return output
            }
        } catch {
            continue
        }
    }
    return nil
}

func unameInfo() -> [String: String] {
    var uts = utsname()
    uname(&uts)

    func toString(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        let bytes = mirror.children.compactMap { $0.value as? Int8 }
        let data = Data(bytes.map { UInt8(bitPattern: $0) })
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? ""
    }

    return [
        "sysname": toString(uts.sysname),
        "nodename": toString(uts.nodename),
        "release": toString(uts.release),
        "version": toString(uts.version),
        "machine": toString(uts.machine),
    ]
}

// MARK: - Results Management

func getResultsDirectory() -> URL {
    let fileManager = FileManager.default
    var currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)

    // Look for GameDemo directory (where Package.swift is)
    var gameDemoDir: URL?
    for _ in 0..<10 {
        if fileManager.fileExists(atPath: currentDir.appendingPathComponent("Package.swift").path) {
            gameDemoDir = currentDir
            break
        }
        let parent = currentDir.deletingLastPathComponent()
        if parent.path == currentDir.path {
            break
        }
        currentDir = parent
    }

    // Fallback: try to locate via #file
    if gameDemoDir == nil {
        let sourceFile = #file
        let sourceURL = URL(fileURLWithPath: sourceFile)
        // Expecting path like: /workspace/Examples/GameDemo/Sources/ServerLoadTest/main.swift
        // Go up 2 levels to reach GameDemo
        gameDemoDir = sourceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    let resultsDir = gameDemoDir!.appendingPathComponent("results/server-loadtest", isDirectory: true)
    try? fileManager.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    return resultsDir
}

func collectResultsMetadata(loadTestConfig: [String: Any]) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let uname = unameInfo()
    let cpuLogical = ProcessInfo.processInfo.processorCount
    let cpuActive = ProcessInfo.processInfo.activeProcessorCount
    let memoryMB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)

    let swiftVersion = runCommandCaptureStdout(["swift", "--version"])
        .flatMap { $0.split(separator: "\n").first.map(String.init) }

    let gitCommit = runCommandCaptureStdout(["git", "rev-parse", "HEAD"])
    let gitBranch = runCommandCaptureStdout(["git", "rev-parse", "--abbrev-ref", "HEAD"])

    return [
        "timestampUTC": iso.string(from: Date()),
        "commandLine": CommandLine.arguments,
        "build": [
            "configuration": buildConfigurationName(),
            "swiftVersion": swiftVersion as Any,
        ],
        "git": [
            "commit": gitCommit as Any,
            "branch": gitBranch as Any,
        ],
        "environment": [
            "osName": uname["sysname"] as Any,
            "kernelVersion": uname["release"] as Any,
            "arch": uname["machine"] as Any,
            "cpuLogicalCores": cpuLogical,
            "cpuActiveLogicalCores": cpuActive,
            "memoryTotalMB": memoryMB,
        ],
        "loadTestConfig": loadTestConfig,
    ]
}

func saveResultsToJSON(_ results: Any, filename: String, loadTestConfig: [String: Any]) {
    let resultsDir = getResultsDirectory()
    let fileURL = resultsDir.appendingPathComponent(filename)

    do {
        let metadata = collectResultsMetadata(loadTestConfig: loadTestConfig)
        let envelope: [String: Any] = [
            "metadata": metadata,
            "results": results,
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: fileURL)
        print("")
        print("Results saved to: \(fileURL.path)")
    } catch {
        print("Failed to save results to JSON: \(error)")
    }
}

// MARK: - Main

@main
struct ServerLoadTest {
    static func main() async throws {
        let config = parseArguments()
        let logger = createGameLogger(scope: "ServerLoadTest", logLevel: config.logLevel)

        if config.rooms == 0 || config.playersPerRoom == 0 {
            print("Nothing to do: rooms=\(config.rooms), playersPerRoom=\(config.playersPerRoom)")
            return
        }

        // Force MessagePack for phase1.
        let transportEncoding: TransportEncodingConfig = .messagepack

        // Extract pathHashes from schema for PathHash compression.
        let landDef = HeroDefense.makeLand()
        let schema = SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
        let pathHashes = schema.lands[config.landType]?.pathHashes

        // IMPORTANT: enableLiveStateHashRecording: false to prevent recorder creation
        // This avoids unnecessary memory/IO overhead in load tests
        let serverConfig = LandServerConfiguration(
            logger: logger,
            jwtConfig: nil,
            jwtValidator: nil,
            allowGuestMode: true,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: false,  // Disable re-evaluation recording
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

        let traffic = TrafficCounter()

        let joinCodec = TransportEncoding.json.makeCodec()
        let messagePackCodec = TransportEncoding.messagepack.makeCodec()

        func makeSessionID(roomIndex: Int, playerIndex: Int) -> SessionID {
            SessionID("s-\(roomIndex)-\(playerIndex)")
        }

        func makeJoinData(roomIndex: Int, playerIndex: Int) throws -> Data {
            let requestID = "join-\(roomIndex)-\(playerIndex)"
            let instanceId = "room-\(roomIndex)"
            let playerID = "p-\(roomIndex)-\(playerIndex)"
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

        func makeClientEventData(second: Int) throws -> Data {
            let target = Position2(x: Float(100 + (second % 100)), y: Float(100 + (second % 50)))
            let event = MoveToEvent(target: target)
            let anyClientEvent = AnyClientEvent(event)
            let eventMessage = TransportMessage(
                kind: .event,
                payload: .event(.fromClient(event: anyClientEvent))
            )
            return try messagePackCodec.encode(eventMessage)
        }

        // Timeline
        let steadySeconds = config.durationSeconds
        let totalSeconds = config.rampUpSeconds + steadySeconds + config.rampDownSeconds
        let roomsPerSecondUp = max(1, config.rooms / max(1, config.rampUpSeconds))
        let sessionsPerSecondDown = max(1, (config.rooms * config.playersPerRoom) / max(1, config.rampDownSeconds))

        // State
        var activeRoomCount = 0
        var connectedSessions: [SessionID] = []
        connectedSessions.reserveCapacity(config.rooms * config.playersPerRoom)

        var seconds: [SecondSample] = []
        seconds.reserveCapacity(totalSeconds + 10)

        var lastTraffic = await traffic.snapshot()
        // peakRSS tracking disabled - use external monitoring tools instead

        // Simple one-line logging per second (no TUI to avoid terminal rendering delays)
        func logProgress(sample: SecondSample) {
            let sentKB = Double(sample.sentBytesPerSecond) / 1024.0
            let recvKB = Double(sample.recvBytesPerSecond) / 1024.0
            let message = "t=\(sample.t)/\(totalSeconds) rooms=\(sample.roomsCreated)/\(sample.roomsTarget) players=\(sample.playersActiveExpected) " +
                "sent=\(String(format: "%.1f", sentKB))KB/s recv=\(String(format: "%.1f", recvKB))KB/s " +
                "msgsOut=\(sample.sentMessagesPerSecond)/s msgsIn=\(sample.recvMessagesPerSecond)/s"
            logger.info(Logger.Message(stringLiteral: message))
        }

        for t in 0..<totalSeconds {
            let isRampUp = t < config.rampUpSeconds
            let isSteady = t >= config.rampUpSeconds && t < (config.rampUpSeconds + steadySeconds)
            let isRampDown = t >= (config.rampUpSeconds + steadySeconds) && config.rampDownSeconds > 0

            var actionsSent = 0

            // Ramp up
            if isRampUp, activeRoomCount < config.rooms {
                let target = min(config.rooms, activeRoomCount + roomsPerSecondUp)
                while activeRoomCount < target {
                    let roomIndex = activeRoomCount
                    for playerIndex in 0..<config.playersPerRoom {
                        let sessionID = makeSessionID(roomIndex: roomIndex, playerIndex: playerIndex)
                        let conn = CountingWebSocketConnection(counter: traffic)
                        await transport.handleConnection(sessionID: sessionID, connection: conn, authInfo: nil)

                        let joinData = try makeJoinData(roomIndex: roomIndex, playerIndex: playerIndex)
                        await traffic.recordReceived(bytes: joinData.count)
                        await transport.handleIncomingMessage(sessionID: sessionID, data: joinData)

                        connectedSessions.append(sessionID)
                    }
                    activeRoomCount += 1
                }
            }

            // Steady + ramp down: inject client events
            if isSteady || isRampDown {
                if config.actionsPerPlayerPerSecond > 0, !connectedSessions.isEmpty {
                    let payloadData = try makeClientEventData(second: t)
                    for _ in 0..<config.actionsPerPlayerPerSecond {
                        for sessionID in connectedSessions {
                            await traffic.recordReceived(bytes: payloadData.count)
                            await transport.handleIncomingMessage(sessionID: sessionID, data: payloadData)
                            actionsSent += 1
                        }
                    }
                }
            }

            // Ramp down
            if isRampDown, !connectedSessions.isEmpty {
                let sessionsToClose = min(connectedSessions.count, sessionsPerSecondDown)
                let closing = connectedSessions.prefix(sessionsToClose)
                for sessionID in closing {
                    await transport.handleDisconnection(sessionID: sessionID)
                }
                connectedSessions.removeFirst(sessionsToClose)
            }

            // Metrics snapshot
            let nowTraffic = await traffic.snapshot()
            let sentDeltaBytes = nowTraffic.sentBytes - lastTraffic.sentBytes
            let recvDeltaBytes = nowTraffic.recvBytes - lastTraffic.recvBytes
            let sentDeltaMsgs = nowTraffic.sentMessages - lastTraffic.sentMessages
            let recvDeltaMsgs = nowTraffic.recvMessages - lastTraffic.recvMessages
            lastTraffic = nowTraffic

            // Skip CPU/RSS sampling to avoid potential blocking from system calls
            // Use external monitoring tools (pidstat/vmstat) via shell script instead
            // This keeps the test process focused on load generation without system call overhead
            let rssBytes: UInt64? = nil  // Disabled - use external monitoring
            let cpuTime: Double? = nil    // Disabled - use external monitoring
            
            let sample = SecondSample(
                t: t,
                roomsTarget: config.rooms,
                roomsCreated: activeRoomCount,
                roomsActiveExpected: Int(ceil(Double(connectedSessions.count) / Double(config.playersPerRoom))),
                playersActiveExpected: connectedSessions.count,
                actionsSentThisSecond: actionsSent,
                sentBytesPerSecond: sentDeltaBytes,
                recvBytesPerSecond: recvDeltaBytes,
                sentMessagesPerSecond: sentDeltaMsgs,
                recvMessagesPerSecond: recvDeltaMsgs,
                processCPUSeconds: cpuTime,
                processRSSBytes: rssBytes
            )
            seconds.append(sample)
            logProgress(sample: sample)

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Final cleanup
        for sessionID in connectedSessions {
            await transport.handleDisconnection(sessionID: sessionID)
        }
        connectedSessions.removeAll()

        try? await Task.sleep(nanoseconds: 6_000_000_000)

        let finalTraffic = await traffic.snapshot()
        // Skip RSS sampling - use external monitoring tools instead

        let summary = LoadTestSummary(
            totalSeconds: totalSeconds,
            rampUpSeconds: config.rampUpSeconds,
            steadySeconds: steadySeconds,
            rampDownSeconds: config.rampDownSeconds,
            roomsTarget: config.rooms,
            roomsCreated: activeRoomCount,
            playersCreated: config.rooms * config.playersPerRoom,
            totalSentBytes: finalTraffic.sentBytes,
            totalReceivedBytes: finalTraffic.recvBytes,
            totalSentMessages: finalTraffic.sentMessages,
            totalReceivedMessages: finalTraffic.recvMessages,
            peakRSSBytes: nil,  // Use external monitoring (pidstat/vmstat)
            endRSSBytes: nil    // Use external monitoring (pidstat/vmstat)
        )

        let results: [String: Any] = [
            "seconds": seconds.map { sample in
                var dict: [String: Any] = [
                    "t": sample.t,
                    "roomsTarget": sample.roomsTarget,
                    "roomsCreated": sample.roomsCreated,
                    "roomsActiveExpected": sample.roomsActiveExpected,
                    "playersActiveExpected": sample.playersActiveExpected,
                    "actionsSentThisSecond": sample.actionsSentThisSecond,
                    "sentBytesPerSecond": sample.sentBytesPerSecond,
                    "recvBytesPerSecond": sample.recvBytesPerSecond,
                    "sentMessagesPerSecond": sample.sentMessagesPerSecond,
                    "recvMessagesPerSecond": sample.recvMessagesPerSecond,
                ]
                if let cpu = sample.processCPUSeconds {
                    dict["processCPUSeconds"] = cpu
                }
                if let rss = sample.processRSSBytes {
                    dict["processRSSBytes"] = rss
                }
                return dict
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
    }
}
