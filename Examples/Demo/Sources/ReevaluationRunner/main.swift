import Foundation
import DemoContent
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
        var exportJsonlPath: String?
        
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
            case "--help", "-h":
                printHelpAndExit()
            default:
                print("Unknown option: \(args[i])")
                printHelpAndExit(exitCode: 1)
            }
        }
        
        guard let inputFile else {
            print("Error: --input is required")
            printHelpAndExit(exitCode: 1)
        }
        
        let source = try JSONReevaluationSource(filePath: inputFile)
        let metadata = try await source.getMetadata()
        let landType = metadata.landType
        
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
        
        if landType == "counter" {
            try await runAndMaybeVerify(
                definition: CounterDemo.makeLand(),
                initialState: CounterState(),
                recordFilePath: inputFile,
                verify: verify,
                exportJsonlPath: exportJsonlPath,
                metadata: metadata,
                currentHardware: currentHardware
            )
            return
        }
        
        if landType == "cookie" {
            try await runAndMaybeVerify(
                definition: CookieGame.makeLand(),
                initialState: CookieGameState(),
                recordFilePath: inputFile,
                verify: verify,
                exportJsonlPath: exportJsonlPath,
                metadata: metadata,
                currentHardware: currentHardware
            )
            return
        }
        
        if landType == "deterministic-math-demo" {
            try await runAndMaybeVerify(
                definition: DeterministicMathDemo.makeLand(),
                initialState: DeterministicMathDemoState(),
                recordFilePath: inputFile,
                verify: verify,
                exportJsonlPath: exportJsonlPath,
                metadata: metadata,
                currentHardware: currentHardware
            )
            return
        }
        
        print("Unsupported landType for Demo ReevaluationRunner: \(landType)")
        printHelpAndExit(exitCode: 2)
    }
    
    private static func runAndMaybeVerify<State: StateNodeProtocol>(
        definition: LandDefinition<State>,
        initialState: State,
        recordFilePath: String,
        verify: Bool,
        exportJsonlPath: String?,
        metadata: ReevaluationRecordMetadata,
        currentHardware: HardwareInfo
    ) async throws {
        let sink = CountingSink()
        
        let first: ReevaluationEngine.RunResult
        do {
            first = try await ReevaluationEngine.run(
                definition: definition,
                initialState: initialState,
                recordFilePath: recordFilePath,
                sink: sink,
                exportJsonlPath: exportJsonlPath
            )
        } catch let error as ReevaluationExportWriteError {
            // The export is incomplete: the run must not report success (#263).
            print("❌ Re-evaluation failed: \(error)")
            exit(12)
        }
        
        let eventCount = await sink.totalEvents
        print("Re-evaluation finished. maxTickId=\(first.maxTickId) emittedServerEvents=\(eventCount)")
        if let last = first.tickHashes[first.maxTickId] {
            print("Final tick hash: \(last)")
        }
        
        print("Sync stream: \(first.syncStreamPresence.summary)")
        print("Sync Output: \(first.syncOutput.summary)")
        print("Initialize: \(first.initialize.summary)")
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
        } else {
            print("❌ Verification failed: mismatched ticks vs recorded=\(recordedMismatches.count)")
            for (tickId, computed, recorded) in recordedMismatches.prefix(10) {
                print("  tick \(tickId): computed=\(computed) recorded=\(recorded)")
            }
            exit(5)
        }

        if !first.serverEventMismatches.isEmpty {
            print("❌ Verification failed: server event mismatches=\(first.serverEventMismatches.count)")
            for (tickId, expected, actual) in first.serverEventMismatches.prefix(5) {
                print("  tick \(tickId): expected \(expected.count) events, got \(actual.count)")
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
        
        let second = try await ReevaluationEngine.run(
            definition: definition,
            initialState: initialState,
            recordFilePath: recordFilePath
        )
        
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
        ReevaluationRunner (Demo)
        
        Usage:
          swift run ReevaluationRunner --input <path> [--verify] [--export-jsonl <path>]
        
        Options:
          --input, -i <path>   Path to re-evaluation record JSON file (required)
          --verify, -v         Run twice and compare per-tick hashes
          --export-jsonl <path>  Export JSONL stream (snapshot + events per tick); a failed
                                 write (a full disk) ends the run with exit 12
          --help, -h           Show this help message

        Sync Output (records with a sync stream, format 2.2):
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
        """)
        exit(exitCode)
    }
}

