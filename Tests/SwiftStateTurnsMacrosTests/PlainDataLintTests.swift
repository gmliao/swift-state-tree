// Tests/SwiftStateTurnsMacrosTests/PlainDataLintTests.swift
//
// The turn core's plain-data rule, on SwiftSyntax's tokens: outside the core's two targets, no
// code may write PlainData's requirement or conform to PlainData by hand, and nothing may take
// the names the macro's expansion relies on. `@PlainData` is the only way in. The rule reads
// the parsed source, so comments, strings, raw strings, tabs and nested comments can't hide
// code from it, and code inside an interpolation is still code. The other turn rules stay in
// scripts/lint-turns.sh.

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// One place the rule refuses, by 1-based line.
struct PlainDataFinding: Equatable, CustomStringConvertible {
    let line: Int
    let message: String

    var description: String { "\(line): \(message)" }
}

enum PlainDataLint {
    static let witness = "a hand-written _plainDataCheck; only @PlainData writes it"
    static let implements = "@_implements naming PlainData writes its requirement by hand; only @PlainData writes it"
    static let conformance = "a hand-written PlainData conformance; use @PlainData"
    static let alias = "a typealias for PlainData lets a type conform without @PlainData"
    static let helperExtension = "an extension of PlainDataCheck can add an overload that lets any type pass the checks"
    static func reserved(_ name: String) -> String {
        "a declaration named \(name) shadows the name @PlainData's expansion relies on"
    }

    /// Names the expansion uses or the standard library's types are pinned through.
    static let reservedNames: Set<String> = ["PlainDataCheck", "SwiftStateTurns", "Swift"]

    /// Paths the rule doesn't apply to: the turn core and its macro write the requirement.
    static func isCore(_ path: String) -> Bool {
        path.hasPrefix("Sources/SwiftStateTurns/") || path.hasPrefix("Sources/SwiftStateTurnsMacros/")
    }

    /// Whether a file can hold a finding at all. Every finding needs one of these words in the
    /// raw text, so a file without any is skipped unparsed.
    static func mayHold(_ text: String) -> Bool {
        if text.contains("PlainData") || text.contains("_implements") || text.contains("SwiftStateTurns") { return true }
        return text.range(of: #"(^|[^A-Za-z0-9_.])Swift([^A-Za-z0-9_]|$)"#, options: .regularExpression) != nil
    }

    static func findings(in source: String) -> [PlainDataFinding] {
        let tree = Parser.parse(source: source)
        let visitor = PlainDataVisitor(converter: SourceLocationConverter(fileName: "", tree: tree))
        visitor.walk(tree)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var seen: Set<Int> = []
        return visitor.found.filter { finding in
            // One finding per line, the first; a line marked for this rule is allowed.
            guard seen.insert(finding.line).inserted else { return false }
            let text = finding.line <= lines.count ? String(lines[finding.line - 1]) : ""
            return !isMarked(text)
        }
    }

    /// The allow marker for this rule, followed on its line by a reason of at least ten
    /// characters. Where a marker may appear and how many a file may hold is
    /// scripts/lint-turns.sh's check. Built in two parts, so this file holds no marker itself.
    static let marker = "// lint-" + "allow: turns-plain-data:"

    static func isMarked(_ line: String) -> Bool {
        guard let range = line.range(of: marker) else { return false }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces).count >= 10
    }
}

