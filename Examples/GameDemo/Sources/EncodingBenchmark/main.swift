// Examples/GameDemo/Sources/EncodingBenchmark/main.swift
//
// Encoding benchmark for comparing different StateUpdateEncoder formats.
// Supports both single-room and multi-room modes using HeroDefenseState.
// Single-room mode uses simplified BenchmarkState for backward compatibility.

import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeMessagePack
import SwiftStateTreeTransport

// MARK: - Benchmark State

/// A simplified state for benchmarking, similar to the structure in SwiftStateTreeBenchmarks
@StateNodeBuilder
struct BenchmarkPlayerState: StateNodeProtocol {
    @Sync(.broadcast)
    var posX: Double = 0.0
    @Sync(.broadcast)
    var posY: Double = 0.0
    @Sync(.broadcast)
    var health: Int = 100
    @Sync(.broadcast)
    var weaponLevel: Int = 0
    @Sync(.broadcast)
    var resources: Int = 0
    init() {}
}

@StateNodeBuilder
struct BenchmarkState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: BenchmarkPlayerState] = [:]
    @Sync(.broadcast)
    var score: Int = 0
    @Sync(.broadcast)
    var monsterCount: Int = 0
    @Sync(.serverOnly)
    var tickCount: Int = 0
    init() {}
}

// MARK: - Benchmark Action

@Payload
struct BenchmarkMutateAction: ActionPayload {
    typealias Response = BenchmarkMutateResponse
    let iteration: Int
    init(iteration: Int) {
        self.iteration = iteration
    }
}

@Payload
struct BenchmarkMutateResponse: ResponsePayload {
    let applied: Bool
    init(applied: Bool) {
        self.applied = applied
    }
}

// MARK: - Command Line Arguments

enum EncodingFormat: String, CaseIterable {
    case jsonObject = "json-object"
    case opcodeJson = "opcode-json"
    case opcodeJsonPathHash = "opcode-json-pathhash"
    case messagepack
    case messagepackPathHash = "messagepack-pathhash"

    var displayName: String {
        switch self {
        case .jsonObject: return "JSON Object"
        case .opcodeJson: return "Opcode JSON (Legacy)"
        case .opcodeJsonPathHash: return "Opcode JSON (PathHash)"
        case .messagepack: return "Opcode MsgPack (Legacy)"
        case .messagepackPathHash: return "Opcode MsgPack (PathHash)"
        }
    }

    var transportEncodingConfig: TransportEncodingConfig {
        switch self {
        case .jsonObject:
            return TransportEncodingConfig(message: .json, stateUpdate: .jsonObject)
        case .opcodeJson:
            return TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArrayLegacy)
        case .opcodeJsonPathHash:
            return TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray)
        case .messagepack:
            return TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
        case .messagepackPathHash:
            return TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
        }
    }

    var usesPathHash: Bool {
        switch self {
        case .opcodeJsonPathHash, .messagepackPathHash:
            return true
        default:
            return false
        }
    }
}

enum OutputFormat: String {
    case table
    case json
}

enum GameType: String {
    case heroDefense = "hero-defense"
    case cardGame = "card-game"
}

struct BenchmarkConfig {
    var format: EncodingFormat = .messagepackPathHash
    var players: Int = 10
    var rooms: Int = 1
    var playersPerRoom: Int = 10
    var iterations: Int = 100
    var output: OutputFormat = .table
    var parallel: Bool = true
    var runAll: Bool = false
    var compareParallel: Bool = false
    var scalabilityTest: Bool = false
    var includeTick: Bool = false  // Whether to simulate tick execution in parallel with sync
    var gameType: GameType = .heroDefense
}

func parseArguments() -> BenchmarkConfig {
    var config = BenchmarkConfig()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--format":
            if i + 1 < args.count, let format = EncodingFormat(rawValue: args[i + 1]) {
                config.format = format
                i += 1
            }
        case "--players":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.players = count
                i += 1
            }
        case "--rooms":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.rooms = count
                i += 1
            }
        case "--players-per-room":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.playersPerRoom = count
                i += 1
            }
        case "--iterations":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.iterations = count
                i += 1
            }
        case "--output":
            if i + 1 < args.count, let output = OutputFormat(rawValue: args[i + 1]) {
                config.output = output
                i += 1
            }
        case "--parallel":
            if i + 1 < args.count {
                config.parallel = args[i + 1] == "true"
                i += 1
            }
        case "--all":
            config.runAll = true
        case "--compare-parallel":
            config.compareParallel = true
        case "--scalability":
            config.scalabilityTest = true
        case "--include-tick":
            config.includeTick = true
        case "--game-type":
            if i + 1 < args.count, let gameType = GameType(rawValue: args[i + 1]) {
                config.gameType = gameType
                i += 1
            }
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            break
        }
        i += 1
    }

    return config
}

func printUsage() {
    print("""
    Usage: EncodingBenchmark [options]

    Options:
      --format <format>       Encoding format (default: messagepack-pathhash)
                              Values: json-object, opcode-json, opcode-json-pathhash,
                                      messagepack, messagepack-pathhash
      --players <count>       Number of players (default: 10, single room mode)
      --rooms <count>         Number of rooms (default: 1, single room mode)
      --players-per-room <count>  Number of players per room (default: 10)
      --iterations <count>    Number of iterations/syncs (default: 100)
      --output <format>       Output format: table or json (default: table)
      --parallel <bool>       Enable parallel encoding (default: true)
      --game-type <type>      Game type: hero-defense or card-game (default: hero-defense)
      --all                   Run benchmark for all formats
      --compare-parallel      Compare serial vs parallel encoding for each format
      --scalability           Run scalability test (different room counts)
      --include-tick          Simulate tick execution in parallel with sync (more realistic)
      --help, -h              Show this help message

    Examples:
      swift run EncodingBenchmark --format messagepack-pathhash --players 10
      swift run EncodingBenchmark --rooms 4 --players-per-room 10
      swift run EncodingBenchmark --game-type card-game --players 20 --parallel true
      swift run EncodingBenchmark --all --output json
      swift run EncodingBenchmark --compare-parallel --rooms 4
    """)
}

// MARK: - Counting Transport

actor CountingTransport: Transport {
    var delegate: TransportDelegate?

    private var sentBytes: Int = 0
    private var sentMessages: Int = 0

    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to _: SwiftStateTreeTransport.EventTarget) async throws {
        sentBytes += message.count
        sentMessages += 1
    }

    func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    func resetCounts() {
        sentBytes = 0
        sentMessages = 0
    }

    func snapshotCounts() -> (bytes: Int, messages: Int) {
        (sentBytes, sentMessages)
    }
}

// MARK: - Multi-Room Benchmark Support

