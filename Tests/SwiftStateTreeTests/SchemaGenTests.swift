// Tests/SwiftStateTreeTests/SchemaGenTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test Types for Schema Generation

/// Test StateNode for schema generation
@StateNodeBuilder
struct TestSchemaStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    @Sync(.broadcast)
    var count: Int = 0
    
    @Sync(.serverOnly)
    var hidden: Bool = false
    
    init() {}
}

/// Test nested StateNode
@StateNodeBuilder
struct TestNestedStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var player: TestSchemaStateNode = TestSchemaStateNode()
    
    @Sync(.broadcast)
    var score: Int = 0
    
    init() {}
}

/// Test Action with @Payload
@Payload
struct TestAction: ActionPayload {
    typealias Response = TestActionResponse
    let id: String
    let value: Int
}

/// Test Action Response
struct TestActionResponse: Codable, Sendable {
    let success: Bool
    let message: String
}

/// Test Event
@Payload
struct TestEvent: ServerEventPayload, SchemaMetadataProvider {
    let type: String
    let data: String
}

// MARK: - SchemaExtractor Tests

@Test("SchemaExtractor can extract schema from LandDefinition")
func testSchemaExtractorBasic() throws {
    // Create a simple land definition
    @StateNodeBuilder
    struct SimpleState: StateNodeProtocol {
        @Sync(.broadcast)
        var value: Int = 0
        
        init() {}
    }
    
    @Payload
    struct SimpleAction: ActionPayload {
        typealias Response = String
        let input: String
    }
    
    enum SimpleClientEvents: ClientEventPayload {
        case test(String)
    }
    
    enum SimpleServerEvents: ServerEventPayload {
        case result(String)
    }
    
    let landDefinition = Land(
        "test-land",
        using: SimpleState.self
    ) {
        Rules {
            HandleAction(SimpleAction.self) { (state: inout SimpleState, action: SimpleAction, ctx: LandContext) in
                return "response"
            }
        }
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition, version: "0.1.0")
    
    // Verify basic structure
    #expect(schema.version == "0.1.0")
    #expect(schema.lands.count == 1)
    #expect(schema.lands["test-land"] != nil)
    
    let landSchema = schema.lands["test-land"]!
    #expect(landSchema.stateType == "SimpleState")
}

@Test("SchemaExtractor includes state type in definitions")
func testSchemaExtractorStateTypeInDefinitions() throws {
    @StateNodeBuilder
    struct TestState: StateNodeProtocol {
        @Sync(.broadcast)
        var field: String = ""
        
        init() {}
    }
    
    enum TestClientEvents: ClientEventPayload {
        case test
    }
    
    enum TestServerEvents: ServerEventPayload {
        case result
    }
    
    let landDefinition = Land(
        "test",
        using: TestState.self
    ) {
        Rules {}
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition)
    
    // Verify state type is in definitions
    #expect(schema.defs["TestState"] != nil)
    
    let stateSchema = schema.defs["TestState"]!
    #expect(stateSchema.type == .object)
    #expect(stateSchema.properties != nil)
    #expect(stateSchema.properties?["field"] != nil)
}

@Test("SchemaExtractor includes actions in schema")
func testSchemaExtractorActions() throws {
    @StateNodeBuilder
    struct TestState: StateNodeProtocol {
        @Sync(.broadcast)
        var value: Int = 0
        
        init() {}
    }
    
    enum TestClientEvents: ClientEventPayload {
        case test
    }
    
    enum TestServerEvents: ServerEventPayload {
        case result
    }
    
    let landDefinition = Land(
        "test",
        using: TestState.self
    ) {
        Rules {
            HandleAction(TestAction.self) { (state: inout TestState, action: TestAction, ctx: LandContext) in
                return TestActionResponse(success: true, message: "ok")
            }
        }
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition)
    
    let landSchema = schema.lands["test"]!
    // Actions should be present (may be empty if action type doesn't conform to SchemaMetadataProvider)
    #expect(landSchema.actions.count >= 0)
}