private final class PlainDataVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    var found: [PlainDataFinding] = []

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func note(_ node: some SyntaxProtocol, _ message: String) {
        let line = node.startLocation(converter: converter).line
        found.append(PlainDataFinding(line: line, message: message))
    }

    /// The identifier a token names, backticks removed, or nil for any other token.
    private func identifier(_ token: TokenSyntax) -> String? {
        guard case .identifier(let text) = token.tokenKind else { return nil }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
    }

    /// Whether `type` names PlainData anywhere: `PlainData`, `SwiftStateTurns.PlainData`, a
    /// composition holding either.
    private func namesPlainData(_ type: some SyntaxProtocol) -> Bool {
        type.tokens(viewMode: .sourceAccurate).contains { identifier($0) == "PlainData" }
    }

    private func reserved(_ name: TokenSyntax) {
        if let text = identifier(name), PlainDataLint.reservedNames.contains(text) {
            note(name, PlainDataLint.reserved(text))
        }
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if identifier(token) == "_plainDataCheck" { note(token, PlainDataLint.witness) }
        return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if node.attributeName.trimmedDescription == "_implements", let arguments = node.arguments, namesPlainData(arguments) {
            note(node, PlainDataLint.implements)
        }
        return .visitChildren
    }

    override func visit(_ node: InheritanceClauseSyntax) -> SyntaxVisitorContinueKind {
        // A protocol may refine PlainData: a conformer through it still needs the requirement.
        // A generic parameter's or an associated type's constraint isn't a conformance.
        let conforms = node.parent.map {
            $0.is(StructDeclSyntax.self) || $0.is(ClassDeclSyntax.self) || $0.is(EnumDeclSyntax.self)
                || $0.is(ActorDeclSyntax.self) || $0.is(ExtensionDeclSyntax.self)
        } ?? false
        if conforms, node.inheritedTypes.contains(where: { namesPlainData($0.type) }) {
            note(node, PlainDataLint.conformance)
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        reserved(node.name)
        if namesPlainData(node.initializer.value) { note(node.initializer, PlainDataLint.alias) }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = node.extendedType.tokens(viewMode: .sourceAccurate).compactMap { identifier($0) }.last
        if extended == "PlainDataCheck" { note(node.extendedType, PlainDataLint.helperExtension) }
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: GenericParameterSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind { reserved(node.name); return .visitChildren }
    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind { reserved(node.identifier); return .visitChildren }
}

/// The repository's root, from this file's path.
private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The Swift files the rule reads, relative to the root, sorted.
private func repositorySwiftFiles() -> [String] {
    var paths: [String] = []
    for top in ["Sources", "Tests", "Examples"] {
        let base = repositoryRoot.appendingPathComponent(top)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".build" || name == "node_modules" { walker.skipDescendants(); continue }
            guard url.pathExtension == "swift" else { continue }
            paths.append(String(url.standardizedFileURL.path.dropFirst(repositoryRoot.standardizedFileURL.path.count + 1)))
        }
    }
    return paths.sorted()
}

@Suite("Plain-data rule (lint on SwiftSyntax)")
struct PlainDataLintTests {
    @Test("The repository: no hand-written witness, conformance or reserved name outside the core")
    func repository() throws {
        let files = repositorySwiftFiles()
        // A path change that finds nothing would pass vacuously; these must be read.
        #expect(files.count > 300, "found \(files.count) Swift files under \(repositoryRoot.path)")
        let marked = "Tests/SwiftStateTurnsTests/Support/DemoActor.swift"
        try #require(files.contains(marked), "\(marked) not found under \(repositoryRoot.path)")

        var report: [String] = []
        var parsed = 0
        for path in files where !PlainDataLint.isCore(path) {
            let text = try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
            guard PlainDataLint.mayHold(text) else { continue }
            parsed += 1
            report += PlainDataLint.findings(in: text).map { "\(path):\($0)" }
        }
        #expect(report.isEmpty, "\(report.joined(separator: "\n"))")
        #expect(parsed > 20, "parsed only \(parsed) files")

        // The marked file holds a hand-written witness under its marker: it was read, and the
        // marker is what lets it pass.
        let demo = try String(contentsOf: repositoryRoot.appendingPathComponent(marked), encoding: .utf8)
        let unmarked = demo.replacingOccurrences(of: PlainDataLint.marker, with: "// removed:")
        #expect(!PlainDataLint.findings(in: unmarked).isEmpty)
    }