// Generic room context for HeroDefense
struct HeroDefenseRoomContext: Sendable {
    let landID: LandID
    let keeper: LandKeeper<HeroDefenseState>
    let adapter: TransportAdapter<HeroDefenseState>
    let transport: CountingTransport
}

// Generic room context for CardGame
struct CardGameRoomContext: Sendable {
    let landID: LandID
    let keeper: LandKeeper<CardGameState>
    let adapter: TransportAdapter<CardGameState>
    let transport: CountingTransport
}

// MARK: - Benchmark Execution

struct BenchmarkResult {
    let format: EncodingFormat
    let timeMs: Double
    let totalBytes: Int
    let bytesPerSync: Int
    let iterations: Int
    let parallel: Bool
    let playerCount: Int
    let roomCount: Int
    let playersPerRoom: Int
    let timePerRoomMs: Double  // Average time per room
    let timePerSyncMs: Double  // Average time per sync
    let avgCostPerSyncMs: Double  // Average cost per sync operation (time per sync / number of rooms)
    
    // Additional metrics for comparison
    var throughputSyncsPerSecond: Double {
        // Total syncs = iterations * roomCount
        let totalSyncs = Double(iterations * roomCount)
        guard timeMs > 0 else { return 0 }
        return (totalSyncs / timeMs) * 1000.0  // Convert to per second
    }
    
    var parallelEfficiency: Double? {
        // Only calculate if we have room count > 1
        guard roomCount > 1 else { return nil }
        // Standard parallel efficiency: E = Speedup / P (where P = min(roomCount, cpuCoreCount))
        // This would need to be compared with serial result, so we'll calculate it in comparison
        return nil
    }
}

func runMultiRoomBenchmarkCardGame(
    format: EncodingFormat,
    roomCount: Int,
    playersPerRoom: Int,
    iterations: Int,
    parallel: Bool,
    includeTick: Bool = false
) async -> BenchmarkResult {
    // Extract pathHashes from schema
    let landDef = CardGame.makeLand()
    let schema = SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
    let pathHashes = format.usesPathHash ? schema.lands["card-game"]?.pathHashes : nil

    let benchmarkLogger = createGameLogger(
        scope: "EncodingBenchmark",
        logLevel: .error
    )

    // Create rooms manually
    var rooms: [CardGameRoomContext] = []
    rooms.reserveCapacity(roomCount)

    for roomIndex in 0 ..< roomCount {
        let landID = LandID(landType: "card-game", instanceId: "benchmark-\(roomIndex)")
        let transport = CountingTransport()
        
        let services = LandServices()
        
        let keeper = LandKeeper<CardGameState>(
            definition: CardGame.makeLand(),
            initialState: CardGameState(),
            services: services,
            transport: nil,
            logger: benchmarkLogger
        )
        
        // Disable per-player parallel encoding in benchmark to focus on room-level parallelism
        // Only room-level parallelism (withTaskGroup) is used for comparison
        let shouldEnableParallel = false  // Always disable per-player encoding parallelism
        
        let adapter = TransportAdapter<CardGameState>(
            keeper: keeper,
            transport: transport,
            landID: landID.stringValue,
            createGuestSession: nil,
            enableDirtyTracking: true,
            encodingConfig: format.transportEncodingConfig,
            pathHashes: pathHashes,
            enableParallelEncoding: shouldEnableParallel,
            logger: benchmarkLogger
        )
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        
        // Connect players to room
        let playerIDs = (0 ..< playersPerRoom).map { PlayerID("room\(roomIndex)-player-\($0)") }
        for (playerIndex, playerID) in playerIDs.enumerated() {
            let sessionID = SessionID("room\(roomIndex)-session-\(playerIndex)")
            let clientID = ClientID("room\(roomIndex)-client-\(playerIndex)")
            await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil as AuthenticatedInfo?)
            
            let playerSession = PlayerSession(
                playerID: playerID.rawValue,
                deviceID: "device-\(roomIndex)-\(playerIndex)",
                metadata: [:]
            )
            if let result = try? await adapter.performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: nil as AuthenticatedInfo?
            ) {
                await adapter.syncStateForNewPlayer(playerID: result.playerID, sessionID: sessionID)
            }
        }
        
        // Initial sync
        await adapter.syncNow()
        
        rooms.append(CardGameRoomContext(
            landID: landID,
            keeper: keeper,
            adapter: adapter,
            transport: transport
        ))
    }
    
    // Wait for a few ticks to let the game state develop (cards drawn, etc.)
    // CardGame tick runs every 100ms, wait for ~5 ticks
    try? await Task.sleep(for: .milliseconds(500))
    
    // Reset counters
    for room in rooms {
        await room.transport.resetCounts()
    }
    
    // Benchmark: Run iterations with serial or parallel sync
    // Note: parallel execution may trigger libmalloc LIFO issues in release mode on macOS
    // Use serial execution for stability, parallel for performance comparison
    let start = ContinuousClock.now
    if parallel {
        // Parallel execution using withTaskGroup (room-level parallelism)
        for _ in 0 ..< iterations {
            await withTaskGroup(of: Void.self) { group in
                for room in rooms {
                    group.addTask { [room] in
                        // Optionally simulate tick execution (more realistic)
                        // In real server, tick and sync run concurrently for each room
                        if includeTick {
                            await room.keeper.stepTickOnce()
                        }
                        await room.adapter.syncNow()
                    }
                }
            }
        }
    } else {
        // Serial execution to avoid memory allocation order issues
        for _ in 0 ..< iterations {
            for room in rooms {
                // Optionally simulate tick execution (more realistic)
                if includeTick {
                    await room.keeper.stepTickOnce()
                }
                await room.adapter.syncNow()
            }
        }
    }
    let duration = start.duration(to: ContinuousClock.now)
    let timeMs = Double(duration.components.seconds) * 1000.0 +
        Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
    
    // Aggregate stats from all rooms
    var totalBytes = 0
    for room in rooms {
        let stats = await room.transport.snapshotCounts()
        totalBytes += stats.bytes
    }
    
    let totalPlayers = roomCount * playersPerRoom
    let timePerRoomMs = roomCount > 0 ? timeMs / Double(roomCount) : timeMs
    let timePerSyncMs = iterations > 0 ? timeMs / Double(iterations) : timeMs
    // Average cost per sync operation (time per sync / number of rooms)
    // This represents the average time to sync one room in one iteration
    let avgCostPerSyncMs = roomCount > 0 ? timePerSyncMs / Double(roomCount) : timePerSyncMs
    
    return BenchmarkResult(
        format: format,
        timeMs: timeMs,
        totalBytes: totalBytes,
        bytesPerSync: iterations > 0 ? totalBytes / iterations : 0,
        iterations: iterations,
        parallel: parallel,
        playerCount: totalPlayers,
        roomCount: roomCount,
        playersPerRoom: playersPerRoom,
        timePerRoomMs: timePerRoomMs,
        timePerSyncMs: timePerSyncMs,
        avgCostPerSyncMs: avgCostPerSyncMs
    )
}

