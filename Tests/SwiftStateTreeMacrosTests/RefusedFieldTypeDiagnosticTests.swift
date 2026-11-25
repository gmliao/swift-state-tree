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
        macros: [
            "StateNodeBuilder": StateNodeBuilderMacro.self, "SnapshotConvertible": SnapshotConvertibleMacro.self,
            "Payload": PayloadMacro.self,
        ],
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

    @Test("Concrete types, a bare protocol name and a typealias pass the macro: the type checker refuses the last two (Sync requires PlainData)", arguments: [
        "Int", "[String: Int]", "Box<Item>?", "Shape", "ShapeAlias", "[PlayerID: Hand]", "AnyThing",
    ])
    func allowed(field: String) {
        #expect(diagnostics(stateNode(field)).isEmpty)
    }

    @Test("A tuple field is refused by the PlainData walk: a tuple can't conform")
    func tupleField() {
        let messages = diagnostics(stateNode("(Int, String)"))
        #expect(messages.first?.hasPrefix("a tuple can't conform to PlainData") == true, "\(messages)")
    }

    @Test("The macro doesn't refuse an @Internal field: Internal requires PlainData, which the type checker refuses (scripts/must-not-compile/internal-not-plain.swift)")
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

    // MARK: Decimal (#597)

    static let decimalSpellings: [(String, String)] = [
        ("Decimal", "Decimal"),
        ("Decimal?", "Decimal"),
        ("[Decimal]", "Decimal"),
        ("[String: Decimal]", "Decimal"),
        ("Foundation.Decimal", "Foundation.Decimal"),
        ("Swift.Optional<Decimal>", "Decimal"),
        ("[Decimal]?", "Decimal"),
        ("(Int, Decimal)", "Decimal"),
    ]

    @Test("A synced Decimal is refused at compile time, at any depth, by the PlainData walk", arguments: decimalSpellings)
    func syncedDecimal(field: String, spelling: String) {
        let messages = diagnostics(stateNode(field))
        // A tuple is refused as a tuple before its elements are read.
        let refusal = field.hasPrefix("(") ? "a tuple can't conform to PlainData" : "Decimal isn't plain data; store an integer in the smallest unit"
        #expect(messages.contains { $0.hasPrefix(refusal) }, "\(messages)")
    }

    @Test("A @Payload Decimal field is refused at compile time, at any depth", arguments: decimalSpellings)
    func payloadDecimal(field: String, spelling: String) {
        let messages = diagnostics("""
            @Payload
            struct PriceEvent: ServerEventPayload {
                let value: \(field)
            }
            """)
        // @Payload checks its fields with @PlainData's walk: the Foundation type is named with its
        // replacement; a tuple is refused as a tuple before its elements are read.
        let refusal = field.hasPrefix("(") ? "a tuple can't conform to PlainData" : "Decimal isn't plain data; store an integer in the smallest unit"
        #expect(messages.contains { $0.hasPrefix(refusal) }, "\(messages)")
        // `Decimal?` also gets @Payload's Optional diagnostic: both are reported.
        if field.hasSuffix("?") {
            #expect(messages.contains { $0.hasPrefix("Payload field 'value' cannot be Optional") }, "\(messages)")
        }
    }

    @Test("@SnapshotConvertible refuses a Decimal property")
    func snapshotConvertibleDecimal() {
        let messages = diagnostics("""
            @SnapshotConvertible
            struct Line {
                var amount: Decimal = 0
            }
            """)
        #expect(messages.first?.hasPrefix("property 'amount' can't have 'Decimal' in its type") == true, "\(messages)")
    }

    @Test("One Decimal message for every state field: server-only and @Internal too; a Decimal of another module passes")
    func decimalEveryField() {
        let messages = diagnostics("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.serverOnly) var hidden: Decimal = 0
                @Internal var scratch: Decimal = 0
            }
            """)
        #expect(messages.filter { $0.hasPrefix("Decimal isn't plain data") }.count == 2, "\(messages)")
        #expect(!messages.contains { $0.contains("can't have 'Decimal'") }, "the classifier's message is @Payload's and @SnapshotConvertible's only: \(messages)")
        #expect(diagnostics(stateNode("Money.Decimal")).isEmpty)
    }

    @Test("A @Payload AnyCodable field passes the macro: the type checker refuses it, since AnyCodable isn't PlainData (must-not-compile server-input-anycodable)")
    func payloadAnyCodableLeftToTheCompiler() {
        #expect(diagnostics("""
            @Payload
            struct ReportEvent: ServerEventPayload {
                let state: AnyCodable
                let byName: [String: AnyCodable]
            }
            """).isEmpty)
    }
}
