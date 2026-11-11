// Tests/SwiftStateTreeMacrosTests/MacroExpansionExpectation.swift
//
// `assertMacroExpansion` from SwiftSyntaxMacrosTestSupport reports through XCTest, so under
// Swift Testing a mismatch doesn't fail the test (#187). This routes the generic assertion's
// failures into Swift Testing.

import SwiftDiagnostics
import SwiftParser
import SwiftParserDiagnostics
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
/// (`expectMacroExpansion` skips the per-diagnostic checks when the count differs). Like the
/// generic assertion, it records an issue if the expanded source doesn't parse.
func expandCollectingDiagnostics(
    _ originalSource: String,
    macros: [String: Macro.Type],
    indentationWidth: Trivia = .spaces(4),
    sourceLocation: Testing.SourceLocation = #_sourceLocation
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
    let parseErrors = ParseDiagnosticsGenerator.diagnostics(for: expanded)
    #expect(parseErrors.isEmpty, "expanded source has syntax errors: \(parseErrors.map(\.message))", sourceLocation: sourceLocation)
    return (expanded.description.trimmingCharacters(in: .newlines), context)
}

/// Expects `diagnostic` to read `message` exactly, with `severity`, at `line` and `column` of the
/// original source, and with the given notes and fix-its (none by default), as the generic
/// assertion's `DiagnosticSpec` does.
func expectDiagnostic(
    _ diagnostic: Diagnostic,
    in context: BasicMacroExpansionContext,
    message: String,
    line: Int,
    column: Int,
    severity: DiagnosticSeverity = .error,
    notes: [String] = [],
    fixIts: [String] = [],
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    #expect(diagnostic.message == message, sourceLocation: sourceLocation)
    expectDiagnosticShape(diagnostic, in: context, line: line, column: column, severity: severity, notes: notes, fixIts: fixIts, sourceLocation: sourceLocation)
}

/// Like `expectDiagnostic`, for a diagnostic whose full text isn't stable (a thrown error's
/// description, #404): its message must start with `prefix` and contain each of `fragments`.
func expectDiagnostic(
    _ diagnostic: Diagnostic,
    in context: BasicMacroExpansionContext,
    messageStartingWith prefix: String,
    containing fragments: [String],
    line: Int,
    column: Int,
    severity: DiagnosticSeverity = .error,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    #expect(diagnostic.message.hasPrefix(prefix), sourceLocation: sourceLocation)
    for fragment in fragments {
        #expect(diagnostic.message.contains(fragment), "message contains \(fragment)", sourceLocation: sourceLocation)
    }
    expectDiagnosticShape(diagnostic, in: context, line: line, column: column, severity: severity, notes: [], fixIts: [], sourceLocation: sourceLocation)
}

private func expectDiagnosticShape(
    _ diagnostic: Diagnostic,
    in context: BasicMacroExpansionContext,
    line: Int,
    column: Int,
    severity: DiagnosticSeverity,
    notes: [String],
    fixIts: [String],
    sourceLocation: Testing.SourceLocation
) {
    let location = context.location(for: diagnostic.position, anchoredAt: diagnostic.node, fileName: "test.swift")
    #expect(location.line == line, "line", sourceLocation: sourceLocation)
    #expect(location.column == column, "column", sourceLocation: sourceLocation)
    #expect(diagnostic.diagMessage.severity == severity, sourceLocation: sourceLocation)
    #expect(diagnostic.notes.map(\.message) == notes, sourceLocation: sourceLocation)
    #expect(diagnostic.fixIts.map(\.message.message) == fixIts, sourceLocation: sourceLocation)
}
