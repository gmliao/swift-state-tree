// Tests/SwiftStateTreeMacrosTests/StatePlainDataMacroTests.swift
//
// A land's State is PlainData. `@StateNodeBuilder` writes the `_plainDataCheck` member with
// checks per `@Sync` and `@Internal` field (the wrapper's storage, and the wrapped value), and
// `@SnapshotConvertible` writes the PlainData extension unless a sibling macro writes the witness.

import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

private let macros: [String: Macro.Type] = [
    "StateNodeBuilder": StateNodeBuilderMacro.self,
    "SnapshotConvertible": SnapshotConvertibleMacro.self,
]

private func expand(_ source: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) -> (expanded: String, messages: [String]) {
    let (expanded, context) = expandCollectingDiagnostics(source, macros: macros, sourceLocation: sourceLocation)
    return (expanded, context.diagnostics.map(\.message))
}

/// The lines of the expanded `_plainDataCheck` member's `check` function, trimmed: up to the
/// function's closing brace.
private func checkLines(_ expanded: String) -> [String] {
    guard let start = expanded.range(of: "func check(_ value: inout Self) {") else { return [] }
    var lines: [String] = []
    for line in expanded[start.upperBound...].split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "}" { break }
        if !trimmed.isEmpty { lines.append(trimmed) }
    }
    return lines
}

