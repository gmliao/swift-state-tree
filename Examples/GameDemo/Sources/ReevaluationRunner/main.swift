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
        
        guard landType == "hero-defense" else {
            print("Unsupported landType for GameDemo ReevaluationRunner: \(landType)")
            printHelpAndExit(exitCode: 2)
        }
        
        var services = LandServices()
        services.register(
            GameConfigProviderService(provider: DefaultGameConfigProvider()),
            as: GameConfigProviderService.self
        )
        
        // Use a logger that only shows errors to suppress info logs like "Player joined/left"
        var logger = Logger(label: "reevaluation-runner")
        logger.logLevel = .error
        
        let sink = CountingSink()
        let first = try await ReevaluationEngine.run(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            recordFilePath: inputFile,
            services: services,
            sink: sink,
            exportJsonlPath: exportJsonlPath,
            logger: logger
        )
        
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
        print("")
        
        guard verify else { return }

        if first.recordedStateHashes.isEmpty {
            print("❌ Verification failed: record does not contain any per-tick stateHash (enable live recording on the server)")
            exit(4)
        }
        let recordedMismatches = diffAgainstRecorded(computed: first.tickHashes, recorded: first.recordedStateHashes)
        if recordedMismatches.isEmpty {
            print("✅ Verified: computed hashes match recorded ground truth")
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
        
        let second = try await ReevaluationEngine.run(
            definition: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            recordFilePath: inputFile,
            services: services,
            logger: logger
        )
        
        let mismatches = diffHashes(a: first.tickHashes, b: second.tickHashes)
        if mismatches.isEmpty {
            print("✅ Verified: hashes are identical across two re-evaluation runs")
        } else {
            print("❌ Verification failed: mismatched ticks=\(mismatches.count)")
            for (tickId, ha, hb) in mismatches.prefix(10) {
                print("  tick \(tickId): run1=\(ha) run2=\(hb)")
            }
            exit(3)
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
        ReevaluationRunner (GameDemo)
        
        Usage:
          swift run ReevaluationRunner --input <path> [--verify] [--export-jsonl <path>]
        
        Options:
          --input, -i <path>   Path to re-evaluation record JSON file (required)
          --verify, -v         Run twice and compare per-tick hashes
          --export-jsonl <path>  Export JSONL stream (snapshot + events per tick)
          --help, -h           Show this help message
        """)
        exit(exitCode)
    }
}

