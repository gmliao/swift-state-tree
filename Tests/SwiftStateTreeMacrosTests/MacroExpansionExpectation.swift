// Tests/SwiftStateTreeMacrosTests/MacroExpansionExpectation.swift
//
// `assertMacroExpansion` from SwiftSyntaxMacrosTestSupport reports through XCTest, so under
// Swift Testing a mismatch doesn't fail the test (#187). This routes the generic assertion's
// failures into Swift Testing.

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
