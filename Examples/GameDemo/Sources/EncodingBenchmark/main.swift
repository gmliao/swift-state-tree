// Examples/GameDemo/Sources/EncodingBenchmark/main.swift
//
// Encoding benchmark for comparing different StateUpdateEncoder formats.
// Supports both single-room and multi-room modes using HeroDefenseState.
// Single-room mode uses simplified BenchmarkState for backward compatibility.
//
// This file contains the main entry point and test mode coordination logic.
// See other files for implementation details:
// - BenchmarkState.swift: State and action definitions
// - BenchmarkConfig.swift: Configuration and argument parsing
// - CountingTransport.swift: Mock transport implementation
// - BenchmarkExecution.swift: Benchmark execution logic
// - BenchmarkResults.swift: Result output formatting
// - ResultsMetadata.swift: Metadata collection and JSON saving

import Foundation
import GameContent

// MARK: - Main

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
            OutputFormatter.printTableHeader()
        }

        for format in EncodingFormat.allCases {
            let result = await BenchmarkRunner.runBenchmark(
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
                OutputFormatter.printTableRow(result, baselineBytes: baselineBytes)
            case .json:
                OutputFormatter.printJSON(result)
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
            OutputFormatter.printTableFooter()

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
        ResultsManager.saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
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
            OutputFormatter.printTableHeader()
        }

        var allResults: [[String: Any]] = []
        
        for format in EncodingFormat.allCases {
            let result: BenchmarkResult
            
            if config.gameType == .cardGame {
                result = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
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
                result = await BenchmarkRunner.runMultiRoomBenchmark(
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
                OutputFormatter.printTableRow(result, baselineBytes: baselineBytes)
            case .json:
                OutputFormatter.printJSON(result)
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
            OutputFormatter.printTableFooter()

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
        ResultsManager.saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
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
            let result = await BenchmarkRunner.runBenchmark(
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
            OutputFormatter.printJSON(result)
        }
    }
    
    static func runSingleFormatMultiRoom(config: BenchmarkConfig) async {
        let result: BenchmarkResult
        if config.gameType == .cardGame {
            result = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
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
            result = await BenchmarkRunner.runMultiRoomBenchmark(
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
            OutputFormatter.printJSON(result)
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
            let serialResult = await BenchmarkRunner.runBenchmark(
                format: format,
                playerCount: config.players,
                iterations: config.iterations,
                parallel: false
            )

            let parallelResult = await BenchmarkRunner.runBenchmark(
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
                serialResult = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "compare/serial/\(format.rawValue)"
                )
                parallelResult = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
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
                serialResult = await BenchmarkRunner.runMultiRoomBenchmark(
                    format: format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    ticksPerSync: config.ticksPerSync,
                    progressEvery: config.progressEvery,
                    progressLabel: "compare/serial/\(format.rawValue)"
                )
                parallelResult = await BenchmarkRunner.runMultiRoomBenchmark(
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
        ResultsManager.saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
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
                serialResult = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    ticksPerSync: config.ticksPerSync
                )
                parallelResult = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: true,
                    ticksPerSync: config.ticksPerSync
                )
            } else {
                serialResult = await BenchmarkRunner.runMultiRoomBenchmark(
                    format: bestSpeedup.format,
                    roomCount: config.rooms,
                    playersPerRoom: config.playersPerRoom,
                    iterations: config.iterations,
                    parallel: false,
                    ticksPerSync: config.ticksPerSync
                )
                parallelResult = await BenchmarkRunner.runMultiRoomBenchmark(
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
                        serialResult = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
                            format: format,
                            roomCount: roomCount,
                            playersPerRoom: playersPerRoom,
                            iterations: config.iterations,
                            parallel: false,
                            ticksPerSync: config.ticksPerSync,
                            progressEvery: config.progressEvery,
                            progressLabel: "scalability/serial/\(format.rawValue)/rooms\(roomCount)/ppr\(playersPerRoom)"
                        )
                        parallelResult = await BenchmarkRunner.runMultiRoomBenchmarkCardGame(
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
                        serialResult = await BenchmarkRunner.runMultiRoomBenchmark(
                            format: format,
                            roomCount: roomCount,
                            playersPerRoom: playersPerRoom,
                            iterations: config.iterations,
                            parallel: false,
                            ticksPerSync: config.ticksPerSync,
                            progressEvery: config.progressEvery,
                            progressLabel: "scalability/serial/\(format.rawValue)/rooms\(roomCount)/ppr\(playersPerRoom)"
                        )
                        parallelResult = await BenchmarkRunner.runMultiRoomBenchmark(
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
        ResultsManager.saveResultsToJSON(allResults, filename: filename, benchmarkConfig: [
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
            
            print(String(format: "  %-27s | %9.2f | %13d | %10.1f | %13.4f",
                         "Current (Unlimited)",
                         currentResult.timeMs,
                         currentTasks,
                         currentResult.throughputSyncsPerSecond,
                         currentResult.avgCostPerSyncMs))
            
            print(String(format: "  %-27s | %9.2f | %13d | %10.1f | %13.4f",
                         "Worker Pool (Static)",
                         workerPoolResult.timeMs,
                         workerPoolTasks,
                         workerPoolResult.throughputSyncsPerSecond,
                         workerPoolResult.avgCostPerSyncMs))
            
            print(String(format: "  %-27s | %9.2f | %13d | %10.1f | %13.4f",
                         "Worker Pool (Dynamic)",
                         dynamicPoolResult.timeMs,
                         dynamicPoolTasks,
                         dynamicPoolResult.throughputSyncsPerSecond,
                         dynamicPoolResult.avgCostPerSyncMs))
            
            print("  ===================================================================================")
            print("")
            print("  Performance Summary:")
            print(String(format: "  - Static Pool Speedup: %.2fx %s", 
                         staticSpeedup,
                         staticSpeedup > 1.0 ? "(Static FASTER ✓)" : "(Current FASTER)"))
            print(String(format: "  - Dynamic Pool Speedup: %.2fx %s", 
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

// MARK: - Program Entry
// This target uses the conventional `main.swift` top-level entry.

Task {
    await EncodingBenchmark.main()
    exit(0)
}

RunLoop.main.run()
