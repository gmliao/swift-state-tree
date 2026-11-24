// Tests/SwiftStateTreeMacrosTests/PayloadExtensionRoleTests.swift
//
// `@Payload`'s extension role: the type is `PlainData`, through `@PlainData`'s builder. The
// conformance is declared only when the compiler asks for it (a `@Payload` struct used as a
// payload's field); a payload conforms through its protocol and gets the witness alone.

import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

/// Expands `@Payload` with its member and extension roles; `conformances` is what the compiler
/// would pass: `PlainData` when the type doesn't conform yet.
private func expand(_ source: String, conforming: Bool) -> (text: String, messages: [String]) {
    let file = Parser.parse(source: source)
    let context = BasicMacroExpansionContext(
        sourceFiles: [file: .init(moduleName: "TestModule", fullFilePath: "test.swift")]
    )
    let spec = conforming
        ? MacroSpec(type: PayloadMacro.self, conformances: [TypeSyntax("PlainData")])
        : MacroSpec(type: PayloadMacro.self)
    let expanded = file.expand(
        macroSpecs: ["Payload": spec],
        contextGenerator: { BasicMacroExpansionContext(sharingWith: context, lexicalContext: $0.allMacroLexicalContexts()) },
        indentationWidth: .spaces(4)
    )
    let text = expanded.description.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    return (text, context.diagnostics.map(\.message))
}

@Suite("@Payload's extension role makes the type PlainData")
struct PayloadExtensionRoleTests {
    @Test("A payload conforms through its protocol: the extension holds the witness only, with a check per field")
    func witnessOnly() {
        let (text, messages) = expand("""
            @Payload
            struct HitEvent: ServerEventPayload {
                let damage: Int
                let tags: [String]
            }
            """, conforming: false)
        #expect(messages.isEmpty, "\(messages)")
        #expect(text.contains("extension HitEvent { /// Compiled, never called"), "\(text)")
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.field(value.damage)"), "\(text)")
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.field(value.tags)"), "\(text)")
        #expect(!text.contains("extension HitEvent: SwiftStateTurns.PlainData"), "\(text)")
    }

    @Test("A @Payload struct that isn't a payload yet: the extension also declares the conformance")
    func declaresConformance() {
        let (text, messages) = expand("""
            @Payload
            struct Line: Codable, Sendable {
                let sku: String
            }
            """, conforming: true)
        #expect(messages.isEmpty, "\(messages)")
        #expect(text.contains("extension Line: SwiftStateTurns.PlainData {"), "\(text)")
    }

    @Test("A generic payload that declares its parameter PlainData gets an unconditional witness; a nested one in a generic type too")
    func genericWhere() {
        let (text, messages) = expand("""
            @Payload
            struct Tagged<T: Codable & Sendable & PlainData>: ServerEventPayload {
                let value: T
            }
            struct Box<U> {
                @Payload
                struct InnerEvent: ServerEventPayload {
                    let n: Int
                }
            }
            """, conforming: false)
        #expect(messages.isEmpty, "\(messages)")
        #expect(text.contains("extension Tagged {"), "\(text)")
        #expect(!text.contains("where"), "\(text)")
        // A non-payload generic @Payload struct, conforming: conditional on its parameter.
        let (conditional, _) = expand("""
            @Payload
            struct Pair<A: Codable & Sendable> {
                let first: A
            }
            """, conforming: true)
        #expect(conditional.contains("extension Pair: SwiftStateTurns.PlainData where A: SwiftStateTurns.PlainData {"), "\(conditional)")
    }

    @Test("A stored generic parameter without PlainData is refused at the parameter, naming the field; an unreadable constraint is left to the compiler")
    func unconstrainedParameter() {
        let (_, messages) = expand("""
            @Payload
            struct BoxEvent<T: Codable & Sendable>: ServerEventPayload {
                let value: T
            }
            """, conforming: false)
        #expect(messages == ["generic parameter 'T' is stored in 'value'; a payload must declare 'T: PlainData'"], "\(messages)")
        let (_, whereClause) = expand("""
            @Payload
            struct BoxEvent<T>: ServerEventPayload where T: PlainData, T: Codable {
                let value: T
            }
            """, conforming: false)
        #expect(whereClause.isEmpty, "\(whereClause)")
        let (_, unreadable) = expand("""
            @Payload
            struct WireEvent<T: Wire>: ServerEventPayload {
                let value: T
            }
            """, conforming: false)
        #expect(unreadable.isEmpty, "\(unreadable)")
        // A parameter no stored property names needs nothing.
        let (_, unused) = expand("""
            @Payload
            struct Marker<T>: ServerEventPayload {
                let n: Int
            }
            """, conforming: false)
        #expect(unused.isEmpty, "\(unused)")
    }

    @Test("The shared walk's refusals: Date and a closure are refused by name; AnyCodable is left to the type checker")
    func sharedWalkRefusals() {
        let (_, messages) = expand("""
            @Payload
            struct Mixed: ServerEventPayload {
                let at: Date
                let done: @Sendable () -> Void
                let tree: AnyCodable
            }
            """, conforming: false)
        #expect(messages.count == 2, "\(messages)")
        #expect(messages.contains { $0.hasPrefix("Date isn't plain data") }, "\(messages)")
        #expect(messages.contains("a function type isn't plain data: it can call through to anything"), "\(messages)")
    }

    @Test("@Payload beside @PlainData or @SnapshotConvertible is refused")
    func besideOtherAttributes() {
        let (_, plain) = expand("""
            @Payload
            @PlainData
            struct Twice: ServerEventPayload {
                let n: Int
            }
            """, conforming: false)
        #expect(plain.contains("@Payload already makes this type PlainData; remove @PlainData"), "\(plain)")
        let (_, snapshot) = expand("""
            @Payload
            @SnapshotConvertible
            struct Both: ServerEventPayload {
                let n: Int
            }
            """, conforming: false)
        #expect(snapshot.contains { $0.hasPrefix("@Payload and @SnapshotConvertible both write getFieldMetadata()") }, "\(snapshot)")
    }
}
