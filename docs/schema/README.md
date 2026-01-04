[English](README.md) | [中文版](README.zh-TW.md)

# Schema Generation

SchemaGen is used to automatically generate JSON Schema from LandDefinition and StateNode, providing stable input for client SDK generation.

## Design Goals

- **Client SDK Generation**: Provide stable schema input for generating TypeScript, Kotlin, and other client SDKs
- **Version Alignment**: Support schema version management to ensure client and server versions are consistent
- **Tool Validation**: Can be used for message format validation, testing tools, etc.
- **Auto-generation**: Driven by macro metadata, avoiding handwritten schema

## Generation Flow

Schema generation flow is as follows:

```mermaid
graph LR
    A[LandDefinition] --> B[SchemaExtractor]
    B --> C[ProtocolSchema]
    C --> D[JSON Schema]
    D --> E[Client SDK Generation]
    
    A1[@StateNodeBuilder] --> B
    A2[@Payload] --> B
    
    style A fill:#e1f5ff
    style D fill:#c8e6c9
```

### Step Description

1. **Macro Generates Metadata**:
   - `@StateNodeBuilder` generates `getSyncFields()` method
   - `@Payload` generates `getFieldMetadata()` method

2. **SchemaExtractor Extraction**:
   - Extract State, Action, Event information from `LandDefinition`
   - Recursively extract nested StateNodes
   - Generate complete JSON Schema

3. **Output Schema**:
   - Use `SchemaGenCLI` to output JSON file
   - Or get through Hummingbird `/schema` endpoint

## Usage

### Method 1: Using SchemaGenCLI (Recommended)

Create an executable target to generate schema:

```swift
// Sources/SchemaGen/main.swift
import Foundation
import SwiftStateTree

@main
struct SchemaGen {
    static func main() {
        // Collect all LandDefinitions
        let landDefinitions = [
            AnyLandDefinition(gameLand),
            AnyLandDefinition(lobbyLand)
        ]
        
        // Generate from command line arguments
        try? SchemaGenCLI.generateFromArguments(landDefinitions: landDefinitions)
    }
}
```

Add executable target in `Package.swift`:

```swift
.executableTarget(
    name: "SchemaGen",
    dependencies: [
        .product(name: "SwiftStateTree", package: "SwiftStateTree")
    ],
    path: "Sources/SchemaGen"
)
```

Usage:

```bash
# Output to stdout
swift run SchemaGen

# Output to file
swift run SchemaGen --output schema.json

# Specify version
swift run SchemaGen --output schema.json --version 1.0.0

# View help
swift run SchemaGen --help
```

### Method 2: Use in Code

Generate schema directly in code:

```swift
import SwiftStateTree

// Extract from single LandDefinition
let schema = SchemaExtractor.extract(
    from: gameLand,
    version: "1.0.0"
)

// Use SchemaGenCLI to generate and output
let landDefinitions = [AnyLandDefinition(gameLand)]
try SchemaGenCLI.generate(
    landDefinitions: landDefinitions,
    version: "1.0.0",
    outputPath: "schema.json"
)
```

### Method 3: Merge Multiple Lands

Generate complete schema containing multiple Lands:

```swift
let landDefinitions = [
    AnyLandDefinition(gameLand),
    AnyLandDefinition(lobbyLand),
    AnyLandDefinition(matchmakingLand)
]

try SchemaGenCLI.generate(
    landDefinitions: landDefinitions,
    version: "1.0.0",
    outputPath: "schema.json"
)
```

## Hummingbird Schema Endpoint

`LandServer` automatically provides `/schema` endpoint, outputting JSON schema for current Land.

### Usage

```bash
# Get schema
curl http://localhost:8080/schema

# Format output with jq
curl http://localhost:8080/schema | jq
```

### Response Format

```json
{
  "version": "1.0.0",
  "lands": {
    "game-room": {
      "stateType": "GameState",
      "actions": {
        "JoinAction": { "$ref": "#/defs/JoinAction" },
        "AttackAction": { "$ref": "#/defs/AttackAction" }
      },
      "events": {
        "PlayerJoinedEvent": { "$ref": "#/defs/PlayerJoinedEvent" },
        "DamageEvent": { "$ref": "#/defs/DamageEvent" }
      },
      "sync": {
        "snapshot": { "$ref": "#/defs/GameState" },
        "diff": { "$ref": "#/defs/StateDiff" }
      }
    }
  },
  "defs": {
    "GameState": {
      "type": "object",
      "properties": {
        "players": {
          "type": "object",
          "additionalProperties": { "$ref": "#/defs/PlayerState" }
        }
      }
    },
    "JoinAction": {
      "type": "object",
      "properties": {
        "playerID": { "type": "string" },
        "name": { "type": "string" }
      },
      "required": ["playerID", "name"]
    }
  }
}
```

### CORS Support