    @Test("Found wherever the code is: tabs, comments holding quotes, nested comments, raw strings, interpolation", arguments: [
        ("struct A {\n\tstatic func _plainDataCheck() {}\n}", 2, PlainDataLint.witness),
        ("\textension Other: PlainData {}", 1, PlainDataLint.conformance),
        ("/* start\n\"\"\"\n*/ struct S { static func _plainDataCheck() {} }", 3, PlainDataLint.witness),
        ("/* outer /* inner */ \"\"\" still a comment */\nstruct N { static func _plainDataCheck() {} }", 2, PlainDataLint.witness),
        ("let s = \"\"\"\n    text\n    \"\"\"; struct T { static func _plainDataCheck() {} }", 3, PlainDataLint.witness),
        ("let r = #\"\\\"#; struct R { static func _plainDataCheck() {} }", 1, PlainDataLint.witness),
        ("let i = \"\\(Holder._plainDataCheck())\"", 1, PlainDataLint.witness),
        ("struct E { static func `_plainDataCheck`() {} }", 1, PlainDataLint.witness),
        ("struct F { static func\n    _plainDataCheck() {} }", 2, PlainDataLint.witness),
        ("struct G { static func/*x*/_plainDataCheck() {} }", 1, PlainDataLint.witness),
        ("extension Bridge { public static func _plainDataCheck() {} }", 1, PlainDataLint.witness),
        ("struct I { @_implements(PlainData, other()) static func anything() {} }", 1, PlainDataLint.implements),
        ("struct J { @_implements(SwiftStateTurns.PlainData,\n    other()) static func anything() {} }", 1, PlainDataLint.implements),
        ("struct Plain: Sendable, SwiftStateTurns.PlainData { var n: Int }", 1, PlainDataLint.conformance),
        ("extension Other: Hashable & PlainData {}", 1, PlainDataLint.conformance),
        ("typealias Alias = PlainData", 1, PlainDataLint.alias),
        ("typealias Joined = Sendable &\n    PlainData", 1, PlainDataLint.alias),
        ("extension PlainDataCheck { static func field(_: Ref.Type) {} }", 1, PlainDataLint.helperExtension),
        ("extension SwiftStateTurns.PlainDataCheck {}", 1, PlainDataLint.helperExtension),
        ("enum SwiftStateTurns {}", 1, PlainDataLint.reserved("SwiftStateTurns")),
        ("enum Swift { struct Array<E> {} }", 1, PlainDataLint.reserved("Swift")),
        ("typealias PlainDataCheck = Int", 1, PlainDataLint.reserved("PlainDataCheck")),
        ("struct Wrap<SwiftStateTurns> {}", 1, PlainDataLint.reserved("SwiftStateTurns")),
        ("struct K {\n    static let SwiftStateTurns = 0\n}", 2, PlainDataLint.reserved("SwiftStateTurns")),
    ])
    func refuses(source: String, line: Int, message: String) {
        #expect(PlainDataLint.findings(in: source) == [PlainDataFinding(line: line, message: message)], "\(source)")
    }

    @Test("Not code, or not a conformance: comments, strings, raw strings, refining protocols, constraints, the macro, a marked line", arguments: [
        "/* _plainDataCheck in a comment\n   spanning lines, with \"\"\" inside */",
        "// struct Fake: PlainData {} in a comment",
        "let r = #\"_plainDataCheck \\(x) extension X: PlainData\"#",
        "let s = \"_plainDataCheck\"; let t = \"\"\"\n    extension X: PlainData {}\n    \"\"\"",
        "protocol Bridge: Sendable, PlainData {}",
        "protocol WhereBridge where Self: PlainData {}",
        "protocol Split\n    where Self: Sendable & PlainData\n{\n}",
        "struct Box<T: PlainData>: Sendable where T: PlainData {}",
        "func use<T>(_ value: T) where T: PlainData {}",
        "protocol HasPayload { associatedtype P: PlainData }",
        "@PlainData\nstruct Model { var n: Int }",
        "typealias Pair = PlainPair<Int, Int>",
        "import SwiftStateTurns\nlet pair = SwiftStateTurns.PlainPair<Int, Int>(1, 2)",
        "let version = \"Swift 6\"; let swift = 6",
    ])
    func allows(source: String) {
        #expect(PlainDataLint.findings(in: source).isEmpty, "\(source)")
    }

    @Test("A line with the marker and a reason is allowed; without a reason it isn't")
    func marker() {
        let witness = "extension ClassMachine { static func _plainDataCheck() {} } "
        #expect(PlainDataLint.findings(in: witness + PlainDataLint.marker + " the class-machine stop").isEmpty)
        #expect(PlainDataLint.findings(in: witness + PlainDataLint.marker + " short") == [PlainDataFinding(line: 1, message: PlainDataLint.witness)])
    }
}