@Suite("State is PlainData: the macros' witness")
struct StatePlainDataMacroTests {
    @Test("@StateNodeBuilder checks each @Sync and @Internal field's storage and wrapped value, annotated or not")
    func memberChecksEachField() {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            struct GameState: StateNodeProtocol {
                @Sync(.broadcast) var players: [PlayerID: PlayerState] = [:]
                @Sync(.serverOnly) var deck: [Card] = []
                @Internal var lastTick: Int64 = 0
                @Internal var cache = [String: Int]()
                var total: Int { players.count }
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(expanded.contains("static func _plainDataCheck()"))
        #expect(checkLines(expanded) == [
            "SwiftStateTurns.PlainDataCheck.field(value._players)",
            "SwiftStateTurns.PlainDataCheck.field(value.players)",
            "SwiftStateTurns.PlainDataCheck.field(value._deck)",
            "SwiftStateTurns.PlainDataCheck.field(value.deck)",
            "SwiftStateTurns.PlainDataCheck.field(value._lastTick)",
            "SwiftStateTurns.PlainDataCheck.field(value.lastTick)",
            "SwiftStateTurns.PlainDataCheck.field(value._cache)",
            "SwiftStateTurns.PlainDataCheck.field(value.cache)",
        ], "\(expanded)")
    }

    @Test("The witness takes the type's access level", arguments: [
        ("public struct", "public static func _plainDataCheck()"),
        ("package struct", "package static func _plainDataCheck()"),
        ("struct", "static func _plainDataCheck()"),
    ])
    func access(declaration: String, witness: String) {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            \(declaration) Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        let line = expanded.split(separator: "\n").first { $0.contains("func _plainDataCheck()") }.map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(line == witness + " {", "\(expanded)")
    }

    @Test("A generic node's member has no where clause: the parameter carries the constraint")
    func genericNode() {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            struct Box<T: PlainData & Sendable>: StateNodeProtocol {
                @Sync(.broadcast) var value: T? = nil
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(checkLines(expanded) == ["SwiftStateTurns.PlainDataCheck.field(value._value)", "SwiftStateTurns.PlainDataCheck.field(value.value)"], "\(expanded)")
        #expect(!expanded.contains("where T: SwiftStateTurns.PlainData"))
    }

    @Test("A field inside #if is checked under its condition")
    func ifConfigMember() {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                #if DEBUG
                @Internal var trace: [String] = []
                #endif
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(checkLines(expanded) == [
            "SwiftStateTurns.PlainDataCheck.field(value._count)",
            "SwiftStateTurns.PlainDataCheck.field(value.count)",
            "#if DEBUG",
            "SwiftStateTurns.PlainDataCheck.field(value._trace)",
            "SwiftStateTurns.PlainDataCheck.field(value.trace)",
            "#endif",
        ], "\(expanded)")
    }

    @Test("An unmarked stored property inside #if is refused, as one outside #if is")
    func ifConfigUnmarked() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                #if DEBUG
                var trace: [String] = []
                #endif
            }
            """)
        // The macro's thrown error is recorded after the diagnostic.
        #expect(messages.first == "Stored property 'trace' in StateNode must be marked with @Sync or @Internal", "\(messages)")
    }

    @Test("@PlainData beside @StateNodeBuilder is refused, bare or qualified", arguments: ["@PlainData", "@SwiftStateTurns.PlainData"])
    func plainDataSibling(attribute: String) {
        let (_, messages) = expand("""
            \(attribute)
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
            }
            """)
        #expect(messages.first == "@StateNodeBuilder writes the PlainData check; remove @PlainData", "\(messages)")
    }

    @Test("A wrapper named Sync or Internal is read through, bare or qualified by an exporting module, and its storage is checked: the name alone doesn't make it the library's")
    func readThroughChecksStorage() {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @SwiftStateTree.Sync(.broadcast) var count: Int = 0
                @SwiftStateTree.Internal var `default`: Int = 0
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(checkLines(expanded) == [
            "SwiftStateTurns.PlainDataCheck.field(value._count)",
            "SwiftStateTurns.PlainDataCheck.field(value.count)",
            "SwiftStateTurns.PlainDataCheck.field(value._default)",
            "SwiftStateTurns.PlainDataCheck.field(value.`default`)",
        ], "\(expanded)")
    }

    @Test("An unannotated read-through field reads its storage and its value")
    func readThroughUnannotated() {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                @Internal var hits = 0
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(checkLines(expanded).suffix(2) == [
            "SwiftStateTurns.PlainDataCheck.field(value._hits)",
            "SwiftStateTurns.PlainDataCheck.field(value.hits)",
        ], "\(expanded)")
    }

    @Test("A wrapper qualified by another module isn't read through as the library's")
    func readThroughOtherModule() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) @MyModule.Internal var hits: Int = 0
                @Sync(.broadcast) @SwiftStateTurns.Internal var misses: Int = 0
            }
            """)
        // Each field passes the marker check through its bare `@Sync`; the qualified wrapper is
        // not read through, so the walk refuses it as a wrapper it can't read.
        let refusals = messages.filter { $0.hasPrefix("the PlainData check reads only @Internal and @Sync fields") }
        #expect(refusals.count == 2, "\(messages)")
    }

    @Test("A wrapper or macro qualified by SwiftStateTreeNIO, which re-exports SwiftStateTree, is the library's")
    func reexportingModule() {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            @SwiftStateTreeNIO.SnapshotConvertible
            struct Node: StateNodeProtocol {
                @SwiftStateTreeNIO.Sync(.broadcast) var count: Int = 0
                @SwiftStateTreeNIO.Internal var hits: Int = 0
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(checkLines(expanded).contains("SwiftStateTurns.PlainDataCheck.field(value._hits)"), "\(expanded)")
    }

    @Test("A @Sync field inside #if is refused: the sync tables read only top-level members")
    func syncInsideIfConfig() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                #if DEBUG
                @Sync(.broadcast) var trace: [String] = []
                #endif
            }
            """)
        #expect(messages.first == "@Sync property 'trace' inside #if isn't synced; declare it outside #if, or mark it @Internal", "\(messages)")
    }

    @Test("An observed property is stored: unmarked, it is refused")
    func observedUnmarked() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                var secret: Int = 0 {
                    didSet {}
                }
            }
            """)
        #expect(messages.contains { $0.contains("Stored property 'secret'") && $0.contains("must be marked with @Sync or @Internal") }, "\(messages)")
    }

    @Test("An observed @Sync field is refused: generated writes skip its observers; an observed @Internal is fine")
    func observedSync() {
        let (_, refused) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0 {
                    didSet {}
                }
            }
            """)
        #expect(refused.first == "@Sync property 'count' can't have willSet or didSet: the generated mutators and the snapshot decode write its storage and skip them; move the work into the code that writes the field, or mark it @Internal", "\(refused)")
        let (_, accepted) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                @Internal var hits: Int = 0 {
                    willSet {}
                }
            }
            """)
        #expect(accepted.isEmpty, "\(accepted)")
    }

    @Test("#warning and #error among the members are compiler directives, not refused expansions")
    func compilerDirectives() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                #warning("check this")
                #if false
                #error("unsupported platform")
                #endif
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
    }

    @Test("A freestanding macro expansion among a state's members is refused: its storage can't be checked")
    func macroExpansionMember() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                #addsStorage()
            }
            """)
        #expect(messages.contains("the PlainData check can't see the storage a macro expansion adds; declare the stored properties in the type"), "\(messages)")
    }

    @Test("A state type takes only this project's macros and built-in attributes", arguments: [
        "@StateNodeBuilder", "@SnapshotConvertible",
    ])
    func stateTypeAttributeRefusals(site: String) {
        let takes = site == "@StateNodeBuilder"
            ? "@SnapshotConvertible, @StateNodeBuilder"
            : "@PlainData, @SnapshotConvertible, @StateNodeBuilder"
        let unknown = "can't be on a state type: a macro there can add members the PlainData check doesn't see; this type takes only \(takes) and attributes that add no members"
        let conformance = site == "@StateNodeBuilder" ? "StateNodeProtocol" : "Codable"
        // A macro this project doesn't list, a namesake qualified by another module, and an
        // attribute inside #if.
        let (_, messages) = expand("""
            \(site)
            @Observable
            @Other.SnapshotConvertible
            #if DEBUG
            @available(*, deprecated)
            #endif
            struct Node: \(conformance) {
                @Sync(.broadcast) var count: Int = 0
            }
            """)
        #expect(messages.filter { $0.hasSuffix(unknown) } == [
            "@Observable " + unknown,
            "@Other.SnapshotConvertible " + unknown,
            "an attribute inside #if " + unknown,
        ], "\(messages)")
    }

    @Test("@Other.StateNodeBuilder doesn't turn @SnapshotConvertible's attribute check off")
    func otherStateNodeBuilder() {
        let (_, messages) = expand("""
            @SnapshotConvertible
            @Other.StateNodeBuilder
            struct Value: Codable {
                var count: Int = 0
            }
            """)
        #expect(messages.contains { $0.hasPrefix("@Other.StateNodeBuilder can't be on a state type") }, "\(messages)")
    }

    @Test("A stored property inside #if is refused by @SnapshotConvertible: the conversion reads top-level members")
    func snapshotStoredInIfConfig() {
        let (_, messages) = expand("""
            @SnapshotConvertible
            struct Value: Codable {
                var count: Int = 0
                #if DEBUG
                var trace: Int = 0
                #endif
            }
            """)
        #expect(messages.first == "@SnapshotConvertible: stored property 'trace' inside #if isn't converted; declare it outside #if", "\(messages)")
    }

    @Test("A state type's allowed attributes, qualified or not, add no diagnostic")
    func stateTypeAttributesAllowed() {
        let (_, messages) = expand("""
            @available(macOS 10.15, *)
            @usableFromInline
            @dynamicMemberLookup
            @dynamicCallable
            @StateNodeBuilder
            @SwiftStateTree.SnapshotConvertible
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
            }

            @SnapshotConvertible
            @SwiftStateTurns.PlainData
            @SwiftStateTree.Payload
            struct Value: Codable {
                var count: Int = 0
            }

            @resultBuilder
            @SnapshotConvertible
            struct Builder: Codable {
                var count: Int = 0
            }
            """)
        #expect(!messages.contains { $0.contains("can't be on a state type") }, "\(messages)")
    }

    @Test("A wrong module's qualifier isn't the library's macro: refused on a state type")
    func wrongModuleQualifier() {
        let (_, messages) = expand("""
            @SnapshotConvertible
            @SwiftStateTurns.StateNodeBuilder
            struct Value: Codable {
                var count: Int = 0
            }
            """)
        #expect(messages.contains { $0.hasPrefix("@SwiftStateTurns.StateNodeBuilder can't be on a state type") }, "\(messages)")
    }

    @Test("Beside @StateNodeBuilder, @SnapshotConvertible still refuses a stored property inside #if: its conversion would drop it")
    func snapshotStoredInIfConfigBesideBuilder() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            @SnapshotConvertible
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) var count: Int = 0
                #if DEBUG
                @Internal var trace: Int = 0
                #endif
            }
            """)
        #expect(messages.contains("@SnapshotConvertible: stored property 'trace' inside #if isn't converted; declare it outside #if"), "\(messages)")
    }

    @Test("A property wrapper other than @Sync and @Internal is refused, by name")
    func unknownWrapper() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Sync(.broadcast) @Clamped var level: Int = 0
            }
            """)
        #expect(messages.first == "the PlainData check reads only @Internal and @Sync fields; another property wrapper's storage can't be checked", "\(messages)")
    }

    @Test("A Foundation value type in a state field is named with its replacement, @Internal included")
    func foundationField() {
        let (_, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Internal var startedAt: Date = Date()
            }
            """)
        #expect(messages.contains { $0.hasPrefix("Date isn't plain data; store an Int64 of milliseconds") }, "\(messages)")
    }

    @Test("An @Internal existential gets the walk's existential check; Internal's constraint refuses it at the field")
    func internalExistential() {
        let (expanded, messages) = expand("""
            @StateNodeBuilder
            struct Node: StateNodeProtocol {
                @Internal var token: (any Token)? = nil
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(checkLines(expanded).prefix(2) == ["SwiftStateTurns.PlainDataCheck.field(value._token)", "SwiftStateTurns.PlainDataCheck.optional(value.token) {"], "\(expanded)")
        #expect(expanded.contains("SwiftStateTurns.PlainDataCheck.existential($0)"), "\(expanded)")
    }

    @Test("@SnapshotConvertible writes the PlainData extension and its checks")
    func snapshotConvertibleWritesPlainData() {
        let (expanded, messages) = expand("""
            @SnapshotConvertible
            struct Card: Codable {
                var rank: Int
                var suit: String
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(expanded.contains("static func _plainDataCheck()"), "\(expanded)")
        #expect(checkLines(expanded) == [
            "SwiftStateTurns.PlainDataCheck.field(value.rank)",
            "SwiftStateTurns.PlainDataCheck.field(value.suit)",
        ], "\(expanded)")
    }

    @Test("@SnapshotConvertible writes no witness beside @PlainData or @Payload, bare or qualified", arguments: [
        "@PlainData", "@SwiftStateTurns.PlainData", "@Payload", "@SwiftStateTree.Payload",
    ])
    func snapshotConvertibleYieldsToPlainData(attribute: String) {
        let (expanded, _) = expand("""
            \(attribute)
            @SnapshotConvertible
            struct Card: Codable {
                var rank: Int
            }
            """)
        #expect(!expanded.contains("_plainDataCheck"), "\(expanded)")
    }

    @Test("Beside @StateNodeBuilder, @SnapshotConvertible writes only the conformance: one _plainDataCheck, the member", arguments: [
        "@StateNodeBuilder", "@SwiftStateTree.StateNodeBuilder",
    ])
    func snapshotConvertibleYieldsToStateNodeBuilder(attribute: String) {
        // The compiler passes `PlainData` to the extension role when the type doesn't conform
        // yet, and leaves that conformance to the expansion even though `StateNodeProtocol`
        // implies it.
        let file = Parser.parse(source: """
            @SnapshotConvertible
            \(attribute)
            struct UnitState: StateNodeProtocol {
                @Sync(.broadcast) var hp: Int = 0
            }
            """)
        let context = BasicMacroExpansionContext(
            sourceFiles: [file: .init(moduleName: "TestModule", fullFilePath: "test.swift")]
        )
        let expanded = file.expand(
            macroSpecs: [
                "StateNodeBuilder": MacroSpec(type: StateNodeBuilderMacro.self),
                "SnapshotConvertible": MacroSpec(type: SnapshotConvertibleMacro.self, conformances: [TypeSyntax("PlainData")]),
            ],
            contextGenerator: { BasicMacroExpansionContext(sharingWith: context, lexicalContext: $0.allMacroLexicalContexts()) },
            indentationWidth: .spaces(4)
        ).description
        #expect(context.diagnostics.isEmpty, "\(context.diagnostics.map(\.message))")
        #expect(expanded.contains("extension UnitState: SwiftStateTurns.PlainData {\n}") || expanded.contains("extension UnitState: SwiftStateTurns.PlainData {}"), "\(expanded)")
        // A qualified spelling isn't expanded here (the specs map bare names), so its member
        // isn't there; the bare one is the only witness.
        let count = expanded.components(separatedBy: "func _plainDataCheck()").count - 1
        #expect(count == (attribute == "@StateNodeBuilder" ? 1 : 0), "\(expanded)")
    }
}
