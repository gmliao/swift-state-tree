// Sources/SwiftStateTreeBenchmarks/BenchmarkConfig.swift

import Foundation

// MARK: - Benchmark Configuration

/// Benchmark configuration
struct BenchmarkConfig {
    let name: String
    let playerCount: Int
    let cardsPerPlayer: Int
    let iterations: Int  // Number of runs for averaging
    
    var description: String {
        "\(name) (Players: \(playerCount), Cards: \(cardsPerPlayer), Iterations: \(iterations))"
    }
}

/// Benchmark result
struct BenchmarkResult {
    let config: BenchmarkConfig
    let averageTime: TimeInterval  // in seconds
    let minTime: TimeInterval
    let maxTime: TimeInterval
    let snapshotSize: Int  // Total bytes sent to all players per sync (for TransportAdapter benchmarks)
    let throughput: Double  // snapshots per second
    let executionMode: String  // "Single-threaded" or "Parallel (N cores)"
    /// Bytes per player (average). Only meaningful for TransportAdapter benchmarks with multiple players.
    /// For single-player benchmarks, this equals snapshotSize.
    let bytesPerPlayer: Int?
    
    var formattedOutput: String {
        var table = TextTable(
            columns: [
                TextTableColumn(header: "Metric"),
                TextTableColumn(header: "Value")
            ],
            header: config.name
        )
        
        // Configuration section
        table.addRow(values: ["Players", "\(config.playerCount)"])
        table.addRow(values: ["Cards/Player", "\(config.cardsPerPlayer)"])
        table.addRow(values: ["Player State Fields", "8 per player"])
        table.addRow(values: ["Iterations", "\(config.iterations)"])
        table.addRow(values: ["Execution", executionMode])
        
        // Results section
        table.addRow(values: ["Average Time", String(format: "%.4f ms", averageTime * 1000)])
        table.addRow(values: ["Min Time", String(format: "%.4f ms", minTime * 1000)])
        table.addRow(values: ["Max Time", String(format: "%.4f ms", maxTime * 1000)])
        table.addRow(values: ["Throughput", String(format: "%.2f snapshots/sec", throughput)])
        if let bytesPerPlayer = bytesPerPlayer {
            table.addRow(values: ["Total Size (all players)", "\(snapshotSize) bytes (~\(formatBytes(snapshotSize)))"])
            table.addRow(values: ["Size per Player", "\(bytesPerPlayer) bytes (~\(formatBytes(bytesPerPlayer)))"])
        } else {
            table.addRow(values: ["Snapshot Size", "\(snapshotSize) bytes (~\(formatBytes(snapshotSize)))"])
        }
        
        return table.render()
    }
    
    var csvRow: String {
        let avgTimeMs = String(format: "%.4f", averageTime * 1000)
        let minTimeMs = String(format: "%.4f", minTime * 1000)
        let maxTimeMs = String(format: "%.4f", maxTime * 1000)
        let throughputStr = String(format: "%.2f", throughput)
        let bytesPerPlayerStr = bytesPerPlayer.map { "\($0)" } ?? ""
        return "\(config.name),\(config.playerCount),\(config.cardsPerPlayer),8,\(config.iterations),\(executionMode),\(avgTimeMs),\(minTimeMs),\(maxTimeMs),\(throughputStr),\(snapshotSize),\(bytesPerPlayerStr)"
    }
    
    /// Formatted values for table display
    var tableValues: (name: String, players: String, cards: String, iterations: String, mode: String, avgTime: String, minTime: String, maxTime: String, throughput: String, totalSize: String, sizePerPlayer: String) {
        (
            name: config.name,
            players: "\(config.playerCount)",
            cards: "\(config.cardsPerPlayer)",
            iterations: "\(config.iterations)",
            mode: executionMode,
            avgTime: String(format: "%.4f", averageTime * 1000),
            minTime: String(format: "%.4f", minTime * 1000),
            maxTime: String(format: "%.4f", maxTime * 1000),
            throughput: String(format: "%.2f", throughput),
            totalSize: "\(snapshotSize)",
            sizePerPlayer: bytesPerPlayer.map { "\($0)" } ?? "-"
        )
    }
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        return String(format: "%.2f KB", Double(bytes) / 1024.0)
    } else {
        return String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}

// MARK: - Predefined Configurations

/// Standard benchmark configurations for different state sizes
struct BenchmarkConfigurations {
    static let standard: [BenchmarkConfig] = [
        BenchmarkConfig(
            name: "Tiny State",
            playerCount: 5,
            cardsPerPlayer: 3,
            iterations: 1000
        ),
        BenchmarkConfig(
            name: "Small State",
            playerCount: 10,
            cardsPerPlayer: 5,
            iterations: 500
        ),
        BenchmarkConfig(
            name: "Medium State",
            playerCount: 100,
            cardsPerPlayer: 10,
            iterations: 100
        ),
        BenchmarkConfig(
            name: "Large State",
            playerCount: 500,
            cardsPerPlayer: 20,
            iterations: 50
        ),
        BenchmarkConfig(
            name: "Very Large State",
            playerCount: 1000,
            cardsPerPlayer: 30,
            iterations: 20
        ),
        // BenchmarkConfig(
        //     name: "Huge State",
        //     playerCount: 5000,
        //     cardsPerPlayer: 50,
        //     iterations: 10
        // )
    ]
    
    /// Quick configurations for faster testing
    static let quick: [BenchmarkConfig] = [
        BenchmarkConfig(
            name: "Small State",
            playerCount: 10,
            cardsPerPlayer: 5,
            iterations: 100
        ),
        BenchmarkConfig(
            name: "Medium State",
            playerCount: 100,
            cardsPerPlayer: 10,
            iterations: 50
        )
    ]
}

