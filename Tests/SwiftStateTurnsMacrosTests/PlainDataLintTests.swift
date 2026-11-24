// Tests/SwiftStateTurnsMacrosTests/PlainDataLintTests.swift
//
// The turn core's plain-data rule, on SwiftSyntax's tokens: outside Sources/SwiftStateTurns/, no
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
    static let helper = "PlainDataCheck is for @PlainData's expansion only: an alias or extension of it can add an overload that lets any type pass the checks"
    static let implements = "@_implements naming PlainData writes its requirement by hand; only @PlainData writes it"
    static let conformance = "a hand-written PlainData conformance; use @PlainData"
    static let alias = "a typealias for PlainData lets a type conform without @PlainData"
    static func reserved(_ name: String) -> String {
        "a declaration named \(name) shadows a name @PlainData's expansion relies on"
    }

    /// Names the expansion qualifies with, and the standard library's wrappers it pins through
    /// `PlainDataCheck`'s helpers. `PlainDataCheck` itself is refused as any token.
    static let reservedNames: Set<String> = ["SwiftStateTurns", "Swift", "Optional", "Array", "ContiguousArray", "Dictionary"]

    /// The turn core: it declares the requirement and its built-in conformances. The macro target
    /// names them only inside string literals, which the rule doesn't read.
    static func isCore(_ path: String) -> Bool {
        path.hasPrefix("Sources/SwiftStateTurns/")
    }

    static func findings(in source: String) -> [PlainDataFinding] {
        let tree = Parser.parse(source: source)
        let visitor = PlainDataVisitor(converter: SourceLocationConverter(fileName: "", tree: tree))
        visitor.walk(tree)
        var seen: Set<Int> = []
        return visitor.found.filter { finding in
            // One finding per line, the first; a line marked for this rule is allowed.
            guard seen.insert(finding.line).inserted else { return false }
            return !visitor.markedLines.contains(finding.line)
        }
    }

    /// The allow marker for this rule. A `//` comment that starts with it, followed by a reason
    /// of at least ten characters, allows its line. A marker later in another comment isn't one:
    /// scripts/lint-turns.sh, which counts markers per file, refuses two on a line. Built in two
    /// parts, so this file holds no marker itself.
    static let marker = "// lint-" + "allow: turns-plain-data:"

    static func isMarker(_ comment: String) -> Bool {
        guard comment.hasPrefix(marker) else { return false }
        return comment.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).count >= 10
    }
}

private final class PlainDataVisitor: SyntaxVisitor {
    let converter: SourceLocationConverter
    var found: [PlainDataFinding] = []
    /// Lines holding a `//` comment that is this rule's marker, from the tree's trivia.
    var markedLines: Set<Int> = []

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