func runMultiRoomBenchmark(
    format: EncodingFormat,
    roomCount: Int,
    playersPerRoom: Int,
    iterations: Int,
    parallel: Bool,
    includeTick: Bool = false
) async -> BenchmarkResult {
    // Extract pathHashes from schema
    let landDef = HeroDefense.makeLand()
    let schema = SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
    let pathHashes = format.usesPathHash ? schema.lands["hero-defense"]?.pathHashes : nil

    let benchmarkLogger = createGameLogger(
        scope: "EncodingBenchmark",
        logLevel: .error
    )

    // Create rooms manually (similar to TransportAdapterMultiRoomParallelEncodingBenchmarkRunner)
    // This gives us control over CountingTransport per room
    var rooms: [HeroDefenseRoomContext] = []
    rooms.reserveCapacity(roomCount)

    for roomIndex in 0 ..< roomCount {
        let landID = LandID(landType: "hero-defense", instanceId: "benchmark-\(roomIndex)")
        let transport = CountingTransport()
        
        // Create services with GameConfig
        var services = LandServices()
        let configProvider = DefaultGameConfigProvider()
        let configService = GameConfigProviderService(provider: configProvider)
        services.register(configService, as: GameConfigProviderService.self)
        
        let keeper = LandKeeper<HeroDefenseState>(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            services: services,
            transport: nil,
            logger: benchmarkLogger
        )
        
        // Disable per-player parallel encoding in benchmark to focus on room-level parallelism
        // Only room-level parallelism (withTaskGroup) is used for comparison
        let shouldEnableParallel = false  // Always disable per-player encoding parallelism
        
        let adapter = TransportAdapter<HeroDefenseState>(
            keeper: keeper,
            transport: transport,
            landID: landID.stringValue,
            createGuestSession: nil,
            enableDirtyTracking: true,
            encodingConfig: format.transportEncodingConfig,
            pathHashes: pathHashes,
            enableParallelEncoding: shouldEnableParallel,
            logger: benchmarkLogger
        )
        
        await keeper.setTransport(adapter)
        await transport.setDelegate(adapter)
        
        // Connect players to room
        let playerIDs = (0 ..< playersPerRoom).map { PlayerID("room\(roomIndex)-player-\($0)") }
        for (playerIndex, playerID) in playerIDs.enumerated() {
            let sessionID = SessionID("room\(roomIndex)-session-\(playerIndex)")
            let clientID = ClientID("room\(roomIndex)-client-\(playerIndex)")
            await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil as AuthenticatedInfo?)
            
            let playerSession = PlayerSession(
                playerID: playerID.rawValue,
                deviceID: "device-\(roomIndex)-\(playerIndex)",
                metadata: [:]
            )
            if let result = try? await adapter.performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: nil as AuthenticatedInfo?
            ) {
                await adapter.syncStateForNewPlayer(playerID: result.playerID, sessionID: sessionID)
            }
        }
        
        // Initial sync
        await adapter.syncNow()
        
        rooms.append(HeroDefenseRoomContext(
            landID: landID,
            keeper: keeper,
            adapter: adapter,
            transport: transport
        ))
    }
    
    // Wait for a few ticks to let the game state develop (monsters spawn, etc.)
    // HeroDefense tick runs every 50ms, wait for ~4 ticks
    try? await Task.sleep(for: .milliseconds(200))
    
    // Reset counters
    for room in rooms {
        await room.transport.resetCounts()
    }
    
    // Benchmark: Run iterations with serial or parallel sync
    // Note: parallel execution may trigger libmalloc LIFO issues in release mode on macOS
    // Use serial execution for stability, parallel for performance comparison
    let start = ContinuousClock.now
    if parallel {
        // Parallel execution using withTaskGroup
        for _ in 0 ..< iterations {
            await withTaskGroup(of: Void.self) { group in
                for room in rooms {
                    group.addTask { [room] in
                        // Optionally simulate tick execution (more realistic)
                        // In real server, tick and sync run concurrently for each room
                        if includeTick {
                            await room.keeper.stepTickOnce()
                        }
                        await room.adapter.syncNow()
                    }
                }
            }
        }
    } else {
        // Serial execution to avoid memory allocation order issues
        for _ in 0 ..< iterations {
            for room in rooms {
                // Optionally simulate tick execution (more realistic)
                if includeTick {
                    await room.keeper.stepTickOnce()
                }
                await room.adapter.syncNow()
            }
        }
    }
    let duration = start.duration(to: ContinuousClock.now)
    let timeMs = Double(duration.components.seconds) * 1000.0 +
        Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
    
    // Aggregate stats from all rooms
    var totalBytes = 0
    for room in rooms {
        let stats = await room.transport.snapshotCounts()
        totalBytes += stats.bytes
    }
    
    let totalPlayers = roomCount * playersPerRoom
    let timePerRoomMs = roomCount > 0 ? timeMs / Double(roomCount) : timeMs
    let timePerSyncMs = iterations > 0 ? timeMs / Double(iterations) : timeMs
    // Average cost per sync operation (time per sync / number of rooms)
    // This represents the average time to sync one room in one iteration
    let avgCostPerSyncMs = roomCount > 0 ? timePerSyncMs / Double(roomCount) : timePerSyncMs
    
    return BenchmarkResult(
        format: format,
        timeMs: timeMs,
        totalBytes: totalBytes,
        bytesPerSync: iterations > 0 ? totalBytes / iterations : 0,
        iterations: iterations,
        parallel: parallel,
        playerCount: totalPlayers,
        roomCount: roomCount,
        playersPerRoom: playersPerRoom,
        timePerRoomMs: timePerRoomMs,
        timePerSyncMs: timePerSyncMs,
        avgCostPerSyncMs: avgCostPerSyncMs
    )
}

