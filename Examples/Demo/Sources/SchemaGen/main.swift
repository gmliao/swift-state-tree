// Examples/Demo/Sources/SchemaGen/main.swift

import Foundation
import SwiftStateTree
import DemoContent

@main
struct SchemaGen {
    static func main() {
        // First, before any output: a closed stdout or stderr pipe gives EPIPE, not a kill (#273).
        ProcessSignals.ignoreSIGPIPE()
        // Collect all LandDefinitions to generate schema for
        let landDefinitions = [
            AnyLandDefinition(CookieGame.makeLand()),
            AnyLandDefinition(CounterDemo.makeLand()),
            AnyLandDefinition(DeterministicMathDemo.makeLand())
            // Add more lands here as needed:
            // AnyLandDefinition(AnotherGame.makeLand()),
        ]
        
        // Generate schema from command line arguments
        do {
            try SchemaGenCLI.generateFromArguments(landDefinitions: landDefinitions)
        } catch {
            print("❌ Error generating schema: \(error)")
            exit(1)
        }
    }
}
