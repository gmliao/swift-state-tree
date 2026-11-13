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

    /// The format's encoding, with `--dynamic-key-compression`, `--path-index` and
    /// `--field-merge` applied (they only change the path-hash formats, the only ones with a key
    /// table, path ids and merged entries).
    var transportEncodingConfig: TransportEncodingConfig {
        baseTransportEncodingConfig
            .withDynamicKeyCompression(DynamicKeyCompressionMode.enabled)
            .withPathIndex(PathIndexMode.enabled)
            .withFieldMerge(FieldMergeMode.enabled)
            // Row entries take effect only for joins through a router: the router path turns
            // them on (`RouterJoin.encoding`); the local path's adapters run without them.
            .withRowAddressing(false)
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
/// `on` (the default, as the adapter's) and `off` fix the setting for the whole run. The
/// adapter no longer switches it (the auto switch was removed), so the former `auto` mode is
/// gone and an error. Dirty tracking should not change the bytes on the wire, only how much
/// state is scanned.
enum DirtyTrackingMode: String, CaseIterable {
    case on
    case off

    /// The transport environment key this mode sets, read by every `TransportAdapter` the
    /// benchmark constructs. It mirrors `TransportEnvKeys`, which is internal to the transport
    /// module.
    static let enableKey = "ENABLE_DIRTY_TRACKING"
    /// The removed auto switch's key. The benchmark never sets it; the recorded environment
    /// keeps it, so a run where the shell set it shows that (the adapter warns and ignores it).
    static let autoKey = "AUTO_DIRTY_TRACKING"
    /// Set by `EncodingBenchmark.main()` so results can report the mode.
    static let modeKey = "ENCODING_BENCHMARK_DIRTY_TRACKING"

    /// Applies the mode to this process's environment, before any adapter exists.
    func apply() {
        setenv(Self.enableKey, self == .on ? "true" : "false", 1)
        setenv(Self.modeKey, rawValue, 1)
    }

    /// The mode `apply()` set, for result metadata.
    static var current: String {
        EnvHelpers.getEnvString(key: modeKey, defaultValue: DirtyTrackingMode.on.rawValue)
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

// MARK: - Path Index

/// `--path-index`: whether the path-hash formats send a pattern's path index (its rank among the
/// land's sorted schema path hashes, `on`) or its 32-bit hash (`off`). Without the flag,
/// `PATH_INDEX` from the shell applies (default on).
enum PathIndexMode: String, CaseIterable {
    case on
    case off

    static let environmentKey = TransportEncodingConfig.pathIndexEnvironmentKey

    /// Sets the mode in this process's environment before any encoder exists, as
    /// `DynamicKeyCompressionMode.apply()` does.
    func apply() {
        setenv(Self.environmentKey, self == .on ? "true" : "false", 1)
    }

    /// The setting in effect, for every encoder and for result metadata.
    static var enabled: Bool {
        TransportEncodingConfig.pathIndexFromEnvironment()
    }
}

// MARK: - Field Merge

/// `--field-merge`: whether the path-hash formats merge the field patches of one parent in a
/// frame into one entry (`on`) or send each patch as its own entry (`off`). Without the flag,
/// `FIELD_MERGE` from the shell applies (default on).
enum FieldMergeMode: String, CaseIterable {
    case on
    case off

    static let environmentKey = TransportEncodingConfig.fieldMergeEnvironmentKey

    /// Sets the mode in this process's environment before any encoder exists, as
    /// `PathIndexMode.apply()` does.
    func apply() {
        setenv(Self.environmentKey, self == .on ? "true" : "false", 1)
    }

    /// The setting in effect, for every encoder and for result metadata.
    static var enabled: Bool {
        TransportEncodingConfig.fieldMergeFromEnvironment()
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
    var dirtyTracking: DirtyTrackingMode = .on
    /// nil without `--dynamic-key-compression`: the environment's setting applies.
    var dynamicKeyCompression: DynamicKeyCompressionMode?
    /// nil without `--path-index`: the environment's setting applies.
    var pathIndex: PathIndexMode?
    /// nil without `--field-merge`: the environment's setting applies.
    var fieldMerge: FieldMergeMode?
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
    /// Hero-defense with `--monster-cap` only: each monster is updated in one tick in this many
    /// (`--monster-active-every`); 1 updates every monster every tick.
    var monsterActiveEvery: Int = 1
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
    /// `--record-dir <dir>`: re-evaluation records of the captured rooms (needs --capture-views).
    var recordDir: URL?
    /// `--baseline entity-delta`: also encode every player's projection with the entity-delta
    /// baseline (EntityDeltaBaseline.swift). Serial hero-defense multi-room runs only.
    var entityDeltaBaseline: Bool = false
    /// `--no-server-events`: the hero-defense land emits no server events (state unchanged), for
    /// comparing state bytes with a baseline that carries none.
    var noServerEvents: Bool = false
    /// `--merge-stats`: count field merge with and without its order rule (hero-defense multi-room runs).
    var mergeStats: Bool = false
    /// `--join-through-router on`: the hero-defense rooms are lands behind a `LandRouter` and a
    /// `WebSocketTransport`, joined by fake connections (RouterJoin.swift). Off by default: the
    /// default path's numbers are unchanged.
    var joinThroughRouter: Bool = false
    /// `--row-addressing on|off` as given, nil when not given. `on` names root map rows by slot
    /// and needs `--join-through-router on` and a -pathhash format; not given, it follows where
    /// it can take effect (`rowAddressingResolved`), the library's default.
    var rowAddressing: OnOff? = nil

    /// Row addressing for the run: as given, or on where it can take effect (the router path
    /// with a -pathhash format, not `--all`), as the library defaults it on.
    var rowAddressingResolved: Bool {
        if let rowAddressing { return rowAddressing == .on }
        return joinThroughRouter && !runAll && format.usesPathHash
    }
}

/// `--join-through-router` and `--row-addressing` take `on` or `off`.
enum OnOff: String {
    case on
    case off
}

// MARK: - Argument Parsing

enum ArgumentParser {
    static func parseCSVInts(_ raw: String) -> [Int] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(Int.init)
    }

    /// Why `--join-through-router` / `--row-addressing` can't run as given, or nil. Only the
    /// hero-defense multi-room runner has the router path, and its join check reads each frame's
    /// op, which the JSON object format doesn't have. Row entries need the router path and a
    /// path-hash format (the only ones with row entries).
    static func routerJoinRefusal(_ config: BenchmarkConfig) -> String? {
        // Only an explicit `on` is refused: not given, it resolves off where it can't take effect.
        if config.rowAddressing == .on {
            let unsupported = [
                (!config.joinThroughRouter, "runs without --join-through-router on (row entries take effect only for joins through a router)"),
                (config.runAll, "--all (it runs formats without row entries)"),
                (!config.runAll && !config.format.usesPathHash, "--format \(config.format.rawValue) (row entries need a -pathhash format)"),
            ].filter(\.0).map(\.1)
            if !unsupported.isEmpty {
                return "--row-addressing on doesn't support \(unsupported.joined(separator: ", "))"
            }
        }
        guard config.joinThroughRouter else { return nil }
        let unsupported = [
            (config.gameType != .heroDefense, "--game-type other than hero-defense"),
            (config.hashCost, "--hash-cost"),
            (config.compareWorkerPool, "--compare-worker-pool"),
            (config.useWorkerPool, "--use-worker-pool"),
            (config.entityDeltaBaseline, "--baseline entity-delta"),
            (config.runAll, "--all (it runs the json-object format)"),
            (!config.runAll && config.format == .jsonObject, "--format json-object (its frames have no op to check the joins by)"),
        ].filter(\.0).map(\.1)
        guard unsupported.isEmpty else {
            return "--join-through-router on doesn't support \(unsupported.joined(separator: ", "))"
        }
        return nil
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
                if value == "auto" {
                    print("Invalid --dirty-tracking value: auto (the auto switch was removed; use on or off)")
                } else {
                    print("Invalid --dirty-tracking value: \(value) (expected on or off)")
                }
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
        case "--path-index":
            guard i + 1 < args.count, let mode = PathIndexMode(rawValue: args[i + 1]) else {
                let value = i + 1 < args.count ? args[i + 1] : "nothing"
                print("Invalid --path-index value: \(value) (expected on or off)")
                exit(1)
            }
            config.pathIndex = mode
            i += 1
        case "--field-merge":
            guard i + 1 < args.count, let mode = FieldMergeMode(rawValue: args[i + 1]) else {
                let value = i + 1 < args.count ? args[i + 1] : "nothing"
                print("Invalid --field-merge value: \(value) (expected on or off)")
                exit(1)
            }
            config.fieldMerge = mode
            i += 1
        case "--join-through-router", "--row-addressing":
            let flag = args[i]
            guard i + 1 < args.count, let mode = OnOff(rawValue: args[i + 1]) else {
                let value = i + 1 < args.count ? args[i + 1] : "nothing"
                print("Invalid \(flag) value: \(value) (expected on or off)")
                exit(1)
            }
            if flag == "--join-through-router" {
                config.joinThroughRouter = mode == .on
                // The hero-defense multi-room runner is the only one with a router path; this
                // keeps a one-room run off the legacy single-room path, as the other
                // hero-defense options do.
                if mode == .on { config.heroDefenseOptionsGiven = true }
            } else {
                config.rowAddressing = mode
            }
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
        case "--monster-active-every":
            config.heroDefenseOptionsGiven = true
            guard i + 1 < args.count, let value = Int(args[i + 1]), value >= 1 else {
                try? FileHandle.standardError.write(contentsOf: Data("--monster-active-every needs an integer >= 1\n".utf8))
                exit(2)
            }
            config.monsterActiveEvery = value
            i += 1
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
        case "--record-dir":
            guard i + 1 < args.count else {
                try? FileHandle.standardError.write(contentsOf: Data("--record-dir needs a directory\n".utf8))
                exit(2)
            }
            config.recordDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            i += 1
        case "--capture-rooms":
            guard i + 1 < args.count, let value = Int(args[i + 1]), value > 0 else {
                try? FileHandle.standardError.write(contentsOf: Data("--capture-rooms needs a positive count\n".utf8))
                exit(2)
            }
            config.captureRooms = value
            i += 1
        case "--baseline":
            guard i + 1 < args.count, args[i + 1] == EntityDeltaRun.formatName else {
                try? FileHandle.standardError.write(contentsOf: Data("--baseline needs \(EntityDeltaRun.formatName)\n".utf8))
                exit(2)
            }
            config.entityDeltaBaseline = true
            config.heroDefenseOptionsGiven = true
            i += 1
        case "--no-server-events":
            config.noServerEvents = true
            config.heroDefenseOptionsGiven = true
        case "--merge-stats":
            config.mergeStats = true
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

        if config.entityDeltaBaseline {
            // Only the serial hero-defense multi-room runner encodes the baseline.
            let unsupported = [
                (config.gameType != .heroDefense, "--game-type other than hero-defense"),
                (config.hashCost, "--hash-cost"),
                (config.compareWorkerPool, "--compare-worker-pool"),
                (config.useWorkerPool, "--use-worker-pool"),
                (!config.parallelGiven || config.parallel || config.compareParallel, "parallel runs (pass --parallel false)"),
            ].filter(\.0).map(\.1)
            if !unsupported.isEmpty {
                try? FileHandle.standardError.write(contentsOf: Data("--baseline doesn't support \(unsupported.joined(separator: ", "))\n".utf8))
                exit(2)
            }
        }
        if config.monsterActiveEvery > 1, config.monsterCap == 0 || config.gameType != .heroDefense {
            // Only the capped provider carries it; elsewhere every monster would still move.
            try? FileHandle.standardError.write(contentsOf: Data("--monster-active-every needs --monster-cap and --game-type hero-defense\n".utf8))
            exit(2)
        }
        if config.recordDir != nil, config.captureViews == nil {
            try? FileHandle.standardError.write(contentsOf: Data("--record-dir needs --capture-views\n".utf8))
            exit(2)
        }
        if let capture = config.captureViews {
            config.captureViews = ViewCaptureConfig(directory: capture.directory, rooms: config.captureRooms, recordDirectory: config.recordDir)
            // The hero-defense runner and the generic runner (visibility-test) capture; elsewhere the
            // gate would pass on nothing. Only the generic runner records.
            let unsupported = [
                (config.recordDir != nil && config.gameType != .visibilityTest, "--record-dir other than with --game-type visibility-test"),
                (config.gameType == .cardGame, "--game-type card-game"),
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
        if let refusal = routerJoinRefusal(config) {
            try? FileHandle.standardError.write(contentsOf: Data("\(refusal)\n".utf8))
            exit(2)
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
      --dirty-tracking <m>    on or off (default: on, as the adapter's): dirty tracking for the
                              whole run. Bytes should match across modes; compare times only
                              from -c release builds.
      --dynamic-key-compression <m>  on or off (default: DYNAMIC_KEY_COMPRESSION, else on). off
                              sends dynamic keys as full strings instead of table slots; only
                              the -pathhash formats change.
      --path-index <m>        on or off (default: PATH_INDEX, else on). on sends a pattern's
                              path index instead of its 32-bit hash; only the -pathhash formats
                              change.
      --field-merge <m>       on or off (default: FIELD_MERGE, else on). on merges the field
                              patches of one parent in a frame into one entry with a field mask;
                              only the -pathhash formats change.
      --join-through-router <m>
                              on or off (default off). on: the hero-defense rooms are lands
                              behind a LandRouter and a WebSocketTransport, and each player is a
                              fake connection that joins through the router and acks its sync
                              sequence (outside the timed spans). Bytes are counted per
                              connection (a broadcast once per session): its bytesPerSync is NOT
                              comparable with a run without it. Recorded in each result's
                              routerJoin. Not with --game-type other than hero-defense,
                              --use-worker-pool, --compare-worker-pool, --hash-cost, --baseline,
                              --all or --format json-object.
      --row-addressing <m>    on or off. Default: on with --join-through-router on and a
                              -pathhash --format (not --all), off otherwise. on: the lands name
                              root map rows by slot; given explicitly, it needs those and fails
                              if rows aren't in effect. routerJoin records whether it was.
      --merge-stats           Hero-defense multi-room runs: count, over the measured iterations,
                              the patches sent inside merged entries with field merge's order
                              rule and without it (plans each frame twice; timings aren't
                              measurements). Printed per run and in the result's fieldMerge.
      --record-dir <dir>      With --capture-views and --game-type visibility-test: also write each
                              captured room's re-evaluation record as <dir>/<run>/room-<i>.sstr, for
                              ReevaluationRunner --verify (run it with the same VISIBILITY_TEST_* env).
      --capture-views <dir>   Hero-defense and visibility-test multi-room runs: write, for the first --capture-rooms
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
      --monster-active-every <int>
                              With --monster-cap: update each monster in one tick in <int>, so
                              the rest stay idle (unwritten); 1 = every tick (default)
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

    Perf counter window (Linux perf, serial multi-room runs only; refused with --parallel true,
    --all and the other multi-run modes):
      ENCODING_BENCHMARK_PERF_CONTROL=<ctl-fifo>,<ack-fifo>
                              The FIFOs given to perf stat/record --delay=-1 --control
                              fifo:<ctl>,<ack>. The run enables the counters around one span per
                              room and iteration and waits for each ack.
      ENCODING_BENCHMARK_PERF_WINDOW=nonsync|ticks
                              nonsync (default): the timed iteration except syncNow(), the span
                              timeMs - syncMs measures. ticks: the stepTickOnce() loop only (the
                              same span in the generic runner). The result JSON records
                              perfWindow {mode, toggles}.

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
