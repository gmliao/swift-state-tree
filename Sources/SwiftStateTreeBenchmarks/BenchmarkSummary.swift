// Sources/SwiftStateTreeBenchmarks/BenchmarkSummary.swift

import Foundation
import SwiftStateTree

/// Generate summary report from benchmark results
struct BenchmarkSummary {
    let results: [BenchmarkResult]
    let showCSV: Bool

    func printSummary() {
        // Compare single-threaded vs parallel (only if both exist)
        let singleThreadedResults = results.filter { $0.executionMode == "Single-threaded" }
        let parallelResults = results.filter { $0.executionMode.contains("Parallel") && !$0.executionMode.contains("Multi-player") }

        if singleThreadedResults.count == parallelResults.count, !singleThreadedResults.isEmpty {
            print("\n" + String(repeating: "═", count: 65))
            print("SUMMARY")
            print(String(repeating: "═", count: 65))
            print("\n📊 Performance Comparison:")
            print(String(repeating: "-", count: 65))
            print("\nSingle-threaded vs Parallel Throughput:")
            for i in 0 ..< singleThreadedResults.count {
                let single = singleThreadedResults[i]
                let parallel = parallelResults[i]
                let speedup = parallel.throughput / single.throughput
                let coreCount = ProcessInfo.processInfo.processorCount
                let efficiency = (speedup / Double(coreCount)) * 100

                print("  \(single.config.name):")
                print("    Single-threaded: \(String(format: "%.2f", single.throughput)) snapshots/sec")
                print("    Parallel:        \(String(format: "%.2f", parallel.throughput)) snapshots/sec")
                print("    Speedup:         \(String(format: "%.2fx", speedup)) (theoretical: \(coreCount)x)")
                print("    Efficiency:      \(String(format: "%.1f", efficiency))%")
            }
        }

        // CSV Output (optional) - Display as ASCII table for better readability
        if showCSV {
            print("\n📊 Results Table (for analysis):")
            print(String(repeating: "-", count: 120))
            
            // Create table with formatted columns
            var table = TextTable(
                columns: [
                    TextTableColumn(header: "Name"),
                    TextTableColumn(header: "Players"),
                    TextTableColumn(header: "Cards"),
                    TextTableColumn(header: "Iters"),
                    TextTableColumn(header: "Mode"),
                    TextTableColumn(header: "Avg(ms)"),
                    TextTableColumn(header: "Min(ms)"),
                    TextTableColumn(header: "Max(ms)"),
                    TextTableColumn(header: "Throughput"),
                    TextTableColumn(header: "Size(bytes)")
                ]
            )
            
            for result in results {
                let values = result.tableValues
                table.addRow(values: [
                    values.name,
                    values.players,
                    values.cards,
                    values.iterations,
                    values.mode,
                    values.avgTime,
                    values.minTime,
                    values.maxTime,
                    values.throughput,
                    values.size
                ])
            }
            
            print(table.render())
            
            // Also output CSV format for script parsing (commented out by default)
            // Uncomment if you need raw CSV format
            // print("\n📄 CSV Format (for script parsing):")
            // print(String(repeating: "-", count: 65))
            // print("Name,Players,Cards/Player,PlayerStateFields,Iterations,ExecutionMode,AvgTime(ms),MinTime(ms),MaxTime(ms),Throughput(snapshots/sec),Size(bytes)")
            // for result in results {
            //     print(result.csvRow)
            // }
        }

        print("\n" + String(repeating: "═", count: 65))
        print("Benchmark completed!")
        print(String(repeating: "═", count: 65))
    }
}
