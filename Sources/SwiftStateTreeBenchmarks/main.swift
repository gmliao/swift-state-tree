// Sources/SwiftStateTreeBenchmarks/main.swift

import Foundation
import SwiftStateTree

// MARK: - Main

@MainActor
func main() async {
    let parser = CommandLineParser()
    
    if parser.showHelp {
        CommandLineParser.printUsage()
        return
    }
    
    if parser.hasError {
        parser.printError()
        exit(1)
    }
    
    var allResults: [BenchmarkResult] = []
    
    // Get suite configurations based on command line arguments
    let suiteTypes = parser.suiteTypes.contains(.all) 
        ? BenchmarkSuiteType.allCases.filter { $0 != .all }
        : parser.suiteTypes
    
    // Only show main title if running all suites
    let isRunningAll = parser.suiteTypes.contains(.all) || suiteTypes.count > 1
    if isRunningAll {
        printBox(title: "SwiftStateTree Snapshot Generation Benchmark")
    }
    
    let suiteConfigs = suiteTypes.flatMap { BenchmarkSuites.get(suiteType: $0) }
    
    // Run selected benchmark suites
    for suiteConfig in suiteConfigs {
        let suite = BenchmarkSuite(
            name: suiteConfig.name,
            runner: suiteConfig.runner,
            configurations: suiteConfig.configurations
        )
        allResults.append(contentsOf: await suite.run())
    }
    
    // Print summary if we have results
    if !allResults.isEmpty {
        BenchmarkSummary(results: allResults, showCSV: parser.showCSV).printSummary()
    }
}

/// Print a box with title (fixed width to prevent layout issues)
private func printBox(title: String) {
    let boxWidth = 63
    let titleWidth = title.count
    let padding = max(0, boxWidth - titleWidth - 2)
    let leftPadding = padding / 2
    let rightPadding = padding - leftPadding
    
    print("")
    print("╔" + String(repeating: "═", count: boxWidth) + "╗")
    print("║" + String(repeating: " ", count: leftPadding) + title + String(repeating: " ", count: rightPadding) + "║")
    print("╚" + String(repeating: "═", count: boxWidth) + "╝")
    print("")
}

// Run main function
Task { @MainActor in
    await main()
    exit(0)
}
RunLoop.main.run()