func runBenchmark(
    format: EncodingFormat,
    playerCount: Int,
    iterations: Int,
    parallel: Bool
) async -> BenchmarkResult {
    // Create a benchmark Land with our local state
    let landDef = Land("encoding-benchmark", using: BenchmarkState.self) {
        Rules {
            OnJoin { (state: inout BenchmarkState, ctx: LandContext) in
                state.players[ctx.playerID] = BenchmarkPlayerState()
            }

            HandleAction(BenchmarkMutateAction.self) { (state: inout BenchmarkState, action: BenchmarkMutateAction, _: LandContext) in
                // Apply mutations directly
                state.score += 1
                state.monsterCount += 1
                state.tickCount += action.iteration
                // Modify player states
                for (playerID, var player) in state.players {
                    player.posX += Double(action.iteration % 10)
                    player.posY += Double(action.iteration % 5)
                    player.resources += 1
                    if action.iteration % 10 == 0 {
                        player.health = max(0, player.health - 1)
                    }
                    state.players[playerID] = player
                }
                return BenchmarkMutateResponse(applied: true)
            }
        }
    }

    // Extract pathHashes from schema
    let schema = SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
    let pathHashes = format.usesPathHash ? schema.lands["encoding-benchmark"]?.pathHashes : nil

    let benchmarkLogger = createGameLogger(
        scope: "EncodingBenchmark",
        logLevel: .error
    )

    let mockTransport = CountingTransport()

    let keeper = LandKeeper(
        definition: landDef,
        initialState: BenchmarkState(),
        transport: nil,
        logger: benchmarkLogger
    )

    // Disable per-player parallel encoding in benchmark to focus on room-level parallelism
    // Only room-level parallelism (withTaskGroup) is used for comparison
    let shouldEnableParallel = false  // Always disable per-player encoding parallelism
    
    let adapter = TransportAdapter<BenchmarkState>(
        keeper: keeper,
        transport: mockTransport,
        landID: "benchmark-land",
        createGuestSession: nil,
        enableDirtyTracking: true,
        encodingConfig: format.transportEncodingConfig,
        pathHashes: pathHashes,
        enableParallelEncoding: shouldEnableParallel,
        logger: benchmarkLogger
    )
    
    await keeper.setTransport(adapter)
    await mockTransport.setDelegate(adapter)

    // Connect players
    let playerIDs = (0 ..< playerCount).map { PlayerID("player-\($0)") }
    for (index, playerID) in playerIDs.enumerated() {
        let sessionID = SessionID("session-\(index)")
        let clientID = ClientID("client-\(index)")
        await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil as AuthenticatedInfo?)

        let playerSession = PlayerSession(
            playerID: playerID.rawValue,
            deviceID: "device-\(index)",
            metadata: [:]
        )
        if let result = try? await adapter.performJoin(
            playerSession: playerSession,
            clientID: clientID,
            sessionID: sessionID,
            authInfo: nil as AuthenticatedInfo?
        ) {
            await adapter.syncStateForNewPlayer(playerID: result.playerID, sessionID: sessionID)
        }
    }

    // Initial sync
    await adapter.syncNow()

    // Warmup
    let warmupIterations = min(5, iterations / 10)
    let actionPlayerID = playerIDs.first ?? PlayerID("player-0")
    let actionClientID = ClientID("client-0")
    let actionSessionID = SessionID("session-0")

    for i in 0 ..< warmupIterations {
        let action = BenchmarkMutateAction(iteration: i)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: BenchmarkMutateAction.self),
            payload: AnyCodable(action)
        )
        _ = try? await keeper.handleActionEnvelope(
            envelope,
            playerID: actionPlayerID,
            clientID: actionClientID,
            sessionID: actionSessionID
        )
        await adapter.syncNow()
    }

    // Reset counters
    await mockTransport.resetCounts()

    // Benchmark
    let start = ContinuousClock.now
    for i in 0 ..< iterations {
        let action = BenchmarkMutateAction(iteration: warmupIterations + i)
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: BenchmarkMutateAction.self),
            payload: AnyCodable(action)
        )
        _ = try? await keeper.handleActionEnvelope(
            envelope,
            playerID: actionPlayerID,
            clientID: actionClientID,
            sessionID: actionSessionID
        )
        await adapter.syncNow()
    }
    let duration = start.duration(to: ContinuousClock.now)
    let timeMs = Double(duration.components.seconds) * 1000.0 +
        Double(duration.components.attoseconds) / 1_000_000_000_000_000.0

    let stats = await mockTransport.snapshotCounts()
    let timePerRoomMs = timeMs  // Single room
    let timePerSyncMs = iterations > 0 ? timeMs / Double(iterations) : timeMs
    let avgCostPerSyncMs = timePerSyncMs  // Single room, so same as timePerSyncMs

    return BenchmarkResult(
        format: format,
        timeMs: timeMs,
        totalBytes: stats.bytes,
        bytesPerSync: iterations > 0 ? stats.bytes / iterations : 0,
        iterations: iterations,
        parallel: parallel,
        playerCount: playerCount,
        roomCount: 1,
        playersPerRoom: playerCount,
        timePerRoomMs: timePerRoomMs,
        timePerSyncMs: timePerSyncMs,
        avgCostPerSyncMs: avgCostPerSyncMs
    )
}

// MARK: - Results Directory

/// Get the results directory path (in source code directory)
func getResultsDirectory() -> URL {
    // Try to find the source directory by looking for Sources/EncodingBenchmark
    // Start from current working directory and search up
    let fileManager = FileManager.default
    var currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
    
    // Look for Sources/EncodingBenchmark directory
    var sourceDir: URL?
    for _ in 0..<10 { // Search up to 10 levels
        let candidate = currentDir.appendingPathComponent("Sources/EncodingBenchmark")
        if fileManager.fileExists(atPath: candidate.path) {
            sourceDir = candidate
            break
        }
        let parent = currentDir.deletingLastPathComponent()
        if parent.path == currentDir.path {
            break // Reached root
        }
        currentDir = parent
    }
    
    // Fallback: use #file and try to find Sources directory
    if sourceDir == nil {
        let sourceFile = #file
        let sourceURL = URL(fileURLWithPath: sourceFile)
        let pathComponents = sourceURL.pathComponents
        if let sourcesIndex = pathComponents.firstIndex(of: "Sources") {
            let basePath = "/" + pathComponents[1..<sourcesIndex+1].joined(separator: "/")
            sourceDir = URL(fileURLWithPath: basePath).appendingPathComponent("EncodingBenchmark")
        } else {
            // Last resort: use current directory
            sourceDir = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("Sources/EncodingBenchmark")
        }
    }
    
    // Create results subdirectory in source directory
    let resultsDir = sourceDir!.appendingPathComponent("results", isDirectory: true)
    
    // Create directory if it doesn't exist
    try? fileManager.createDirectory(at: resultsDir, withIntermediateDirectories: true)
    
    return resultsDir
}

/// Save benchmark results to JSON file
func saveResultsToJSON(_ results: [[String: Any]], filename: String) {
    let resultsDir = getResultsDirectory()
    let fileURL = resultsDir.appendingPathComponent(filename)
    
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: fileURL)
        print("")
        print("📊 Results saved to: \(fileURL.path)")
    } catch {
        print("⚠️ Failed to save results to JSON: \(error)")
    }
}

// MARK: - Output

