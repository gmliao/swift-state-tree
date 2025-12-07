// Examples/HummingbirdDemo/Sources/SchemaGen/main.swift

import Foundation
import SwiftStateTree
import HummingbirdDemoContent

@main
struct SchemaGen {
    static func main() {
        // Collect all LandDefinitions to generate schema for
        let landDefinitions = [
            AnyLandDefinition(DemoGame.makeLand())
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
