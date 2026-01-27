// Sources/ServerLoadTest/LoadTestConfig.swift
//
// Configuration and argument parsing for ServerLoadTest.

import Foundation
import Logging

// MARK: - Configuration

struct LoadTestConfig: Sendable {
    var landType: String = "hero-defense"
    var rooms: Int = 500
    var playersPerRoom: Int = 5
    var durationSeconds: Int = 30
    var rampUpSeconds: Int = 5
    var rampDownSeconds: Int = 5
    var actionsPerPlayerPerSecond: Int = 1
    var createRoomsFirst: Bool = false
    var tui: Bool = false
    var logLevel: Logger.Level = .info

    var totalPlayers: Int { rooms * playersPerRoom }
    var totalSeconds: Int { rampUpSeconds + durationSeconds + rampDownSeconds }
    var playersPerSecondUp: Int { max(1, totalPlayers / max(1, rampUpSeconds)) }
    var sessionsPerSecondDown: Int { max(1, totalPlayers / max(1, rampDownSeconds)) }
}

// MARK: - Argument Parsing

func parseArguments() -> LoadTestConfig {
    var config = LoadTestConfig()
    var i = 1

    func readInt(_ arg: String) -> Int? { Int(arg) }
    func readBool(_ arg: String) -> Bool? {
        switch arg.lowercased() {
        case "1", "true", "yes", "y": return true
        case "0", "false", "no", "n": return false
        default: return nil
        }
    }

    while i < CommandLine.arguments.count {
        let arg = CommandLine.arguments[i]
        let next = (i + 1 < CommandLine.arguments.count) ? CommandLine.arguments[i + 1] : nil

        switch arg {
        case "--rooms":
            if let next, let v = readInt(next) { config.rooms = v; i += 1 }
        case "--players-per-room":
            if let next, let v = readInt(next) { config.playersPerRoom = v; i += 1 }
        case "--duration-seconds":
            if let next, let v = readInt(next) { config.durationSeconds = v; i += 1 }
        case "--ramp-up-seconds":
            if let next, let v = readInt(next) { config.rampUpSeconds = v; i += 1 }
        case "--ramp-down-seconds":
            if let next, let v = readInt(next) { config.rampDownSeconds = v; i += 1 }
        case "--actions-per-player-per-second":
            if let next, let v = readInt(next) { config.actionsPerPlayerPerSecond = v; i += 1 }
        case "--tui":
            if let next, let v = readBool(next) { config.tui = v; i += 1 }
        case "--log-level":
            if let next {
                switch next.lowercased() {
                case "trace": config.logLevel = .trace
                case "debug": config.logLevel = .debug
                case "info": config.logLevel = .info
                case "notice": config.logLevel = .notice
                case "warning": config.logLevel = .warning
                case "error": config.logLevel = .error
                case "critical": config.logLevel = .critical
                default: break
                }
                i += 1
            }
        case "--help", "-h":
            printUsageAndExit()
        default:
            break
        }
        i += 1
    }

    return config
}

func printUsageAndExit() -> Never {
    print("""
    Usage: ServerLoadTest [options]

    Options:
      --rooms <count>                           Number of rooms (default: 500)
      --players-per-room <count>                Players per room (default: 5)
      --duration-seconds <seconds>              Steady-state duration (default: 30)
      --ramp-up-seconds <seconds>               Ramp-up duration (default: 5)
      --ramp-down-seconds <seconds>             Ramp-down duration (default: 5)
      --actions-per-player-per-second <count>   Actions per player per second (default: 1)
      --log-level <level>                       Log level (default: info)
      --help, -h                                Show this help message

    Examples:
      swift run -c release ServerLoadTest --rooms 500 --players-per-room 5 --duration-seconds 30
    """)
    exit(0)
}
