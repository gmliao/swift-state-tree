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
}

func runMultiRoomBenchmarkCardGame(
    format: EncodingFormat,
    roomCount: Int,
    playersPerRoom: Int,
    iterations: Int,
    parallel: Bool
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
        
        // Only enable parallel encoding for JSON formats (MessagePack doesn't support it)
        let shouldEnableParallel = parallel && (format == .jsonObject || format == .opcodeJson || format == .opcodeJsonPathHash)
        
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
        
        // Configure parallel encoding parameters for optimal performance
        // Note: Parallel encoding only works with JSON encoders, not MessagePack
        // Only configure if using JSON format AND parallel is enabled
        if parallel && (format == .jsonObject || format == .opcodeJson || format == .opcodeJsonPathHash) {
            // Set minimum player count (default: 20)
            await adapter.setParallelEncodingMinPlayerCount(20)
            // Set batch size (default: 12) - players per encoding task
            await adapter.setParallelEncodingBatchSize(12)
            // Set concurrency caps: lowCap=2, highCap=4, threshold=30
            await adapter.setParallelEncodingConcurrencyCaps(
                lowPlayerCap: 2,
                highPlayerCap: 4,
                highPlayerThreshold: 30
            )
        }
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
    
    // Benchmark: Run iterations with serial sync (not parallel to avoid libmalloc LIFO issues)
    let start = ContinuousClock.now
    for _ in 0 ..< iterations {
        // Serial execution instead of withTaskGroup to avoid memory allocation order issues
        for room in rooms {
            // CardGame tick runs automatically, we just need to sync
            await room.adapter.syncNow()
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
        timePerSyncMs: timePerSyncMs
    )
}

func runMultiRoomBenchmark(
    format: EncodingFormat,
    roomCount: Int,
    playersPerRoom: Int,
    iterations: Int,
    parallel: Bool
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
        
        // Only enable parallel encoding for JSON formats (MessagePack doesn't support it)
        let shouldEnableParallel = parallel && (format == .jsonObject || format == .opcodeJson || format == .opcodeJsonPathHash)
        
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
        
        // Configure parallel encoding parameters only for JSON formats
        if shouldEnableParallel {
            await adapter.setParallelEncodingMinPlayerCount(20)
            await adapter.setParallelEncodingBatchSize(12)
            await adapter.setParallelEncodingConcurrencyCaps(
                lowPlayerCap: 2,
                highPlayerCap: 4,
                highPlayerThreshold: 30
            )
        }
        
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
    
    // Benchmark: Run iterations with serial sync (not parallel to avoid libmalloc LIFO issues)
    let start = ContinuousClock.now
    for _ in 0 ..< iterations {
        // Serial execution instead of withTaskGroup to avoid memory allocation order issues
        for room in rooms {
            // HeroDefense tick runs automatically, we just need to sync
            await room.adapter.syncNow()
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
        timePerSyncMs: timePerSyncMs
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

    // Only enable parallel encoding for JSON formats (MessagePack doesn't support it)
    let shouldEnableParallel = parallel && (format == .jsonObject || format == .opcodeJson || format == .opcodeJsonPathHash)
    
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
    
    // Configure parallel encoding parameters only for JSON formats
    if shouldEnableParallel {
        await adapter.setParallelEncodingMinPlayerCount(20)
        await adapter.setParallelEncodingBatchSize(12)
        await adapter.setParallelEncodingConcurrencyCaps(
            lowPlayerCap: 2,
            highPlayerCap: 4,
            highPlayerThreshold: 30
        )
    }
    
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
        timePerSyncMs: timePerSyncMs
    )
}

// MARK: - Output

func printTableHeader() {
    print("===================== Encoding Benchmark Results =====================")
    print("Format                      | Time (ms) | Total Bytes | Per Sync | vs JSON")
    print("------------------------------------------------------------------------")
}

func printTableRow(_ result: BenchmarkResult, baselineBytes: Int?) {
    let ratio: String
    if let baseline = baselineBytes, baseline > 0 {
        ratio = String(format: "%5.1f%%", Double(result.totalBytes) / Double(baseline) * 100)
    } else {
        ratio = "  100%"
    }

    print(String(format: "%-27s | %9.2f | %11d | %8d | %s",
                 result.format.displayName,
                 result.timeMs,
                 result.totalBytes,
                 result.bytesPerSync,
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
    ]
    
    if result.roomCount > 1 {
        json["roomCount"] = result.roomCount
        json["playersPerRoom"] = result.playersPerRoom
        json["timePerRoomMs"] = result.timePerRoomMs
    }
    json["timePerSyncMs"] = result.timePerSyncMs
    
    if let data = try? JSONSerialization.data(withJSONObject: json, options: []),
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
        
        if config.compareParallel {
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

        for format in EncodingFormat.allCases {
            let result = await runMultiRoomBenchmark(
                format: format,
                roomCount: config.rooms,
                playersPerRoom: config.playersPerRoom,
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
                parallel: config.parallel
            )
        } else {
            result = await runMultiRoomBenchmark(
                format: config.format,
                roomCount: config.rooms,
                playersPerRoom: config.playersPerRoom,
                iterations: config.iterations,
                parallel: config.parallel
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
        print("  Iterations: \(config.iterations)")
        print("")
        print("  Format                      | Serial (ms) | Parallel (ms) | Speedup")
        print("  ---------------------------------------------------------------------------")

        for format in EncodingFormat.allCases {
            let serialResult: BenchmarkResult
            let parallelResult: BenchmarkResult
            
            if config.gameType == .cardGame {
                serialResult = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false
                )
                parallelResult = await runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true
                )
            } else {
                serialResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false
                )
                parallelResult = await runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true
                )
            }

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
}
