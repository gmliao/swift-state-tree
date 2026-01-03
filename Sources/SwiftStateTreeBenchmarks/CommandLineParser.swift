// Sources/SwiftStateTreeBenchmarks/CommandLineParser.swift

import Foundation

/// Command line argument parser for benchmark tool
struct CommandLineParser {
    let suiteTypes: [BenchmarkSuiteType]
    let showHelp: Bool
    let hasError: Bool
    let errorMessage: String?
    let showCSV: Bool
    /// Optional override for TransportAdapter dirty tracking in benchmarks.
    /// - nil  : use each suite's default
    /// - true : force enable dirty tracking
    /// - false: force disable dirty tracking
    let transportDirtyTrackingOverride: Bool?
    /// Optional override for TransportAdapter dirty player ratio in benchmarks.
    /// - nil  : use suite defaults (Low/Medium/High)
    /// - 0.0~1.0: approximate ratio of players to modify per tick
    let transportDirtyRatioOverride: Double?
    /// Whether to skip the interactive "Press Enter" prompt before running benchmarks.
    let skipWaitForEnter: Bool
    /// Optional filter to run only a specific suite by name (exact match).
    let suiteNameFilter: String?
    /// Optional override for player counts to test (e.g., "4,10,20,30,50").
    /// If nil, uses each suite's default player counts.
    let playerCountsOverride: [Int]?
    /// Optional override for parallel encoding concurrency levels (e.g., "1,2,4,8").
    /// If nil, uses each suite's default concurrency levels.
    let parallelConcurrencyOverride: [Int]?
    /// Optional override for room counts in multi-room benchmarks (e.g., "1,2,4,8").
    /// If nil, uses each suite's default room counts.
    let roomCountsOverride: [Int]?
    /// Optional override for multi-room tick mode ("synchronized" or "staggered").
    /// If nil, uses each suite's default tick mode.
    let tickModeOverride: TransportAdapterMultiRoomParallelEncodingBenchmarkRunner.TickMode?
    /// Optional override for multi-room tick strides (e.g., "1,2,3,4").
    /// If nil, uses each suite's default tick strides.
    let tickStridesOverride: [Int]?

