// Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkResults.swift
//
// Benchmark result output formatting.

import Foundation

// MARK: - Output

enum OutputFormatter {
    static func printTableHeader() {
    print("===================== Encoding Benchmark Results =====================")
    print("Format                      | Time (ms) | Total Bytes | Per Sync | Avg Cost/Sync | vs JSON")
        print("------------------------------------------------------------------------")
    }

    static func printTableRow(_ result: BenchmarkResult, baselineBytes: Int?) {
    let ratio: String
    if let baseline = baselineBytes, baseline > 0 {
        ratio = String(format: "%5.1f%%", Double(result.totalBytes) / Double(baseline) * 100)
    } else {
        ratio = "  100%"
    }

    print(String(format: "%-27@ | %9.2f | %11d | %8d | %13.4f | %@",
                 result.format.displayName,
                 result.timeMs,
                 result.totalBytes,
                 result.bytesPerSync,
                 result.avgCostPerSyncMs,
                 ratio))
    }

    static func printTableFooter() {
        print("========================================================================")
    }

    static func printJSON(_ result: BenchmarkResult) {
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
}