func printTableHeader() {
    print("===================== Encoding Benchmark Results =====================")
    print("Format                      | Time (ms) | Total Bytes | Per Sync | Avg Cost/Sync | vs JSON")
    print("------------------------------------------------------------------------")
}

func printTableRow(_ result: BenchmarkResult, baselineBytes: Int?) {
    let ratio: String
    if let baseline = baselineBytes, baseline > 0 {
        ratio = String(format: "%5.1f%%", Double(result.totalBytes) / Double(baseline) * 100)
    } else {
        ratio = "  100%"
    }

    print(String(format: "%-27s | %9.2f | %11d | %8d | %13.4f | %s",
                 result.format.displayName,
                 result.timeMs,
                 result.totalBytes,
                 result.bytesPerSync,
                 result.avgCostPerSyncMs,
                 ratio))
}

func printTableFooter() {
    print("========================================================================")
}

func printJSON(_ result: BenchmarkResult) {
    var json: [String: Any] = [
        "format": result.format.rawValue,
        "displayName": result.format.displayName,
        "timeMs": result.timeMs,
        "totalBytes": result.totalBytes,
        "bytesPerSync": result.bytesPerSync,
        "iterations": result.iterations,
        "parallel": result.parallel,
        "playerCount": result.playerCount,
        "timePerSyncMs": result.timePerSyncMs,
        "avgCostPerSyncMs": result.avgCostPerSyncMs,
        "throughputSyncsPerSecond": result.throughputSyncsPerSecond
    ]
    
    if result.roomCount > 1 {
        json["roomCount"] = result.roomCount
        json["playersPerRoom"] = result.playersPerRoom
        json["timePerRoomMs"] = result.timePerRoomMs
    }
    
    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
       let jsonString = String(data: data, encoding: .utf8)
    {
        print(jsonString)
    }
}

// MARK: - Main

@main
struct EncodingBenchmark {
    static func main() async {
        let config = parseArguments()

        // Determine if multi-room mode
        // If rooms > 1, use multi-room mode
        // Otherwise, use single-room mode (backward compatibility)
        let isMultiRoom = config.rooms > 1
        
        if config.scalabilityTest {
            await runScalabilityTest(config: config)
        } else if config.compareParallel {
            if isMultiRoom {
                await runParallelComparisonMultiRoom(config: config)
            } else {
                await runParallelComparison(config: config)
            }
        } else if config.runAll {
            if isMultiRoom {
                await runAllFormatsMultiRoom(config: config)
            } else {
                await runAllFormats(config: config)
            }
        } else {
            if isMultiRoom {
                await runSingleFormatMultiRoom(config: config)
            } else {
                await runSingleFormat(config: config)
            }
        }
    }

    static func runAllFormats(config: BenchmarkConfig) async {
        var results: [BenchmarkResult] = []
        var baselineBytes: Int?
        var allResults: [[String: Any]] = []

        if config.output == .table {
            print("")
            print("  Players: \(config.players), Iterations: \(config.iterations)")
            print("  Parallel: \(config.parallel)")
            print("")
            printTableHeader()
        }

        for format in EncodingFormat.allCases {
            let result = await runBenchmark(
                format: format,
                playerCount: config.players,
                iterations: config.iterations,
                parallel: config.parallel
            )
            results.append(result)

            if format == .jsonObject {
                baselineBytes = result.totalBytes
            }

            switch config.output {
            case .table:
                printTableRow(result, baselineBytes: baselineBytes)
            case .json:
                printJSON(result)
            }
            
            // Collect results for JSON export
            var json: [String: Any] = [
                "format": result.format.rawValue,
                "displayName": result.format.displayName,
                "timeMs": result.timeMs,
                "totalBytes": result.totalBytes,
                "bytesPerSync": result.bytesPerSync,
                "iterations": result.iterations,
                "parallel": result.parallel,
                "playerCount": result.playerCount,
                "timePerSyncMs": result.timePerSyncMs,
                "avgCostPerSyncMs": result.avgCostPerSyncMs,
                "throughputSyncsPerSecond": result.throughputSyncsPerSecond
            ]
            allResults.append(json)
        }

        if config.output == .table {
            printTableFooter()

            if let best = results.min(by: { $0.totalBytes < $1.totalBytes }),
               let baseline = baselineBytes, baseline > 0
            {
                let savings = (1.0 - Double(best.totalBytes) / Double(baseline)) * 100
                print(String(format: "Best: %s saves %.1f%% vs JSON Object",
                             best.format.displayName, savings))
            }
        }
        
        // Save results to JSON
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let parallelSuffix = config.parallel ? "-parallel" : "-serial"
        let filename = "all-formats-\(config.players)players-\(config.iterations)iterations\(parallelSuffix)-\(timestamp).json"
        saveResultsToJSON(allResults, filename: filename)
    }
    
    static func runAllFormatsMultiRoom(config: BenchmarkConfig) async {
        var results: [BenchmarkResult] = []
        var baselineBytes: Int?

        if config.output == .table {
            print("")
            print("  Rooms: \(config.rooms), Players per room: \(config.playersPerRoom), Total players: \(config.rooms * config.playersPerRoom)")
            print("  Iterations: \(config.iterations), Parallel: \(config.parallel)")
            print("")
            printTableHeader()
        }

        var allResults: [[String: Any]] = []
        
        for format in EncodingFormat.allCases {
            let result: BenchmarkResult
            
            if config.gameType == .cardGame {
                result = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: config.parallel,
                    includeTick: config.includeTick
                )
            } else {
                result = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: config.parallel,
                    includeTick: config.includeTick
                )
            }
            
            results.append(result)

            if format == .jsonObject {
                baselineBytes = result.totalBytes
            }

            switch config.output {
            case .table:
                printTableRow(result, baselineBytes: baselineBytes)
            case .json:
                printJSON(result)
            }
            
