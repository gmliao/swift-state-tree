// Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkExecution.swift
//
// Benchmark execution logic for single-room and multi-room scenarios.

import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeMessagePack
import SwiftStateTreeTransport

// MARK: - Types

/// Config provider used when `--monster-cap` is set: forces spawn interval to 1 and
/// refills monsters up to the cap every tick (the land clamps to `monsterMaxCount`),
/// so the live monster count stays at ~cap for the whole measurement window.
struct CappedMonsterGameConfigProvider: GameConfigProvider {
    let base = DefaultGameConfigProvider()
    let cap: Int

    var monsterMaxCount: Int { cap }
    var monsterSpawnIntervalMinTicks: Int { 1 }
    var monsterSpawnIntervalMaxTicks: Int { 1 }
    var monsterSpawnCountMin: Int { cap }
    var monsterSpawnCountMax: Int { cap }

    // Delegate everything else to the default provider
    var worldWidth: Float { base.worldWidth }
    var worldHeight: Float { base.worldHeight }
    var baseCenterX: Float { base.baseCenterX }
    var baseCenterY: Float { base.baseCenterY }
    var baseRadius: Float { base.baseRadius }
    var baseMaxHealth: Int { base.baseMaxHealth }
    var tickIntervalMs: Int { base.tickIntervalMs }
    var monsterSpawnAccelerationTicks: Int64 { base.monsterSpawnAccelerationTicks }
    var monsterMoveSpeed: Float { base.monsterMoveSpeed }
    var monsterBaseHealth: Int { base.monsterBaseHealth }
    var monsterBaseReward: Int { base.monsterBaseReward }
    var weaponBaseDamage: Int { base.weaponBaseDamage }
    var weaponBaseRange: Float { base.weaponBaseRange }
    var weaponFireRateTicks: Int { base.weaponFireRateTicks }
    var turretBaseDamage: Int { base.turretBaseDamage }
    var turretBaseRange: Float { base.turretBaseRange }
    var turretFireRateTicks: Int { base.turretFireRateTicks }
    var turretPlacementDistance: Float { base.turretPlacementDistance }
    var weaponUpgradeCost: Int { base.weaponUpgradeCost }
    var turretUpgradeCost: Int { base.turretUpgradeCost }
    var turretPlacementCost: Int { base.turretPlacementCost }
}

/// Inject a deterministic MoveToEvent for every player in the room so each player
/// produces a position change every tick (active-player workload).
/// Targets are derived from indices with integer math only (deterministic across runs).
func injectActiveMoveTargets(
    room: HeroDefenseRoomContext,
    roomIndex: Int,
    playersPerRoom: Int,
    iteration: Int
) async {
    for playerIndex in 0 ..< playersPerRoom {
        let tx = Float((playerIndex * 37 + iteration * 13) % 128)
        let ty = Float((playerIndex * 53 + iteration * 17) % 72)
        let event = MoveToEvent(x: tx, y: ty)
        guard let data = try? JSONEncoder().encode(event),
          let payload = try? JSONDecoder().decode(AnyCodable.self, from: data)
    else { continue }
    try? await room.keeper.handleClientEvent(
        AnyClientEvent(type: "MoveTo", payload: payload),
        playerID: PlayerID("room\(roomIndex)-player-\(playerIndex)"),
        clientID: ClientID("room\(roomIndex)-client-\(playerIndex)"),
        sessionID: SessionID("room\(roomIndex)-session-\(playerIndex)")
    )
    }
}

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

// MARK: - Work Queue for Dynamic Worker Pool

