// Sources/SwiftStateTreeBenchmarks/main.swift

import Foundation
import SwiftStateTree

// MARK: - Main

@MainActor
func main(parser: CommandLineParser) async {
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

    var suiteConfigs = suiteTypes.flatMap {
        BenchmarkSuites.get(
            suiteType: $0,
            transportDirtyTrackingOverride: parser.transportDirtyTrackingOverride,
            dirtyRatioOverride: parser.transportDirtyRatioOverride,
            playerCountsOverride: parser.playerCountsOverride,
            roomCountsOverride: parser.roomCountsOverride,
            tickModeOverride: parser.tickModeOverride,
            tickStridesOverride: parser.tickStridesOverride
        )
    }

    // Filter by suite name if specified
    if let nameFilter = parser.suiteNameFilter {
        suiteConfigs = suiteConfigs.filter { $0.name == nameFilter }
        if suiteConfigs.isEmpty {
            print("Error: No suite found with name '\(nameFilter)'")
            print("Available suites:")
            let allConfigs = suiteTypes.flatMap {
                BenchmarkSuites.get(
                    suiteType: $0,
                    transportDirtyTrackingOverride: parser.transportDirtyTrackingOverride,
                    dirtyRatioOverride: parser.transportDirtyRatioOverride,
                    playerCountsOverride: parser.playerCountsOverride,
                    roomCountsOverride: parser.roomCountsOverride,
                    tickModeOverride: parser.tickModeOverride,
                    tickStridesOverride: parser.tickStridesOverride
                )
            }
            for config in allConfigs {
                print("  - \(config.name)")
            }
            exit(1)
        }
    }

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
    let parser = CommandLineParser()

    if parser.showHelp {
        CommandLineParser.printUsage()
        exit(0)
    }

    if parser.hasError {
        parser.printError()
        exit(1)
    }

    // Allow skipping the "Press Enter" prompt via CLI flag when doing automated runs
    if !parser.skipWaitForEnter {
        print("Press Enter to start the benchmark...")
        _ = readLine() // 這行會卡住，等你在 Terminal 按 Enter
    }

    await main(parser: parser)
    exit(0)
}

RunLoop.main.run()
