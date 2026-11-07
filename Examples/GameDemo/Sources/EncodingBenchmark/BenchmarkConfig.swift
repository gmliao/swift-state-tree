// Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkConfig.swift
//
// Command line argument parsing and configuration types.

import Foundation
import SwiftStateTree
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

    /// The format's encoding, with `--dynamic-key-compression` applied (it only changes the
    /// path-hash formats, the only ones with a key table).
    var transportEncodingConfig: TransportEncodingConfig {
        baseTransportEncodingConfig.withDynamicKeyCompression(DynamicKeyCompressionMode.enabled)
    }

    private var baseTransportEncodingConfig: TransportEncodingConfig {
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

// MARK: - Dirty Tracking

/// `--dirty-tracking`: whether every `TransportAdapter` diffs only dirty fields.
///
/// `on` and `off` fix the setting for the whole run (auto dirty tracking is turned off with
/// them, so the adapter never switches); `auto` keeps the adapter's default, dirty tracking on
/// with automatic switching, which is what the benchmark measured before this option.
/// Dirty tracking should not change the bytes on the wire, only how much state is scanned.
enum DirtyTrackingMode: String, CaseIterable {
    case auto
    case on
    case off

    /// The transport environment keys this mode sets, read by every `TransportAdapter` the
    /// benchmark constructs. They mirror `TransportEnvKeys`, which is internal to the transport
    /// module. The environment, not the `enableDirtyTracking:` argument, because the adapter's
    /// auto switch would otherwise turn dirty tracking back on mid-run.
    static let enableKey = "ENABLE_DIRTY_TRACKING"
    static let autoKey = "AUTO_DIRTY_TRACKING"
    /// Set by `EncodingBenchmark.main()` so results can report the mode.
    static let modeKey = "ENCODING_BENCHMARK_DIRTY_TRACKING"

    /// Applies the mode to this process's environment, before any adapter exists.
    func apply() {
        switch self {
        case .auto:
            break
        case .on, .off:
            setenv(Self.enableKey, self == .on ? "true" : "false", 1)
            setenv(Self.autoKey, "false", 1)
        }
        setenv(Self.modeKey, rawValue, 1)
    }

    /// The mode `apply()` set, for result metadata.
    static var current: String {
        EnvHelpers.getEnvString(key: modeKey, defaultValue: DirtyTrackingMode.auto.rawValue)
    }
}

// MARK: - Dynamic-Key Compression

/// `--dynamic-key-compression`: whether the path-hash formats send dynamic keys as table slots
/// after their first use (`on`) or always as full key strings (`off`), so its byte contribution
/// can be measured apart from path hashing (#59). Without the flag, `DYNAMIC_KEY_COMPRESSION`
/// from the shell applies (default on).
enum DynamicKeyCompressionMode: String, CaseIterable {
    case on
    case off

    static let environmentKey = TransportEncodingConfig.dynamicKeyCompressionEnvironmentKey

    /// Sets the mode in this process's environment, before any encoder exists, like
    /// `--sync-strategy` and `--dirty-tracking`: every run* function makes its encoders from
    /// `EncodingFormat.transportEncodingConfig`, which reads it back. Called only for an explicit
    /// flag, so a shell `DYNAMIC_KEY_COMPRESSION` is kept otherwise.
    func apply() {
        setenv(Self.environmentKey, self == .on ? "true" : "false", 1)
    }

    /// The setting in effect, for every encoder and for result metadata.
    static var enabled: Bool {
        TransportEncodingConfig.dynamicKeyCompressionFromEnvironment()
    }
}

// MARK: - Output Format

enum OutputFormat: String {
    case table
    case json
}

// MARK: - Game Type

enum GameType: String, CaseIterable {
    case heroDefense = "hero-defense"
    case cardGame = "card-game"
    /// Per-player projection that changes every tick (#65): entities move only in ticks.
    case visibilityTest = "visibility-test"
}

// MARK: - Benchmark Configuration

struct BenchmarkConfig {
    var format: EncodingFormat = .messagepackPathHash
    var syncStrategy: SyncStrategy = .delta
    var dirtyTracking: DirtyTrackingMode = .auto
    /// nil without `--dynamic-key-compression`: the environment's setting applies.
    var dynamicKeyCompression: DynamicKeyCompressionMode?
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
    /// `--parallel` was given: `--scalability` then runs only that mode instead of both.
    var parallelGiven: Bool = false
    var runAll: Bool = false
    var compareParallel: Bool = false
    var scalabilityTest: Bool = false
    /// `--hash-cost`: time the replay state hash per tick, full state vs broadcast view.
    var hashCost: Bool = false
    var hashCostWarmupTicks: Int = 200
    /// Number of ticks to run per sync iteration. For tick=20Hz & sync=10Hz, use 2.
    /// Set to 0 to disable tick simulation.
    var ticksPerSync: Int = 0
    /// Print progress every N iterations for long-running benchmarks. Set to 0 to disable.
    var progressEvery: Int = 0
    
    // Worker Pool configuration
    var useWorkerPool: Bool = false
    var workerCount: Int? = nil
    var compareWorkerPool: Bool = false
    var gameType: GameType = .heroDefense
    /// Hero-defense only: when > 0, rooms refill monsters to this count every tick
    /// (spawn interval forced to 1) so the live monster count stays at ~cap.
    var monsterCap: Int = 0
    /// Hero-defense only: when true, every player receives a deterministic MoveToEvent
    /// each iteration so all players produce position changes every tick.
    var activePlayers: Bool = false
    /// True when an option that only the hero-defense multi-room runner honours was given
    /// (`--game-type`, `--players-per-room`, `--ticks-per-sync`, `--monster-cap`,
    /// `--active-players`). Such runs never take the legacy single-room path, which runs a
    /// different land and ignores those options.
    var heroDefenseOptionsGiven: Bool = false
    /// `--capture-views <dir>` and `--capture-rooms <n>`: frames and projections for the
    /// reconstruction-equals-projection gate (`ViewCapture.swift`).
    var captureViews: ViewCaptureConfig?
    var captureRooms: Int = 10
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
    var ticksPerSyncGiven = false

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--format":
            if i + 1 < args.count, let format = EncodingFormat(rawValue: args[i + 1]) {
                config.format = format
                i += 1
            }
        case "--sync-strategy":
            if i + 1 < args.count, let strategy = SyncStrategy(rawValue: args[i + 1].lowercased()) {
                config.syncStrategy = strategy
                i += 1
            } else {
                print("Error: --sync-strategy requires delta or full-snapshot")
                exit(1)
            }
        case "--dirty-tracking":
            guard i + 1 < args.count, let mode = DirtyTrackingMode(rawValue: args[i + 1]) else {
                let value = i + 1 < args.count ? args[i + 1] : "nothing"
                print("Invalid --dirty-tracking value: \(value) (expected on, off or auto)")
                exit(1)
            }
            config.dirtyTracking = mode
            i += 1
        case "--dynamic-key-compression":
            guard i + 1 < args.count, let mode = DynamicKeyCompressionMode(rawValue: args[i + 1]) else {
                let value = i + 1 < args.count ? args[i + 1] : "nothing"
                print("Invalid --dynamic-key-compression value: \(value) (expected on or off)")
                exit(1)
            }
            config.dynamicKeyCompression = mode
            i += 1
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
            config.heroDefenseOptionsGiven = true
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
                config.parallelGiven = true
                i += 1
            }
        case "--all":
            config.runAll = true
        case "--compare-parallel":
            config.compareParallel = true
        case "--scalability":
            config.scalabilityTest = true
        case "--include-tick":
            ticksPerSyncGiven = true
            // Backward-compatible sugar: tick once per sync
            config.ticksPerSync = max(config.ticksPerSync, 1)
        case "--ticks-per-sync":
            ticksPerSyncGiven = true
            config.heroDefenseOptionsGiven = true
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
            guard i + 1 < args.count, let gameType = GameType(rawValue: args[i + 1]) else {
                let given = i + 1 < args.count ? args[i + 1] : "nothing"
                let allowed = GameType.allCases.map(\.rawValue).joined(separator: ", ")
                try? FileHandle.standardError.write(contentsOf: Data("--game-type must be one of \(allowed) (got \(given))\n".utf8))
                exit(2)
            }
            config.gameType = gameType
            config.heroDefenseOptionsGiven = true
            i += 1
        case "--monster-cap":
            config.heroDefenseOptionsGiven = true
            if i + 1 < args.count, let value = Int(args[i + 1]) {
                config.monsterCap = max(0, value)
                i += 1
            }
        case "--active-players":
            config.activePlayers = true
            config.heroDefenseOptionsGiven = true
        case "--use-worker-pool":
            config.useWorkerPool = true
        case "--workers":
            if i + 1 < args.count, let value = Int(args[i + 1]) {
                config.workerCount = value
                i += 1
            }
        case "--compare-worker-pool":
            config.compareWorkerPool = true
        case "--capture-views":
            guard i + 1 < args.count else {
                try? FileHandle.standardError.write(contentsOf: Data("--capture-views needs a directory\n".utf8))
                exit(2)
            }
            config.captureViews = ViewCaptureConfig(directory: URL(fileURLWithPath: args[i + 1], isDirectory: true), rooms: 0)
            config.heroDefenseOptionsGiven = true
            i += 1
        case "--capture-rooms":
            guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                try? FileHandle.standardError.write(contentsOf: Data("--capture-rooms needs a positive count\n".utf8))
                exit(2)
            }
            config.captureRooms = value
            i += 1
        case "--hash-cost":
            config.hashCost = true
        case "--hash-warmup":
            if i + 1 < args.count, let value = Int(args[i + 1]) {
                config.hashCostWarmupTicks = value
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

        if let capture = config.captureViews {
            config.captureViews = ViewCaptureConfig(directory: capture.directory, rooms: config.captureRooms)
            // Only the hero-defense multi-room runner captures; elsewhere the gate would pass on nothing.
            let unsupported = [
                (config.gameType != .heroDefense, "--game-type other than hero-defense"),
                (config.hashCost, "--hash-cost"),
                (config.compareWorkerPool, "--compare-worker-pool"),
                (config.useWorkerPool, "--use-worker-pool"),
            ].filter(\.0).map(\.1)
            if !unsupported.isEmpty {
                try? FileHandle.standardError.write(contentsOf: Data("--capture-views doesn't support \(unsupported.joined(separator: ", "))\n".utf8))
                exit(2)
            }
        }
        if config.gameType != .heroDefense {
            // These modes build Hero Defense rooms only; they would silently measure the wrong land.
            let unsupported = [
                (config.hashCost, "--hash-cost"),
                (config.compareWorkerPool, "--compare-worker-pool"),
                (config.useWorkerPool, "--use-worker-pool"),
            ].filter(\.0).map(\.1)
            if !unsupported.isEmpty {
                try? FileHandle.standardError.write(contentsOf: Data("\(unsupported.joined(separator: ", ")) supports only --game-type hero-defense\n".utf8))
                exit(2)
            }
        }
        if config.gameType == .visibilityTest, !ticksPerSyncGiven {
            // Its entities move only in ticks: without one there is nothing to sync.
            config.ticksPerSync = 1
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
      --hash-cost             Time the replay state hash per tick on Hero Defense: full state (record
                              2.4) vs broadcast view (older records). Rooms from --room-counts
                              (default 1,10,50,100), players from --players-per-room(-list),
                              measured ticks from --iterations, after --hash-warmup <n> ticks
                              (default 200). Release builds only.
      --sync-strategy <s>     Sync strategy: delta (default) or full-snapshot (send full view every sync)
      --dirty-tracking <m>    on, off or auto (default: auto). on/off fix dirty tracking for the run
                              (auto switching off); auto keeps the adapter default (on, switching
                              automatically). Bytes should match across modes; compare times only
                              from -c release builds.
      --dynamic-key-compression <m>  on or off (default: DYNAMIC_KEY_COMPRESSION, else on). off
                              sends dynamic keys as full strings instead of table slots; only
                              the -pathhash formats change.
      --capture-views <dir>   Hero-defense multi-room runs: write, for the first --capture-rooms
                              rooms (default 10), every frame sent with its target and, after
                              every sync, each player's projection, as <dir>/<run>/room-<i>.ndjson.
                              ws-loadtest's verify-views checks that every recipient's state,
                              rebuilt from its frames by the TypeScript SDK, equals its projection
                              after every sync. A capture pass's timings aren't measurements.
      --players <count>       Number of players (default: 10, single room mode)
      --rooms <count>         Number of rooms (default: 1, single room mode)
                              Single room mode runs its own encoding-benchmark land, not Hero
                              Defense. Any of --game-type, --players-per-room, --ticks-per-sync,
                              --monster-cap or --active-players selects the multi-room path
                              instead, even with --rooms 1.
      --players-per-room <count>  Number of players per room (default: 10)
      --players-per-room-list <csv>  Players per room list for matrix runs (e.g. 5,10)
      --iterations <count>    Number of iterations/syncs (default: 100)
      --output <format>       Output format: table or json (default: table)
      --parallel <bool>       Enable parallel execution across rooms (default: true)
      --game-type <type>      Game type: hero-defense, card-game or visibility-test (default:
                              hero-defense). Other than hero-defense, runs use the multi-room
                              path (--rooms, --players-per-room) even with one room, and not
                              --hash-cost or the worker pool. visibility-test defaults to
                              --ticks-per-sync 1 (its entities move only in ticks).
      --monster-cap <int>     Hero-defense: keep live monsters at ~this count (0 = default spawning)
      --active-players        Hero-defense: inject a deterministic move target per player per iteration
      --all                   Run benchmark for all formats
      --compare-parallel      Compare serial vs parallel execution for each format
      --scalability           Run scalability test (different room counts)
      --room-counts <csv>     Room counts override for scalability (e.g. 10,20,30,40,50)
      --include-tick          Backward-compatible: equivalent to --ticks-per-sync 1
      --ticks-per-sync <int>  Number of ticks per sync iteration (e.g. 2 for tick20/sync10)
      --progress-every <int>  Print progress every N iterations (e.g. 50); 0 disables
      --help, -h              Show this help message

    Saved JSON results record memory in metadata.memory: peakRSSMiB (peak resident memory of
    the whole process) and endRSSMiB (resident memory when the results are saved). Hero-defense
    multi-room results also carry cpuMs (process CPU over the timed spans) and, with
    --parallel false, syncMs (time in syncNow() alone; timeMs also includes the ticks and the
    move injection). Timing and memory are only comparable between -c release builds.

    Examples:
      swift run EncodingBenchmark --format messagepack-pathhash --players 10
      swift run EncodingBenchmark --rooms 4 --players-per-room 10
      swift run EncodingBenchmark --rooms 50 --players-per-room 10 --ticks-per-sync 2
      swift run EncodingBenchmark --game-type card-game --players-per-room 20 --parallel true
      swift run EncodingBenchmark --game-type visibility-test --rooms 10 --players-per-room 4 --all
      swift run EncodingBenchmark --all --output json
      swift run EncodingBenchmark --compare-parallel --rooms 4
    """)
    }
}
