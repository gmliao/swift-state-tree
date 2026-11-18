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
        #expect(text.contains("extension Room: PlainData {"))
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
        #expect(text.contains("extension Box: PlainData where T: PlainData, U: PlainData {"))
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
        #expect(text.contains("extension Phase: PlainData {"))
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
        #expect(text.contains("PlainDataCheck.field((Int).self) #if DEBUG PlainDataCheck.field(([String]).self) #elseif os(Linux) PlainDataCheck.field((UInt32).self) #else #endif"))
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
                case traced(any Error)
                #endif
            }
            """)
        #expect(enumResult.messages.contains { $0.contains("an existential or opaque type isn't plain data") })
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
            ("var errors: [any Error]", "an existential or opaque type isn't plain data: its value can be a class"),
            ("var handlers: [String: any Sendable]", "an existential or opaque type isn't plain data: its value can be a class"),
            ("var last: (Int, String)", "a tuple can't conform to PlainData; use PlainPair or a @PlainData struct"),
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