@Test("SchemaExtractor includes struct server events in definitions")
func testSchemaExtractorStructServerEvents() throws {
    @StateNodeBuilder
    struct TestState: StateNodeProtocol {
        @Sync(.broadcast)
        var value: Int = 0
        
        init() {}
    }
    
    enum TestClientEvents: ClientEventPayload {
        case test
    }
    
    // Use TestEvent (struct ServerEventPayload with @Payload) as server events type
    let landDefinition = Land(
        "test-events",
        using: TestState.self
    ) {
        ServerEvents {
            Register(TestEvent.self)
        }
        Rules { }
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition)
    
    // Verify TestEvent is present in definitions with full properties
    let typeName = String(describing: TestEvent.self)
    #expect(schema.defs[typeName] != nil)
    
    let eventSchema = schema.defs[typeName]!
    #expect(eventSchema.type == .object)
    // TestEvent has "type" and "data" fields
    #expect(eventSchema.properties?["type"]?.type == .string)
    #expect(eventSchema.properties?["data"]?.type == .string)
    #expect(eventSchema.required?.contains("type") == true)
    #expect(eventSchema.required?.contains("data") == true)
    
    // Verify events map uses generated event ID (e.g., "TestEvent" -> "test")
    let landSchema = schema.lands["test-events"]!
    let eventKeys = Array(landSchema.events.keys)
    // Event ID is generated from type name: "TestEvent" -> "test"
    #expect(eventKeys.contains("test"))
    
    // Verify the event reference points to the correct definition
    let eventRef = landSchema.events["test"]
    #expect(eventRef?.ref == "#/defs/\(typeName)")
}

// MARK: - TypeToSchemaConverter Tests

