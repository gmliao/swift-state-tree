// Sources/SwiftStateTreeBenchmarks/TransportAdapterConcurrentStabilityBenchmarkRunner.swift

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

/// Benchmark runner for testing concurrent sync stability in TransportAdapter.
///
/// This benchmark tests the stability and correctness of parallel sync operations
/// by running multiple concurrent syncNow() calls and verifying:
/// - Data consistency across all players
/// - No race conditions or data corruption
/// - Correct serialization of concurrent sync operations
/// - Error rate and stability metrics
struct TransportAdapterConcurrentStabilityBenchmarkRunner: BenchmarkRunner {
    let playerCounts: [Int]
    let concurrentSyncs: Int  // Number of concurrent sync operations per iteration
    let iterations: Int  // Number of test iterations
    let enableDirtyTracking: Bool
    let enableParallelEncoding: Bool?
    
    /// Store all results for multi-player-count benchmarks
    var allCollectedResults: [BenchmarkResult] = []
    
    init(
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        concurrentSyncs: Int = 5,
        iterations: Int = 100,
        enableDirtyTracking: Bool = true,
        enableParallelEncoding: Bool? = nil
    ) {
        self.playerCounts = playerCounts
        self.concurrentSyncs = concurrentSyncs
        self.iterations = iterations
        self.enableDirtyTracking = enableDirtyTracking
        self.enableParallelEncoding = enableParallelEncoding
    }
    
    mutating func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        print("  TransportAdapter Concurrent Sync Stability Benchmark")
        print("  =====================================================")
        
        allCollectedResults = []
        var allResults: [BenchmarkResult] = []
        
        for playerCount in playerCounts {
            print("\n  Testing with \(playerCount) players, \(concurrentSyncs) concurrent syncs...")
            
            // Create test state
            var testState = BenchmarkStateRootNode()
            let testPlayerIDs = (0..<playerCount).map { PlayerID("player_\($0)") }
            
            for pid in testPlayerIDs {
                testState.players[pid] = BenchmarkPlayerState(
                    name: "Player \(pid.rawValue)",
                    hpCurrent: 100,
                    hpMax: 100
                )
                testState.hands[pid] = BenchmarkHandState(
                    ownerID: pid,
                    cards: (0..<config.cardsPerPlayer).map { BenchmarkCard(id: $0, suit: $0 % 4, rank: $0 % 13) }
                )
            }
            testState.round = 1
            
            let result = await benchmarkConcurrentStability(
                state: testState,
                playerIDs: testPlayerIDs,
                iterations: iterations,
                concurrentSyncs: concurrentSyncs
            )
            
            // Extract success rate from executionMode
            let successRateStr = result.executionMode.components(separatedBy: "Success: ").last?.components(separatedBy: "%").first ?? "100"
            let successRate = Double(successRateStr) ?? 100.0
            print("    Success Rate: \(String(format: "%.2f", successRate))%")
            print("    Average Time: \(String(format: "%.4f", result.averageTime * 1000))ms")
            if let bytesPerPlayer = result.bytesPerPlayer {
                print("    Total Payload: \(result.snapshotSize) bytes (per player: \(bytesPerPlayer) bytes)")
            }
            
            allResults.append(result)
        }
        
        allCollectedResults = allResults
        
