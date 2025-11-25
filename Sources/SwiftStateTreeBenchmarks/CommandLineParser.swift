// Sources/SwiftStateTreeBenchmarks/CommandLineParser.swift

import Foundation

/// Command line argument parser for benchmark tool
struct CommandLineParser {
    let suiteTypes: [BenchmarkSuiteType]
    let showHelp: Bool
    let hasError: Bool
    let errorMessage: String?
    let showCSV: Bool
    
    init() {
        let arguments = CommandLine.arguments.dropFirst()
        
        if arguments.contains("--help") || arguments.contains("-h") {
            self.showHelp = true
            self.suiteTypes = []
            self.hasError = false
            self.errorMessage = nil
            self.showCSV = false
            return
        }
        
        // Check for CSV output flag
        self.showCSV = arguments.contains("--csv") || arguments.contains("-c")
        
        // Parse suite types from arguments (exclude flags)
        var types: [BenchmarkSuiteType] = []
        var invalidArgs: [String] = []
        
        for arg in arguments {
            // Skip flags
            if arg == "--csv" || arg == "-c" {
                continue
            }
            
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
            return
        }
        
        // If no arguments provided, run all
        if types.isEmpty {
            types = [.all]
        }
        
        self.suiteTypes = types
        self.showHelp = false
        self.hasError = false
        self.errorMessage = nil
    }
    
    static func printUsage() {
        print("""
        Usage: swift run SwiftStateTreeBenchmarks [suite...]
        
        Available benchmark suites:
          single      - Single-threaded execution
          parallel    - Parallel execution
          multiplayer - Multi-player parallel execution
          diff        - Standard vs Optimized diff comparison
          mirror      - Mirror vs Macro comparison
          all         - Run all suites (default)
        
        Examples:
          swift run SwiftStateTreeBenchmarks
          swift run SwiftStateTreeBenchmarks single parallel
          swift run SwiftStateTreeBenchmarks diff mirror
          swift run SwiftStateTreeBenchmarks all
        
        Options:
          -h, --help  - Show this help message
          -c, --csv   - Include CSV output in summary
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

