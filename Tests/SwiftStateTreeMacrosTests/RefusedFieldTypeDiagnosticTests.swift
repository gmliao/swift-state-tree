// Tests/SwiftStateTreeMacrosTests/RefusedFieldTypeDiagnosticTests.swift
//
// #535 D8 (b): a synced field whose declared type can hold a value of any type is refused at
// macro expansion, wherever the syntax shows it.

import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

private func diagnostics(_ source: String) -> [String] {
    let context = BasicMacroExpansionContext()
    _ = Parser.parse(source: source).expand(
        macros: ["StateNodeBuilder": StateNodeBuilderMacro.self, "SnapshotConvertible": SnapshotConvertibleMacro.self],
        contextGenerator: { _ in context }
    )
    return context.diagnostics.map(\.message)
}

private func stateNode(_ field: String) -> String {
    """
    @StateNodeBuilder
    struct Node: StateNodeProtocol {
        @Sync(.broadcast) var value: \(field) = .init()
    }
    """
}

@Suite("Refused synced field types (#535 D8 (b))")
struct RefusedFieldTypeDiagnosticTests {
    @Test("A @Sync field is refused for any, Any, AnyObject, a composition, AnyHashable or AnyCodable, at any depth", arguments: [
        ("Any", "Any"),
        ("AnyObject", "AnyObject"),
        ("any Shape", "any Shape"),
        ("(any Shape)?", "any Shape"),
        ("[any Shape]", "any Shape"),
        ("[String: Any]", "Any"),
        ("[AnyHashable: Int]", "AnyHashable"),
        ("Set<AnyHashable>", "AnyHashable"),
        ("Box<AnyCodable>", "AnyCodable"),
        ("[SwiftStateTree.AnyCodable]", "SwiftStateTree.AnyCodable"),
        ("(Int, any Shape)", "any Shape"),
        ("Shape & Named", "Shape & Named"),
        ("Dictionary<String, any Shape>", "any Shape"),
    ])
    func refused(field: String, spelling: String) {
        let messages = diagnostics(stateNode(field))
        #expect(messages.first?.hasPrefix("synced property 'value' can't have '\(spelling)' in its type") == true, "\(messages)")
    }

    @Test("Concrete types, a bare protocol name and a typealias pass: the gap is documented, the backstop covers it", arguments: [
        "Int", "[String: Int]", "Box<Item>?", "Shape", "ShapeAlias", "[PlayerID: Hand]", "AnyThing", "(Int, String)",
    ])
    func allowed(field: String) {
        #expect(diagnostics(stateNode(field)).isEmpty)
    }

    @Test("An @Internal field may hold anything")
    func internalField() {
        let messages = diagnostics("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                @Internal var cache: [String: Any] = [:]
            }
            """)
        #expect(messages.isEmpty)
    }

    @Test("Every refused field is reported, not only the first")
    func everyField() {
        let messages = diagnostics("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var a: Any = 0
                @Sync(.broadcast) var b: [AnyHashable] = []
            }
            """)
        #expect(messages.filter { $0.hasPrefix("synced property") }.count == 2, "\(messages)")
    }

    @Test("@SnapshotConvertible refuses every stored property with such a type; static and computed ones aren't stored")
    func snapshotConvertible() {
        let refused = diagnostics("""
            @SnapshotConvertible
            struct Value {
                var count: Int = 0
                let payload: any Shape
                static var shared: Any = 0
                var computed: Any { 0 }
            }
            """)
        #expect(refused.count >= 1 && refused.first?.hasPrefix("synced property 'payload' can't have 'any Shape'") == true, "\(refused)")
        #expect(refused.filter { $0.hasPrefix("synced property") }.count == 1, "\(refused)")
        #expect(diagnostics("""
            @SnapshotConvertible
            struct Value {
                var count: Int = 0
                var tags: [String] = []
            }
            """).isEmpty)
    }
}
