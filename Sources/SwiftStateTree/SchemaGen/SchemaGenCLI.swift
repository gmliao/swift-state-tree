import Foundation

/// CLI utility for generating protocol schemas from LandDefinitions.
public struct SchemaGenCLI {
    /// Generate aggregated ProtocolSchema from LandDefinitions (without writing to file).
    ///
    /// This is a helper method that extracts the schema aggregation logic,
    /// useful for HTTP endpoints or other programmatic uses.
    ///
    /// - Parameters:
    ///   - landDefinitions: Array of LandDefinitions to generate schema for
    ///   - version: Schema version string (default: "0.1.0")
    /// - Returns: Aggregated ProtocolSchema containing all lands and definitions
    public static func generateSchema(
        landDefinitions: [AnyLandDefinition],
        version: String = "0.1.0"
    ) -> ProtocolSchema {
        guard !landDefinitions.isEmpty else {
            return ProtocolSchema(version: version, lands: [:], defs: [:])
        }
        
        // Merge all lands into one schema
        var allDefinitions: [String: JSONSchema] = [:]
        var allLands: [String: LandSchema] = [:]
        
        for anyDef in landDefinitions {
            let schema = anyDef.extractSchema()
            
            // Merge definitions (avoid duplicates)
            // If key already exists, keep the first one (they should be identical)
            for (key, value) in schema.defs {
                if allDefinitions[key] == nil {
                    allDefinitions[key] = value
                }
            }
            
            // Merge lands
            for (key, value) in schema.lands {
                allLands[key] = value
            }
        }
        
        // Compute and include schemaHash for version verification
        return ProtocolSchema(
            version: version,
            lands: allLands,
            defs: allDefinitions
        ).withComputedHash()
    }
    
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
        
        // Use the shared aggregation logic
        let finalSchema = generateSchema(landDefinitions: landDefinitions, version: version)
        
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
            print("   - SchemaHash: \(finalSchema.schemaHash)")
            print("   - Lands: \(finalSchema.lands.count)")
            print("   - Definitions: \(finalSchema.defs.count)")
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

