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
    /// Optional list for matrix runs (e.g. "5,10"). If empty, uses `playersPerRoom`.
    var playersPerRoomList: [Int] = []
    /// Optional room counts override for scalability runs. If empty, uses default set.
    var roomCounts: [Int] = []
    var iterations: Int = 100
    var output: OutputFormat = .table
    var parallel: Bool = true
    var runAll: Bool = false
    var compareParallel: Bool = false
    var scalabilityTest: Bool = false
    /// Number of ticks to run per sync iteration. For tick=20Hz & sync=10Hz, use 2.
    /// Set to 0 to disable tick simulation.
    var ticksPerSync: Int = 0
    /// Print progress every N iterations for long-running benchmarks. Set to 0 to disable.
    var progressEvery: Int = 0
    var gameType: GameType = .heroDefense
}

func parseCSVInts(_ raw: String) -> [Int] {
    raw.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .compactMap(Int.init)
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
        case "--players-per-room-list":
            if i + 1 < args.count {
                config.playersPerRoomList = parseCSVInts(args[i + 1])
                i += 1
            }
        case "--room-counts":
            if i + 1 < args.count {
                config.roomCounts = parseCSVInts(args[i + 1])
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
            // Backward-compatible sugar: tick once per sync
            config.ticksPerSync = max(config.ticksPerSync, 1)
        case "--ticks-per-sync":
            if i + 1 < args.count, let value = Int(args[i + 1]) {
                config.ticksPerSync = max(0, value)
                i += 1
            }
        case "--progress-every":
            if i + 1 < args.count, let value = Int(args[i + 1]) {
                config.progressEvery = max(0, value)
                i += 1
            }
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
      --players-per-room-list <csv>  Players per room list for matrix runs (e.g. 5,10)
      --iterations <count>    Number of iterations/syncs (default: 100)
      --output <format>       Output format: table or json (default: table)
      --parallel <bool>       Enable parallel encoding (default: true)
      --game-type <type>      Game type: hero-defense or card-game (default: hero-defense)
      --all                   Run benchmark for all formats
      --compare-parallel      Compare serial vs parallel encoding for each format
      --scalability           Run scalability test (different room counts)
      --room-counts <csv>     Room counts override for scalability (e.g. 10,20,30,40,50)
      --include-tick          Backward-compatible: equivalent to --ticks-per-sync 1
      --ticks-per-sync <int>  Number of ticks per sync iteration (e.g. 2 for tick20/sync10)
      --progress-every <int>  Print progress every N iterations (e.g. 50); 0 disables
      --help, -h              Show this help message

    Examples:
      swift run EncodingBenchmark --format messagepack-pathhash --players 10
      swift run EncodingBenchmark --rooms 4 --players-per-room 10
      swift run EncodingBenchmark --rooms 50 --players-per-room 10 --ticks-per-sync 2
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
    ticksPerSync: Int = 0,
    progressEvery: Int = 0,
    progressLabel: String? = nil
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
            suppressMissingPathHashesWarning: !format.usesPathHash,
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
    let label = progressLabel ?? (parallel ? "parallel" : "serial")
    if parallel {
        // Parallel execution using withTaskGroup (room-level parallelism)
        for iterationIndex in 0 ..< iterations {
            await withTaskGroup(of: Void.self) { group in
                for room in rooms {
                    group.addTask { [room] in
                        if ticksPerSync > 0 {
                            for _ in 0 ..< ticksPerSync {
                                await room.keeper.stepTickOnce()
                            }
                        }
                        await room.adapter.syncNow()
                    }
                }
            }
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
            }
        }
    } else {
        // Serial execution to avoid memory allocation order issues
        for iterationIndex in 0 ..< iterations {
            for room in rooms {
                if ticksPerSync > 0 {
                    for _ in 0 ..< ticksPerSync {
                        await room.keeper.stepTickOnce()
                    }
                }
                await room.adapter.syncNow()
            }
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
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
    ticksPerSync: Int = 0,
    progressEvery: Int = 0,
    progressLabel: String? = nil
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
            suppressMissingPathHashesWarning: !format.usesPathHash,
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
    let label = progressLabel ?? (parallel ? "parallel" : "serial")
    if parallel {
        // Parallel execution using withTaskGroup
        for iterationIndex in 0 ..< iterations {
            await withTaskGroup(of: Void.self) { group in
                for room in rooms {
                    group.addTask { [room] in
                        if ticksPerSync > 0 {
                            for _ in 0 ..< ticksPerSync {
                                await room.keeper.stepTickOnce()
                            }
                        }
                        await room.adapter.syncNow()
                    }
                }
            }
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
            }
        }
    } else {
        // Serial execution to avoid memory allocation order issues
        for iterationIndex in 0 ..< iterations {
            for room in rooms {
                if ticksPerSync > 0 {
                    for _ in 0 ..< ticksPerSync {
                        await room.keeper.stepTickOnce()
                    }
                }
                await room.adapter.syncNow()
            }
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
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
        suppressMissingPathHashesWarning: !format.usesPathHash,
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

// MARK: - Results Metadata

func runCommandCaptureStdout(_ launchPath: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}

func runCommandCaptureStdout(_ arguments: [String]) -> String? {
    guard let executable = arguments.first else { return nil }
    // Resolve common executables via PATH by trying /usr/bin and /bin first, then raw.
    let candidates = ["/usr/bin/\(executable)", "/bin/\(executable)", executable]
    for candidate in candidates {
        let output = runCommandCaptureStdout(candidate, Array(arguments.dropFirst()))
        if let output, !output.isEmpty {
            return output
        }
    }
    return nil
}

func readTextFile(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

func detectWSL() -> Bool {
    if ProcessInfo.processInfo.environment["WSL_INTEROP"] != nil { return true }
    if let osrelease = readTextFile("/proc/sys/kernel/osrelease"),
       osrelease.lowercased().contains("microsoft") { return true }
    return false
}

func detectContainer() -> Bool {
    if FileManager.default.fileExists(atPath: "/.dockerenv") { return true }
    if let cgroup = readTextFile("/proc/1/cgroup")?.lowercased() {
        if cgroup.contains("docker") || cgroup.contains("containerd") || cgroup.contains("kubepods") { return true }
    }
    return false
}

func cpuModelName() -> String? {
    guard let cpuinfo = readTextFile("/proc/cpuinfo") else { return nil }
    for line in cpuinfo.split(separator: "\n") {
        if line.lowercased().hasPrefix("model name") {
            return line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

func cpuPhysicalCoresHint() -> Int? {
    // Best-effort on Linux: use the first 'cpu cores' entry.
    guard let cpuinfo = readTextFile("/proc/cpuinfo") else { return nil }
    for line in cpuinfo.split(separator: "\n") {
        if line.lowercased().hasPrefix("cpu cores") {
            if let value = line.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let cores = Int(value)
            {
                return cores
            }
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
        "machine": toString(uts.machine)
    ]
}

func buildConfigurationName() -> String {
#if DEBUG
    return "debug"
#else
    return "release"
#endif
}

func collectResultsMetadata(benchmarkConfig: [String: Any]) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let uname = unameInfo()
    let env = ProcessInfo.processInfo.environment

    // Minimal, safe allowlist (avoid secrets).
    let allowEnvKeys = [
        "TRANSPORT_ENCODING",
        "WSL_DISTRO_NAME",
        "WSL_INTEROP"
    ]
    var selectedEnv: [String: String] = [:]
    for key in allowEnvKeys {
        if let value = env[key] {
            selectedEnv[key] = value
        }
    }

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
            "swiftVersion": swiftVersion as Any
        ],
        "git": [
            "commit": gitCommit as Any,
            "branch": gitBranch as Any
        ],
        "environment": [
            "osName": uname["sysname"] as Any,
            "kernelVersion": uname["release"] as Any,
            "arch": uname["machine"] as Any,
            "cpuModel": cpuModelName() as Any,
            "cpuPhysicalCores": cpuPhysicalCoresHint() as Any,
            "cpuLogicalCores": cpuLogical,
            "cpuActiveLogicalCores": cpuActive,
            "memoryTotalMB": memoryMB,
            "wsl": detectWSL(),
            "container": detectContainer()
        ],
        "env": selectedEnv,
        "benchmarkConfig": benchmarkConfig
    ]
}

/// Save benchmark results to JSON file as an envelope: { metadata, results }
func saveResultsToJSON(_ results: Any, filename: String, benchmarkConfig: [String: Any] = [:]) {
    let resultsDir = getResultsDirectory()
    let fileURL = resultsDir.appendingPathComponent(filename)
    
    do {
        let metadata = collectResultsMetadata(benchmarkConfig: benchmarkConfig)
        let envelope: [String: Any] = [
            "metadata": metadata,
            "results": results
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: fileURL)
        print("")
        print("Results saved to: \(fileURL.path)")
    } catch {
        print("Failed to save results to JSON: \(error)")
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
            let json: [String: Any] = [
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
        saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
            "mode": "all-formats",
            "rooms": 1,
            "players": config.players,
            "iterations": config.iterations,
            "parallel": config.parallel,
            "formatCount": EncodingFormat.allCases.count
        ])
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
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "all/\(format.rawValue)"
                )
            } else {
                result = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: config.parallel,
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "all/\(format.rawValue)"
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
            let json: [String: Any] = [
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
                    "ticksPerSync": config.ticksPerSync,
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
        let tickSuffix = config.ticksPerSync > 0 ? "-tick\(config.ticksPerSync)" : ""
        let playerSuffix = "-ppr\(config.playersPerRoom)"
        let filename = "all-formats-multiroom-\(config.rooms)rooms\(playerSuffix)-\(config.iterations)iterations\(parallelSuffix)\(tickSuffix)-\(timestamp).json"
        saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
            "mode": "all-formats-multiroom",
            "rooms": config.rooms,
            "playersPerRoom": config.playersPerRoom,
            "iterations": config.iterations,
            "parallel": config.parallel,
            "ticksPerSync": config.ticksPerSync,
            "gameType": config.gameType.rawValue,
            "formatCount": EncodingFormat.allCases.count
        ])
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
                ticksPerSync: config.ticksPerSync,
                progressEvery: config.progressEvery,
                progressLabel: "single/\(config.format.rawValue)"
            )
        } else {
            result = await runMultiRoomBenchmark(
                format: config.format,
                roomCount: config.rooms,
                playersPerRoom: config.playersPerRoom,
                iterations: config.iterations,
                parallel: config.parallel,
                ticksPerSync: config.ticksPerSync,
                progressEvery: config.progressEvery,
                progressLabel: "single/\(config.format.rawValue)"
            )
        }

        switch config.output {
        case .table:
            print("")
            print("  Format: \(config.format.displayName)")
            print("  Rooms: \(config.rooms), Players per room: \(config.playersPerRoom), Total players: \(result.playerCount)")
            print("  Iterations: \(config.iterations), Parallel: \(config.parallel)")
            print("  Ticks per sync: \(config.ticksPerSync)")
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
        print("  Iterations: \(config.iterations), Ticks per sync: \(config.ticksPerSync)")
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
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "compare/serial/\(format.rawValue)"
                )
                parallelResult = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "compare/parallel/\(format.rawValue)"
                )
            } else {
                serialResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "compare/serial/\(format.rawValue)"
                )
                parallelResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "compare/parallel/\(format.rawValue)"
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
                    "ticksPerSync": config.ticksPerSync,
                    "gameType": config.gameType.rawValue
                ]
            ])
        }

        print("  ===========================================================================================")
        print("")
        
        // Save results to JSON
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let tickSuffix = config.ticksPerSync > 0 ? "-tick\(config.ticksPerSync)" : ""
        let playerSuffix = "-ppr\(config.playersPerRoom)"
        let filename = "parallel-comparison-multiroom-\(config.rooms)rooms\(playerSuffix)-\(config.iterations)iterations\(tickSuffix)-\(timestamp).json"
        saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
            "mode": "parallel-comparison-multiroom",
            "rooms": config.rooms,
            "playersPerRoom": config.playersPerRoom,
            "iterations": config.iterations,
            "ticksPerSync": config.ticksPerSync,
            "gameType": config.gameType.rawValue,
            "formats": EncodingFormat.allCases.map(\.rawValue)
        ])
        
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
                    ticksPerSync: config.ticksPerSync
                )
                parallelResult = await runMultiRoomBenchmarkCardGame(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    ticksPerSync: config.ticksPerSync
                )
            } else {
                serialResult = await runMultiRoomBenchmark(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    ticksPerSync: config.ticksPerSync
                )
                parallelResult = await runMultiRoomBenchmark(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    ticksPerSync: config.ticksPerSync
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
        print("  Players per room: \(config.playersPerRoom), Iterations: \(config.iterations), Ticks per sync: \(config.ticksPerSync)")
        print("  測試不同房間數下的性能變化，展示並行系統的可擴展性")
        print("")

        let defaultRoomCounts = [1, 2, 4, 8, 10, 16, 20, 30, 32, 40, 50]
        let roomCounts = config.roomCounts.isEmpty ? defaultRoomCounts : config.roomCounts
        let playersPerRoomValues = config.playersPerRoomList.isEmpty ? [config.playersPerRoom] : config.playersPerRoomList
        let formats = config.runAll ? Array(EncodingFormat.allCases) : [config.format]

        print("  Room counts: \(roomCounts.map(String.init).joined(separator: ", "))")
        print("  Formats: \(formats.map { $0.displayName }.joined(separator: ", "))")
        print("  PlayersPerRoom: \(playersPerRoomValues.map(String.init).joined(separator: ", "))")
        print("")

        let cpuCoreCount = Double(ProcessInfo.processInfo.processorCount)
        var allResults: [[String: Any]] = []

        for playersPerRoom in playersPerRoomValues {
            for format in formats {
                if config.output == .table {
                    print("  Format: \(format.displayName), PlayersPerRoom: \(playersPerRoom)")
                    print("  Rooms | Serial (ms) | Parallel (ms) | Speedup | Parallel Throughput (syncs/s) | Efficiency")
                    print("  ------------------------------------------------------------------------------------------------")
                }

                for roomCount in roomCounts {
                    let serialResult: BenchmarkResult
                    let parallelResult: BenchmarkResult

                    if config.gameType == .cardGame {
                        serialResult = await runMultiRoomBenchmarkCardGame(
                            format: format,
                            roomCount: roomCount,
                            playersPerRoom: playersPerRoom,
                            iterations: config.iterations,
                            parallel: false,
                            ticksPerSync: config.ticksPerSync,
                            progressEvery: config.progressEvery,
                            progressLabel: "scalability/serial/\(format.rawValue)/rooms\(roomCount)/ppr\(playersPerRoom)"
                        )
                        parallelResult = await runMultiRoomBenchmarkCardGame(
                            format: format,
                            roomCount: roomCount,
                            playersPerRoom: playersPerRoom,
                            iterations: config.iterations,
                            parallel: true,
                            ticksPerSync: config.ticksPerSync,
                            progressEvery: config.progressEvery,
                            progressLabel: "scalability/parallel/\(format.rawValue)/rooms\(roomCount)/ppr\(playersPerRoom)"
                        )
                    } else {
                        serialResult = await runMultiRoomBenchmark(
                            format: format,
                            roomCount: roomCount,
                            playersPerRoom: playersPerRoom,
                            iterations: config.iterations,
                            parallel: false,
                            ticksPerSync: config.ticksPerSync,
                            progressEvery: config.progressEvery,
                            progressLabel: "scalability/serial/\(format.rawValue)/rooms\(roomCount)/ppr\(playersPerRoom)"
                        )
                        parallelResult = await runMultiRoomBenchmark(
                            format: format,
                            roomCount: roomCount,
                            playersPerRoom: playersPerRoom,
                            iterations: config.iterations,
                            parallel: true,
                            ticksPerSync: config.ticksPerSync,
                            progressEvery: config.progressEvery,
                            progressLabel: "scalability/parallel/\(format.rawValue)/rooms\(roomCount)/ppr\(playersPerRoom)"
                        )
                    }

                    let speedup = serialResult.timeMs / max(parallelResult.timeMs, 0.001)
                    let theoreticalSpeedup = min(Double(roomCount), cpuCoreCount)
                    let efficiency = (speedup / max(theoreticalSpeedup, 0.001)) * 100.0

                    if config.output == .table {
                        print(String(format: "  %5d | %11.2f | %13.2f | %6.2fx | %27.1f | %9.1f%%",
                                     roomCount,
                                     serialResult.timeMs,
                                     parallelResult.timeMs,
                                     speedup,
                                     parallelResult.throughputSyncsPerSecond,
                                     efficiency))
                    }

                    allResults.append([
                        "rooms": roomCount,
                        "playersPerRoom": playersPerRoom,
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
                            "iterations": config.iterations,
                            "ticksPerSync": config.ticksPerSync,
                            "gameType": config.gameType.rawValue
                        ]
                    ])
                }

                if config.output == .table {
                    print("")
                }
            }
        }

        // Save results to JSON (single matrix file)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let tickSuffix = config.ticksPerSync > 0 ? "-tick\(config.ticksPerSync)" : ""
        let playersSuffix = playersPerRoomValues.isEmpty
            ? ""
            : "-ppr\(playersPerRoomValues.map(String.init).joined(separator: "+"))"
        let formatsSuffix = config.runAll ? "-all-formats" : "-\(config.format.rawValue)"
        let filename = "scalability-matrix\(formatsSuffix)\(playersSuffix)-\(config.iterations)iterations\(tickSuffix)-\(timestamp).json"
        saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
            "mode": "scalability-matrix",
            "roomCounts": roomCounts,
            "playersPerRoom": playersPerRoomValues,
            "iterations": config.iterations,
            "ticksPerSync": config.ticksPerSync,
            "gameType": config.gameType.rawValue,
            "formats": formats.map(\.rawValue)
        ])
    }
}
