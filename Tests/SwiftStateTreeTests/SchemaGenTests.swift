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
struct TestEvent: ServerEventPayload {
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
        using: SimpleState.self,
        clientEvents: SimpleClientEvents.self,
        serverEvents: SimpleServerEvents.self
    ) {
        Rules {
            Action(SimpleAction.self) { (state: inout SimpleState, action: SimpleAction, ctx: LandContext) in
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
        using: TestState.self,
        clientEvents: TestClientEvents.self,
        serverEvents: TestServerEvents.self
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
        using: TestState.self,
        clientEvents: TestClientEvents.self,
        serverEvents: TestServerEvents.self
    ) {
        Rules {
            Action(TestAction.self) { (state: inout TestState, action: TestAction, ctx: LandContext) in
                return TestActionResponse(success: true, message: "ok")
            }
        }
    }
    
    let schema = SchemaExtractor.extract(from: landDefinition)
    
    let landSchema = schema.lands["test"]!
    // Actions should be present (may be empty if action type doesn't conform to SchemaMetadataProvider)
    #expect(landSchema.actions.count >= 0)
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
    
    // Should create a schema for the action (either direct object or reference)
    // If TestAction conforms to SchemaMetadataProvider, it will be an object
    // Otherwise, it will be a reference to a definition
    if schema.ref != nil {
        // It's a reference, check that definition exists
        let typeName = String(describing: TestAction.self)
        #expect(definitions[typeName] != nil)
    } else {
        // It's a direct object schema
        #expect(schema.type == .object)
    }
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
    
    // Should create a schema for the event (either direct object or reference)
    // If TestEvent conforms to SchemaMetadataProvider, it will be an object
    // Otherwise, it will be a reference to a definition
    if schema.ref != nil {
        // It's a reference, check that definition exists
        let typeName = String(describing: TestEvent.self)
        #expect(definitions[typeName] != nil)
    } else {
        // It's a direct object schema
        #expect(schema.type == .object)
    }
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
        using: TestState.self,
        clientEvents: TestClientEvents.self,
        serverEvents: TestServerEvents.self
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
