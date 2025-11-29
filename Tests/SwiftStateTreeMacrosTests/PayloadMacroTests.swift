import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class PayloadMacroTests {
    let testMacros: [String: Macro.Type] = [
        "Payload": PayloadMacro.self
    ]
    
    @Test("Payload macro rejects optional fields")
    func testPayloadRejectsOptionalFields() {
        assertMacroExpansion(
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
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Payload field 'name' cannot be Optional; use a concrete value with a default instead",
                    line: 4,
                    column: 5
                )
            ],
            macros: testMacros
        )
    }
}
