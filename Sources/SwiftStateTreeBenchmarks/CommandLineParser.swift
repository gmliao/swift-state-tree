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
    
    init() {
        let arguments = CommandLine.arguments.dropFirst()
        
        // Default values
        var showHelp = false
        var showCSV = false
        var dirtyOverride: Bool? = nil
        var dirtyRatioOverride: Double? = nil
        var skipWaitForEnter = false
        
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
