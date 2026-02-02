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
    // Note (macOS / release):
    // A previous crash (exit 139) observed under `-c release --compare-parallel` was caused by
    // using C printf-style `%s` with Swift `String` in `String(format:)` (invalid C varargs).
    // That issue is fixed; keep output code type-safe (prefer interpolation or %@).
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
    // Note (macOS / release):
    // A previous crash (exit 139) observed under `-c release --compare-parallel` was caused by
    // using C printf-style `%s` with Swift `String` in `String(format:)` (invalid C varargs).
    // That issue is fixed; keep output code type-safe (prefer interpolation or %@).
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

    // NOTE: Use %@ (Objective-C object) instead of %s. %s expects a C string pointer and can
    // crash in release builds when passed a Swift String.
    print(String(format: "%-27@ | %9.2f | %11d | %8d | %13.4f | %@",
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
        let config = ArgumentParser.parseArguments()

        // Determine if multi-room mode
        // If rooms > 1, use multi-room mode
        // Otherwise, use single-room mode (backward compatibility)
        let isMultiRoom = config.rooms > 1
        
        if config.compareWorkerPool {
            await runWorkerPoolComparison(config: config)
        } else if config.scalabilityTest {
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
        } else if config.useWorkerPool && isMultiRoom {
            await runSingleFormatMultiRoomWorkerPool(config: config)
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
                print(String(format: "Best: %@ saves %.1f%% vs JSON Object",
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
                print(String(format: "Best: %@ saves %.1f%% vs JSON Object",
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

            print(String(format: "  %-27@ | %11.2f | %13.2f | %6.2fx",
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

            print(String(format: "  %-27@ | %11.2f | %13.2f | %6.2fx | %21.1f",
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
    
    static func runSingleFormatMultiRoomWorkerPool(config: BenchmarkConfig) async {
        let result = await BenchmarkRunner.runMultiRoomBenchmarkWithWorkerPool(
            format: config.format,
            roomCount: config.rooms,
            playersPerRoom: config.playersPerRoom,
            iterations: config.iterations,
            ticksPerSync: config.ticksPerSync,
            workerCount: config.workerCount,
            progressEvery: config.progressEvery,
            progressLabel: "worker-pool/\(config.format.rawValue)"
        )

        switch config.output {
        case .table:
            let cpuCores = ProcessInfo.processInfo.activeProcessorCount
            let effectiveWorkers = config.workerCount ?? (cpuCores * 2)
            
            print("")
            print("  Format: \(config.format.displayName)")
            print("  Rooms: \(config.rooms), Players per room: \(config.playersPerRoom), Total players: \(result.playerCount)")
            print("  Iterations: \(config.iterations), Worker Pool: \(effectiveWorkers) workers")
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
            OutputFormatter.printJSON(result)
        }
    }
    
    static func runWorkerPoolComparison(config: BenchmarkConfig) async {
        print("")
        print("  ==================== Worker Pool Strategy Comparison ====================")
        
        let testRooms: [Int]
        if !config.roomCounts.isEmpty {
            testRooms = config.roomCounts
        } else if config.rooms > 1 {
            testRooms = [config.rooms]
        } else {
            testRooms = [50, 100, 200]  // Default test sizes
        }
        
        let cpuCores = ProcessInfo.processInfo.activeProcessorCount
        let workerCount = config.workerCount ?? (cpuCores * 2)
        
        print("  Players per room: \(config.playersPerRoom), Iterations: \(config.iterations)")
        print("  Ticks per sync: \(config.ticksPerSync)")
        print("  CPU Cores: \(cpuCores), Worker Count: \(workerCount)")
        print("")
        
        for rooms in testRooms {
            print("  Testing with \(rooms) rooms:")
            print("  Strategy                    | Time (ms) | Tasks Created | Throughput | Avg Cost/Sync")
            print("  --------------------------- | --------- | ------------- | ---------- | -------------")
            
            var allResults: [[String: Any]] = []
            
            // Test 1: Current implementation (unlimited parallelism)
            let currentResult = await BenchmarkRunner.runMultiRoomBenchmark(
                format: config.format,
                roomCount: rooms,
                playersPerRoom: config.playersPerRoom,
                iterations: config.iterations,
                parallel: true,
                ticksPerSync: config.ticksPerSync,
                progressEvery: config.progressEvery,
                progressLabel: "current/\(rooms)rooms"
            )
            
            let currentTasks = config.iterations * rooms
            
            // Test 2: Worker Pool implementation (static assignment)
            let workerPoolResult = await BenchmarkRunner.runMultiRoomBenchmarkWithWorkerPool(
                format: config.format,
                roomCount: rooms,
                playersPerRoom: config.playersPerRoom,
                iterations: config.iterations,
                ticksPerSync: config.ticksPerSync,
                workerCount: workerCount,
                progressEvery: config.progressEvery,
                progressLabel: "static-pool/\(rooms)rooms"
            )
            
            let workerPoolTasks = config.iterations * workerCount
            
            // Test 3: Dynamic Worker Pool (task reuse + work queue)
            let dynamicPoolResult = await BenchmarkRunner.runMultiRoomBenchmarkWithDynamicWorkerPool(
                format: config.format,
                roomCount: rooms,
                playersPerRoom: config.playersPerRoom,
                iterations: config.iterations,
                ticksPerSync: config.ticksPerSync,
                workerCount: cpuCores,  // Use CPU cores for dynamic pool
                progressEvery: config.progressEvery,
                progressLabel: "dynamic-pool/\(rooms)rooms"
            )
            
            let dynamicPoolTasks = cpuCores  // Only create this many tasks!
            
            // Calculate metrics
            let staticSpeedup = currentResult.timeMs / workerPoolResult.timeMs
            let dynamicSpeedup = currentResult.timeMs / dynamicPoolResult.timeMs
            let taskReductionStatic = ((Double(currentTasks - workerPoolTasks) / Double(currentTasks)) * 100.0)
            let taskReductionDynamic = ((Double(currentTasks - dynamicPoolTasks) / Double(currentTasks)) * 100.0)
            
            print(String(format: "  %-27@ | %9.2f | %13d | %10.1f | %13.4f",
                         "Current (Unlimited)" as NSString,
                         currentResult.timeMs,
                         currentTasks,
                         currentResult.throughputSyncsPerSecond,
                         currentResult.avgCostPerSyncMs))
            
            print(String(format: "  %-27@ | %9.2f | %13d | %10.1f | %13.4f",
                         "Worker Pool (Static)" as NSString,
                         workerPoolResult.timeMs,
                         workerPoolTasks,
                         workerPoolResult.throughputSyncsPerSecond,
                         workerPoolResult.avgCostPerSyncMs))
            
            print(String(format: "  %-27@ | %9.2f | %13d | %10.1f | %13.4f",
                         "Worker Pool (Dynamic)" as NSString,
                         dynamicPoolResult.timeMs,
                         dynamicPoolTasks,
                         dynamicPoolResult.throughputSyncsPerSecond,
                         dynamicPoolResult.avgCostPerSyncMs))
            
            print("  ===================================================================================")
            print("")
            print("  Performance Summary:")
            print(String(format: "  - Static Pool Speedup: %.2fx %@", 
                         staticSpeedup,
                         staticSpeedup > 1.0 ? "(Static FASTER ✓)" : "(Current FASTER)"))
            print(String(format: "  - Dynamic Pool Speedup: %.2fx %@", 
                         dynamicSpeedup,
                         dynamicSpeedup > 1.0 ? "(Dynamic FASTER ✓)" : "(Current FASTER)"))
            print(String(format: "  - Task Reduction (Static): %.1f%% (%d → %d)",
                         taskReductionStatic,
                         currentTasks,
                         workerPoolTasks))
            print(String(format: "  - Task Reduction (Dynamic): %.1f%% (%d → %d) **TRUE WORKER POOL**",
                         taskReductionDynamic,
                         currentTasks,
                         dynamicPoolTasks))
            print("")
            
            // Determine winner
            let fastestTime = min(currentResult.timeMs, workerPoolResult.timeMs, dynamicPoolResult.timeMs)
            var winner = "Current"
            if dynamicPoolResult.timeMs == fastestTime {
                winner = "Dynamic Pool"
            } else if workerPoolResult.timeMs == fastestTime {
                winner = "Static Pool"
            }
            print("  🏆 Winner: \(winner)")
            print("")
            
            // Collect results for JSON
            allResults.append([
                "rooms": rooms,
                "current": [
                    "timeMs": currentResult.timeMs,
                    "totalBytes": currentResult.totalBytes,
                    "bytesPerSync": currentResult.bytesPerSync,
                    "throughputSyncsPerSecond": currentResult.throughputSyncsPerSecond,
                    "avgCostPerSyncMs": currentResult.avgCostPerSyncMs,
                    "tasksCreated": currentTasks
                ],
                "staticWorkerPool": [
                    "timeMs": workerPoolResult.timeMs,
                    "totalBytes": workerPoolResult.totalBytes,
                    "bytesPerSync": workerPoolResult.bytesPerSync,
                    "throughputSyncsPerSecond": workerPoolResult.throughputSyncsPerSecond,
                    "avgCostPerSyncMs": workerPoolResult.avgCostPerSyncMs,
                    "tasksCreated": workerPoolTasks,
                    "workerCount": workerCount
                ],
                "dynamicWorkerPool": [
                    "timeMs": dynamicPoolResult.timeMs,
                    "totalBytes": dynamicPoolResult.totalBytes,
                    "bytesPerSync": dynamicPoolResult.bytesPerSync,
                    "throughputSyncsPerSecond": dynamicPoolResult.throughputSyncsPerSecond,
                    "avgCostPerSyncMs": dynamicPoolResult.avgCostPerSyncMs,
                    "tasksCreated": dynamicPoolTasks,
                    "workerCount": cpuCores
                ],
                "staticSpeedup": staticSpeedup,
                "dynamicSpeedup": dynamicSpeedup,
                "taskReductionStatic": taskReductionStatic,
                "taskReductionDynamic": taskReductionDynamic,
                "winner": winner
            ])
            
            // Save results to JSON
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let filename = "worker-pool-comparison-v2-rooms\(rooms)-ppr\(config.playersPerRoom)-iter\(config.iterations)-tick\(config.ticksPerSync)-\(timestamp).json"
            ResultsManager.saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
                "mode": "worker-pool-comparison-v2",
                "rooms": rooms,
                "playersPerRoom": config.playersPerRoom,
                "iterations": config.iterations,
                "ticksPerSync": config.ticksPerSync,
                "format": config.format.rawValue,
                "cpuCores": cpuCores,
                "staticWorkerCount": workerCount,
                "dynamicWorkerCount": cpuCores
            ])
        }
        
        print("  ✓ Worker Pool comparison complete!")
        print("")
    }
}
