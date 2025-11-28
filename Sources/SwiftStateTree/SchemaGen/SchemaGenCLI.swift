import Foundation

/// CLI utility for generating protocol schemas from LandDefinitions.
public struct SchemaGenCLI {
    /// Generate schema from LandDefinitions and write to file or stdout.
    ///
    /// - Parameters:
    ///   - landDefinitions: Array of LandDefinitions to generate schema for
    ///   - version: Schema version string (default: "0.1.0")
    ///   - outputPath: Optional file path to write schema to. If nil, writes to stdout
    /// - Throws: Encoding errors if JSON encoding fails
    public static func generate(
        landDefinitions: [AnyLandDefinition],
        version: String = "0.1.0",
        outputPath: String? = nil
    ) throws {
        guard !landDefinitions.isEmpty else {
            print("⚠️  Warning: No LandDefinitions provided")
            return
        }
        
        // Merge all lands into one schema
        var allDefinitions: [String: JSONSchema] = [:]
        var allLands: [String: LandSchema] = [:]
        
        for anyDef in landDefinitions {
            let schema = anyDef.extractSchema()
            
            // Merge definitions (avoid duplicates)
            for (key, value) in schema.defs {
                // If key already exists, keep the first one (they should be identical)
                if allDefinitions[key] == nil {
                    allDefinitions[key] = value
                }
            }
            
            // Merge lands
            for (key, value) in schema.lands {
                allLands[key] = value
            }
        }
        
        let finalSchema = ProtocolSchema(
            version: version,
            lands: allLands,
            defs: allDefinitions
        )
        
        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(finalSchema)
        
        // Output
        if let outputPath = outputPath {
            let outputURL = URL(fileURLWithPath: outputPath)
            try jsonData.write(to: outputURL)
            print("✅ Schema generated: \(outputPath)")
            print("   - Version: \(version)")
            print("   - Lands: \(allLands.count)")
            print("   - Definitions: \(allDefinitions.count)")
        } else {
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            }
        }
    }
    
    /// Parse command line arguments and generate schema.
    ///
    /// Supported arguments:
    /// - `--output <path>`: Output file path (optional, defaults to stdout)
    /// - `--version <version>`: Schema version (optional, defaults to "0.1.0")
    ///
    /// - Parameters:
    ///   - landDefinitions: Array of LandDefinitions to generate schema for
    ///   - arguments: Command line arguments (defaults to CommandLine.arguments)
    /// - Throws: Encoding errors if JSON encoding fails
    public static func generateFromArguments(
        landDefinitions: [AnyLandDefinition],
        arguments: [String] = CommandLine.arguments
    ) throws {
        var outputPath: String?
        var version: String = "0.1.0"
        
        // Parse arguments
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--output", "-o":
                if i + 1 < arguments.count {
                    outputPath = arguments[i + 1]
                    i += 1
                }
            case "--version", "-v":
                if i + 1 < arguments.count {
                    version = arguments[i + 1]
                    i += 1
                }
            case "--help", "-h":
                print("Usage: schema-gen [options]")
                print("Options:")
                print("  --output, -o <path>    Output file path (default: stdout)")
                print("  --version, -v <version> Schema version (default: 0.1.0)")
                print("  --help, -h             Show this help message")
                return
            default:
                break
            }
            i += 1
        }
        
        try generate(
            landDefinitions: landDefinitions,
            version: version,
            outputPath: outputPath
        )
    }
}