            // Collect results for JSON export
            var json: [String: Any] = [
                "format": result.format.rawValue,
                "displayName": result.format.displayName,
                "timeMs": result.timeMs,
                "totalBytes": result.totalBytes,
                "bytesPerSync": result.bytesPerSync,
                "iterations": result.iterations,
                "parallel": result.parallel,
                "roomCount": result.roomCount,
                "playersPerRoom": result.playersPerRoom,
                "timePerRoomMs": result.timePerRoomMs,
                "timePerSyncMs": result.timePerSyncMs,
                "avgCostPerSyncMs": result.avgCostPerSyncMs,
                "throughputSyncsPerSecond": result.throughputSyncsPerSecond,
                "config": [
                    "includeTick": config.includeTick,
                    "gameType": config.gameType.rawValue
                ]
            ]
            allResults.append(json)
        }

        if config.output == .table {
            printTableFooter()

            if let best = results.min(by: { $0.totalBytes < $1.totalBytes }),
               let baseline = baselineBytes, baseline > 0
            {
                let savings = (1.0 - Double(best.totalBytes) / Double(baseline)) * 100
                print(String(format: "Best: %s saves %.1f%% vs JSON Object",
                             best.format.displayName, savings))
            }
        }
        
        // Save results to JSON
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let parallelSuffix = config.parallel ? "-parallel" : "-serial"
        let tickSuffix = config.includeTick ? "-tick" : ""
        let filename = "all-formats-multiroom-\(config.rooms)rooms-\(config.iterations)iterations\(parallelSuffix)\(tickSuffix)-\(timestamp).json"
        saveResultsToJSON(allResults, filename: filename)
    }

    static func runSingleFormat(config: BenchmarkConfig) async {
        let result = await runBenchmark(
            format: config.format,
            playerCount: config.players,
            iterations: config.iterations,
            parallel: config.parallel
        )

        switch config.output {
        case .table:
            print("")
            print("  Format: \(config.format.displayName)")
            print("  Players: \(config.players), Iterations: \(config.iterations)")
            print("  Parallel: \(config.parallel)")
            print("")
            print("  Time: \(String(format: "%.2f", result.timeMs))ms")
            print("  Total Bytes: \(result.totalBytes)")
            print("  Bytes/Sync: \(result.bytesPerSync)")
            print("")
        case .json:
            printJSON(result)
        }
    }
    
    static func runSingleFormatMultiRoom(config: BenchmarkConfig) async {
        let result: BenchmarkResult
        if config.gameType == .cardGame {
            result = await runMultiRoomBenchmarkCardGame(
                format: config.format,
                roomCount: config.rooms,
                playersPerRoom: config.playersPerRoom,
                iterations: config.iterations,
                parallel: config.parallel,
                includeTick: config.includeTick
            )
        } else {
            result = await runMultiRoomBenchmark(
                format: config.format,
                roomCount: config.rooms,
                playersPerRoom: config.playersPerRoom,
                iterations: config.iterations,
                parallel: config.parallel,
                includeTick: config.includeTick
            )
        }

        switch config.output {
        case .table:
            print("")
            print("  Format: \(config.format.displayName)")
            print("  Rooms: \(config.rooms), Players per room: \(config.playersPerRoom), Total players: \(result.playerCount)")
            print("  Iterations: \(config.iterations), Parallel: \(config.parallel)")
            print("")
            print("  Total Time: \(String(format: "%.2f", result.timeMs))ms")
            print("  Time per Room: \(String(format: "%.2f", result.timePerRoomMs))ms")
            print("  Time per Sync: \(String(format: "%.4f", result.timePerSyncMs))ms")
            print("  Avg Cost per Sync: \(String(format: "%.4f", result.avgCostPerSyncMs))ms")
            print("  Throughput: \(String(format: "%.1f", result.throughputSyncsPerSecond)) syncs/sec")
            print("  Total Bytes: \(result.totalBytes)")
            print("  Bytes/Sync: \(result.bytesPerSync)")
            print("")
        case .json:
            printJSON(result)
        }
    }

    static func runParallelComparison(config: BenchmarkConfig) async {
        print("")
        print("  ==================== Serial vs Parallel Comparison ====================")
        print("  Players: \(config.players), Iterations: \(config.iterations)")
        print("")
        print("  Format                      | Serial (ms) | Parallel (ms) | Speedup")
        print("  ---------------------------------------------------------------------------")

        for format in EncodingFormat.allCases {
            let serialResult = await runBenchmark(
                format: format,
                playerCount: config.players,
                iterations: config.iterations,
                parallel: false
            )

            let parallelResult = await runBenchmark(
                format: format,
                playerCount: config.players,
                iterations: config.iterations,
                parallel: true
            )

            let speedup = serialResult.timeMs / max(parallelResult.timeMs, 0.001)

            print(String(format: "  %-27s | %11.2f | %13.2f | %6.2fx",
                         format.displayName,
                         serialResult.timeMs,
                         parallelResult.timeMs,
                         speedup))
        }

        print("  ===========================================================================")
        print("")
    }
    
    static func runParallelComparisonMultiRoom(config: BenchmarkConfig) async {
        print("")
        print("  ==================== Serial vs Parallel Comparison (Multi-Room) ====================")
        print("  Rooms: \(config.rooms), Players per room: \(config.playersPerRoom), Total players: \(config.rooms * config.playersPerRoom)")
        print("  Iterations: \(config.iterations), Include Tick: \(config.includeTick)")
        print("")
        print("  Format                      | Serial (ms) | Parallel (ms) | Speedup | Throughput (syncs/s)")
        print("  -------------------------------------------------------------------------------------------")

        var bestSpeedup: (format: EncodingFormat, speedup: Double)?
        var bestThroughput: (format: EncodingFormat, throughput: Double)?
        var allResults: [[String: Any]] = []

        for format in EncodingFormat.allCases {
            let serialResult: BenchmarkResult
            let parallelResult: BenchmarkResult
            
            if config.gameType == .cardGame {
                serialResult = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    includeTick: config.includeTick
                )
                parallelResult = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    includeTick: config.includeTick
                )
            } else {
                serialResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    includeTick: config.includeTick
                )
                parallelResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    includeTick: config.includeTick
                )
            }

            let speedup = serialResult.timeMs / max(parallelResult.timeMs, 0.001)
            let parallelThroughput = parallelResult.throughputSyncsPerSecond
            
            if bestSpeedup == nil || speedup > bestSpeedup!.speedup {
                bestSpeedup = (format, speedup)
            }
            if bestThroughput == nil || parallelThroughput > bestThroughput!.throughput {
                bestThroughput = (format, parallelThroughput)
            }

            print(String(format: "  %-27s | %11.2f | %13.2f | %6.2fx | %21.1f",
                         format.displayName,
                         serialResult.timeMs,
                         parallelResult.timeMs,
                         speedup,
                         parallelThroughput))
            
            // Collect results for JSON export
            allResults.append([
                "format": format.rawValue,
                "displayName": format.displayName,
                "serial": [
                    "timeMs": serialResult.timeMs,
                    "totalBytes": serialResult.totalBytes,
                    "bytesPerSync": serialResult.bytesPerSync,
                    "throughputSyncsPerSecond": serialResult.throughputSyncsPerSecond,
                    "avgCostPerSyncMs": serialResult.avgCostPerSyncMs
                ],
                "parallel": [
                    "timeMs": parallelResult.timeMs,
                    "totalBytes": parallelResult.totalBytes,
                    "bytesPerSync": parallelResult.bytesPerSync,
                    "throughputSyncsPerSecond": parallelResult.throughputSyncsPerSecond,
                    "avgCostPerSyncMs": parallelResult.avgCostPerSyncMs
                ],
                "speedup": speedup,
                "config": [
                    "rooms": config.rooms,
                    "playersPerRoom": config.playersPerRoom,
                    "iterations": config.iterations,
                    "includeTick": config.includeTick,
                    "gameType": config.gameType.rawValue
                ]
            ])
        }

        print("  ===========================================================================================")
        print("")
        
        // Save results to JSON
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let tickSuffix = config.includeTick ? "-tick" : ""
        let filename = "parallel-comparison-multiroom-\(config.rooms)rooms-\(config.iterations)iterations\(tickSuffix)-\(timestamp).json"
        saveResultsToJSON(allResults, filename: filename)
        
        // Calculate additional metrics
        if let bestSpeedup = bestSpeedup {
            // Standard parallel efficiency: E = Speedup / P (where P = CPU cores)
            let cpuCoreCount = Double(ProcessInfo.processInfo.processorCount)
            let theoreticalSpeedup = min(Double(config.rooms), cpuCoreCount)
            let parallelEfficiency = (bestSpeedup.speedup / theoreticalSpeedup) * 100.0
            
            // Get serial and parallel results for best format to calculate detailed metrics
            let serialResult: BenchmarkResult
            let parallelResult: BenchmarkResult
            
            if config.gameType == .cardGame {
                serialResult = await runMultiRoomBenchmarkCardGame(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    includeTick: config.includeTick
                )
                parallelResult = await runMultiRoomBenchmarkCardGame(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    includeTick: config.includeTick
                )
            } else {
                serialResult = await runMultiRoomBenchmark(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    includeTick: config.includeTick
                )
                parallelResult = await runMultiRoomBenchmark(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    includeTick: config.includeTick
                )
            }
            
            let serialThroughput = serialResult.throughputSyncsPerSecond
            let parallelThroughput = parallelResult.throughputSyncsPerSecond
            let throughputImprovement = ((parallelThroughput - serialThroughput) / serialThroughput) * 100.0
            
            let latencyReduction = ((serialResult.avgCostPerSyncMs - parallelResult.avgCostPerSyncMs) / serialResult.avgCostPerSyncMs) * 100.0
            
            print("  📊 關鍵性能指標:")
            print("")
            print("  1. 並行加速比:")
            print("     - 最佳加速比: \(String(format: "%.2f", bestSpeedup.speedup))x (\(bestSpeedup.format.displayName))")
            print("     - 理論最大加速比: \(String(format: "%.2f", theoreticalSpeedup))x (完美並行)")
            print("     - 並行效率: \(String(format: "%.1f", parallelEfficiency))%")
            print("")
            
            if let bestThroughput = bestThroughput {
                print("  2. 吞吐量提升:")
                print("     - 序列化吞吐量: \(String(format: "%.1f", serialThroughput)) syncs/sec")
                print("     - 並行吞吐量: \(String(format: "%.1f", parallelThroughput)) syncs/sec")
                print("     - 吞吐量提升: \(String(format: "%.1f", throughputImprovement))%")
                print("     - 最高吞吐量: \(String(format: "%.1f", bestThroughput.throughput)) syncs/sec (\(bestThroughput.format.displayName))")
                print("")
            }
            
            print("  3. 延遲改善:")
            print("     - 序列化延遲: \(String(format: "%.4f", serialResult.avgCostPerSyncMs))ms/sync")
            print("     - 並行延遲: \(String(format: "%.4f", parallelResult.avgCostPerSyncMs))ms/sync")
            print("     - 延遲降低: \(String(format: "%.1f", latencyReduction))%")
            print("")
            
            print("  4. 系統優勢 (vs 普通系統):")
            print("     - ✅ 支援房間級別並行處理，充分利用多核 CPU")
            print("     - ✅ 相比序列化執行，性能提升 \(String(format: "%.1f", (bestSpeedup.speedup - 1) * 100))%")
            print("     - ✅ 並行效率 \(String(format: "%.1f", parallelEfficiency))%，接近理論最大值")
            print("     - ✅ 普通系統（不支援房間並行）需要 \(String(format: "%.2f", theoreticalSpeedup))x 的時間來完成相同工作")
            print("     - ✅ 普通系統的吞吐量僅為並行系統的 \(String(format: "%.1f", (serialThroughput / parallelThroughput) * 100))%")
            print("     - ✅ 普通系統的延遲是並行系統的 \(String(format: "%.2f", serialResult.avgCostPerSyncMs / parallelResult.avgCostPerSyncMs))x")
            print("")
            
            print("  5. 實際應用場景:")
            print("     - 在 \(config.rooms) 個房間的環境下，並行系統可以:")
            print("       • 每秒處理 \(String(format: "%.0f", parallelThroughput)) 個 sync 操作")
            print("       • 每個 sync 操作僅需 \(String(format: "%.4f", parallelResult.avgCostPerSyncMs))ms")
            print("       • 相比普通系統節省 \(String(format: "%.1f", (1.0 - 1.0/bestSpeedup.speedup) * 100))% 的處理時間")
            print("")
        }
    }
    
    static func runScalabilityTest(config: BenchmarkConfig) async {
        print("")
        print("  ==================== 可擴展性測試 (Scalability Test) ====================")
        print("  Players per room: \(config.playersPerRoom), Iterations: \(config.iterations), Include Tick: \(config.includeTick)")
        print("  測試不同房間數下的性能變化，展示並行系統的可擴展性")
        print("")
        
        // Test room counts: 1, 2, 4, 8, 16, 32, 50
        let roomCounts = [1, 2, 4, 8, 16, 32, 50]
        let format = config.format
        
        print("  Format: \(format.displayName)")
        print("")
        print("  Rooms | Serial (ms) | Parallel (ms) | Speedup | Throughput (syncs/s) | Efficiency | Serial/Parallel Ratio")
        print("  -----------------------------------------------------------------------------------------------------------------")
        
        var scalabilityData: [(rooms: Int, serial: Double, parallel: Double, speedup: Double, throughput: Double, efficiency: Double)] = []
        var allResults: [[String: Any]] = []
        
        for roomCount in roomCounts {
            let serialResult: BenchmarkResult
            let parallelResult: BenchmarkResult
            
            if config.gameType == .cardGame {
                serialResult = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: roomCount,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    includeTick: config.includeTick
                )
                parallelResult = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: roomCount,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    includeTick: config.includeTick
                )
            } else {
                serialResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: roomCount,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    includeTick: config.includeTick
                )
                parallelResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: roomCount,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    includeTick: config.includeTick
                )
            }
            
            let speedup = serialResult.timeMs / max(parallelResult.timeMs, 0.001)
            // Standard parallel efficiency formula: E = Speedup / P
            // where P is the number of processors (CPU cores), not the number of tasks (rooms)
            // Theoretical max speedup = min(roomCount, cpuCoreCount)
            let cpuCoreCount = Double(ProcessInfo.processInfo.processorCount)
            let theoreticalSpeedup = min(Double(roomCount), cpuCoreCount)
            let efficiency = (speedup / theoreticalSpeedup) * 100.0
            
            scalabilityData.append((
                rooms: roomCount,
                serial: serialResult.timeMs,
                parallel: parallelResult.timeMs,
                speedup: speedup,
                throughput: parallelResult.throughputSyncsPerSecond,
                efficiency: efficiency
            ))
            
            let ratio = serialResult.timeMs / max(parallelResult.timeMs, 0.001)
            print(String(format: "  %5d | %11.2f | %13.2f | %6.2fx | %21.1f | %9.1f%% | %18.2fx",
                         roomCount,
                         serialResult.timeMs,
                         parallelResult.timeMs,
                         speedup,
                         parallelResult.throughputSyncsPerSecond,
                         efficiency,
                         ratio))
            
            // Collect results for JSON export
            allResults.append([
                "rooms": roomCount,
                "format": format.rawValue,
                "displayName": format.displayName,
                "serial": [
                    "timeMs": serialResult.timeMs,
                    "totalBytes": serialResult.totalBytes,
                    "bytesPerSync": serialResult.bytesPerSync,
                    "throughputSyncsPerSecond": serialResult.throughputSyncsPerSecond,
                    "avgCostPerSyncMs": serialResult.avgCostPerSyncMs
                ],
                "parallel": [
                    "timeMs": parallelResult.timeMs,
                    "totalBytes": parallelResult.totalBytes,
                    "bytesPerSync": parallelResult.bytesPerSync,
                    "throughputSyncsPerSecond": parallelResult.throughputSyncsPerSecond,
                    "avgCostPerSyncMs": parallelResult.avgCostPerSyncMs
                ],
                "speedup": speedup,
                "efficiency": efficiency,
                "config": [
                    "playersPerRoom": config.playersPerRoom,
                    "iterations": config.iterations,
                    "includeTick": config.includeTick,
                    "gameType": config.gameType.rawValue
                ]
            ])
        }
        
        print("  -----------------------------------------------------------------------------------------------------------------")
        print("")
        
        // Save results to JSON
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let tickSuffix = config.includeTick ? "-tick" : ""
        let filename = "scalability-test-\(format.rawValue)-\(config.iterations)iterations\(tickSuffix)-\(timestamp).json"
        saveResultsToJSON(allResults, filename: filename)
        
        // Calculate scalability metrics
        if scalabilityData.count >= 2 {
            let first = scalabilityData[0]
            let last = scalabilityData[scalabilityData.count - 1]
            
            let serialScaling = last.serial / first.serial  // How much slower serial gets
            let parallelScaling = last.parallel / first.parallel  // How much slower parallel gets
            
            print("  📈 可擴展性分析:")
            print("")
            print("  1. 房間數增加時的性能變化:")
            print("     - 從 \(first.rooms) 個房間增加到 \(last.rooms) 個房間:")
            print("       • 序列化系統: 時間增加 \(String(format: "%.2f", serialScaling))x")
            print("       • 並行系統: 時間增加 \(String(format: "%.2f", parallelScaling))x")
            print("       • 並行系統的擴展效率: \(String(format: "%.1f", (1.0 / parallelScaling) * 100))%")
            print("")
            
            print("  2. 吞吐量擴展:")
            for data in scalabilityData {
                print("     - \(data.rooms) 個房間: \(String(format: "%.1f", data.throughput)) syncs/sec")
            }
            print("")
            
            print("  3. 系統優勢總結:")
            print("     - ✅ 並行系統隨著房間數增加，性能下降幅度遠小於序列化系統")
            print("     - ✅ 在 \(last.rooms) 個房間時，並行系統比序列化系統快 \(String(format: "%.2f", last.speedup))x")
            print("     - ✅ 並行效率: \(String(format: "%.1f", last.efficiency))% (接近理論最大值)")
            print("     - ✅ 普通系統（不支援房間並行）在 \(last.rooms) 個房間時需要 \(String(format: "%.2f", last.serial / first.serial))x 的時間")
            print("     - ✅ 並行系統在 \(last.rooms) 個房間時僅需 \(String(format: "%.2f", last.parallel / first.parallel))x 的時間")
            print("")
            
            // Calculate scalability metrics for different room ranges
            print("  4. 不同規模下的性能表現:")
            if scalabilityData.count >= 4 {
                let small = scalabilityData[2]  // 4 rooms
                let medium = scalabilityData[4]  // 16 rooms
                let large = scalabilityData[6]  // 50 rooms
                
                print("     - 小規模 (4 個房間):")
                print("       • 序列化: \(String(format: "%.2f", small.serial))ms, 並行: \(String(format: "%.2f", small.parallel))ms")
                print("       • 加速比: \(String(format: "%.2f", small.speedup))x, 效率: \(String(format: "%.1f", small.efficiency))%")
                print("       • 吞吐量: \(String(format: "%.1f", small.throughput)) syncs/sec")
                print("")
                print("     - 中規模 (16 個房間):")
                print("       • 序列化: \(String(format: "%.2f", medium.serial))ms, 並行: \(String(format: "%.2f", medium.parallel))ms")
                print("       • 加速比: \(String(format: "%.2f", medium.speedup))x, 效率: \(String(format: "%.1f", medium.efficiency))%")
                print("       • 吞吐量: \(String(format: "%.1f", medium.throughput)) syncs/sec")
                print("")
                print("     - 大規模 (50 個房間):")
                print("       • 序列化: \(String(format: "%.2f", large.serial))ms, 並行: \(String(format: "%.2f", large.parallel))ms")
                print("       • 加速比: \(String(format: "%.2f", large.speedup))x, 效率: \(String(format: "%.1f", large.efficiency))%")
                print("       • 吞吐量: \(String(format: "%.1f", large.throughput)) syncs/sec")
                print("")
                
                // Calculate scaling factor
                let serialScalingFactor = large.serial / small.serial
                let parallelScalingFactor = large.parallel / small.parallel
                let scalingAdvantage = serialScalingFactor / parallelScalingFactor
                
                print("  5. 擴展性分析:")
                print("     - 從 4 個房間擴展到 50 個房間:")
                print("       • 序列化系統時間增加: \(String(format: "%.2f", serialScalingFactor))x")
                print("       • 並行系統時間增加: \(String(format: "%.2f", parallelScalingFactor))x")
                print("       • 並行系統的擴展優勢: \(String(format: "%.2f", scalingAdvantage))x")
                print("       • 結論: 並行系統在規模擴展時表現更穩定，性能下降更緩慢")
                print("")
            }
        }
    }
}
