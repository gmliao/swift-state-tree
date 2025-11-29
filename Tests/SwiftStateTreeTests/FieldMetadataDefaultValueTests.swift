import Testing
@testable import SwiftStateTree

@Test("StateNodeBuilder captures default values in FieldMetadata")
func stateNodeMetadataIncludesDefaultValues() {
    @StateNodeBuilder
    struct ExampleState: StateNodeProtocol {
        @Sync(.broadcast)
        var score: Int = 7

        @Sync(.serverOnly)
        var tags: [String] = ["alpha", "beta"]
    }

    let metadata = ExampleState.getFieldMetadata()

    let scoreField = metadata.first(where: { $0.name == "score" })
    #expect(scoreField?.defaultValue == .int(7))

    let tagsField = metadata.first(where: { $0.name == "tags" })
    #expect(tagsField?.defaultValue == .array([.string("alpha"), .string("beta")]))
}

@Test("Payload captures default values in FieldMetadata")
func payloadMetadataIncludesDefaultValues() {
    struct EmptyResponse: Codable, Sendable {}
    
    @Payload
    struct ExampleAction: ActionPayload {
        typealias Response = EmptyResponse
        
        var id: String = "default-id"
        var count: Int = 2
    }

    let metadata = ExampleAction.getFieldMetadata()

    let idField = metadata.first(where: { $0.name == "id" })
    #expect(idField?.defaultValue == .string("default-id"))

    let countField = metadata.first(where: { $0.name == "count" })
    #expect(countField?.defaultValue == .int(2))
}
