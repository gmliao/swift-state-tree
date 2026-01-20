import Foundation
import SwiftStateTree
import Logging

// MARK: - Main

await ReplayRunner.main()

struct ReplayRunner {
    /// Sink for replaying server events (can be extended to send to clients or write to file)
    actor ReplaySink {
        private var events: [RecordedServerEvent] = []
        
        func record(_ event: RecordedServerEvent) {
            events.append(event)
        }
        
        func getAllEvents() -> [RecordedServerEvent] {
            return events.sorted { $0.sequence < $1.sequence }
        }
        
        func printEvents() {
            let sortedEvents = getAllEvents()
            print("\n=== Server Events (sorted by sequence) ===")
            for event in sortedEvents {
                print("Tick \(event.tickId), Sequence \(event.sequence): \(event.typeIdentifier)")
            }
            print("Total: \(sortedEvents.count) events\n")
        }
    }
    
    /// Calculate deterministic hash of state for verification
    static func calculateStateHash<State: StateNodeProtocol>(_ state: State) -> String {
        let syncEngine = SyncEngine()
        let snapshot: StateSnapshot
        do {
            snapshot = try syncEngine.snapshot(from: state, mode: .all)
        } catch {
            return "error"
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        
        guard let data = try? encoder.encode(snapshot) else {
            return "error"
        }
        
        let hash = DeterministicHash.fnv1a64(data)
        return DeterministicHash.toHex64(hash)
    }
    
    static func main() async {
        let arguments = CommandLine.arguments
        
        // Simple argument parsing
        var inputFile: String?
        var verify = false
        
        var i = 1
        while i < arguments.count {
            switch arguments[i] {
            case "--input", "-i":
                if i + 1 < arguments.count {
                    inputFile = arguments[i + 1]
                    i += 2
                } else {
                    print("Error: --input requires a file path")
                    exit(1)
                }
            case "--verify", "-v":
                verify = true
                i += 1
            case "--help", "-h":
                print("""
                ReplayRunner - Deterministic Replay Tool
                
                Usage: ReplayRunner [options]
                
                Options:
                  --input, -i <path>    Path to recording JSON file (required)
                  --verify, -v          Enable state hash verification
                  --help, -h            Show this help message
                """)
                exit(0)
            default:
                print("Unknown option: \(arguments[i])")
                print("Use --help for usage information")
                exit(1)
            }
        }
        
        guard let inputFile = inputFile else {
            print("Error: --input is required")
            print("Use --help for usage information")
            exit(1)
        }
        
        // Create logger
        let logger = createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.replay",
            scope: "ReplayRunner"
        )
        
        logger.info("Starting replay", metadata: [
            "inputFile": .string(inputFile),
            "verify": .stringConvertible(verify)
        ])
        
        // Load recording file
        do {
            let actionSource = try JSONActionSource(filePath: inputFile)
            let maxTickId = try await actionSource.getMaxTickId()
            
            logger.info("Recording loaded", metadata: [
                "maxTickId": .stringConvertible(maxTickId)
            ])
            
            // For now, we'll use a simple test land definition
            // In a full implementation, we'd need to:
            // 1. Load the land definition from the recording metadata
            // 2. Or require the user to specify the land type
            // 3. Or infer from the recording file structure
            
            logger.warning("ReplayRunner requires land definition to be specified")
            logger.warning("This is a simplified implementation - full version would:")
            logger.warning("  1. Load land definition from recording metadata")
            logger.warning("  2. Initialize LandKeeper with correct definition")
            logger.warning("  3. Run replay loop with state hash verification")
            
            // TODO: Implement full replay loop
            // This would require:
            // - Land definition (from recording or user input)
            // - Initial state
            // - Replay loop that:
            //   1. Creates LandKeeper(mode: .replay, actionSource: actionSource)
            //   2. Runs ticks from 0 to maxTickId
            //   3. Verifies state hash at each tick (if --verify is enabled)
            //   4. Collects server events via replay sink
            
            print("\n✅ ReplayRunner basic structure complete")
            print("⚠️  Full replay loop implementation pending")
            print("   - Requires land definition loading")
            print("   - Requires state hash verification")
            print("   - Requires server event replay sink integration\n")
            
        } catch {
            logger.error("Failed to load recording", metadata: [
                "error": .string(String(describing: error))
            ])
            exit(1)
        }
    }
}
