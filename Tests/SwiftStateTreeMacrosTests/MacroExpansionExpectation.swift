// Tests/SwiftStateTreeMacrosTests/MacroExpansionExpectation.swift
//
// `assertMacroExpansion` from SwiftSyntaxMacrosTestSupport reports through XCTest, so under
// Swift Testing a mismatch doesn't fail the test (#187). This routes the generic assertion's
// failures into Swift Testing.

import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosGenericTestSupport
import Testing

/// Expands `originalSource` with `macros` and records an issue for each difference from
/// `expandedSource` and `diagnostics`.
func expectMacroExpansion(
    _ originalSource: String,
    expandedSource: String,
    diagnostics: [DiagnosticSpec] = [],
    macros: [String: Macro.Type],
    indentationWidth: Trivia = .spaces(4),
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    assertMacroExpansion(
        originalSource,
        expandedSource: expandedSource,
        diagnostics: diagnostics,
        macroSpecs: macros.mapValues { MacroSpec(type: $0) },
        indentationWidth: indentationWidth,
        failureHandler: { failure in
            Issue.record(Comment(rawValue: failure.message), sourceLocation: sourceLocation)
        }
    )
}

/// Expands `originalSource` the way `expectMacroExpansion` does and returns the expanded text
/// with the context that holds every diagnostic, for tests that assert the diagnostics one by one
/// (`expectMacroExpansion` skips the per-diagnostic checks when the count differs).
func expandCollectingDiagnostics(
    _ originalSource: String,
    macros: [String: Macro.Type],
    indentationWidth: Trivia = .spaces(4)
) -> (expanded: String, context: BasicMacroExpansionContext) {
    let sourceFile = Parser.parse(source: originalSource)
    let context = BasicMacroExpansionContext(
        sourceFiles: [sourceFile: .init(moduleName: "TestModule", fullFilePath: "test.swift")]
    )
    let expanded = sourceFile.expand(
        macroSpecs: macros.mapValues { MacroSpec(type: $0) },
        contextGenerator: { BasicMacroExpansionContext(sharingWith: context, lexicalContext: $0.allMacroLexicalContexts()) },
        indentationWidth: indentationWidth
    )
    return (expanded.description.trimmingCharacters(in: .newlines), context)
}

/// Expects `diagnostic` to have `message`, at `line` and `column` of the original source.
func expectDiagnostic(
    _ diagnostic: Diagnostic,
    in context: BasicMacroExpansionContext,
    message: String,
    line: Int,
    column: Int,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    #expect(diagnostic.message == message, sourceLocation: sourceLocation)
    let location = context.location(for: diagnostic.position, anchoredAt: diagnostic.node, fileName: "test.swift")
    #expect(location.line == line, "line", sourceLocation: sourceLocation)
    #expect(location.column == column, "column", sourceLocation: sourceLocation)
}
