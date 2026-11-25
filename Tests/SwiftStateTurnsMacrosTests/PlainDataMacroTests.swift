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
        // Each check reads the stored value, never a spelled type.
        #expect(text.contains("@available(*, deprecated, message: \"the @PlainData checks; never called\") func check(_ value: inout Self) { SwiftStateTurns.PlainDataCheck.field(value.players)"))
        #expect(text.contains("PlainDataCheck.field(value.open)"))
        #expect(text.contains("PlainDataCheck.field(value.ticks)"))
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
        #expect(text.contains("PlainDataCheck.field(value.a) SwiftStateTurns.PlainDataCheck.field(value.b)"))
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
        #expect(text.contains("PlainDataCheck.field(value.value)"))
        #expect(text.contains("PlainDataCheck.field(value.index)"))
    }

    @Test("A generic parameter no stored value names adds no constraint (#769)")
    func unstoredParameters() {
        let (text, messages) = expand("""
            @PlainData
            struct ProductInfo<D: HasProductDatabase> {
                let productID: Int
                func lookup(_ deps: D) -> String { "" }
                var none: D? { nil }
            }
            @PlainData
            enum Choice<T, U> {
                case some(T)
                case none
            }
            @PlainData
            struct Nested<A, B, C: Collection> {
                var list: [A]
                var first: C.Element?
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("extension ProductInfo: SwiftStateTurns.PlainData {"))
        #expect(text.contains("extension Choice: SwiftStateTurns.PlainData where T: SwiftStateTurns.PlainData {"))
        // Named inside another type, or by a member type: `[A]` names A, `C.Element` names C.
        #expect(text.contains("extension Nested: SwiftStateTurns.PlainData where A: SwiftStateTurns.PlainData, C: SwiftStateTurns.PlainData {"))
    }

    @Test("A same-type requirement makes the other side's generic parameters named when one side's are, either way round and transitively")
    func sameTypeRequirementsCarryTheName() {
        let (text, messages) = expand("""
            @PlainData
            struct First<C: Collection, T> where C.Element == T {
                let first: C.Element?
            }
            @PlainData
            struct Reversed<C: Collection, T, U> where T == C.Element, U == T {
                let first: C.Element?
            }
            @PlainData
            struct OutOfOrder<C: Collection, T, U> where U == T, T == C.Element {
                let first: C.Element?
            }
            @PlainData
            struct Concrete<D: HasID> where D.ID == Int {
                let productID: Int
            }
            @PlainData
            struct Unrelated<C: Collection, T, U> where C.Element == T {
                let u: U
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("extension First: SwiftStateTurns.PlainData where C: SwiftStateTurns.PlainData, T: SwiftStateTurns.PlainData {"))
        #expect(text.contains("extension Reversed: SwiftStateTurns.PlainData where C: SwiftStateTurns.PlainData, T: SwiftStateTurns.PlainData, U: SwiftStateTurns.PlainData {"))
        // `U == T` comes first, before anything names `T`: only a second pass over the
        // requirements reaches `U`.
        #expect(text.contains("extension OutOfOrder: SwiftStateTurns.PlainData where C: SwiftStateTurns.PlainData, T: SwiftStateTurns.PlainData, U: SwiftStateTurns.PlainData {"))
        // A concrete type isn't a parameter: a field of `Int` doesn't reach `D` through `D.ID == Int`.
        #expect(text.contains("extension Concrete: SwiftStateTurns.PlainData {"))
        // A requirement whose sides no field names adds nothing.
        #expect(text.contains("extension Unrelated: SwiftStateTurns.PlainData where U: SwiftStateTurns.PlainData {"))
    }

    @Test("A field of a type or typealias the body declares constrains every parameter, `#if` included", arguments: [
        "struct Inner { let x: Int }",
        "enum Inner { case x }",
        "typealias Inner = Int",
        "#if DEBUG\ntypealias Inner = Int\n#endif",
    ])
    func localTypesConstrainEverything(_ local: String) {
        let (text, messages) = expand("""
            @PlainData
            struct Outer<A, B> {
                \(local)
                let inner: Inner
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("extension Outer: SwiftStateTurns.PlainData where A: SwiftStateTurns.PlainData, B: SwiftStateTurns.PlainData {"))
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
        // Each case's values are bound by position and checked; a case without values has none.
        #expect(text.contains("if case let .joining(v0, v1) = value { SwiftStateTurns.PlainDataCheck.field(v0) SwiftStateTurns.PlainDataCheck.field(v1) }"))
        #expect(text.contains("if case let .running(v0) = value { SwiftStateTurns.PlainDataCheck.field(v0) }"))
        #expect(text.contains("if case let .ended(v0) = value { SwiftStateTurns.PlainDataCheck.field(v0) }"))
        #expect(!text.contains(".idle"))
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
        #expect(text.contains("PlainDataCheck.field(value.n)"))
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
        #expect(text.contains("PlainDataCheck.field(value.n) #if DEBUG SwiftStateTurns.PlainDataCheck.field(value.trace) #elseif os(Linux) SwiftStateTurns.PlainDataCheck.field(value.linuxOnly) #else #endif"))
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

    @Test("An existential value is checked on its own and as the element of Optional, Array, ContiguousArray and a Dictionary's value")
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
                var spelled: Dictionary<String, any Payload>
            }
            """)
        #expect(messages.isEmpty)
        let check = "SwiftStateTurns.PlainDataCheck."
        // An existential field is checked as a value; inside a wrapper, every element is passed
        // to the closure and checked there, with the dictionary's key checked as a whole. The
        // wrapper's helper takes the standard library's type, however the field spells it.
        #expect(text.contains("\(check)existential(value.head)"))
        #expect(text.contains("\(check)optional(value.next) { \(check)existential($0) }"))
        #expect(text.contains("\(check)array(value.all) { \(check)existential($0) }"))
        #expect(text.contains("\(check)contiguousArray(value.later) { \(check)existential($0) }"))
        #expect(text.contains("\(check)dictionary(value.byName) { \(check)field($0); \(check)existential($1) }"))
        #expect(text.contains("\(check)array(value.nested) { \(check)optional($0) { \(check)array($0) { \(check)existential($0) } } }"))
        #expect(text.contains("\(check)optional(value.plain) { \(check)array($0) { \(check)existential($0) } }"))
        #expect(text.contains("\(check)existential(value.grouped)"))
        #expect(text.contains("\(check)optional(value.qualified) { \(check)existential($0) }"))
        #expect(text.contains("\(check)dictionary(value.spelled) { \(check)field($0); \(check)existential($1) }"))
        // No spelled type reaches the checks.
        #expect(!text.contains(".self"))
        let counts = ["existential(", "field(", "optional(", "array(", "contiguousArray(", "dictionary("].map {
            text.components(separatedBy: "PlainDataCheck.\($0)").count - 1
        }
        #expect(counts == [10, 2, 4, 4, 1, 2])
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
        #expect(text.contains("SwiftStateTurns.PlainDataCheck.field(value.value)"))
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
        #expect(text.contains("PlainDataCheck.field(value.value)"))
        // A type nested in the module's own `Date` or `URL` isn't Foundation's either.
        let (nested, nestedMessages) = expand("""
            @PlainData
            struct T {
                var part: Date.Part
                var host: URL.Host
            }
            """)
        #expect(nestedMessages.isEmpty)
        #expect(nested.contains("PlainDataCheck.field(value.part)"))
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
        #expect(whole.text.contains("if case let .node(v0, v1) = value"))
        let single = expand("""
            @PlainData
            enum List {
                case end
                indirect case cons(Int, List)
            }
            """)
        #expect(single.messages.isEmpty)
        #expect(single.text.contains("if case let .cons(v0, v1) = value"))
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
            ("@lowercased var level: Int", "@PlainData can't check a property wrapper's storage; store the value itself"),
            ("@usableFromInline @Clamped var level: Int", "@PlainData can't check a property wrapper's storage; store the value itself"),
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

    @Test("A built-in attribute that leaves the storage alone isn't a wrapper; a computed property is skipped, and an attached macro on it is refused (#837)")
    func storageNeutralAttributes() {
        let (text, messages) = expand("""
            @PlainData
            struct Angle {
                @usableFromInline
                internal var degrees: Int32
                @available(*, deprecated) var old: Int
                @inlinable
                public var radians: Float { Float(degrees) }
            }
            """)
        #expect(messages.isEmpty, "\(messages)")
        #expect(text.contains("PlainDataCheck.field(value.degrees) SwiftStateTurns.PlainDataCheck.field(value.old) }"))
        // A macro attached to a computed property can add a stored peer the witness doesn't see.
        let (_, attached) = expand("""
            @PlainData
            struct Angle {
                var degrees: Int32
                @Clamped var shown: Int { 0 }
            }
            """)
        #expect(attached == [
            "@Clamped on 'shown' can't be in a PlainData type: a macro attached to a member can add stored members the PlainData check doesn't see; members take only built-in attributes that add none, such as @available and @inlinable",
        ], "\(attached)")
    }

    @Test("Enum cases that share a base name are refused, naming the case, backticked or not; exclusive `#if` clauses may each declare it")
    func sharedCaseNames() {
        let (text, messages) = expand("""
            @PlainData
            enum E {
                case item(count: Int)
                case item(label: String)
                case other
            }
            """)
        #expect(messages == ["@PlainData can't check enum cases that share the base name 'item'; give each case its own name"])
        #expect(!text.contains("extension E"))
        let (_, nested) = expand("""
            @PlainData
            enum F {
                case item(Int)
                #if DEBUG
                case item(label: String)
                #else
                case trace(String)
                #endif
            }
            """)
        #expect(nested == ["@PlainData can't check enum cases that share the base name 'item'; give each case its own name"])
        let (_, distinct) = expand("""
            @PlainData
            enum G {
                case item(Int)
                #if DEBUG
                case trace(String)
                #endif
            }
            """)
        #expect(distinct.isEmpty)
        // Only one clause is active per build, so each may declare the same case.
        let (_, exclusive) = expand("""
            @PlainData
            enum H {
                #if os(Linux)
                case item(count: Int)
                #elseif DEBUG
                case item(label: String, at: Int)
                #else
                case item
                #endif
                case other
            }
            """)
        #expect(exclusive.isEmpty, "\(exclusive)")
        // A clause's name still clashes with the enclosing list after the `#if`.
        let (_, after) = expand("""
            @PlainData
            enum J {
                #if DEBUG
                case item(Int)
                #endif
                case item(label: String)
            }
            """)
        #expect(after == ["@PlainData can't check enum cases that share the base name 'item'; give each case its own name"])
        let (_, backticked) = expand("""
            @PlainData
            enum K {
                case item(count: Int)
                case `item`(label: String)
            }
            """)
        #expect(backticked == ["@PlainData can't check enum cases that share the base name 'item'; give each case its own name"])
    }

    @Test("A nested type's field of an enclosing type's generic parameter adds that parameter's constraint; an unused one adds none (#782)")
    func enclosingGenericParameters() {
        let (text, messages) = expand("""
            struct Outer<T, U> {
                enum Middle {
                    @PlainData
                    struct Inner<V> {
                        var value: T
                        var own: V
                        var count: Int
                    }
                    @PlainData
                    struct Counter {
                        var n: Int
                        func identity(_ value: T) -> T { value }
                        var doubled: U { fatalError() }
                    }
                    @PlainData
                    enum Wrapped {
                        case one(U)
                    }
                }
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("Inner: SwiftStateTurns.PlainData where V: SwiftStateTurns.PlainData, T: SwiftStateTurns.PlainData {"))
        #expect(!text.contains("Inner: SwiftStateTurns.PlainData where V: SwiftStateTurns.PlainData, T: SwiftStateTurns.PlainData, U"))
        // Only stored values count: a method's or a computed property's parameter adds nothing.
        #expect(text.contains("Counter: SwiftStateTurns.PlainData {"))
        #expect(text.contains("Wrapped: SwiftStateTurns.PlainData where U: SwiftStateTurns.PlainData {"))
        // A parameter the nested type redeclares is its own, constrained once.
        let (shadow, _) = expand("""
            struct Outer<T> {
                @PlainData
                struct Inner<T> {
                    var value: T
                }
            }
            """)
        #expect(shadow.contains("Inner: SwiftStateTurns.PlainData where T: SwiftStateTurns.PlainData {"))
        // A keyword name is compared without its backticks and emitted with them.
        let (keyword, _) = expand("""
            struct Outer<`repeat`> {
                @PlainData
                struct Inner {
                    var value: `repeat`
                }
            }
            """)
        #expect(keyword.contains("Inner: SwiftStateTurns.PlainData where `repeat`: SwiftStateTurns.PlainData {"))
    }

    @Test("A deprecated field or case is read inside a deprecated `check`, so the expansion doesn't warn")
    func deprecatedMembers() {
        let (text, messages) = expand("""
            @PlainData
            struct S {
                @available(*, deprecated) var old: Int
            }
            """)
        #expect(messages.isEmpty)
        #expect(text.contains("@available(*, deprecated, message: \"the @PlainData checks; never called\") func check(_ value: inout Self) { SwiftStateTurns.PlainDataCheck.field(value.old) }"))
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

    @Test("An attribute a PlainData type doesn't list is refused: another macro could add members its witness doesn't see (#837)")
    func unknownTypeAttribute() {
        let rest = "can't be on a PlainData type: a macro there can add members the PlainData check doesn't see; this type takes only @PlainData, @SnapshotConvertible and attributes that add no members"
        let (_, onStruct) = expand("""
            @PlainData
            @Memoized
            @frozen
            @Other.PlainData
            struct Room {
                var size: Int
            }
            """)
        #expect(onStruct.filter { $0.contains("can't be on a PlainData type") } == ["@Memoized " + rest, "@Other.PlainData " + rest], "\(onStruct)")
        let (_, onEnum) = expand("""
            @PlainData
            @Memoized
            enum Phase {
                case lobby
            }
            """)
        #expect(onEnum.filter { $0.contains("can't be on a PlainData type") } == ["@Memoized " + rest], "\(onEnum)")
        let (_, inIf) = expand("""
            @PlainData
            #if DEBUG
            @Memoized
            #endif
            struct Room {
                var size: Int
            }
            """)
        #expect(inIf.contains("an attribute inside #if " + rest), "\(inIf)")
    }

    @Test("Beside another of the project's macros, @PlainData leaves the type's attributes to it: one report per type")
    func typeAttributesCheckedOnce() {
        for other in ["@StateNodeBuilder", "@SnapshotConvertible", "@Payload"] {
            let (_, messages) = expand("""
                \(other)
                @PlainData
                @Memoized
                struct Room {
                    var size: Int
                }
                """)
            #expect(!messages.contains { $0.contains("can't be on a PlainData type") }, "\(other): \(messages)")
        }
    }

    @Test("An attribute on a member that could add declarations is refused, on a struct and an enum; built-ins pass (#837)")
    func memberAttributes() {
        let rest = " can't be in a PlainData type: a macro attached to a member can add stored members the PlainData check doesn't see; members take only built-in attributes that add none, such as @available and @inlinable"
        let refused: [(member: String, name: String)] = [
            ("@Memoized func cost() -> Int { 0 }", "@Memoized on 'cost()'"),
            ("@AddRef var view: Int { 0 }", "@AddRef on 'view'"),
            ("@AddRef static var shared: Int = 0", "@AddRef on 'shared'"),
            ("@Peer init(x: Int) { self.init() }", "@Peer on 'init(...)'"),
            ("@Peer subscript(i: Int) -> Int { i }", "@Peer on 'subscript(...)'"),
            ("@Peer struct Inner {}", "@Peer on 'Inner'"),
            ("@Peer typealias Alias = Int", "@Peer on 'Alias'"),
            ("#if DEBUG\n@Memoized func debugCost() -> Int { 0 }\n#endif", "@Memoized on 'debugCost()'"),
        ]
        for (member, name) in refused {
            let (_, messages) = expand("@PlainData\nstruct Room {\nvar size: Int\ninit() { size = 0 }\n\(member)\n}")
            #expect(messages.filter { $0.contains("a macro attached to a member") } == [name + rest], "\(member): \(messages)")
        }
        let (_, onCase) = expand("@PlainData\nenum Phase {\ncase lobby\n@Peer case playing\n}")
        #expect(onCase.filter { $0.contains("a macro attached to a member") } == ["@Peer on 'case playing'" + rest], "\(onCase)")
        let allowed = """
            @inlinable func a() -> Int { 0 }
            @available(*, deprecated) var b: Int { 0 }
            @discardableResult mutating func c() -> Int { 0 }
            @TaskLocal static var d: Int = 0
            @_spi(Test) public init(e: Int) { self.init() }
            @PlainData struct Inner { var f: Int }
            """
        let (_, messages) = expand("@PlainData\nstruct Room {\nvar size: Int\ninit() { size = 0 }\n\(allowed)\n}")
        #expect(!messages.contains { $0.contains("a macro attached to a member") }, "\(messages)")
    }
}
