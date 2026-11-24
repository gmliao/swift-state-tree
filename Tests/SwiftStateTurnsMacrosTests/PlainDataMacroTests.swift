// Tests/SwiftStateTurnsMacrosTests/PlainDataMacroTests.swift
//
// `@PlainData` writes the conformance and one compile-time check per stored property or
// associated value, and refuses what it can't check. These read the expanded source and each
// diagnostic; whether a check line fails to compile for a non-plain type is the must-fail
// snippets' job (scripts/must-not-compile/turns/).

import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing
import SwiftStateTurnsMacros


private func squashed(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The expansion squashed to single spaces, and the diagnostics' messages. `missing`: the
/// conformances the compiler would report as not yet declared (none when the type declares
/// PlainData itself).
private func expand(_ source: String, missing: [String] = ["PlainData"]) -> (text: String, messages: [String]) {
    let sourceFile = Parser.parse(source: source)
    let context = BasicMacroExpansionContext(
        sourceFiles: [sourceFile: .init(moduleName: "TestModule", fullFilePath: "test.swift")]
    )
    let spec = MacroSpec(type: PlainDataMacro.self, conformances: missing.map { TypeSyntax(stringLiteral: $0) })
    let expanded = sourceFile.expand(
        macroSpecs: ["PlainData": spec],
        contextGenerator: { BasicMacroExpansionContext(sharingWith: context, lexicalContext: $0.allMacroLexicalContexts()) },
        indentationWidth: .spaces(4)
    )
    return (squashed(expanded.description), context.diagnostics.map(\.message))
}

@Suite("@PlainData expansion")
struct PlainDataMacroTests {
    @Test("A struct gets the conformance and one check per stored property; computed and static ones are skipped")
    func structChecksStoredProperties() {
        let (text, messages) = expand("""
            @PlainData
            struct Room {
                var players: [Int: String]
                let open: Bool
                var ticks: Int = 0 { didSet {} }
                var count: Int { players.count }
                static var shared: Int = 0
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("extension Room: SwiftStateTurns.PlainData {"))
        #expect(text.contains("PlainDataCheck.field(([Int: String]).self)"))
        #expect(text.contains("PlainDataCheck.field((Bool).self)"))
        #expect(text.contains("PlainDataCheck.field((Int).self)"))
        // `ticks` is checked once (Int); `count` and `shared` aren't checked at all.
        #expect(text.components(separatedBy: "PlainDataCheck.field").count - 1 == 3)
    }

    @Test("`var a, b: Int` checks both bindings with the shared annotation")
    func sharedAnnotation() {
        let (text, messages) = expand("""
            @PlainData
            struct Pair {
                var a, b: Int
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.components(separatedBy: "PlainDataCheck.field((Int).self)").count - 1 == 2)
    }

    @Test("A generic struct's conformance requires each parameter to be PlainData")
    func genericStruct() {
        let (text, messages) = expand("""
            @PlainData
            struct Box<T, U: Hashable> {
                var value: T
                var index: [U: T]
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("extension Box: SwiftStateTurns.PlainData where T: SwiftStateTurns.PlainData, U: SwiftStateTurns.PlainData {"))
        #expect(text.contains("PlainDataCheck.field((T).self)"))
        #expect(text.contains("PlainDataCheck.field(([U: T]).self)"))
    }

    @Test("An enum checks every associated value of every case")
    func enumAssociatedValues() {
        let (text, messages) = expand("""
            @PlainData
            enum Phase {
                case idle
                case joining(player: Int, attempt: UInt64)
                case running([String]), ended(String?)
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("extension Phase: SwiftStateTurns.PlainData {"))
        for type in ["Int", "UInt64", "[String]", "String?"] {
            #expect(text.contains("PlainDataCheck.field((\(type)).self)"), "checks \(type)")
        }
    }

    @Test("A type that already declares PlainData gets the checks without a second conformance")
    func declaredConformance() {
        let (text, messages) = expand("""
            @PlainData
            struct Done: PlainData {
                var n: Int
            }
            """, missing: [])
        #expect(messages.isEmpty)
        #expect(text.contains("extension Done {"))
        #expect(!text.contains("extension Done: PlainData"))
        #expect(text.contains("PlainDataCheck.field((Int).self)"))
    }

    @Test("Members inside `#if` are checked under the same conditions, in every clause")
    func ifConfigMembers() {
        let (text, messages) = expand("""
            @PlainData
            struct Room {
                var n: Int
                #if DEBUG
                var trace: [String]
                #elseif os(Linux)
                var linuxOnly: UInt32
                #else
                #endif
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("PlainDataCheck.field((Int).self) #if DEBUG SwiftStateTurns.PlainDataCheck.field(([String]).self) #elseif os(Linux) SwiftStateTurns.PlainDataCheck.field((UInt32).self) #else #endif"))
    }

    @Test("A closure inside `#if` is refused like one outside it; so is an enum case inside `#if`")
    func ifConfigRefusals() {
        let structResult = expand("""
            @PlainData
            struct Room {
                #if DEBUG
                var hook: @Sendable () -> Void = {}
                #endif
            }
            """)
        #expect(structResult.messages.contains { $0.contains("a function type isn't plain data") })
        #expect(!structResult.text.contains("extension Room"))
        let enumResult = expand("""
            @PlainData
            enum Phase {
                case idle
                #if DEBUG
                case traced(Box<any Error>)
                #endif
            }
            """)
        #expect(enumResult.messages.contains { $0.contains("@PlainData checks an existential only as a field") })
    }

    @Test("Refused: a class, an actor and a protocol", arguments: ["class", "actor", "protocol"])
    func refusesNonValueKinds(_ kind: String) {
        let body = kind == "protocol" ? "var n: Int { get }" : "var n: Int = 0"
        let (text, messages) = expand("""
            @PlainData
            \(kind) Thing {
                \(body)
            }
            """)
        #expect(messages == ["@PlainData applies to a struct or an enum; a class, an actor or a protocol isn't plain data"])
        #expect(!text.contains("extension Thing"))
    }

    @Test("Refused: a stored property without a type annotation")
    func refusesMissingAnnotation() {
        let (text, messages) = expand("""
            @PlainData
            struct S {
                var count = 0
            }
            """)
        #expect(messages == ["stored property 'count' needs a type annotation for @PlainData to check it"])
        #expect(!text.contains("extension S"))
    }

    @Test("Refused: closures, existentials, opaque types and tuples, also nested in another type")
    func refusesTypes() {
        let cases: [(String, String)] = [
            ("var onEnd: () -> Void", "a function type isn't plain data: it can call through to anything"),
            ("var onEnd: (@Sendable (Int) -> Void)?", "a function type isn't plain data: it can call through to anything"),
            ("var errors: Set<any Error>", "@PlainData checks an existential only as a field, or inside Optional, Array, ContiguousArray or a Dictionary's value; it can't see what this type does with it"),
            ("var kind: any Error.Type", "a metatype isn't plain data; store a name or an id that a lookup turns into the type"),
            ("var view: some Sendable", "an opaque type isn't plain data, and neither is an existential nested in it: its value can be a class"),
            ("var last: (Int, String)", "a tuple can't conform to PlainData; use PlainPair or a @PlainData struct"),
            // An existential inside a closure, a tuple or a dictionary's key.
            ("var make: () -> any Payload", "a function type isn't plain data: it can call through to anything"),
            ("var make: @Sendable () -> any Payload", "a function type isn't plain data: it can call through to anything"),
            ("var both: (Int, any Payload)", "a tuple can't conform to PlainData; use PlainPair or a @PlainData struct"),
            ("var byKind: [any Payload: Int]", "@PlainData checks an existential only as a field, or inside Optional, Array, ContiguousArray or a Dictionary's value; it can't see what this type does with it"),
            ("var byKind: Dictionary<any Payload, Int>", "@PlainData checks an existential only as a field, or inside Optional, Array, ContiguousArray or a Dictionary's value; it can't see what this type does with it"),
        ]
        for (property, message) in cases {
            let (text, messages) = expand("""
                @PlainData
                struct S {
                    \(property)
                }
                """)
            #expect(messages == [message], "\(property)")
            #expect(!text.contains("extension S"), "\(property)")
        }
    }

    @Test("An existential gets a closure check, on its own and as the element of Optional, Array, ContiguousArray and a Dictionary's value")
    func existentialChecks() {
        let (text, messages) = expand("""
            @PlainData
            struct Queue {
                var head: any Payload
                var next: (any Payload)?
                var all: [any Payload]
                var later: ContiguousArray<any Payload>
                var byName: [String: any Payload]
                var nested: [[any Payload & Sendable]?]
                var plain: Optional<Array<any Payload>>
                var grouped: any (Payload & Sendable)
                var qualified: Swift.Optional<any Payload>
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.field((String).self)"))
        // One closure check per existential; no check for a wrapper, which can't conform.
        #expect(text.components(separatedBy: "SwiftStateTurns.PlainDataCheck.existential { (value: any Payload) in value }").count - 1 == 7)
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.existential { (value: any Payload & Sendable) in value }"))
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.existential { (value: any (Payload & Sendable)) in value }"))
        #expect(text.components(separatedBy: "PlainDataCheck.field").count - 1 == 1)
        // A wrapper spelled by name is checked to be the standard library's, each layer; one
        // spelled `Swift.` or as sugar needs no check.
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.same((ContiguousArray<any Payload>).self, (Swift.ContiguousArray<any Payload>).self)"))
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.same((Optional<Array<any Payload>>).self, (Swift.Optional<Array<any Payload>>).self)"))
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.same((Array<any Payload>).self, (Swift.Array<any Payload>).self)"))
        #expect(text.components(separatedBy: "PlainDataCheck.same").count - 1 == 3)
    }

    @Test("The expansion names the core's module for the conformance and a generic's constraint")
    func qualifiedNames() {
        let (text, _) = expand("""
            @PlainData
            struct Box<T> {
                var value: T
            }
            """)
        #expect(text.contains("extension Box: SwiftStateTurns.PlainData where T: SwiftStateTurns.PlainData {"))
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.field((T).self)"))
    }

    @Test("The checks' witness is as visible as the type: public for a public type, internal otherwise")
    func witnessAccess() {
        let (open, _) = expand("""
            @PlainData
            public struct Seat {
                public var number: Int
            }
            """)
        #expect(open.contains("public static func _plainDataCheck() {"))
        let (closed, _) = expand("""
            @PlainData
            struct Row {
                var number: Int
            }
            """)
        #expect(closed.contains("static func _plainDataCheck() {"))
        #expect(!closed.contains("public static func"))
        #expect(!closed.contains("package static func"))
        let (shared, _) = expand("""
            @PlainData
            package struct Row {
                var number: Int
            }
            """)
        #expect(shared.contains("package static func _plainDataCheck() {"))
    }

    @Test("A member of an extension without its own modifier takes the extension's access", arguments: [
        ("public", "public static func _plainDataCheck() {"),
        ("package", "package static func _plainDataCheck() {"),
    ])
    func witnessAccessFromExtension(access: String, witness: String) {
        let (text, _) = expand("""
            \(access) extension Outer {
                @PlainData
                struct Inner {
                    var number: Int
                }
            }
            """)
        #expect(text.contains(witness))
        // Its own modifier wins over the extension's.
        let (own, _) = expand("""
            \(access) extension Outer {
                @PlainData
                internal struct Inner {
                    var number: Int
                }
            }
            """)
        #expect(own.contains("static func _plainDataCheck() {"))
        #expect(!own.contains("\(access) static func _plainDataCheck"))
    }

    @Test("A @usableFromInline type's witness is @usableFromInline")
    func witnessUsableFromInline() {
        let (text, _) = expand("""
            @PlainData
            @usableFromInline
            struct Row {
                var number: Int
            }
            """)
        #expect(text.contains("@usableFromInline static func _plainDataCheck() {"))
    }

    @Test("Foundation's value types are refused with what to store instead", arguments: [
        ("Date", "an Int64 of milliseconds, or read the turn's `now`"),
        ("UUID", "a String, or a project ID type"),
        ("URL", "a String"),
        ("Decimal", "an integer in the smallest unit, or a String"),
        ("Foundation.Date", "an Int64 of milliseconds, or read the turn's `now`"),
        ("[UUID]", "a String, or a project ID type"),
    ])
    func refusesFoundationTypes(_ type: String, _ replacement: String) {
        let (text, messages) = expand("""
            @PlainData
            struct S {
                var value: \(type)
            }
            """)
        let name = type.replacingOccurrences(of: "Foundation.", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        #expect(messages == ["\(name) isn't plain data; store \(replacement) (for your own type of that name, qualify it with its module)"])
        #expect(!text.contains("extension S"))
    }

    @Test("A type of the same name from another module isn't taken for Foundation's")
    func qualifiedNamesakeIsChecked() {
        let (text, messages) = expand("""
            @PlainData
            struct S {
                var value: Calendar.Date
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("PlainDataCheck.field((Calendar.Date).self)"))
        // A type nested in the module's own `Date` or `URL` isn't Foundation's either.
        let (nested, nestedMessages) = expand("""
            @PlainData
            struct T {
                var part: Date.Part
                var host: URL.Host
            }
            """)
        #expect(nestedMessages.isEmpty)
        #expect(nested.contains("PlainDataCheck.field((Date.Part).self)"))
    }

    @Test("An indirect enum and an indirect case are checked like any enum")
    func indirectEnums() {
        let whole = expand("""
            @PlainData
            indirect enum Tree {
                case leaf(Int)
                case node(Tree, Tree)
            }
            """)
        #expect(whole.messages.isEmpty)
        #expect(whole.text.contains("PlainDataCheck.field((Tree).self)"))
        let single = expand("""
            @PlainData
            enum List {
                case end
                indirect case cons(Int, List)
            }
            """)
        #expect(single.messages.isEmpty)
        #expect(single.text.contains("PlainDataCheck.field((List).self)"))
    }

    @Test("A parenthesized type is not a tuple")
    func parenthesizedType() {
        let (_, messages) = expand("""
            @PlainData
            struct S {
                var n: (Int)
            }
            """)
        #expect(messages.isEmpty)
    }

    @Test("Refused: weak and unowned properties, property wrappers, tuple patterns")
    func refusesStorageForms() {
        let cases: [(String, String)] = [
            ("weak var owner: Owner?", "a weak or unowned property holds a reference, which isn't plain data"),
            ("unowned let owner: Owner", "a weak or unowned property holds a reference, which isn't plain data"),
            ("@Clamped var level: Int", "@PlainData can't check a property wrapper's storage; store the value itself"),
            ("let (a, b): (Int, Int)", "@PlainData checks one stored property per binding; split the tuple pattern"),
        ]
        for (property, message) in cases {
            let (_, messages) = expand("""
                @PlainData
                struct S {
                    \(property)
                }
                """)
            #expect(messages == [message], "\(property)")
        }
    }

    @Test("An enum case's closure payload is refused")
    func refusesEnumClosure() {
        let (_, messages) = expand("""
            @PlainData
            enum Work {
                case later(() -> Void)
            }
            """)
        #expect(messages == ["a function type isn't plain data: it can call through to anything"])
    }
}
