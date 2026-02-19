// Examples/GameDemo/Sources/SchemaGen/main.swift

import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeReevaluationMonitor

@main
struct SchemaGen {
    static func main() {
        // Collect all LandDefinitions to generate schema for
        // Same-land replay: hero-defense-replay is convention-based alias (replayLandTypes)
        let landDefinitions = [
            AnyLandDefinition(HeroDefense.makeLand()),
            AnyLandDefinition(ReevaluationMonitor.makeLand()),
            AnyLandDefinition(HeroDefenseReplay.makeLand()),
        ]

        do {
            let schema = SchemaGenCLI.generateSchema(
                landDefinitions: landDefinitions,
                replayLandTypes: ["hero-defense"]
            )
            let outputPath = parseOutputPath(from: CommandLine.arguments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(schema)
            if let path = outputPath {
                try jsonData.write(to: URL(fileURLWithPath: path))
                print("✅ Schema generated: \(path)")
                print("   - Lands: \(schema.lands.count)")
            } else {
                if let str = String(data: jsonData, encoding: .utf8) { print(str) }
            }
        } catch {
            print("❌ Error generating schema: \(error)")
            exit(1)
        }
    }

    private static func parseOutputPath(from args: [String]) -> String? {
        var i = 0
        while i < args.count {
            if (args[i] == "--output" || args[i] == "-o"), i + 1 < args.count {
                return args[i + 1]
            }
            i += 1
        }
        return nil
    }
}
