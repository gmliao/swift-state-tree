import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
import SwiftStateTreeMacros

final class PayloadMacroSortingTests: XCTestCase {
    // Register the macro for testing
    let testMacros: [String: Macro.Type] = [
        "Payload": PayloadMacro.self
    ]
    
    func testPayloadSorting() {
        assertMacroExpansion(
            """
            @Payload
            struct TestPayload {
                let z: Int
                let a: String
                let m: Int
            }
            """,
            expandedSource: """
            struct TestPayload {
                let z: Int
                let a: String
                let m: Int
            
                public static func getFieldMetadata() -> [FieldMetadata] {
                    return [FieldMetadata(
                    name: "a",
                    type: String.self,
                    policy: nil,
                    nodeKind: SchemaHelper.determineNodeKind(from: String.self),
                    defaultValue: nil
                        ), FieldMetadata(
                    name: "m",
                    type: Int.self,
                    policy: nil,
                    nodeKind: SchemaHelper.determineNodeKind(from: Int.self),
                    defaultValue: nil
                        ), FieldMetadata(
                    name: "z",
                    type: Int.self,
                    policy: nil,
                    nodeKind: SchemaHelper.determineNodeKind(from: Int.self),
                    defaultValue: nil
                        )]
                }
            
                public func encodeAsArray() -> [AnyCodable] {
                    return [AnyCodable(self.a), AnyCodable(self.m), AnyCodable(self.z)]
                }
            }
            """,
            macros: testMacros
        )
    }
}
