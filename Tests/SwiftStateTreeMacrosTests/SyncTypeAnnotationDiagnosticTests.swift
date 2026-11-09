// Tests/SwiftStateTreeMacrosTests/SyncTypeAnnotationDiagnosticTests.swift
//
// An @Sync property needs an explicit type (#179): without one its field metadata type is `Any`,
// which schema generation and the nesting check can't look into.

import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

private func diagnostics(_ source: String) -> [String] {
    let context = BasicMacroExpansionContext()
    _ = Parser.parse(source: source).expand(macros: ["StateNodeBuilder": StateNodeBuilderMacro.self], contextGenerator: { _ in context })
    return context.diagnostics.map(\.message)
}

@Suite("@Sync type annotation diagnostic")
struct SyncTypeAnnotationDiagnosticTests {
    @Test("An @Sync property without a type annotation is an error")
    func missingType() {
        let messages = diagnostics("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var box = Box()
            }
            """)
        // The expansion also reports the thrown error itself, as for a missing marker.
        #expect(messages.first == "@Sync property 'box' needs an explicit type annotation, for example 'var box: Int = 0'")
    }

    @Test("Annotated @Sync properties and untyped @Internal ones are fine")
    func annotated() {
        let messages = diagnostics("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var box: Box = Box()
                @Internal var cache = 0
            }
            """)
        #expect(messages.isEmpty)
    }
}
