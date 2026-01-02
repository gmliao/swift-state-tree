// Sources/SwiftStateTreeBenchmarks/ParallelEncodeBenchmarkRunner.swift

import Darwin
import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

actor EncodeThreadRecorder {
    private var threadIDs: Set<UInt64> = []

    func recordCurrentThread() {
        threadIDs.insert(currentThreadID())
    }

    func reset() {
        threadIDs.removeAll()
    }

    func uniqueThreadCount() -> Int {
        threadIDs.count
    }
}

private func currentThreadID() -> UInt64 {
    var tid: UInt64 = 0
    pthread_threadid_np(nil, &tid)
    return tid
}

struct ParallelEncodeBenchmarkRunner: BenchmarkRunner {
    enum Mode: String {
        case serial = "serial"
        case parallel = "parallel"
        case both = "both"

        static var current: Mode {
            if let envValue = ProcessInfo.processInfo.environment["PARALLEL_ENCODE_MODE"]?.lowercased(),
               let mode = Mode(rawValue: envValue) {
                return mode
            }
            return .both
        }
    }

    private struct Metrics {
        let averageTime: TimeInterval
        let minTime: TimeInterval
        let maxTime: TimeInterval
        let throughput: Double
        let threadCount: Int?
    }

    let playerCounts: [Int]
    let codec = JSONTransportCodec()
    let chunkSize: Int
    let probeParallelism: Bool

    init(
        playerCounts: [Int] = [4, 10, 20, 30, 50],
        chunkSize: Int? = nil,
        probeParallelism: Bool? = nil
    ) {
        self.playerCounts = playerCounts
        if let chunkSize, chunkSize > 0 {
            self.chunkSize = chunkSize
        } else if let envValue = ProcessInfo.processInfo.environment["PARALLEL_ENCODE_CHUNK"],
                  let envChunk = Int(envValue),
                  envChunk > 0 {
            self.chunkSize = envChunk
        } else {
            self.chunkSize = 1
        }
        if let probeParallelism {
            self.probeParallelism = probeParallelism
        } else {
            let envValue = ProcessInfo.processInfo.environment["PARALLEL_ENCODE_PROBE"]?.lowercased()
            self.probeParallelism = envValue != "0"
        }
    }

    func run(
        config: BenchmarkConfig,
        state: BenchmarkStateRootNode,
        playerID: PlayerID
    ) async -> BenchmarkResult {
        _ = state
        _ = playerID

        print("  Parallel Encode Experiment (JSON)")
        print("  =================================")
        print("  Mode: \(Mode.current.rawValue), Chunk: \(chunkSize), Encoding: \(codec.encoding.rawValue)")

        var firstResult: BenchmarkResult?
        let mode = Mode.current
        let coreCount = ProcessInfo.processInfo.processorCount

        for playerCount in playerCounts {
            print("\n  Testing with \(playerCount) players...")
            let playerIDs = (0..<playerCount).map { PlayerID("player_\($0)") }
            let updates = makeUpdates(playerIDs: playerIDs, cardsPerPlayer: config.cardsPerPlayer)
            let averageBytes = updates
                .compactMap { try? codec.encode($0).count }
                .reduce(0, +) / max(1, updates.count)

            let serialMetrics: Metrics?
            if mode == .serial || mode == .both {
                let metrics = await runSerial(
                    updates: updates,
                    iterations: config.iterations
                )
                print("    Serial avg: \(String(format: "%.4f", metrics.averageTime * 1000))ms")
                serialMetrics = metrics
                if mode == .serial {
                    firstResult = makeResult(
                        config: config,
                        playerCount: playerCount,
                        averageBytes: averageBytes,
                        metrics: metrics,
                        executionMode: "Encode (Serial)"
                    )
                }
            } else {
                serialMetrics = nil
            }

            let parallelMetrics: Metrics?
            if mode == .parallel || mode == .both {
                let metrics = await runParallel(
                    updates: updates,
                    iterations: config.iterations
                )
                print("    Parallel avg: \(String(format: "%.4f", metrics.averageTime * 1000))ms")
                if let threadCount = metrics.threadCount {
                    print("    Parallel probe: \(threadCount) unique threads used")
                }
                parallelMetrics = metrics
                if mode == .parallel {
                    firstResult = makeResult(
                        config: config,
                        playerCount: playerCount,
                        averageBytes: averageBytes,
                        metrics: metrics,
                        executionMode: "Encode (Concurrent TaskGroup)"
                    )
                }
            } else {
                parallelMetrics = nil
            }

            if mode == .both, let serialMetrics, let parallelMetrics {
                let speedup = serialMetrics.averageTime / parallelMetrics.averageTime
                let efficiency = (speedup / Double(coreCount)) * 100.0
                print("    Speedup: \(String(format: "%.2fx", speedup)) (theoretical: \(coreCount)x)")
                print("    Efficiency: \(String(format: "%.1f", efficiency))%")
                firstResult = makeResult(
                    config: config,
                    playerCount: playerCount,
                    averageBytes: averageBytes,
                    metrics: parallelMetrics,
                    executionMode: "Encode (Concurrent TaskGroup)"
                )
            }
        }

        return firstResult ?? BenchmarkResult(
            config: config,
            averageTime: 0,
            minTime: 0,
            maxTime: 0,
            snapshotSize: 0,
            throughput: 0,
            executionMode: "Encode (Concurrent TaskGroup)"
        )
    }