Schema endpoint automatically supports CORS for frontend tool usage:

```javascript
// Get schema in browser
fetch('http://localhost:8080/schema')
  .then(response => response.json())
  .then(schema => {
    // Use schema to generate client code
    generateClientSDK(schema)
  })
```

## Schema Format

Generated schema conforms to ProtocolSchema format:

### Top-Level Structure

```json
{
  "version": "1.0.0",        // Schema version
  "lands": { ... },           // Land definitions
  "defs": { ... }             // Type definitions
}
```

### Land Schema

Each Land contains:

- `stateType`: StateNode type name
- `actions`: Action ID → Schema reference
- `clientEvents`: Client Event ID → Schema reference
- `events`: Server Event ID → Schema reference
- `sync`: Sync-related schemas (snapshot, diff)

### Type Definitions

`defs` contains all used type definitions, using JSON Schema format:

- Basic types: `string`, `number`, `boolean`, `integer`
- Objects: `object` with `properties`
- Arrays: `array` with `items`
- References: `$ref` pointing to other definitions

## Schema Version Alignment

### Version Management

Schema version is used to ensure client and server versions are consistent:

```swift
// Specify version when generating
let schema = SchemaExtractor.extract(
    from: gameLand,
    version: "1.2.3"  // Use semantic versioning
)
```

### Version Check

Clients can check schema version:

```typescript
// Client checks version
const schema = await fetch('/schema').then(r => r.json())
if (schema.version !== expectedVersion) {
  console.warn(`Schema version mismatch: expected ${expectedVersion}, got ${schema.version}`)
}
```

### Version Compatibility

- **Major version change**: May include incompatible changes
- **Minor version change**: New features, backward compatible
- **Patch version change**: Bug fixes, backward compatible

## Implementation Details

### SchemaExtractor

`SchemaExtractor` is the main extractor:

```swift
// Extract schema from single Land
let schema = SchemaExtractor.extract(
    from: landDefinition,
    version: "1.0.0"
)
```

**Extraction Flow**:

1. Extract StateTree schema (recursively process nested structures)
2. Extract Action schemas (from action handlers)
3. Extract Event schemas (from event handlers)
4. Generate sync schemas (snapshot and diff)

### StateTreeSchemaExtractor

Recursively extract StateNode schema:

```swift
// Extract StateNode schema
let stateSchema = StateTreeSchemaExtractor.extract(
    GameState.self,
    definitions: &definitions,
    visitedTypes: &visitedTypes
)
```

**Processing Logic**:

- Use `getSyncFields()` to get field metadata
- Recursively process nested StateNodes
- Avoid circular references (using `visitedTypes`)

### ActionEventExtractor

Extract Action and Event schemas:

```swift
// Extract Action schema
let actionSchema = ActionEventExtractor.extractAction(
    JoinAction.self,
    definitions: &definitions
)
```

**Processing Logic**:

- Use `getFieldMetadata()` to get field information
- Process nested types (recursive extraction)
- Generate JSON Schema format

## Best Practices

### 1. Regularly Generate Schema

Automatically generate schema in CI/CD pipeline:

```yaml
# .github/workflows/generate-schema.yml
- name: Generate Schema
  run: swift run SchemaGen --output schema.json --version ${{ github.ref_name }}
```

### 2. Version Management

Use semantic versioning for schema management:

```swift
let version = "1.2.3"  // major.minor.patch
```

### 3. Schema Validation

Validate schema version on client:

```typescript
// Client validation
const serverSchema = await fetch('/schema').then(r => r.json())
if (!isCompatible(serverSchema.version, clientSchemaVersion)) {
  throw new Error('Schema version incompatible')
}
```

### 4. Documentation

Add generated schema to version control for easy change tracking:

```bash
# Generate and commit schema
swift run SchemaGen --output schema.json --version 1.0.0
git add schema.json
git commit -m "Update schema to v1.0.0"
```

## Common Questions

### Q: Why don't some types appear in the schema?

A: Ensure all types are marked with corresponding macros:
- StateNode: Mark with `@StateNodeBuilder`
- Payload: Mark with `@Payload`
- Nested structures: Mark with `@SnapshotConvertible`

### Q: How to handle custom types?

A: Ensure custom types implement necessary protocols:
- `Codable`: For serialization
- `Sendable`: For concurrency safety
- Mark with `@Payload` or `@SnapshotConvertible` to provide metadata

### Q: What if the schema file is too large?

A: Consider:
- Separating schemas for different Lands
- Using `$ref` to reduce duplicate definitions
- Compressing schema files

## Related Documentation

- [Macros](../macros/README.md) - Understand macro usage
- [Core Concepts](../core/README.md) - Understand StateNode and Land DSL
- [Design Documents](../../Notes/protocol/SCHEMA_DEFINITION.md) - Detailed schema format description
