import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing
import SwiftStateTreeMacros

final class PayloadMacroTests {
    let testMacros: [String: Macro.Type] = [
        "Payload": PayloadMacro.self
    ]
    
    @Test("Payload macro rejects optional fields")
    func testPayloadRejectsOptionalFields() {
        expectMacroExpansion(
            """
            @Payload
            struct InvalidPayload: ActionPayload {
                typealias Response = EmptyResponse
                var name: String?
            }
            
            struct EmptyResponse: Codable, Sendable {}
            """,
            expandedSource: """
            struct InvalidPayload: ActionPayload {
                typealias Response = EmptyResponse
                var name: String?
            }
            
            struct EmptyResponse: Codable, Sendable {}

            extension InvalidPayload {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {
                    @available(*, deprecated, message: "the @PlainData checks; never called")
                    func check(_ value: inout Self) {
                        SwiftStateTurns.PlainDataCheck.field(value.name)
                    }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Payload field 'name' cannot be Optional; use a concrete value with a default instead",
                    line: 4,
                    column: 9
                )
            ],
            macros: testMacros
        )
    }
}