    private func runSerial(
        updates: [StateUpdate],
        iterations: Int
    ) async -> Metrics {
        _ = encodeSerial(updates: updates) // warmup

        var times: [TimeInterval] = []
        times.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let elapsed = measureTime {
                _ = encodeSerial(updates: updates)
            }
            times.append(elapsed)
        }

        return summarize(times: times, threadCount: nil)
    }

    private func runParallel(
        updates: [StateUpdate],
        iterations: Int
    ) async -> Metrics {
        _ = await encodeParallel(updates: updates, threadRecorder: nil) // warmup

        let recorder = EncodeThreadRecorder()
        var threadCount: Int? = nil
        if probeParallelism {
            await recorder.reset()
            _ = await encodeParallel(updates: updates, threadRecorder: recorder)
            threadCount = await recorder.uniqueThreadCount()
        }

        var times: [TimeInterval] = []
        times.reserveCapacity(iterations)

        for _ in 0..<iterations {
            let elapsed = await measureTimeAsync {
                _ = await encodeParallel(updates: updates, threadRecorder: nil)
            }
            times.append(elapsed)
        }

        return summarize(times: times, threadCount: threadCount)
    }

    private func encodeSerial(updates: [StateUpdate]) -> Int {
        var totalBytes = 0
        for update in updates {
            if let encoded = try? codec.encode(update) {
                totalBytes += encoded.count
            }
        }
        return totalBytes
    }

    private func encodeParallel(
        updates: [StateUpdate],
        threadRecorder: EncodeThreadRecorder?
    ) async -> Int {
        let totalUpdates = updates.count
        let chunkSize = max(1, min(self.chunkSize, totalUpdates))

        return await withTaskGroup(of: Int.self) { group in
            var startIndex = 0
            while startIndex < totalUpdates {
                let endIndex = min(startIndex + chunkSize, totalUpdates)
                let chunk = Array(updates[startIndex..<endIndex])

                group.addTask {
                    if let threadRecorder {
                        await threadRecorder.recordCurrentThread()
                    }
                    var totalBytes = 0
                    let codec = JSONTransportCodec()
                    for update in chunk {
                        if let encoded = try? codec.encode(update) {
                            totalBytes += encoded.count
                        }
                    }
                    return totalBytes
                }

                startIndex = endIndex
            }

            var totalBytes = 0
            for await bytes in group {
                totalBytes += bytes
            }
            return totalBytes
        }
    }

    private func makeUpdates(
        playerIDs: [PlayerID],
        cardsPerPlayer: Int
    ) -> [StateUpdate] {
        let cards: [SnapshotValue] = (0..<cardsPerPlayer).map { index in
            .object([
                "id": .int(index),
                "suit": .int(index % 4),
                "rank": .int(index % 13)
            ])
        }

        return playerIDs.map { playerID in
            let handValue: SnapshotValue = .object([
                "ownerID": .string(playerID.rawValue),
                "cards": .array(cards)
            ])
            let handPath = "/hands/\(escapeJsonPointer(playerID.rawValue))"
            let patches = [
                StatePatch(path: "/round", operation: .set(.int(1))),
                StatePatch(path: handPath, operation: .set(handValue))
            ]
            return .diff(patches)
        }
    }

    private func escapeJsonPointer(_ value: String) -> String {
        value.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }

    private func summarize(times: [TimeInterval], threadCount: Int?) -> Metrics {
        let average = times.reduce(0, +) / Double(times.count)
        let minTime = times.min() ?? 0
        let maxTime = times.max() ?? 0
        let throughput = 1.0 / average
        return Metrics(
            averageTime: average,
            minTime: minTime,
            maxTime: maxTime,
            throughput: throughput,
            threadCount: threadCount
        )
    }

    private func makeResult(
        config: BenchmarkConfig,
        playerCount: Int,
        averageBytes: Int,
        metrics: Metrics,
        executionMode: String
    ) -> BenchmarkResult {
        BenchmarkResult(
            config: BenchmarkConfig(
                name: config.name,
                playerCount: playerCount,
                cardsPerPlayer: config.cardsPerPlayer,
                iterations: config.iterations
            ),
            averageTime: metrics.averageTime,
            minTime: metrics.minTime,
            maxTime: metrics.maxTime,
            snapshotSize: averageBytes,
            throughput: metrics.throughput,
            executionMode: executionMode
        )
    }
}