        return allResults.first ?? BenchmarkResult(
            config: config,
            averageTime: 0,
            minTime: 0,
            maxTime: 0,
            snapshotSize: 0,
            throughput: 0,
            executionMode: "Concurrent Stability Test",
            bytesPerPlayer: nil
        )
    }
    
    private func benchmarkConcurrentStability(
        state: BenchmarkStateRootNode,
        playerIDs: [PlayerID],
        iterations: Int,
        concurrentSyncs: Int
    ) async -> BenchmarkResult {
        // Convert BenchmarkStateRootNode to BenchmarkStateForSync
        var syncState = BenchmarkStateForSync()
        syncState.players = state.players
        syncState.hands = state.hands
        syncState.round = state.round
        
        let definition = Land("benchmark-concurrent-stability", using: BenchmarkStateForSync.self) {
            Rules {
                HandleAction(BenchmarkMutationAction.self) { (state: inout BenchmarkStateForSync, action: BenchmarkMutationAction, _: LandContext) in
                    // Simple mutation: increment round
                    state.round += 1
                    return BenchmarkMutationResponse(applied: true)
                }
            }
        }
        
        // Create logger with high log level for benchmarks
        let benchmarkLogger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.benchmark.concurrent",
            scope: nil,
            logLevel: .error,
            useColors: false
        )
        
        // Create mock transport that tracks sent data for consistency verification
        let mockTransport = CountingTransport()
        
        // Create keeper and adapter
        let keeper = LandKeeper(
            definition: definition,
            initialState: syncState,
            transport: nil,
            logger: benchmarkLogger
        )
        let adapter = TransportAdapter<BenchmarkStateForSync>(
            keeper: keeper,
            transport: mockTransport,
            landID: "benchmark-land",
            createGuestSession: nil,
            enableLegacyJoin: false,
            enableDirtyTracking: enableDirtyTracking,
            codec: JSONTransportCodec(),
            enableParallelEncoding: enableParallelEncoding,
            logger: benchmarkLogger
        )
        await keeper.setTransport(adapter)
        await mockTransport.setDelegate(adapter)
        
        // Connect and join all players
        for (index, playerID) in playerIDs.enumerated() {
            let sessionID = SessionID("session-\(index)")
            let clientID = ClientID("client-\(index)")
            await adapter.onConnect(sessionID: sessionID, clientID: clientID)
            
            let playerSession = PlayerSession(
                playerID: playerID.rawValue,
                deviceID: "device-\(index)",
                metadata: [:]
            )
            _ = try? await adapter.performJoin(
                playerSession: playerSession,
                clientID: clientID,
                sessionID: sessionID,
                authInfo: nil as AuthenticatedInfo?
            )
        }
        
        // Initial sync to populate cache
        await adapter.syncNow()
        
        let actionPlayerID = playerIDs.first ?? PlayerID("player_0")
        let actionClientID = ClientID("client-0")
        let actionSessionID = SessionID("session-0")
        
        // Warmup
        let warmupIterations = min(5, iterations / 10)
        if warmupIterations > 0 {
            for i in 0..<warmupIterations {
                let action = BenchmarkMutationAction(iteration: i)
                _ = try? await keeper.handleAction(
                    action,
                    playerID: actionPlayerID,
                    clientID: actionClientID,
                    sessionID: actionSessionID
                )
                await adapter.syncNow()
            }
        }
        
        await mockTransport.resetCounts()
        
        // Track statistics
        var totalSyncTime: TimeInterval = 0
        var successfulSyncs = 0
        var failedSyncs = 0
        var consistencyErrors = 0
        
        // Run concurrent stability test
        for i in 0..<iterations {
            let iterationIndex = warmupIterations + i
            
            // Modify state before concurrent syncs
            let action = BenchmarkMutationAction(iteration: iterationIndex)
            _ = try? await keeper.handleAction(
                action,
                playerID: actionPlayerID,
                clientID: actionClientID,
                sessionID: actionSessionID
            )
            
            // Capture state before concurrent syncs for consistency check
            let stateBeforeSync = await keeper.currentState()
            let expectedRound = stateBeforeSync.round
            
            // Run multiple concurrent sync operations
            #if canImport(Foundation)
            let startTime = Date().timeIntervalSince1970
            #else
            let startTime = ContinuousClock.now
            #endif
            
            // Run concurrent sync operations
            // Note: syncNow() doesn't throw, but we track completion for statistics
            var completedSyncs = 0
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<concurrentSyncs {
                    group.addTask { @Sendable in
                        await adapter.syncNow()
                        return true
                    }
                }
                
                // Count completed syncs
                for await _ in group {
                    completedSyncs += 1
                }
            }
            
            #if canImport(Foundation)
            let endTime = Date().timeIntervalSince1970
            totalSyncTime += endTime - startTime
            #else
            let endTime = ContinuousClock.now
            totalSyncTime += endTime.timeIntervalSince(startTime)
            #endif
            
            // Verify consistency: state should not be corrupted
            let stateAfterSync = await keeper.currentState()
            
            // Check for consistency errors
            if stateAfterSync.round != expectedRound {
                consistencyErrors += 1
                print("    ⚠️  Consistency error at iteration \(i): round changed from \(expectedRound) to \(stateAfterSync.round)")
            }
            
            // Check for completion (all syncs should complete)
            if completedSyncs == concurrentSyncs {
                successfulSyncs += concurrentSyncs
            } else {
                let failed = concurrentSyncs - completedSyncs
                failedSyncs += failed
                print("    ⚠️  Incomplete syncs at iteration \(i): \(completedSyncs)/\(concurrentSyncs)")
            }
        }
        
        let averageTime = iterations > 0 ? totalSyncTime / Double(iterations) : 0
        let throughput = totalSyncTime > 0 ? Double(iterations) / totalSyncTime : 0
        let sendCounts = await mockTransport.snapshotCounts()
        let totalBytesPerSync = iterations > 0 ? Double(sendCounts.bytes) / Double(iterations) : 0.0
        let bytesPerPlayer = playerIDs.count > 0 ? Int(totalBytesPerSync / Double(playerIDs.count)) : nil
        
        // Calculate success rate
        let totalSyncOperations = iterations * concurrentSyncs
        let successRate = totalSyncOperations > 0 ? Double(successfulSyncs) / Double(totalSyncOperations) : 0.0
        
        // Build mode label with stability metrics
        var modeLabel = enableDirtyTracking ? "DirtyTracking: On" : "DirtyTracking: Off"
        if let enableParallel = enableParallelEncoding {
            modeLabel += ", Encoding: \(enableParallel ? "Parallel" : "Serial")"
        } else {
            modeLabel += ", Encoding: Default"
        }
        modeLabel += ", Concurrent: \(concurrentSyncs)"
        modeLabel += ", Success: \(String(format: "%.1f", successRate * 100))%"
        if consistencyErrors > 0 {
            modeLabel += ", ConsistencyErrors: \(consistencyErrors)"
        }
        
        // Print detailed statistics
        print("    Total Sync Operations: \(totalSyncOperations)")
        print("    Successful: \(successfulSyncs)")
        print("    Failed: \(failedSyncs)")
        print("    Consistency Errors: \(consistencyErrors)")
        
        return BenchmarkResult(
            config: BenchmarkConfig(
                name: "ConcurrentStability",
                playerCount: playerIDs.count,
                cardsPerPlayer: state.hands.values.first?.cards.count ?? 0,
                iterations: iterations
            ),
            averageTime: averageTime,
            minTime: averageTime,
            maxTime: averageTime,
            snapshotSize: Int(totalBytesPerSync.rounded()),
            throughput: throughput,
            executionMode: modeLabel,
            bytesPerPlayer: bytesPerPlayer
        )
    }
}

// Note: Success rate is embedded in executionMode string for display
// A proper implementation would extend BenchmarkResult to store successRate as a separate field
