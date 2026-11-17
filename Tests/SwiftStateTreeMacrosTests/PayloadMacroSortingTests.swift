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
            
                public func _writePayloadFields<__PayloadWriter: _PayloadFieldWriter>(into writer: inout __PayloadWriter) throws {
                    try writer.field(self.a)
                    try writer.field(self.m)
                    try writer.field(self.z)
                }
            
                public static var _payloadHasTypedWriter: Bool {
                    true
                }
            
                public static var _payloadFieldForms: [_PayloadFieldFormEntry] {
                    [_PayloadFieldFormEntry("a", _payloadFieldForm(of: \\Self.a)), _PayloadFieldFormEntry("m", _payloadFieldForm(of: \\Self.m)), _PayloadFieldFormEntry("z", _payloadFieldForm(of: \\Self.z))]
                }
            }
            """,
            macros: testMacros
        )
    }
}