    init() {
        let arguments = CommandLine.arguments.dropFirst()

        // Default values
        var showHelp = false
        var showCSV = false
        var dirtyOverride: Bool? = nil
        var dirtyRatioOverride: Double? = nil
        var skipWaitForEnter = false
        var suiteNameFilter: String? = nil
        var playerCountsOverride: [Int]? = nil
        var parallelConcurrencyOverride: [Int]? = nil
        var roomCountsOverride: [Int]? = nil
        var tickModeOverride: TransportAdapterMultiRoomParallelEncodingBenchmarkRunner.TickMode? = nil
        var tickStridesOverride: [Int]? = nil

        // Parse suite types from arguments (exclude flags)
        var types: [BenchmarkSuiteType] = []
        var invalidArgs: [String] = []

        for arg in arguments {
            // Flags that do not consume suite names
            if arg == "--help" || arg == "-h" {
                showHelp = true
                continue
            }
            if arg == "--csv" || arg == "-c" {
                showCSV = true
                continue
            }
            if arg == "--dirty-on" {
                dirtyOverride = true
                continue
            }
            if arg == "--dirty-off" {
                dirtyOverride = false
                continue
            }
            if arg == "--no-wait" {
                skipWaitForEnter = true
                continue
            }
            if arg.hasPrefix("--dirty-ratio=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let value = Double(parts[1]) {
                    dirtyRatioOverride = value
                } else {
                    invalidArgs.append(arg)
                }
                continue
            }
            if arg.hasPrefix("--suite-name=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    suiteNameFilter = String(parts[1])
                } else {
                    invalidArgs.append(arg)
                }
                continue
            }
            if arg.hasPrefix("--player-counts=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let countsString = String(parts[1])
                    let counts = countsString.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if !counts.isEmpty {
                        playerCountsOverride = counts
                    } else {
                        invalidArgs.append(arg)
                    }
                } else {
                    invalidArgs.append(arg)
                }
                continue
            }
            if arg.hasPrefix("--parallel-concurrency=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let levelsString = String(parts[1])
                    let levels = levelsString.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if !levels.isEmpty {
                        parallelConcurrencyOverride = levels
                    } else {
                        invalidArgs.append(arg)
                    }
                } else {
                    invalidArgs.append(arg)
                }
                continue
            }
            if arg.hasPrefix("--room-counts=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let countsString = String(parts[1])
                    let counts = countsString.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if !counts.isEmpty {
                        roomCountsOverride = counts
                    } else {
                        invalidArgs.append(arg)
                    }
                } else {
                    invalidArgs.append(arg)
                }
                continue
            }
            if arg.hasPrefix("--tick-mode=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let value = String(parts[1]).lowercased()
                    if let mode = TransportAdapterMultiRoomParallelEncodingBenchmarkRunner.TickMode(rawValue: value) {
                        tickModeOverride = mode
                    } else {
                        invalidArgs.append(arg)
                    }
                } else {
                    invalidArgs.append(arg)
                }
                continue
            }
            if arg.hasPrefix("--tick-strides=") {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let countsString = String(parts[1])
                    let counts = countsString.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if !counts.isEmpty {
                        tickStridesOverride = counts
                    } else {
                        invalidArgs.append(arg)
                    }
                } else {
                    invalidArgs.append(arg)
                }
                continue
            }

            // Suite type argument
            if let suiteType = BenchmarkSuiteType(rawValue: arg.lowercased()) {
                types.append(suiteType)
            } else {
                invalidArgs.append(arg)
            }
        }

        // If invalid arguments provided, show error
        if !invalidArgs.isEmpty {
            self.showHelp = false
            self.suiteTypes = []
            self.hasError = true
            self.errorMessage = "Unknown benchmark suite(s): \(invalidArgs.joined(separator: ", "))"
            self.showCSV = showCSV
            self.transportDirtyTrackingOverride = dirtyOverride
            self.transportDirtyRatioOverride = dirtyRatioOverride
            self.skipWaitForEnter = skipWaitForEnter
            self.suiteNameFilter = suiteNameFilter
            self.playerCountsOverride = playerCountsOverride
            self.parallelConcurrencyOverride = parallelConcurrencyOverride
            self.roomCountsOverride = roomCountsOverride
            self.tickModeOverride = tickModeOverride
            self.tickStridesOverride = tickStridesOverride
            return
        }

        // If no arguments provided, run all
        if types.isEmpty {
            types = [.all]
        }

        self.suiteTypes = types
        self.showHelp = showHelp
        self.hasError = false
        self.errorMessage = nil
        self.showCSV = showCSV
        self.transportDirtyTrackingOverride = dirtyOverride
        self.transportDirtyRatioOverride = dirtyRatioOverride
        self.skipWaitForEnter = skipWaitForEnter
        self.suiteNameFilter = suiteNameFilter
        self.playerCountsOverride = playerCountsOverride
        self.parallelConcurrencyOverride = parallelConcurrencyOverride
        self.roomCountsOverride = roomCountsOverride
        self.tickModeOverride = tickModeOverride
        self.tickStridesOverride = tickStridesOverride
    }

    static func printUsage() {
        print("""
        Usage: swift run SwiftStateTreeBenchmarks [suite...]

        Available benchmark suites:
          single         - Single-threaded execution
          diff           - Standard vs Optimized diff comparison
          mirror         - Mirror vs Macro comparison
          transport-sync - TransportAdapter Sync Performance
          transport-sync-players - TransportAdapter Sync (broadcast players mutated each tick)
          transport-concurrent-stability - TransportAdapter Concurrent Sync Stability Test
          transport-parallel-tuning - TransportAdapter Parallel Encoding Tuning
          transport-multiroom-parallel-tuning - TransportAdapter Multi-Room Parallel Encoding Tuning
          all            - Run all suites (default)

        Examples:
          swift run SwiftStateTreeBenchmarks
          swift run SwiftStateTreeBenchmarks single parallel
          swift run SwiftStateTreeBenchmarks diff mirror
          swift run SwiftStateTreeBenchmarks all

        Options:
          -h, --help          - Show this help message
          -c, --csv           - Include CSV output in summary
          --dirty-on          - Force enable dirty tracking for TransportAdapter sync benchmarks
          --dirty-off         - Force disable dirty tracking for TransportAdapter sync benchmarks
          --dirty-ratio=VAL   - Override dirty player ratio (0.0–1.0) for TransportAdapter sync benchmarks
          --suite-name=NAME   - Run only the suite with exact name match (useful for isolated testing)
          --player-counts=VAL - Override player counts to test (comma-separated, e.g., \"4,10,20,30,50\")
          --parallel-concurrency=VAL - Override parallel encoding concurrency levels (comma-separated, e.g., \"1,2,4,8\")
          --room-counts=VAL   - Override room counts for multi-room benchmarks (comma-separated, e.g., \"1,2,4,8\")
          --tick-mode=VAL     - Override tick mode for multi-room benchmarks (\"synchronized\" or \"staggered\")
          --tick-strides=VAL  - Override tick strides for multi-room benchmarks (comma-separated, e.g., \"1,2,3,4\")
          --no-wait           - Skip \"Press Enter\" prompt (useful for automated scripts)
        """)
    }

    func printError() {
        if let errorMessage = errorMessage {
            print("Error: \(errorMessage)")
            print("")
            Self.printUsage()
        }
    }
}
