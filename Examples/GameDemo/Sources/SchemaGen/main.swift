// Examples/GameDemo/Sources/SchemaGen/main.swift

import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

@main
struct SchemaGen {
    static func main() {
        // Collect all LandDefinitions to generate schema for
        let landDefinitions = [
            AnyLandDefinition(HeroDefense.makeLand()),
            AnyLandDefinition(ReevaluationMonitor.makeLand()),
            AnyLandDefinition(HeroDefenseReplay.makeLand()),
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
