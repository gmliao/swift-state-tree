import Foundation
import GameContent
import Logging
import SwiftStateTree

@main
struct ReevaluationRunnerMain {
    actor CountingSink: ReevaluationSink {
        private(set) var totalEvents: Int = 0
        
        func onEmittedServerEvents(tickId: Int64, events: [ReevaluationRecordedServerEvent]) async {
            totalEvents += events.count
        }
    }
    
    static func main() async throws {
        let args = CommandLine.arguments
        
        var inputFile: String?
        var verify = false
        var recordMode = false
        var outputPath: String?
        var seedId = 1
        var recordTicks: Int64 = 1200
        var recordPlayers = 5
        var recordMoveEvery: Int64 = 20
        var exportJsonlPath: String?
        var diffWithPath: String?

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--input", "-i":
                inputFile = (i + 1 < args.count) ? args[i + 1] : nil
                i += 2
            case "--verify", "-v":
                verify = true
                i += 1
            case "--export-jsonl":
                exportJsonlPath = (i + 1 < args.count) ? args[i + 1] : nil
                i += 2
            case "--diff-with":
                diffWithPath = (i + 1 < args.count) ? args[i + 1] : nil
                i += 2
            case "--record":
                recordMode = true
                i += 1
            case "--output", "-o":
                outputPath = (i + 1 < args.count) ? args[i + 1] : nil
                i += 2
            case "--seed-id":
                seedId = (i + 1 < args.count) ? (Int(args[i + 1]) ?? 1) : 1
                i += 2
            case "--ticks":
                recordTicks = (i + 1 < args.count) ? (Int64(args[i + 1]) ?? 1200) : 1200
                i += 2
            case "--players":
                recordPlayers = (i + 1 < args.count) ? (Int(args[i + 1]) ?? 5) : 5
                i += 2
            case "--move-every":
                recordMoveEvery = (i + 1 < args.count) ? (Int64(args[i + 1]) ?? 20) : 20
                i += 2
            case "--help", "-h":
                printHelpAndExit()
            default:
                print("Unknown option: \(args[i])")
                printHelpAndExit(exitCode: 1)
            }
        }
        
        if recordMode {
            guard let outputPath else {
                print("Error: --output is required with --record")
                printHelpAndExit(exitCode: 1)
            }
            try await runRecord(
                outputPath: outputPath, seedId: seedId,
                ticks: recordTicks, players: recordPlayers,
                moveEvery: recordMoveEvery)
            return
        }

        guard let inputFile else {
            print("Error: --input is required")
            printHelpAndExit(exitCode: 1)
        }

        if let path = diffWithPath, !FileManager.default.fileExists(atPath: path) {
            print("Error: --diff-with file not found: \(path)")
            exit(1)
        }
        
        let source = try JSONReevaluationSource(filePath: inputFile)
        let metadata = try await source.getMetadata()
        let landType = metadata.landType
        let maxTickId = try await source.getMaxTickId()
        
        // Calculate statistics from the record
        var totalActions = 0
        var totalClientEvents = 0
        var totalLifecycleEvents = 0
        var ticksWithStateHash = 0
        
        for tickId in 0...maxTickId {
            let actions = try await source.getActions(for: tickId)
            let clientEvents = try await source.getClientEvents(for: tickId)
            let lifecycleEvents = try await source.getLifecycleEvents(for: tickId)
            let stateHash = try await source.getStateHash(for: tickId)
            
            totalActions += actions.count
            totalClientEvents += clientEvents.count
            totalLifecycleEvents += lifecycleEvents.count
            if stateHash != nil {
                ticksWithStateHash += 1
            }
        }
        
        // Display record statistics
        print("📊 Record Statistics:")
        print("   Total Ticks: \(maxTickId + 1)")
        print("   Actions: \(totalActions)")
        print("   Client Events: \(totalClientEvents)")
        print("   Lifecycle Events: \(totalLifecycleEvents)")
        if ticksWithStateHash > 0 {
            print("   Ticks with State Hash: \(ticksWithStateHash)")
        }
        print("")
        
        // Display hardware information
        if let recordedHardware = metadata.hardwareInfo {
            print("📋 Recorded Hardware Info:")
            print("   CPU Architecture: \(recordedHardware.cpuArchitecture)")
            print("   OS: \(recordedHardware.osName) \(recordedHardware.osVersion)")
            if let cpuModel = recordedHardware.cpuModel {
                print("   CPU Model: \(cpuModel)")
            }
            if let cpuCores = recordedHardware.cpuCores {
                print("   CPU Cores: \(cpuCores)")
            }
            if let swiftVersion = recordedHardware.swiftVersion {
                print("   Swift Version: \(swiftVersion)")
            }
            print("")
        }
        
        // Display hardware information
        if let recordedHardware = metadata.hardwareInfo {
            print("📋 Recorded Hardware Info:")
            print("   CPU Architecture: \(recordedHardware.cpuArchitecture)")
            print("   OS: \(recordedHardware.osName) \(recordedHardware.osVersion)")
            if let cpuModel = recordedHardware.cpuModel {
                print("   CPU Model: \(cpuModel)")
            }
            if let cpuCores = recordedHardware.cpuCores {
                print("   CPU Cores: \(cpuCores)")
            }
            if let swiftVersion = recordedHardware.swiftVersion {
                print("   Swift Version: \(swiftVersion)")
            }
            print("")
        }
        
        let currentHardware = HardwareInfoCollector.collect()
        print("🖥️  Current Hardware Info:")
        print("   CPU Architecture: \(currentHardware.cpuArchitecture)")
        print("   OS: \(currentHardware.osName) \(currentHardware.osVersion)")
        if let cpuModel = currentHardware.cpuModel {
            print("   CPU Model: \(cpuModel)")
        }
        if let cpuCores = currentHardware.cpuCores {
            print("   CPU Cores: \(cpuCores)")
        }
        if let swiftVersion = currentHardware.swiftVersion {
            print("   Swift Version: \(swiftVersion)")
        }
        print("")
        
        // Replays a record of the land it names; the batch recorder below is Hero Defense only.
        typealias EngineRun = (_ sink: (any ReevaluationSink)?, _ exportJsonlPath: String?, _ diffWithPath: String?, _ logger: Logger) async throws -> ReevaluationEngine.RunResult
        let runEngine: EngineRun
        switch landType {
        case "hero-defense":
            var services = LandServices()
            services.register(
                GameConfigProviderService(provider: DefaultGameConfigProvider()),
                as: GameConfigProviderService.self
            )
            runEngine = { sink, exportJsonlPath, diffWithPath, logger in
                try await ReevaluationEngine.run(
                    definition: HeroDefense.makeLand(),
                    initialState: HeroDefenseState(),
                    recordFilePath: inputFile,
                    services: services,
                    sink: sink,
                    exportJsonlPath: exportJsonlPath,
                    diffWithPath: diffWithPath,
                    logger: logger
                )
            }
        case VisibilityTestConfig.landType:
            runEngine = { sink, exportJsonlPath, diffWithPath, logger in
                try await ReevaluationEngine.run(
                    definition: VisibilityTest.makeLand(),
                    initialState: VisibilityTestState(),
                    recordFilePath: inputFile,
                    sink: sink,
                    exportJsonlPath: exportJsonlPath,
                    diffWithPath: diffWithPath,
                    logger: logger
                )
            }
        default:
            print("Unsupported landType for GameDemo ReevaluationRunner: \(landType)")
            printHelpAndExit(exitCode: 2)
        }
        
        // Use a logger that only shows errors to suppress info logs like "Player joined/left"
        var logger = Logger(label: "reevaluation-runner")
        logger.logLevel = .error
        
        let sink = CountingSink()
        let first = try await runEngine(sink, exportJsonlPath, diffWithPath, logger)
        
        let eventCount = await sink.totalEvents
        
        // Display re-evaluation results
        print("🔄 Re-evaluation Results:")
        print("   Processed Ticks: \(first.maxTickId + 1)")
        if eventCount > 0 {
            print("   Emitted Server Events: \(eventCount)")
        }
        if let last = first.tickHashes[first.maxTickId] {
            print("   Final Tick Hash: \(last)")
        }
        print("   Sync Stream: \(first.syncStreamPresence.summary)")
        print("   Sync Output: \(first.syncOutput.summary)")
        print("   Initialize: \(first.initialize.summary)")
        print("")
        
        guard verify else { return }

        if first.recordedStateHashes.isEmpty {
            print("❌ Verification failed: record does not contain any per-tick stateHash (enable live recording on the server)")
            exit(4)
        }
        // Ticks recorded as unavailable are not compared here; they are reported (exit 11) only
        // after every definite failure below.
        let recordedMismatches = diffAgainstRecorded(
            computed: first.tickHashes,
            recorded: first.recordedStateHashes.filter { first.unverifiableStateHashes[$0.key] == nil }
        )
        if recordedMismatches.isEmpty {
            print("✅ Verified state hashes: computed hashes match recorded ground truth")
            if let recordedHardware = metadata.hardwareInfo {
                let hardwareMatch = recordedHardware.cpuArchitecture == currentHardware.cpuArchitecture
                if hardwareMatch {
                    print("   ✅ Same CPU architecture (\(currentHardware.cpuArchitecture))")
                } else {
                    print("   ✅ Cross-architecture verification: \(recordedHardware.cpuArchitecture) → \(currentHardware.cpuArchitecture)")
                }
            }
        } else if let reason = first.hashIncomparability {
            // A record older than 2.3 of a land whose hashes changed with #175: not a replay
            // difference, and not verifiable by this build.
            print("❌ Verification not possible: \(reason); \(recordedMismatches.count) ticks differ, first at tick \(recordedMismatches.first?.0 ?? -1). Re-record with this build.")
            exit(10)
        } else {
            print("❌ Verification failed: mismatched ticks vs recorded=\(recordedMismatches.count)")
            for (tickId, computed, recorded) in recordedMismatches.prefix(10) {
                print("  tick \(tickId): computed=\(computed) recorded=\(recorded)")
            }
            exit(5)
        }

        // Decided per tick by the engine: ticks with sequence watermarks must match exactly,
        // including `sequence`; ticks without them (older records) may differ in `sequence` only.
        switch first.serverEventVerification {
        case .passed:
            break
        case let .passedIgnoringSequence(ticks):
            print("⚠️ Server event sequence numbering differs in replay on \(ticks.count) ticks without sequence watermarks (older record format); event content matches")
        case let .failed(ticks):
            print("❌ Verification failed: server event mismatches=\(ticks.count)")
            let failedTicks = Set(ticks)
            for (tickId, expected, actual) in first.serverEventMismatches.filter({ failedTicks.contains($0.tickId) }).prefix(5) {
                let mode = first.watermarkedTicks.contains(tickId) ? "exact" : "content"
                print("  tick \(tickId) [\(mode)]: expected \(expected.count) events \(describe(expected)), got \(actual.count) events \(describe(actual))")
            }
            exit(6)
        }

        // Sync outputs and OnInitialize: `failed` and `malformed` fail verification; `partial` and
        // `skipped` are reported, since older records and degraded views cannot be fully compared.
        switch first.syncOutput.verdict {
        case .failed, .malformed:
            print("❌ Verification failed: sync output \(first.syncOutput.summary)")
            exit(8)
        case .passed, .partial, .skipped:
            break
        }
        if case .failed(let reason) = first.initialize {
            print("❌ Verification failed: OnInitialize \(reason)")
            exit(9)
        }
        if case .notComparable(let reason) = first.initialize {
            print("❌ Verification not possible: OnInitialize \(reason)")
            exit(10)
        }
        
        let second = try await runEngine(nil, nil, nil, logger)
        
        let mismatches = diffHashes(a: first.tickHashes, b: second.tickHashes)
        if mismatches.isEmpty {
            print("✅ Verified state hashes: identical across two re-evaluation runs")
        } else {
            print("❌ Verification failed: mismatched ticks=\(mismatches.count)")
            for (tickId, ha, hb) in mismatches.prefix(10) {
                print("  tick \(tickId): run1=\(ha) run2=\(hb)")
            }
            exit(3)
        }

        // Only after every definite failure: hashes the live run could not compute.
        var unverifiable: [String] = []
        if let (tickId, reason) = first.unverifiableStateHashes.min(by: { $0.key < $1.key }) {
            unverifiable.append("\(first.unverifiableStateHashes.count) ticks recorded without a state hash, first at tick \(tickId) (\(reason))")
        }
        if case .unverifiable(let reason) = first.initialize {
            unverifiable.append("OnInitialize \(reason)")
        }
        if !unverifiable.isEmpty {
            print("❌ Verification not possible: \(unverifiable.joined(separator: "; "))")
            exit(11)
        }
    }

    /// Headless batch recording: live keeper + deterministic MoveTo injection, saved as a
    /// re-evaluation record. The RNG seed is derived from the landID, so each seedId yields
    /// a distinct recording.
    private static func runRecord(outputPath: String, seedId: Int, ticks: Int64, players: Int, moveEvery: Int64) async throws {
        let landID = "hero-defense:batch-\(seedId)"
        var services = LandServices()
        services.register(
            GameConfigProviderService(provider: DefaultGameConfigProvider()),
            as: GameConfigProviderService.self
        )
        let keeper = LandKeeper<HeroDefenseState>(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            services: services,
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        await keeper.setLandID(landID)
        guard let recorder = await keeper.getReevaluationRecorder() else {
            print("Error: ReevaluationRecorder not available")
            exit(7)
        }
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "hero-defense",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ["seedId": "\(seedId)"],
            rngSeed: DeterministicSeed.fromLandID(landID),
            version: "2.0"
        ))
        for p in 0 ..< players {
            try await keeper.join(
                playerID: PlayerID("batch\(seedId)-player-\(p)"),
                clientID: ClientID("batch\(seedId)-client-\(p)"),
                sessionID: SessionID("batch\(seedId)-session-\(p)")
            )
        }
        for tickId in Int64(0) ..< ticks {
            if tickId % moveEvery == 0 {
                for p in 0 ..< players {
                    // Deterministic far-away targets (integer math only) keep every player moving
                    let tx = Float((p * 37 + Int(tickId) * 13) % 128)
                    let ty = Float((p * 53 + Int(tickId) * 17) % 72)
                    let event = MoveToEvent(x: tx, y: ty)
                    guard let data = try? JSONEncoder().encode(event),
                          let payload = try? JSONDecoder().decode(AnyCodable.self, from: data)
                    else { continue }
                    try? await keeper.handleClientEvent(
                        AnyClientEvent(type: "MoveTo", payload: payload),
                        playerID: PlayerID("batch\(seedId)-player-\(p)"),
                        clientID: ClientID("batch\(seedId)-client-\(p)"),
                        sessionID: SessionID("batch\(seedId)-session-\(p)")
                    )
                }
            }
            await keeper.stepTickOnce()
        }
        try await recorder.save(to: outputPath)
        print("✅ Recorded \(ticks) ticks to \(outputPath) (landID=\(landID))")
    }

    /// Short "sequence:type" listing of server events for mismatch output.
    private static func describe(_ events: [ReevaluationRecordedServerEvent]) -> String {
        "[" + events.map { "\($0.sequence):\($0.typeIdentifier)" }.joined(separator: ", ") + "]"
    }

    private static func diffAgainstRecorded(
        computed: [Int64: String],
        recorded: [Int64: String]
    ) -> [(Int64, String, String)] {
        let ticks = recorded.keys.sorted()
        var out: [(Int64, String, String)] = []
        for tickId in ticks {
            let c = computed[tickId] ?? "missing"
            let r = recorded[tickId] ?? "missing"
            if c != r {
                out.append((tickId, c, r))
            }
        }
        return out
    }
    
    private static func diffHashes(
        a: [Int64: String],
        b: [Int64: String]
    ) -> [(Int64, String, String)] {
        let maxTick = max(a.keys.max() ?? -1, b.keys.max() ?? -1)
        guard maxTick >= 0 else { return [] }
        var out: [(Int64, String, String)] = []
        for tickId in 0...maxTick {
            let ha = a[tickId] ?? "missing"
            let hb = b[tickId] ?? "missing"
            if ha != hb {
                out.append((tickId, ha, hb))
            }
        }
        return out
    }
    
    private static func printHelpAndExit(exitCode: Int32 = 0) -> Never {
        print("""
        ReevaluationRunner (GameDemo)

        Usage:
          swift run ReevaluationRunner --input <path> [--verify] [--export-jsonl <path>] [--diff-with <path>]

        Options:
          --input, -i <path>     Path to re-evaluation record JSON file (required unless --record)
          --record               Headless batch recording mode (writes a new record)
          --output, -o <path>    Output record path for --record
          --seed-id <n>          Seed index for --record (varies the RNG seed; default 1)
          --ticks <n>            Ticks to record (default 1200)
          --players <n>          Players to join in --record (default 5)
          --verify, -v           Run twice and compare per-tick hashes
          --export-jsonl <path>  Export JSONL stream (snapshot + events per tick)
          --diff-with <path>     Compare with recorded state JSONL (output field-level diffs)
          --help, -h             Show this help message

        Sync Output (records with a sync stream, format 2.2 and later):
          passed     every scope (broadcast, per-player, seed; events with opcode 107) was
                     compared, nothing was unverifiable, every skip was benign, and no event
                     was left after the last output
          partial    no mismatch, but something could not be compared (a degraded view, an
                     encode drop, an event sent outside the merged frame, a scope never seen),
                     was skipped for a reason that is not benign, or events were left after
                     the last output; the summary lists the skip reasons
          failed     a recorded hash was not reproduced, or the replay's patches applied to
                     its previous view did not give its new view (the apply check, which finds
                     diff bugs both sides share); --verify exits 8, also on malformed
          The apply check uses a reference client, not the TypeScript SDK: passing it proves
          the patches correct, not that the TS client converges (#121).
          Mismatch detail: REEVALUATION_RECORD_SYNC_DETAILS=true (per-player hashes: one per
          player with patches, per output) and REEVALUATION_RECORD_SYNC_PATCHES=true (every
          patch value, roughly every state update sent, uncapped: short runs only) on the
          recording server let the report name the player and the first differing patch.
          skipped    the record cannot be verified (no sync stream, or older than 2.2)
          Benign skips: an opcode 107 per-player update that was not sent (its cache was not
          committed, so the next diff resends it), once a later comparison for that player saw
          the resend; a joiner's full view that did not encode, once a later seed for that
          player was compared. Without that later comparison neither is benign.
        Initialize: OnInitialize's events and state hash (--verify exits 9 on a mismatch).
        Records older than 2.3 (#175), of a land whose state has a @SnapshotConvertible state
          node in a String or PlayerID map (Hero Defense): a state or initialize hash mismatch
          is reported as "recorded before #175, hash not comparable" and --verify exits 10;
          re-record with this build. Any other mismatch, and every sync-output failure, still
          fails (exit 5, 9 or 8).
        State hash: from record format 2.4, every @Sync field at every depth, whatever its
          policy (not @Internal); older records hold the broadcast view and are compared with
          that. A tick recorded without a hash (the live run could not compute it) is
          unverifiable: --verify exits 11, after every definite failure (5, 6, 8, 9). A valid
          recorded hash this replay cannot compute is a mismatch (exit 5).
        """)
        exit(exitCode)
    }
}