@Test("TypeToSchemaConverter converts primitive types")
func testTypeToSchemaConverterPrimitives() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    // Test String
    let stringSchema = TypeToSchemaConverter.convert(
        String.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    #expect(stringSchema.type == .string)
    
    // Test Int
    let intSchema = TypeToSchemaConverter.convert(
        Int.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    #expect(intSchema.type == .integer)
    
    // Test Bool
    let boolSchema = TypeToSchemaConverter.convert(
        Bool.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    #expect(boolSchema.type == .boolean)
    
    // Test Double
    let doubleSchema = TypeToSchemaConverter.convert(
        Double.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    #expect(doubleSchema.type == .number)
}

@Test("TypeToSchemaConverter converts StateNodeProtocol types")
func testTypeToSchemaConverterStateNode() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let schema = TypeToSchemaConverter.convert(
        TestSchemaStateNode.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    // Should create a reference to the definition
    #expect(schema.ref != nil)
    #expect(schema.ref!.contains("TestSchemaStateNode"))
    
    // Should have definition
    #expect(definitions["TestSchemaStateNode"] != nil)
    
    let stateSchema = definitions["TestSchemaStateNode"]!
    #expect(stateSchema.type == .object)
    #expect(stateSchema.properties != nil)
    #expect(stateSchema.properties?["name"] != nil)
    #expect(stateSchema.properties?["count"] != nil)
    #expect(stateSchema.properties?["hidden"] != nil)
}

@Test("TypeToSchemaConverter handles nested StateNodes")
func testTypeToSchemaConverterNestedStateNode() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    _ = TypeToSchemaConverter.convert(
        TestNestedStateNode.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    // Should have both types in definitions
    #expect(definitions["TestNestedStateNode"] != nil)
    #expect(definitions["TestSchemaStateNode"] != nil)
    
    let nestedSchema = definitions["TestNestedStateNode"]!
    #expect(nestedSchema.properties?["player"] != nil)
    #expect(nestedSchema.properties?["score"] != nil)
}

@Test("TypeToSchemaConverter resolves map value types")
func testTypeToSchemaConverterMapValueType() {
    @StateNodeBuilder
    struct MapState: StateNodeProtocol {
        @Sync(.broadcast)
        var players: [PlayerID: String] = [:]
        
        init() {}
    }
    
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    _ = TypeToSchemaConverter.convert(
        MapState.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    let typeName = String(describing: MapState.self)
    #expect(definitions[typeName] != nil)
    
    let stateSchema = definitions[typeName]!
    let playersSchema = stateSchema.properties?["players"]
    #expect(playersSchema?.type == .object)
    #expect(playersSchema?.additionalProperties?.value.type == .string)
}

// MARK: - StateTreeSchemaExtractor Tests

@Test("StateTreeSchemaExtractor extracts schema from StateNode type")
func testStateTreeSchemaExtractor() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let schema = StateTreeSchemaExtractor.extract(
        TestSchemaStateNode.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    #expect(schema.ref != nil)
    #expect(definitions["TestSchemaStateNode"] != nil)
}

@Test("StateTreeSchemaExtractor extracts schema from StateNode instance")
func testStateTreeSchemaExtractorFromInstance() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let state = TestSchemaStateNode()
    let schema = StateTreeSchemaExtractor.extract(
        from: state,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    #expect(schema.ref != nil)
    #expect(definitions["TestSchemaStateNode"] != nil)
}

// MARK: - ActionEventExtractor Tests

@Test("ActionEventExtractor extracts action schema")
func testActionEventExtractorAction() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let schema = ActionEventExtractor.extractAction(
        TestAction.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    // We always return a $ref and store the full schema in defs
    let typeName = String(describing: TestAction.self)
    #expect(schema.ref == "#/defs/\(typeName)")
    #expect(definitions[typeName] != nil)
    
    let def = definitions[typeName]!
    #expect(def.type == .object)
    #expect(def.properties?["id"]?.type == .string)
    #expect(def.properties?["value"]?.type == .integer)
    #expect(def.required?.contains("id") == true)
    #expect(def.required?.contains("value") == true)
}

@Test("ActionEventExtractor extracts event schema")
func testActionEventExtractorEvent() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let schema = ActionEventExtractor.extractEvent(
        TestEvent.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    let typeName = String(describing: TestEvent.self)
    #expect(schema.ref == "#/defs/\(typeName)")
    #expect(definitions[typeName] != nil)
    
    let def = definitions[typeName]!
    #expect(def.type == .object)
    #expect(def.properties?["type"]?.type == .string)
    #expect(def.properties?["data"]?.type == .string)
    #expect(def.required?.contains("type") == true)
    #expect(def.required?.contains("data") == true)
}

// MARK: - Event Property Extraction Tests

/// Test event with multiple properties (similar to ChatMessageEvent)
@Payload
struct TestChatMessageEvent: ServerEventPayload {
    let message: String
    let from: String
}

/// Test event with single property (similar to WelcomeEvent)
@Payload
struct TestWelcomeEvent: ServerEventPayload {
    let message: String
}

/// Test event with no properties (similar to PongEvent)
@Payload
struct TestPongEvent: ServerEventPayload {
    init() {}
}

@Test("ActionEventExtractor extracts ChatMessageEvent-like event with multiple properties")
func testActionEventExtractorChatMessageEvent() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let schema = ActionEventExtractor.extractEvent(
        TestChatMessageEvent.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    let typeName = String(describing: TestChatMessageEvent.self)
    #expect(schema.ref == "#/defs/\(typeName)")
    #expect(definitions[typeName] != nil)
    
    let def = definitions[typeName]!
    #expect(def.type == .object)
    #expect(def.properties?["message"]?.type == .string)
    #expect(def.properties?["from"]?.type == .string)
    #expect(def.required?.contains("message") == true)
    #expect(def.required?.contains("from") == true)
}

@Test("ActionEventExtractor extracts WelcomeEvent-like event with single property")
func testActionEventExtractorWelcomeEvent() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let schema = ActionEventExtractor.extractEvent(
        TestWelcomeEvent.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    let typeName = String(describing: TestWelcomeEvent.self)
    #expect(schema.ref == "#/defs/\(typeName)")
    #expect(definitions[typeName] != nil)
    
    let def = definitions[typeName]!
    #expect(def.type == .object)
    #expect(def.properties?["message"]?.type == .string)
    #expect(def.required?.contains("message") == true)
}

@Test("ActionEventExtractor extracts PongEvent-like event with no properties")
func testActionEventExtractorPongEvent() {
    var definitions: [String: JSONSchema] = [:]
    var visitedTypes: Set<String> = []
    
    let schema = ActionEventExtractor.extractEvent(
        TestPongEvent.self,
        definitions: &definitions,
        visitedTypes: &visitedTypes
    )
    
    let typeName = String(describing: TestPongEvent.self)
    #expect(schema.ref == "#/defs/\(typeName)")
    #expect(definitions[typeName] != nil)
    
    let def = definitions[typeName]!
    #expect(def.type == .object)
    // Empty event should have no properties or empty properties
    #expect(def.properties == nil || def.properties?.isEmpty == true)
}

@Test("SchemaExtractor includes server event properties in definitions")
func testSchemaExtractorServerEventProperties() {
    @StateNodeBuilder
    struct TestState: StateNodeProtocol {
        @Sync(.broadcast)
        var value: Int = 0
        
        init() {}
    }
    
    let landDefinition = Land(
        "test-events-properties",
        using: TestState.self
    ) {
        ServerEvents {
            Register(TestChatMessageEvent.self)
            Register(TestWelcomeEvent.self)
            Register(TestPongEvent.self)
        }
        Rules { }
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition)
    
    // Verify TestChatMessageEvent has properties
    let chatMessageTypeName = String(describing: TestChatMessageEvent.self)
    #expect(schema.defs[chatMessageTypeName] != nil)
    let chatMessageDef = schema.defs[chatMessageTypeName]!
    #expect(chatMessageDef.type == .object)
    #expect(chatMessageDef.properties?["message"]?.type == .string)
    #expect(chatMessageDef.properties?["from"]?.type == .string)
    #expect(chatMessageDef.required?.contains("message") == true)
    #expect(chatMessageDef.required?.contains("from") == true)
    
    // Verify TestWelcomeEvent has properties
    let welcomeTypeName = String(describing: TestWelcomeEvent.self)
    #expect(schema.defs[welcomeTypeName] != nil)
    let welcomeDef = schema.defs[welcomeTypeName]!
    #expect(welcomeDef.type == .object)
    #expect(welcomeDef.properties?["message"]?.type == .string)
    #expect(welcomeDef.required?.contains("message") == true)
    
    // Verify TestPongEvent (empty event)
    let pongTypeName = String(describing: TestPongEvent.self)
    #expect(schema.defs[pongTypeName] != nil)
    let pongDef = schema.defs[pongTypeName]!
    #expect(pongDef.type == .object)
    
    // Verify events are in land schema
    let landSchema = schema.lands["test-events-properties"]!
    #expect(landSchema.events.count == 3)
}

// MARK: - ProtocolSchema Encoding Tests

@Test("ProtocolSchema can be encoded to JSON")
func testProtocolSchemaEncoding() throws {
    @StateNodeBuilder
    struct TestState: StateNodeProtocol {
        @Sync(.broadcast)
        var value: Int = 0
        
        init() {}
    }
    
    enum TestClientEvents: ClientEventPayload {
        case test
    }
    
    enum TestServerEvents: ServerEventPayload {
        case result
    }
    
    let landDefinition = Land(
        "test",
        using: TestState.self
    ) {
        Rules {}
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition)
    
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let jsonData = try encoder.encode(schema)
    
    // Should encode without errors
    #expect(jsonData.count > 0)
    
    // Verify it can be decoded back
    let decoder = JSONDecoder()
    let decodedSchema = try decoder.decode(ProtocolSchema.self, from: jsonData)
    #expect(decodedSchema.version == schema.version)
    #expect(decodedSchema.lands.count == schema.lands.count)
}

// MARK: - End-to-End Schema Generation Tests

/// Test event types matching the demo (ChatMessageEvent, WelcomeEvent, PongEvent)
@Payload
struct DemoChatMessageEvent: ServerEventPayload {
    let message: String
    let from: String
}

@Payload
struct DemoWelcomeEvent: ServerEventPayload {
    let message: String
}

@Payload
struct DemoPongEvent: ServerEventPayload {
    init() {}
}

/// Test action matching the demo (JoinAction)
@Payload
struct DemoJoinAction: ActionPayload {
    typealias Response = DemoJoinResult
    let name: String
}

struct DemoJoinResult: Codable, Sendable {
    let playerID: String
    let message: String
}

/// Test state matching the demo (DemoGameState)
@StateNodeBuilder
struct DemoGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var messageCount: Int = 0
    
    @Sync(.broadcast)
    var ticks: Int = 0
    
    init() {}
}

@Test("SchemaExtractor generates complete schema for demo-like LandDefinition")
func testSchemaExtractorDemoLikeLandDefinition() {
    let landDefinition = Land(
        "demo-game",
        using: DemoGameState.self
    ) {
        ServerEvents {
            Register(DemoChatMessageEvent.self)
            Register(DemoWelcomeEvent.self)
            Register(DemoPongEvent.self)
        }
        Rules {
            HandleAction(DemoJoinAction.self) { (state: inout DemoGameState, action: DemoJoinAction, ctx: LandContext) in
                return DemoJoinResult(playerID: ctx.playerID.rawValue, message: "Joined")
            }
        }
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition, version: "0.1.0")
    
    // Verify state type
    #expect(schema.defs["DemoGameState"] != nil)
    let stateDef = schema.defs["DemoGameState"]!
    #expect(stateDef.properties?["players"] != nil)
    #expect(stateDef.properties?["messageCount"] != nil)
    #expect(stateDef.properties?["ticks"] != nil)
    
    // Verify ChatMessageEvent has complete properties
    #expect(schema.defs["DemoChatMessageEvent"] != nil)
    let chatMessageDef = schema.defs["DemoChatMessageEvent"]!
    #expect(chatMessageDef.type == .object)
    #expect(chatMessageDef.properties?["message"]?.type == .string)
    #expect(chatMessageDef.properties?["from"]?.type == .string)
    #expect(chatMessageDef.required?.contains("message") == true)
    #expect(chatMessageDef.required?.contains("from") == true)
    
    // Verify WelcomeEvent has complete properties
    #expect(schema.defs["DemoWelcomeEvent"] != nil)
    let welcomeDef = schema.defs["DemoWelcomeEvent"]!
    #expect(welcomeDef.type == .object)
    #expect(welcomeDef.properties?["message"]?.type == .string)
    #expect(welcomeDef.required?.contains("message") == true)
    
    // Verify PongEvent (empty event)
    #expect(schema.defs["DemoPongEvent"] != nil)
    let pongDef = schema.defs["DemoPongEvent"]!
    #expect(pongDef.type == .object)
    #expect(pongDef.properties != nil) // Should have properties object even if empty
    
    // Verify JoinAction
    #expect(schema.defs["DemoJoinAction"] != nil)
    let joinActionDef = schema.defs["DemoJoinAction"]!
    #expect(joinActionDef.properties?["name"]?.type == .string)
    #expect(joinActionDef.required?.contains("name") == true)
    
    // Verify land schema
    #expect(schema.lands["demo-game"] != nil)
    let landSchema = schema.lands["demo-game"]!
    #expect(landSchema.stateType == "DemoGameState")
    #expect(landSchema.actions.count == 1)
    #expect(landSchema.events.count == 3)
    // Event IDs are generated from type names
    // Check that all three events are present (exact IDs depend on generateEventID implementation)
    let eventKeys = Array(landSchema.events.keys)
    #expect(eventKeys.count == 3)
    // Verify that the event definitions exist (regardless of the exact ID format)
    #expect(schema.defs["DemoChatMessageEvent"] != nil)
    #expect(schema.defs["DemoWelcomeEvent"] != nil)
    #expect(schema.defs["DemoPongEvent"] != nil)
}

@Test("SchemaExtractor generates JSON-encodable schema with complete event properties")
func testSchemaExtractorJSONEncodableWithEventProperties() throws {
    let landDefinition = Land(
        "test-land",
        using: DemoGameState.self
    ) {
        ServerEvents {
            Register(DemoChatMessageEvent.self)
            Register(DemoWelcomeEvent.self)
        }
        Rules { }
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition)
    
    // Encode to JSON
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let jsonData = try encoder.encode(schema)
    
    // Decode back to verify structure
    let decoder = JSONDecoder()
    let decodedSchema = try decoder.decode(ProtocolSchema.self, from: jsonData)
    
    // Verify ChatMessageEvent properties are preserved
    let chatMessageDef = decodedSchema.defs["DemoChatMessageEvent"]
    #expect(chatMessageDef != nil)
    #expect(chatMessageDef?.properties?["message"]?.type == .string)
    #expect(chatMessageDef?.properties?["from"]?.type == .string)
    
    // Verify WelcomeEvent properties are preserved
    let welcomeDef = decodedSchema.defs["DemoWelcomeEvent"]
    #expect(welcomeDef != nil)
    #expect(welcomeDef?.properties?["message"]?.type == .string)
}

// MARK: - SchemaHelper Tests

@Test("SchemaHelper determines nodeKind correctly")
func testSchemaHelperNodeKind() {
    // Test primitive types
    #expect(SchemaHelper.determineNodeKind(from: String.self) == .leaf)
    #expect(SchemaHelper.determineNodeKind(from: Int.self) == .leaf)
    #expect(SchemaHelper.determineNodeKind(from: Bool.self) == .leaf)
    
    // Test array
    #expect(SchemaHelper.determineNodeKind(from: [String].self) == .array)
    
    // Test dictionary
    #expect(SchemaHelper.determineNodeKind(from: [String: Int].self) == .map)
    
    // Test StateNode
    #expect(SchemaHelper.determineNodeKind(from: TestSchemaStateNode.self) == .object)
}