    private func markers(in trivia: Trivia, from start: AbsolutePosition) {
        var position = start
        for piece in trivia {
            if case .lineComment(let text) = piece, PlainDataLint.isMarker(text) {
                markedLines.insert(converter.location(for: position).line)
            }
            position += piece.sourceLength
        }
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        markers(in: token.leadingTrivia, from: token.position)
        markers(in: token.trailingTrivia, from: token.endPositionBeforeTrailingTrivia)
        // A string literal's text is a segment token, never an identifier: only code is read.
        switch identifier(token) {
        case "_plainDataCheck": note(token, PlainDataLint.witness)
        case "PlainDataCheck": note(token, PlainDataLint.helper)
        default: break
        }
        return .visitChildren
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let name = node.attributeName.tokens(viewMode: .sourceAccurate).compactMap { identifier($0) }.last
        if name == "_implements", let arguments = node.arguments, namesPlainData(arguments) {
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

/// The Swift files under `tops` of `root`, relative to `root`, sorted: what SwiftPM can compile.
/// A symlinked directory is followed (each real directory once, so a cycle ends). A `.build` or
/// `node_modules` directory is skipped only at a package's root (beside a `Package.swift` or a
/// `package.json`); anywhere else it may hold a target's sources.
func swiftFiles(under root: URL, in tops: [String]) -> [String] {
    let files = FileManager.default
    var paths: [String] = []
    var visited: Set<String> = []
    func walk(_ relative: String) {
        let url = root.appendingPathComponent(relative)
        guard visited.insert(url.resolvingSymlinksInPath().path).inserted,
              let names = try? files.contentsOfDirectory(atPath: url.path) else { return }
        let packageRoot = names.contains("Package.swift") || names.contains("package.json")
        for name in names.sorted() {
            let child = relative + "/" + name
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: root.appendingPathComponent(child).path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if packageRoot, name == ".build" || name == "node_modules" { continue }
                walk(child)
            } else if name.hasSuffix(".swift") {
                paths.append(child)
            }
        }
    }
    for top in tops { walk(top) }
    return paths.sorted()
}

/// The findings in `paths` under `root`, outside the core, as `path:line: message`, sorted.
/// Every file is parsed, in parallel: a prefilter on the raw text would have to know every
/// spelling the visitor finds.
func scan(_ paths: [String], under root: URL) async throws -> [String] {
    try await withThrowingTaskGroup(of: [String].self) { group in
        for path in paths where !PlainDataLint.isCore(path) {
            group.addTask {
                let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                return PlainDataLint.findings(in: text).map { "\(path):\($0)" }
            }
        }
        return try await group.reduce(into: []) { $0 += $1 }.sorted()
    }
}

@Suite("Plain-data rule (lint on SwiftSyntax)")
struct PlainDataLintTests {
    @Test("The repository: no hand-written witness, conformance or reserved name outside the core")
    func repository() async throws {
        let files = swiftFiles(under: repositoryRoot, in: ["Sources", "Tests", "Examples"])
        // A path change that finds nothing would pass vacuously; these must be read.
        #expect(files.count > 300, "found \(files.count) Swift files under \(repositoryRoot.path)")
        let marked = "Tests/SwiftStateTurnsTests/Support/DemoActor.swift"
        try #require(files.contains(marked), "\(marked) not found under \(repositoryRoot.path)")

        let report = try await scan(files, under: repositoryRoot)
        #expect(report.isEmpty, "\(report.joined(separator: "\n"))")

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
        ("struct H { @`_implements`(PlainData, other()) static func anything() {} }", 1, PlainDataLint.implements),
        ("extension PlainDataCheck { static func field(_: Ref.Type) {} }", 1, PlainDataLint.helper),
        ("extension SwiftStateTurns.PlainDataCheck {}", 1, PlainDataLint.helper),
        ("typealias Helper = SwiftStateTurns.PlainDataCheck\nextension Helper {}", 1, PlainDataLint.helper),
        ("enum Box { typealias H = PlainDataCheck }", 1, PlainDataLint.helper),
        ("protocol Hook {}\ntypealias Check = PlainDataCheck\nextension Check: Hook {}", 2, PlainDataLint.helper),
        ("let call: () = PlainDataCheck.field(Int.self)", 1, PlainDataLint.helper),
        ("struct X {}\r_ = 0; static func _plainDataCheck() {}", 2, PlainDataLint.witness),
        ("enum SwiftStateTurns {}", 1, PlainDataLint.reserved("SwiftStateTurns")),
        ("enum Swift { struct Array<E> {} }", 1, PlainDataLint.reserved("Swift")),
        ("typealias PlainDataCheck = Int", 1, PlainDataLint.helper),
        ("typealias Array<E> = Swift.Array<Ref>", 1, PlainDataLint.reserved("Array")),
        ("struct Optional<W> {}", 1, PlainDataLint.reserved("Optional")),
        ("enum Dictionary {}", 1, PlainDataLint.reserved("Dictionary")),
        ("final class ContiguousArray {}", 1, PlainDataLint.reserved("ContiguousArray")),
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
        "let text = \"SwiftStateTurns.PlainDataCheck.field((Int).self)\"",
        "let names: Swift.Array<Int> = []; let d: Dictionary<String, Int> = [:]",
    ])
    func allows(source: String) {
        #expect(PlainDataLint.findings(in: source).isEmpty, "\(source)")
    }

    @Test("A line whose // comment starts with the marker and a reason is allowed; a reason too short, a marker inside another comment or a string, isn't")
    func marker() {
        let witness = "extension ClassMachine { static func _plainDataCheck() {} } "
        let refused = [PlainDataFinding(line: 1, message: PlainDataLint.witness)]
        #expect(PlainDataLint.findings(in: witness + PlainDataLint.marker + " the class-machine stop").isEmpty)
        #expect(PlainDataLint.findings(in: witness + PlainDataLint.marker + " short") == refused)
        #expect(PlainDataLint.findings(in: witness + "// lint-" + "allow: turns-isolated: another rule " + PlainDataLint.marker + " hidden behind it") == refused)
        #expect(PlainDataLint.findings(in: witness + "/* " + PlainDataLint.marker + " in a block comment */") == refused)
        #expect(PlainDataLint.findings(in: "let s = \"" + PlainDataLint.marker + " in a string\"; " + witness) == refused)
        // The marker allows its own line only, \r-separated lines included.
        #expect(PlainDataLint.findings(in: PlainDataLint.marker + " the line above\r" + witness) == [PlainDataFinding(line: 2, message: PlainDataLint.witness)])
    }

    @Test("Discovery follows a symlinked directory, once, and skips .build and node_modules only at a package's root")
    func discovery() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("plain-data-lint-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        func write(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try write("Sources/A/a.swift")
        try write("Sources/A/.build/nested.swift")
        try write("Sources/A/node_modules/vendored.swift")
        try write("Elsewhere/linked.swift")
        try write("Examples/P/Package.swift")
        try write("Examples/P/.build/built.swift")
        try write("Examples/P/Sources/p.swift")
        try write("Examples/W/package.json")
        try write("Examples/W/node_modules/dep.swift")
        try files.createSymbolicLink(atPath: root.appendingPathComponent("Sources/Link").path, withDestinationPath: "../Elsewhere")
        try files.createSymbolicLink(atPath: root.appendingPathComponent("Sources/A/loop").path, withDestinationPath: "..")
        #expect(swiftFiles(under: root, in: ["Sources", "Examples"]) == [
            "Examples/P/Package.swift",
            "Examples/P/Sources/p.swift",
            "Sources/A/.build/nested.swift",
            "Sources/A/a.swift",
            "Sources/A/node_modules/vendored.swift",
            "Sources/Link/linked.swift",
        ])
    }

    @Test("The scan reads every file: one whose only finding is a witness, with no other trigger word, is reported")
    func scanReadsEveryFile() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("plain-data-scan-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        try Data("extension AppState { static func _plainDataCheck() {} }\n".utf8)
            .write(to: root.appendingPathComponent("Sources/App/Evil.swift"))
        try Data("let n = 0\n".utf8).write(to: root.appendingPathComponent("Sources/App/Fine.swift"))
        let report = try await scan(swiftFiles(under: root, in: ["Sources"]), under: root)
        #expect(report == ["Sources/App/Evil.swift:1: \(PlainDataLint.witness)"])
    }
}
