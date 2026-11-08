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
    var pacing: Pacing = .spread
    /// Joins and actions in flight at most (`spread` and `aligned`); further sends are skipped and counted.
    var maxInFlight: Int = 10_000
    var createRoomsFirst: Bool = false
    var tui: Bool = false
    var logLevel: Logger.Level = .info
    /// Re-evaluation recording (`--record on|off`, default off).
    var record: Bool = false
    /// Each room streams its re-evaluation record here and saves it when it closes (`--record-dir`,
    /// needs `--record on`).
    var recordDir: String?
    /// Writes each session's received frames here, one file per session, each frame as a 4-byte
    /// big-endian length and the frame (`--stream-dir`, default off).
    var streamDir: String?

    var totalPlayers: Int { rooms * playersPerRoom }
    var totalSeconds: Int { rampUpSeconds + durationSeconds + rampDownSeconds }
    var playersPerSecondUp: Int { max(1, totalPlayers / max(1, rampUpSeconds)) }
    var sessionsPerSecondDown: Int { max(1, totalPlayers / max(1, rampDownSeconds)) }
}

/**
 * How the generator paces joins and actions.
 * - `spread` (default): deadline-based seconds, each session's actions at a stable offset in the
 *   second, joins evenly spaced, an in-flight cap.
 * - `aligned`: deadline-based seconds and the in-flight cap, but every send at the second's
 *   start. Not comparable with runs before deadline pacing.
 * - `legacy`: legacy generator, deadline sampler — rows are not comparable with old reports. The
 *   generator is the one before deadline pacing (join pool cap, awaited action rounds, a full
 *   second's sleep after the work); the sampler is deadline-based in every mode.
 */
enum Pacing: String, Sendable, CaseIterable {
    case spread
    case aligned
    case legacy
}

/// Environment keys ServerLoadTest reads.
enum ServerLoadTestEnvKeys {
    /// Message and state update encoding: messagepack (default), json, jsonOpcode or opcode.
    static let transportEncoding = "TRANSPORT_ENCODING"
    /// Where the result file goes (`BENCHMARK_RESULTS_DIR`, as for EncodingBenchmark). Unset:
    /// `results/server-loadtest/` in the package.
    static let resultsDir = "BENCHMARK_RESULTS_DIR"
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
        case "--pacing":
            if let next, let v = Pacing(rawValue: next.lowercased()) { config.pacing = v; i += 1 }
        case "--max-in-flight":
            if let next, let v = readInt(next), v > 0 { config.maxInFlight = v; i += 1 }
        case "--record":
            if let next {
                switch next.lowercased() {
                case "on": config.record = true
                case "off": config.record = false
                default: break
                }
                i += 1
            }
        case "--record-dir":
            if let next { config.recordDir = next; i += 1 }
        case "--stream-dir":
            if let next { config.streamDir = next; i += 1 }
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
      --pacing <spread|aligned|legacy>          spread (default): deadline-based seconds, each
                                                session's actions at a stable offset in the
                                                second, joins evenly spaced;
                                                aligned: deadline-based seconds, every send at the
                                                second's start (not comparable with earlier runs);
                                                legacy: legacy generator, deadline sampler --
                                                rows are not comparable with old reports (join
                                                pool cap, awaited action rounds, 1 s sleep after
                                                the work)
      --max-in-flight <count>                   Joins and actions in flight at most in spread and
                                                aligned (default: 10000); sends over the cap are
                                                skipped and counted per second
      --record <on|off>                         Re-evaluation recording (default: off)
      --record-dir <dir>                        Stream each room's 3.0 record to <dir>/spool
                                                while it runs; the room saves it as
                                                <dir>/hero-defense-<time>-<id>.sstr when it
                                                closes; needs --record on
      --stream-dir <dir>                        Write each session's received frames to
                                                <dir>/room-<i>-<session>.bin (4-byte big-endian
                                                length, then the frame), for offline sizing
      --log-level <level>                       Log level (default: info)

    Environment:
      TRANSPORT_ENCODING                        messagepack (default), json, jsonOpcode, opcode
      --help, -h                                Show this help message

    Examples:
      swift run -c release ServerLoadTest --rooms 500 --players-per-room 5 --duration-seconds 30
    """)
    exit(0)
}
