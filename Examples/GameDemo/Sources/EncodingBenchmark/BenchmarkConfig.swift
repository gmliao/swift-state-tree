// Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkConfig.swift
//
// Command line argument parsing and configuration types.

import Foundation
import SwiftStateTreeTransport

// MARK: - Encoding Format

enum EncodingFormat: String, CaseIterable {
    case jsonObject = "json-object"
    case opcodeJson = "opcode-json"
    case opcodeJsonPathHash = "opcode-json-pathhash"
    case messagepack
    case messagepackPathHash = "messagepack-pathhash"

    var displayName: String {
        switch self {
        case .jsonObject: return "JSON Object"
        case .opcodeJson: return "Opcode JSON (Legacy)"
        case .opcodeJsonPathHash: return "Opcode JSON (PathHash)"
        case .messagepack: return "Opcode MsgPack (Legacy)"
        case .messagepackPathHash: return "Opcode MsgPack (PathHash)"
        }
    }

    var transportEncodingConfig: TransportEncodingConfig {
        switch self {
        case .jsonObject:
            return TransportEncodingConfig(message: .json, stateUpdate: .jsonObject)
        case .opcodeJson:
            return TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArrayLegacy)
        case .opcodeJsonPathHash:
            return TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray)
        case .messagepack:
            return TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
        case .messagepackPathHash:
            return TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
        }
    }

    var usesPathHash: Bool {
        switch self {
        case .opcodeJsonPathHash, .messagepackPathHash:
            return true
        default:
            return false
        }
    }
}

// MARK: - Output Format

enum OutputFormat: String {
    case table
    case json
}

// MARK: - Game Type

enum GameType: String {
    case heroDefense = "hero-defense"
    case cardGame = "card-game"
}

// MARK: - Benchmark Configuration

struct BenchmarkConfig {
    var format: EncodingFormat = .messagepackPathHash
    var players: Int = 10
    var rooms: Int = 1
    var playersPerRoom: Int = 10
    /// Optional list for matrix runs (e.g. "5,10"). If empty, uses `playersPerRoom`.
    var playersPerRoomList: [Int] = []
    /// Optional room counts override for scalability runs. If empty, uses default set.
    var roomCounts: [Int] = []
    var iterations: Int = 100
    var output: OutputFormat = .table
    var parallel: Bool = true
    var runAll: Bool = false
    var compareParallel: Bool = false
    var scalabilityTest: Bool = false
    /// Number of ticks to run per sync iteration. For tick=20Hz & sync=10Hz, use 2.
    /// Set to 0 to disable tick simulation.
    var ticksPerSync: Int = 0
    /// Print progress every N iterations for long-running benchmarks. Set to 0 to disable.
    var progressEvery: Int = 0
    var gameType: GameType = .heroDefense
}

// MARK: - Argument Parsing

enum ArgumentParser {
    static func parseCSVInts(_ raw: String) -> [Int] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(Int.init)
    }

    static func parseArguments() -> BenchmarkConfig {
    var config = BenchmarkConfig()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--format":
            if i + 1 < args.count, let format = EncodingFormat(rawValue: args[i + 1]) {
                config.format = format
                i += 1
            }
        case "--players":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.players = count
                i += 1
            }
        case "--rooms":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.rooms = count
                i += 1
            }
        case "--players-per-room":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.playersPerRoom = count
                i += 1
            }
        case "--players-per-room-list":
            if i + 1 < args.count {
                config.playersPerRoomList = parseCSVInts(args[i + 1])
                i += 1
            }
        case "--room-counts":
            if i + 1 < args.count {
                config.roomCounts = parseCSVInts(args[i + 1])
                i += 1
            }
        case "--iterations":
            if i + 1 < args.count, let count = Int(args[i + 1]) {
                config.iterations = count
                i += 1
            }
        case "--output":
            if i + 1 < args.count, let output = OutputFormat(rawValue: args[i + 1]) {
                config.output = output
                i += 1
            }
        case "--parallel":
            if i + 1 < args.count {
                config.parallel = args[i + 1] == "true"
                i += 1
            }
        case "--all":
            config.runAll = true
        case "--compare-parallel":
            config.compareParallel = true
        case "--scalability":
            config.scalabilityTest = true
        case "--include-tick":
            // Backward-compatible sugar: tick once per sync
            config.ticksPerSync = max(config.ticksPerSync, 1)
        case "--ticks-per-sync":
            if i + 1 < args.count, let value = Int(args[i + 1]) {
                config.ticksPerSync = max(0, value)
                i += 1
            }
        case "--progress-every":
            if i + 1 < args.count, let value = Int(args[i + 1]) {
                config.progressEvery = max(0, value)
                i += 1
            }
        case "--game-type":
            if i + 1 < args.count, let gameType = GameType(rawValue: args[i + 1]) {
                config.gameType = gameType
                i += 1
            }
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            break
        }
        i += 1
    }

        return config
    }

    static func printUsage() {
    print("""
    Usage: EncodingBenchmark [options]

    Options:
      --format <format>       Encoding format (default: messagepack-pathhash)
                              Values: json-object, opcode-json, opcode-json-pathhash,
                                      messagepack, messagepack-pathhash
      --players <count>       Number of players (default: 10, single room mode)
      --rooms <count>         Number of rooms (default: 1, single room mode)
      --players-per-room <count>  Number of players per room (default: 10)
      --players-per-room-list <csv>  Players per room list for matrix runs (e.g. 5,10)
      --iterations <count>    Number of iterations/syncs (default: 100)
      --output <format>       Output format: table or json (default: table)
      --parallel <bool>       Enable parallel encoding (default: true)
      --game-type <type>      Game type: hero-defense or card-game (default: hero-defense)
      --all                   Run benchmark for all formats
      --compare-parallel      Compare serial vs parallel encoding for each format
      --scalability           Run scalability test (different room counts)
      --room-counts <csv>     Room counts override for scalability (e.g. 10,20,30,40,50)
      --include-tick          Backward-compatible: equivalent to --ticks-per-sync 1
      --ticks-per-sync <int>  Number of ticks per sync iteration (e.g. 2 for tick20/sync10)
      --progress-every <int>  Print progress every N iterations (e.g. 50); 0 disables
      --help, -h              Show this help message

    Examples:
      swift run EncodingBenchmark --format messagepack-pathhash --players 10
      swift run EncodingBenchmark --rooms 4 --players-per-room 10
      swift run EncodingBenchmark --rooms 50 --players-per-room 10 --ticks-per-sync 2
      swift run EncodingBenchmark --game-type card-game --players 20 --parallel true
      swift run EncodingBenchmark --all --output json
      swift run EncodingBenchmark --compare-parallel --rooms 4
    """)
    }
}
