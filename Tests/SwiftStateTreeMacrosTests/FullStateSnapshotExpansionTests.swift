// Tests/SwiftStateTreeMacrosTests/FullStateSnapshotExpansionTests.swift
//
// The macros generate the full-state conversions for the replay hash (#180). These tests read the
// expanded source directly: `assertMacroExpansion` reports through XCTest, which does not fail a
// Swift Testing test.

import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

private func expand(_ source: String, _ macros: [String: Macro.Type]) -> (text: String, diagnostics: Int) {
    let context = BasicMacroExpansionContext()
    let expanded = Parser.parse(source: source).expand(macros: macros, contextGenerator: { _ in context })
    return (expanded.description, context.diagnostics.count)
}

private func squashed(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Suite("Full-state conversion expansion")
struct FullStateSnapshotExpansionTests {
    @Test("@StateNodeBuilder generates fullStateSnapshot() with every @Sync field and no @Internal")
    func stateNodeBuilder() {
        let (text, diagnostics) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var shown: Int = 0
                @Sync(.serverOnly) var hidden: [String: Int] = [:]
                @Sync(.masked({ _ in 0 })) var masked: Int = 0
                @Internal var cache: Int = 0
            }
            """, ["StateNodeBuilder": StateNodeBuilderMacro.self])
        #expect(diagnostics == 0)
        let body = squashed(text)
        #expect(body.contains("public func fullStateSnapshot() throws -> StateSnapshot {"))
        for field in ["shown", "hidden", "masked"] {
            #expect(body.contains("result[\"\(field)\"] = try SnapshotValue.makeFull(from: self._\(field).wrappedValue as Any)"), "\(field)")
        }
        #expect(!body.contains("result[\"cache\"] = try SnapshotValue.makeFull"))
        // The full conversion never reads a policy.
        let full = body.components(separatedBy: "public func fullStateSnapshot()")[1].components(separatedBy: "return StateSnapshot(values: result)")[0]
        #expect(!full.contains("policy"))
    }

    @Test("The non-Equatable check is left out for server-only fields and for fields of a generic parameter's type")
    func syncCheckFields() {
        let (text, diagnostics) = expand("""
            @StateNodeBuilder
            struct Box<T: Sendable, Other>: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                @Sync(.broadcast) var items: [String: T] = [:]
                @Sync(.broadcast) var others: [Other]? = nil
                @Sync(.broadcast) var total: Total = Total()
                @Sync(.perPlayerSlice()) var own: [PlayerID: Int] = [:]
                @Sync(.serverOnly) var hidden: Int = 0
            }
            """, ["StateNodeBuilder": StateNodeBuilderMacro.self])
        #expect(diagnostics == 0)
        let body = squashed(text)
        // `Total` contains the letter T but doesn't name the parameter.
        for field in ["count", "total", "own"] {
            #expect(body.contains("_syncCheck_\(field)(_syncFieldKind {"), "\(field)")
            #expect(body.contains("private static func _syncCheck_\(field)(_: _SyncFallbackField)"), "\(field)")
        }
        for field in ["items", "others", "hidden"] {
            #expect(!body.contains("_syncCheck_\(field)"), "\(field)")
        }
    }

    @Test("@SnapshotConvertible generates toFullSnapshotValue() over every stored property")
    func snapshotConvertible() {
        let (text, diagnostics) = expand("""
            @SnapshotConvertible
            struct Holder {
                var count: UInt64 = 0
                var node: Inner = Inner()
            }
            """, ["SnapshotConvertible": SnapshotConvertibleMacro.self])
        #expect(diagnostics == 0)
        let body = squashed(text)
        #expect(body.contains("extension Holder: SnapshotValueConvertible, FullSnapshotValueConvertible {"))
        #expect(body.contains("public func toFullSnapshotValue() throws -> SnapshotValue {"))
        #expect(body.contains("\"count\": try SnapshotValue.makeFull(from: self.count as Any)"))
        #expect(body.contains("\"node\": try SnapshotValue.makeFull(from: self.node as Any)"))
        #expect(body.contains("\"count\": SnapshotValue.unsigned(count)"), "UInt64 converts losslessly")
    }
}
