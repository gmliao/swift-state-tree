// Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkExecution.swift
//
// Benchmark execution logic for single-room and multi-room scenarios.

import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeMessagePack
import SwiftStateTreeTransport

// MARK: - Types

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

// Benchmark Result
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

// MARK: - Multi-Room Benchmark Execution

enum BenchmarkRunner {
    static func runMultiRoomBenchmarkCardGame(
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
            autoStartLoops: false,
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

    // Deterministic warmup (avoid wall-clock tick/sync loops affecting workload).
    // This makes serial vs parallel comparable on bytesPerSync.
    let warmupTicks = 5
    for _ in 0 ..< warmupTicks {
        for room in rooms {
            await room.keeper.stepTickOnce()
        }
    }
    // Flush warmup dirtiness so the measured iterations start from a steady baseline.
    for room in rooms {
        await room.adapter.syncNow()
    }
    // Reset counters for measurement window.
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
    
    static func runMultiRoomBenchmark(
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
            autoStartLoops: false,
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

    // Deterministic warmup (avoid wall-clock tick/sync loops affecting workload).
    // This makes serial vs parallel comparable on bytesPerSync.
    let warmupTicks = 4
    for _ in 0 ..< warmupTicks {
        for room in rooms {
            await room.keeper.stepTickOnce()
        }
    }
    // Flush warmup dirtiness so the measured iterations start from a steady baseline.
    for room in rooms {
        await room.adapter.syncNow()
    }
    // Reset counters for measurement window.
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
    
    // MARK: - Single-Room Benchmark Execution
    
    static func runBenchmark(
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
        autoStartLoops: false,
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
}
