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

    @Test("Concrete types, a bare protocol name and a typealias pass: the gap is documented, the backstop covers it", arguments: [
        "Int", "[String: Int]", "Box<Item>?", "Shape", "ShapeAlias", "[PlayerID: Hand]", "AnyThing", "(Int, String)",
    ])
    func allowed(field: String) {
        #expect(diagnostics(stateNode(field)).isEmpty)
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

    @Test("A synced Decimal is refused at compile time, at any depth", arguments: decimalSpellings)
    func syncedDecimal(field: String, spelling: String) {
        let messages = diagnostics(stateNode(field))
        #expect(messages.first?.hasPrefix("property 'value' can't have '\(spelling)' in its type: Decimal isn't plain data") == true, "\(messages)")
    }

    @Test("A @Payload Decimal field is refused at compile time, at any depth", arguments: decimalSpellings)
    func payloadDecimal(field: String, spelling: String) {
        let messages = diagnostics("""
            @Payload
            struct PriceEvent: ServerEventPayload {
                let value: \(field)
            }
            """)
        #expect(messages.contains { $0.hasPrefix("property 'value' can't have '\(spelling)' in its type: Decimal isn't plain data") }, "\(messages)")
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

    @Test("Not refused by the macro: a server-only or @Internal Decimal (the type checker refuses the @Internal one: Decimal isn't PlainData), a @Payload AnyCodable, and a Decimal of another module")
    func decimalAllowed() {
        #expect(diagnostics("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.serverOnly) var hidden: Decimal = 0
                @Internal var scratch: Decimal = 0
            }
            """).isEmpty)
        #expect(diagnostics("""
            @Payload
            struct ReportEvent: ServerEventPayload {
                let state: AnyCodable
                let byName: [String: AnyCodable]
            }
            """).isEmpty)
        #expect(diagnostics(stateNode("Money.Decimal")).isEmpty)
    }

    @Test("The serverOnly skip reads the policy, not the text: a policy closure that names serverOnly is still checked")
    func serverOnlyFromThePolicy() {
        let messages = diagnostics("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.perPlayer({ value, serverOnly in value })) var value: Decimal = 0
            }
            """)
        #expect(messages.contains { $0.hasPrefix("property 'value' can't have 'Decimal' in its type") }, "\(messages)")
    }
}