/// Hands each iteration's rooms to long-lived workers, one item per room, and returns from
/// `runIteration` once every item completed: a room never has two syncs in flight, and the
/// caller can drain between iterations outside the timed span (#160).
actor IterationWorkQueue {
    private var items: [Int] = []
    private var remaining = 0
    private var waiters: [CheckedContinuation<Int?, Never>] = []
    private var iterationDone: CheckedContinuation<Void, Never>?
    private var finished = false

    /// Runs one iteration's room indices on the workers and waits for all of them.
    func runIteration(_ roomIndices: [Int]) async {
        guard !roomIndices.isEmpty else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            items = roomIndices
            remaining = roomIndices.count
            iterationDone = done
            while !items.isEmpty, !waiters.isEmpty {
                waiters.removeFirst().resume(returning: items.removeFirst())
            }
        }
    }

    /// The next room index of the current iteration; waits for the next iteration; `nil` after `finish()`.
    func next() async -> Int? {
        if !items.isEmpty { return items.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// A worker finished the item `next()` gave it.
    func complete() {
        remaining -= 1
        if remaining == 0 {
            iterationDone?.resume()
            iterationDone = nil
        }
    }

    /// Ends the workers waiting in `next()`.
    func finish() {
        finished = true
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }
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
    /// Live monster count in the first room at the end of the measurement window
    /// (all rooms evolve identically; 0 for non-hero-defense benchmarks).
    var finalMonsterCount: Int = 0
    /// Serial multi-room runs: the time in `syncNow()` alone, without the ticks and the move
    /// injection that `timeMs` includes. nil for other runs.
    var syncMs: Double? = nil
    /// Serial runs of the generic multi-room runner: the time in `stepTickOnce()` alone. nil for
    /// other runs.
    var tickMs: Double? = nil
    /// Process CPU time (user + system, all threads) over the spans `timeMs` covers; nil where
    /// a run doesn't measure it or the platform doesn't report it.
    var cpuMs: Double? = nil
    /// Hero-defense multi-room runs: the first room's highest live monster count after any
    /// iteration (untimed). nil for other runs.
    var peakMonsterCount: Int? = nil
    /// `--baseline entity-delta`: the baseline's own metrics (`EntityDeltaCell.report`). nil otherwise.
    var entityDelta: [String: Any]? = nil
    /// Sync strategy every `TransportAdapter` this run constructed actually used.
    /// `EncodingBenchmark.main()` sets `SYNC_STRATEGY` via `setenv` once, right after
    /// parsing `--sync-strategy`, before any run* function (and therefore any
    /// `TransportAdapter`) is created — so reading the env var back here, instead of
    /// threading `config.syncStrategy` through every run* function signature, always
    /// matches what those adapters actually used.
    let syncStrategy: String = SyncStrategy.parse(
        ProcessInfo.processInfo.environment[SyncStrategy.environmentKey], default: .delta
    ).rawValue
    /// `--dirty-tracking` mode, set in the environment the same way before any adapter exists.
    let dirtyTracking: String = DirtyTrackingMode.current
    /// Dirty tracking the adapters actually had when the measurement ended. Under `auto` an
    /// adapter can switch during the run, so this can differ from `dirtyTracking`.
    var dirtyTrackingEffective = EffectiveDirtyTracking()
    /// Measured sync cycles the adapters skipped (back-pressure or a cycle in flight); the run
    /// exits unless it is 0 (#160).
    var syncSkips = 0
    
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
    let schema = benchmarkSchema(landDef)
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
        
        let adapter = TransportAdapter<CardGameState>(
            keeper: keeper,
            transport: transport,
            landID: landID.stringValue,
            createGuestSession: nil,
            enableDirtyTracking: true,
            encodingConfig: format.transportEncodingConfig,
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: !format.usesPathHash
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
    // Count from an empty writer: the warm-up flush must not land in the window (#160).
    await MeasuredSync.drain(rooms.map(\.adapter))
    for room in rooms {
        await room.transport.resetCounts()
    }
    
    // Benchmark: Run iterations with serial or parallel sync
    // Note: parallel execution may trigger libmalloc LIFO issues in release mode on macOS
    // Use serial execution for stability, parallel for performance comparison
    let skipsBefore = await MeasuredSync.skipCount(rooms.map(\.adapter))
    // Tick and sync time only: the drain after each iteration is not timed.
    var duration = Duration.zero
    let label = progressLabel ?? (parallel ? "parallel" : "serial")
    if parallel {
        // Parallel execution using withTaskGroup (room-level parallelism)
        for iterationIndex in 0 ..< iterations {
            let iterationStart = ContinuousClock.now
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
            duration += iterationStart.duration(to: ContinuousClock.now)
            await MeasuredSync.drain(rooms.map(\.adapter))
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
            }
        }
    } else {
        // Serial execution to avoid memory allocation order issues
        for iterationIndex in 0 ..< iterations {
            let iterationStart = ContinuousClock.now
            for room in rooms {
                if ticksPerSync > 0 {
                    for _ in 0 ..< ticksPerSync {
                        await room.keeper.stepTickOnce()
                    }
                }
                await room.adapter.syncNow()
            }
            duration += iterationStart.duration(to: ContinuousClock.now)
            await MeasuredSync.drain(rooms.map(\.adapter))
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
            }
        }
    }
    let syncSkips = await MeasuredSync.skipCount(rooms.map(\.adapter)) - skipsBefore
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
    
    var result = BenchmarkResult(
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
    result.dirtyTrackingEffective = await EffectiveDirtyTracking(adapters: rooms.map(\.adapter))
    result.syncSkips = syncSkips
    MeasuredSync.requireNoSkips(syncSkips, label: "\(format.displayName)")
    return result
    }
    
    static func runMultiRoomBenchmarkWithWorkerPool(
        format: EncodingFormat,
        roomCount: Int,
        playersPerRoom: Int,
        iterations: Int,
        ticksPerSync: Int = 0,
        workerCount: Int? = nil,
        progressEvery: Int = 0,
        progressLabel: String? = nil
    ) async -> BenchmarkResult {
        // Extract pathHashes from schema
        let landDef = HeroDefense.makeLand()
        let schema = benchmarkSchema(landDef)
        let pathHashes = format.usesPathHash ? schema.lands["hero-defense"]?.pathHashes : nil

        let benchmarkLogger = createGameLogger(
            scope: "EncodingBenchmark",
            logLevel: .error
        )

        // Create rooms (same as regular multi-room benchmark)
        var rooms: [HeroDefenseRoomContext] = []
        rooms.reserveCapacity(roomCount)

        for roomIndex in 0 ..< roomCount {
            let landID = LandID(landType: "hero-defense", instanceId: "benchmark-\(roomIndex)")
            let transport = CountingTransport()
            
            var services = LandServices()
            let configProvider = DefaultGameConfigProvider()
            let configService = GameConfigProviderService(provider: configProvider)
            services.register(configService, as: GameConfigProviderService.self)
            
            let keeper = LandKeeper<HeroDefenseState>(
                definition: landDef,
                initialState: HeroDefenseState(),
                mode: .live,
                services: services,
                enableLiveStateHashRecording: false,
                transport: nil,
                logger: benchmarkLogger
            )
            
            let adapter = TransportAdapter<HeroDefenseState>(
                keeper: keeper,
                transport: transport,
                landID: landID.stringValue,
                createGuestSession: nil,
                enableDirtyTracking: true,
                encodingConfig: format.transportEncodingConfig,
                pathHashes: pathHashes
            )
            
            rooms.append(HeroDefenseRoomContext(
                landID: landID,
                keeper: keeper,
                adapter: adapter,
                transport: transport
            ))
        }

        // Connect players to each room
        for (roomIndex, room) in rooms.enumerated() {
            let playerIDs = (0 ..< playersPerRoom).map { PlayerID("room\(roomIndex)-player-\($0)") }
            for (playerIndex, playerID) in playerIDs.enumerated() {
                let sessionID = SessionID("room\(roomIndex)-session-\(playerIndex)")
                let clientID = ClientID("room\(roomIndex)-client-\(playerIndex)")
                await room.adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil as AuthenticatedInfo?)
                
                let playerSession = PlayerSession(
                    playerID: playerID.rawValue,
                    deviceID: "device-\(roomIndex)-\(playerIndex)",
                    metadata: [:]
                )
                if let result = try? await room.adapter.performJoin(
                    playerSession: playerSession,
                    clientID: clientID,
                    sessionID: sessionID,
                    authInfo: nil as AuthenticatedInfo?
                ) {
                    await room.adapter.syncStateForNewPlayer(playerID: result.playerID, sessionID: sessionID)
                }
            }
        }
        
        // Initial sync
        for room in rooms {
            await room.adapter.syncNow()
        }

        // Warmup
        let warmupTicks = 4
        for _ in 0 ..< warmupTicks {
            for room in rooms {
                await room.keeper.stepTickOnce()
            }
        }
        for room in rooms {
            await room.adapter.syncNow()
        }
        // Count from an empty writer: the warm-up flush must not land in the window (#160).
        await MeasuredSync.drain(rooms.map(\.adapter))
        for room in rooms {
            await room.transport.resetCounts()
        }

        // Calculate worker count
        let effectiveWorkerCount: Int
        if let workerCount = workerCount {
            effectiveWorkerCount = max(1, workerCount)
        } else {
            let cpuCores = ProcessInfo.processInfo.activeProcessorCount
            effectiveWorkerCount = cpuCores * 2
        }
        
        // Static assignment: divide rooms evenly among workers
        let roomsPerWorker = (rooms.count + effectiveWorkerCount - 1) / effectiveWorkerCount
        
        let skipsBefore = await MeasuredSync.skipCount(rooms.map(\.adapter))
        // Tick and sync time only: the drain after each iteration is not timed.
        var duration = Duration.zero
        let label = progressLabel ?? "worker-pool"
        
        // Worker Pool execution with static room assignment
        for iterationIndex in 0 ..< iterations {
            let iterationStart = ContinuousClock.now
            await withTaskGroup(of: Void.self) { group in
                for workerIndex in 0 ..< effectiveWorkerCount {
                    let startIdx = workerIndex * roomsPerWorker
                    let endIdx = min(startIdx + roomsPerWorker, rooms.count)
                    
                    guard startIdx < rooms.count else { break }
                    
                    let workerRooms = Array(rooms[startIdx..<endIdx])
                    
                    group.addTask { [workerRooms] in
                        // Sequential processing within worker
                        for room in workerRooms {
                            if ticksPerSync > 0 {
                                for _ in 0 ..< ticksPerSync {
                                    await room.keeper.stepTickOnce()
                                }
                            }
                            await room.adapter.syncNow()
                        }
                    }
                }
            }
            
            duration += iterationStart.duration(to: ContinuousClock.now)
            await MeasuredSync.drain(rooms.map(\.adapter))
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
            }
        }
        
        let syncSkips = await MeasuredSync.skipCount(rooms.map(\.adapter)) - skipsBefore
        let timeMs = Double(duration.components.seconds) * 1000.0 +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        
        // Aggregate stats
        var totalBytes = 0
        for room in rooms {
            let stats = await room.transport.snapshotCounts()
            totalBytes += stats.bytes
        }
        
        let totalPlayers = roomCount * playersPerRoom
        let timePerRoomMs = roomCount > 0 ? timeMs / Double(roomCount) : timeMs
        let timePerSyncMs = iterations > 0 ? timeMs / Double(iterations) : timeMs
        let avgCostPerSyncMs = (roomCount > 0 && iterations > 0) ? timeMs / Double(roomCount * iterations) : timeMs

    var result = BenchmarkResult(
        format: format,
        timeMs: timeMs,
        totalBytes: totalBytes,
        bytesPerSync: iterations > 0 ? totalBytes / iterations : 0,
        iterations: iterations,
        parallel: true,  // Worker pool is a form of parallel execution
        playerCount: totalPlayers,
        roomCount: roomCount,
        playersPerRoom: playersPerRoom,
        timePerRoomMs: timePerRoomMs,
        timePerSyncMs: timePerSyncMs,
        avgCostPerSyncMs: avgCostPerSyncMs
    )
    result.dirtyTrackingEffective = await EffectiveDirtyTracking(adapters: rooms.map(\.adapter))
    result.syncSkips = syncSkips
    MeasuredSync.requireNoSkips(syncSkips, label: "\(format.displayName)")
    return result
    }
    
    static func runMultiRoomBenchmarkWithDynamicWorkerPool(
        format: EncodingFormat,
        roomCount: Int,
        playersPerRoom: Int,
        iterations: Int,
        ticksPerSync: Int = 0,
        workerCount: Int? = nil,
        progressEvery: Int = 0,
        progressLabel: String? = nil
    ) async -> BenchmarkResult {
        // Extract pathHashes from schema
        let landDef = HeroDefense.makeLand()
        let schema = benchmarkSchema(landDef)
        let pathHashes = format.usesPathHash ? schema.lands["hero-defense"]?.pathHashes : nil

        let benchmarkLogger = createGameLogger(
            scope: "EncodingBenchmark",
            logLevel: .error
        )

        // Create rooms (same setup as other benchmarks)
        var rooms: [HeroDefenseRoomContext] = []
        rooms.reserveCapacity(roomCount)

        for roomIndex in 0 ..< roomCount {
            let landID = LandID(landType: "hero-defense", instanceId: "benchmark-\(roomIndex)")
            let transport = CountingTransport()
            
            var services = LandServices()
            let configProvider = DefaultGameConfigProvider()
            let configService = GameConfigProviderService(provider: configProvider)
            services.register(configService, as: GameConfigProviderService.self)
            
            let keeper = LandKeeper<HeroDefenseState>(
                definition: landDef,
                initialState: HeroDefenseState(),
                mode: .live,
                services: services,
                enableLiveStateHashRecording: false,
                transport: nil,
                logger: benchmarkLogger
            )
            
            let adapter = TransportAdapter<HeroDefenseState>(
                keeper: keeper,
                transport: transport,
                landID: landID.stringValue,
                createGuestSession: nil,
                enableDirtyTracking: true,
                encodingConfig: format.transportEncodingConfig,
                pathHashes: pathHashes
            )
            
            rooms.append(HeroDefenseRoomContext(
                landID: landID,
                keeper: keeper,
                adapter: adapter,
                transport: transport
            ))
        }

        // Connect players to each room
        for (roomIndex, room) in rooms.enumerated() {
            let playerIDs = (0 ..< playersPerRoom).map { PlayerID("room\(roomIndex)-player-\($0)") }
            for (playerIndex, playerID) in playerIDs.enumerated() {
                let sessionID = SessionID("room\(roomIndex)-session-\(playerIndex)")
                let clientID = ClientID("room\(roomIndex)-client-\(playerIndex)")
                await room.adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: nil as AuthenticatedInfo?)
                
                let playerSession = PlayerSession(
                    playerID: playerID.rawValue,
                    deviceID: "device-\(roomIndex)-\(playerIndex)",
                    metadata: [:]
                )
                if let result = try? await room.adapter.performJoin(
                    playerSession: playerSession,
                    clientID: clientID,
                    sessionID: sessionID,
                    authInfo: nil as AuthenticatedInfo?
                ) {
                    await room.adapter.syncStateForNewPlayer(playerID: result.playerID, sessionID: sessionID)
                }
            }
        }
        
        // Initial sync
        for room in rooms {
            await room.adapter.syncNow()
        }

        // Warmup
        let warmupTicks = 4
        for _ in 0 ..< warmupTicks {
            for room in rooms {
                await room.keeper.stepTickOnce()
            }
        }
        for room in rooms {
            await room.adapter.syncNow()
        }
        // Count from an empty writer: the warm-up flush must not land in the window (#160).
        await MeasuredSync.drain(rooms.map(\.adapter))
        for room in rooms {
            await room.transport.resetCounts()
        }

        // Calculate worker count
        let effectiveWorkerCount: Int
        if let workerCount = workerCount {
            effectiveWorkerCount = max(1, workerCount)
        } else {
            let cpuCores = ProcessInfo.processInfo.activeProcessorCount
            effectiveWorkerCount = cpuCores
        }
        
        // Long-lived workers pull each iteration's rooms from a shared queue. The iteration is
        // the barrier: a room has one sync in flight at a time (a second one would be skipped),
        // and the drain after it runs outside the timed span, as in the other modes.
        let workQueue = IterationWorkQueue()
        let allRooms = Array(rooms.indices)

        let skipsBefore = await MeasuredSync.skipCount(rooms.map(\.adapter))
        var duration = Duration.zero

        await withTaskGroup(of: Void.self) { group in
            for workerID in 0..<effectiveWorkerCount {
                group.addTask { [rooms, workQueue] in
                    var processed = 0
                    while let roomIdx = await workQueue.next() {
                        let room = rooms[roomIdx]
                        if ticksPerSync > 0 {
                            for _ in 0 ..< ticksPerSync {
                                await room.keeper.stepTickOnce()
                            }
                        }
                        await room.adapter.syncNow()
                        await workQueue.complete()
                        processed += 1
                        if progressEvery > 0, processed % progressEvery == 0 {
                            print("  [worker-\(workerID)] processed \(processed) tasks")
                        }
                    }
                    if progressEvery > 0 {
                        print("  [worker-\(workerID)] completed \(processed) tasks total")
                    }
                }
            }
            for _ in 0 ..< iterations {
                let iterationStart = ContinuousClock.now
                await workQueue.runIteration(allRooms)
                duration += iterationStart.duration(to: ContinuousClock.now)
                await MeasuredSync.drain(rooms.map(\.adapter))
            }
            await workQueue.finish()
        }

        let syncSkips = await MeasuredSync.skipCount(rooms.map(\.adapter)) - skipsBefore
        let timeMs = Double(duration.components.seconds) * 1000.0 +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        
        // Aggregate stats
        var totalBytes = 0
        for room in rooms {
            let stats = await room.transport.snapshotCounts()
            totalBytes += stats.bytes
        }
        
        let totalPlayers = roomCount * playersPerRoom
        let timePerRoomMs = roomCount > 0 ? timeMs / Double(roomCount) : timeMs
        let timePerSyncMs = iterations > 0 ? timeMs / Double(iterations) : timeMs
        let avgCostPerSyncMs = (roomCount > 0 && iterations > 0) ? timeMs / Double(roomCount * iterations) : timeMs

        var result = BenchmarkResult(
            format: format,
            timeMs: timeMs,
            totalBytes: totalBytes,
            bytesPerSync: iterations > 0 ? totalBytes / iterations : 0,
            iterations: iterations,
            parallel: true,  // Dynamic worker pool is parallel
            playerCount: totalPlayers,
            roomCount: roomCount,
            playersPerRoom: playersPerRoom,
            timePerRoomMs: timePerRoomMs,
            timePerSyncMs: timePerSyncMs,
            avgCostPerSyncMs: avgCostPerSyncMs
        )
        result.dirtyTrackingEffective = await EffectiveDirtyTracking(adapters: rooms.map(\.adapter))
        result.syncSkips = syncSkips
        MeasuredSync.requireNoSkips(syncSkips, label: "\(format.displayName)")
        return result
    }
    
    static func runMultiRoomBenchmark(
        format: EncodingFormat,
        roomCount: Int,
        playersPerRoom: Int,
        iterations: Int,
        parallel: Bool,
        ticksPerSync: Int = 0,
        monsterCap: Int = 0,
        activePlayers: Bool = false,
        progressEvery: Int = 0,
        progressLabel: String? = nil
    ) async -> BenchmarkResult {
    // Extract pathHashes from schema
    let landDef = HeroDefense.makeLand(maxPlayers: max(10, playersPerRoom))
    let schema = benchmarkSchema(landDef)
    let pathHashes = format.usesPathHash ? schema.lands["hero-defense"]?.pathHashes : nil

    let benchmarkLogger = createGameLogger(
        scope: "EncodingBenchmark",
        logLevel: .error
    )

    // Create rooms manually (multi-room benchmark)
    // This gives us control over CountingTransport per room
    var rooms: [HeroDefenseRoomContext] = []
    rooms.reserveCapacity(roomCount)

    for roomIndex in 0 ..< roomCount {
        let landID = LandID(landType: "hero-defense", instanceId: "benchmark-\(roomIndex)")
        let transport = CountingTransport()
        
        // Create services with GameConfig
        var services = LandServices()
        let configProvider: any GameConfigProvider = monsterCap > 0
            ? CappedMonsterGameConfigProvider(cap: monsterCap)
            : DefaultGameConfigProvider()
        let configService = GameConfigProviderService(provider: configProvider)
        services.register(configService, as: GameConfigProviderService.self)
        
        let keeper = LandKeeper<HeroDefenseState>(
            definition: HeroDefense.makeLand(maxPlayers: max(10, playersPerRoom)),
            initialState: HeroDefenseState(),
            services: services,
            autoStartLoops: false,
            transport: nil,
            logger: benchmarkLogger
        )
        
        let adapter = TransportAdapter<HeroDefenseState>(
            keeper: keeper,
            transport: transport,
            landID: landID.stringValue,
            createGuestSession: nil,
            enableDirtyTracking: true,
            encodingConfig: format.transportEncodingConfig,
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: !format.usesPathHash
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
        
        // Fail loudly if the land's join policy rejected any player
        let joinedCount = await keeper.playerCount()
        if joinedCount != playersPerRoom {
            print("WARNING: room \(roomIndex) joined \(joinedCount)/\(playersPerRoom) players (join policy rejected the rest)")
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
    // Count from an empty writer: the warm-up flush must not land in the window (#160).
    await MeasuredSync.drain(rooms.map(\.adapter))
    for room in rooms {
        await room.transport.resetCounts()
    }
    
    // Benchmark: Run iterations with serial or parallel sync
    // Note: parallel execution may trigger libmalloc LIFO issues in release mode on macOS
    // Use serial execution for stability, parallel for performance comparison
    let skipsBefore = await MeasuredSync.skipCount(rooms.map(\.adapter))
    // Tick and sync time only: the drain after each iteration is not timed.
    var duration = Duration.zero
    let label = progressLabel ?? (parallel ? "parallel" : "serial")
    if parallel {
        // Parallel execution using withTaskGroup
        for iterationIndex in 0 ..< iterations {
            let iterationStart = ContinuousClock.now
            await withTaskGroup(of: Void.self) { group in
                for (roomIndex, room) in rooms.enumerated() {
                    group.addTask { [room] in
                        if activePlayers {
                            await injectActiveMoveTargets(
                                room: room, roomIndex: roomIndex,
                                playersPerRoom: playersPerRoom, iteration: iterationIndex)
                        }
                        if ticksPerSync > 0 {
                            for _ in 0 ..< ticksPerSync {
                                await room.keeper.stepTickOnce()
                            }
                        }
                        await room.adapter.syncNow()
                    }
                }
            }
            duration += iterationStart.duration(to: ContinuousClock.now)
            await MeasuredSync.drain(rooms.map(\.adapter))
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
            }
        }
    } else {
        // Serial execution to avoid memory allocation order issues
        for iterationIndex in 0 ..< iterations {
            let iterationStart = ContinuousClock.now
            for (roomIndex, room) in rooms.enumerated() {
                if activePlayers {
                    await injectActiveMoveTargets(
                        room: room, roomIndex: roomIndex,
                        playersPerRoom: playersPerRoom, iteration: iterationIndex)
                }
                if ticksPerSync > 0 {
                    for _ in 0 ..< ticksPerSync {
                        await room.keeper.stepTickOnce()
                    }
                }
                await room.adapter.syncNow()
            }
            duration += iterationStart.duration(to: ContinuousClock.now)
            await MeasuredSync.drain(rooms.map(\.adapter))
            if progressEvery > 0, (iterationIndex + 1) % progressEvery == 0 {
                print("  [\(label)] iteration \(iterationIndex + 1)/\(iterations)")
            }
        }
    }
    let syncSkips = await MeasuredSync.skipCount(rooms.map(\.adapter)) - skipsBefore
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
    
    // Record the final monster count from the first room (all rooms evolve identically)
    var finalMonsterCount = 0
    if let firstRoom = rooms.first {
        finalMonsterCount = await firstRoom.keeper.currentState().liveMonsterCount
    }
    
    var result = BenchmarkResult(
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
        avgCostPerSyncMs: avgCostPerSyncMs,
        finalMonsterCount: finalMonsterCount
    )
    result.dirtyTrackingEffective = await EffectiveDirtyTracking(adapters: rooms.map(\.adapter))
    result.syncSkips = syncSkips
    MeasuredSync.requireNoSkips(syncSkips, label: "\(format.displayName)")
    return result
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
    let schema = benchmarkSchema(landDef)
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

    let adapter = TransportAdapter<BenchmarkState>(
        keeper: keeper,
        transport: mockTransport,
        landID: "benchmark-land",
        createGuestSession: nil,
        enableDirtyTracking: true,
        encodingConfig: format.transportEncodingConfig,
        pathHashes: pathHashes,
            suppressMissingPathHashesWarning: !format.usesPathHash
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
    // Count from an empty writer: the warm-up flush must not land in the window (#160).
    await MeasuredSync.drain([adapter])
    await mockTransport.resetCounts()

    // Benchmark
    let skipsBefore = await MeasuredSync.skipCount([adapter])
    // Tick and sync time only: the drain after each iteration is not timed.
    var duration = Duration.zero
    for i in 0 ..< iterations {
        let iterationStart = ContinuousClock.now
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
        duration += iterationStart.duration(to: ContinuousClock.now)
        await MeasuredSync.drain([adapter])
    }
    let syncSkips = await MeasuredSync.skipCount([adapter]) - skipsBefore
    let timeMs = Double(duration.components.seconds) * 1000.0 +
        Double(duration.components.attoseconds) / 1_000_000_000_000_000.0

    let stats = await mockTransport.snapshotCounts()
    let timePerRoomMs = timeMs  // Single room
    let timePerSyncMs = iterations > 0 ? timeMs / Double(iterations) : timeMs
    let avgCostPerSyncMs = timePerSyncMs  // Single room, so same as timePerSyncMs

    var result = BenchmarkResult(
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
    result.dirtyTrackingEffective = await EffectiveDirtyTracking(adapters: [adapter])
    result.syncSkips = syncSkips
    MeasuredSync.requireNoSkips(syncSkips, label: "\(format.displayName)")
    return result
    }
}

/// How many adapters had dirty tracking on and off when the measurement ended.
struct EffectiveDirtyTracking {
    var on = 0
    var off = 0

    init() {}

    init<State: StateNodeProtocol>(adapters: [TransportAdapter<State>]) async {
        for adapter in adapters {
            if await adapter.isDirtyTrackingEnabled() {
                on += 1
            } else {
                off += 1
            }
        }
    }

    /// For result JSON. At the end of the measurement: under `auto` it can differ from the
    /// requested `dirtyTracking` mode.
    var json: [String: Any] {
        ["atEnd": summary, "adaptersOn": on, "adaptersOff": off]
    }

    /// `on`, `off`, or `mixed` when the adapters disagree (`none` without adapters).
    var summary: String {
        switch (on, off) {
        case (0, 0): return "none"
        case (_, 0): return "on"
        case (0, _): return "off"
        default: return "mixed"
        }
    }
}

/// The schema of a benchmark land. These lands are fixed and valid, so a schema error (#179's
/// nesting check) is a programming error here.
func benchmarkSchema<State: StateNodeProtocol>(_ landDef: LandDefinition<State>) -> ProtocolSchema {
    do {
        return try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
    } catch {
        fatalError("Benchmark land schema failed: \(error)")
    }
}
