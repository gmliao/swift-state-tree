// A throwaway codemod for #771 D2 and #769 R1 (Notes/plans/2026-11-24-dsl-inferred-handlers.md §4,
// Notes/plans/2026-11-24-resolvers-as-values.md §3.2). Not part of the library: it is committed
// so a reviewer can read it, and deleted in the same PR.
//
// What it rewrites, in the closures passed to the DSL's entries (HandleAction, HandleEvent,
// HandleServerInput, CanJoin, OnJoin, OnLeave, OnInitialize, OnFinalize, AfterFinalize, Tick,
// StateSync, DestroyWhenEmpty, PersistSnapshot):
// 1. #771: parameter and return-type annotations are stripped (`{ (state: inout S, ctx:
//    LandContext) -> R in` becomes `{ state, ctx in`). A closure listed in `--restore` keeps them.
// 2. #769: an entry's resolver outputs become a handler parameter, after the input. A
//    `ctx.<name>` read of an output becomes a read of that parameter (`resolved.<i>` for several).
// 3. #769: `resolvers: X.self` on HandleAction, OnInitialize and OnFinalize becomes a builder
//    closure (`{ _, _, _ in X() }`), and X's declaration a `Resolver` value with
//    `Dependencies = NoServices`, when X's `resolve(ctx:)` doesn't read its context and nothing
//    else names X. Every other resolver is listed, not edited: making it a value is a design
//    change per resolver.
//
// Usage:
//   DSLCodemod [--dry-run] [--restore <file>] [--values <file>] [--report <file>] <path>...
//   DSLCodemod --locate <path:line>...      prints `path#ordinal` of the innermost entry call
//
// `--values` is a JSON object from a resolver's name to the value its builder closure returns,
// for the resolvers converted by hand (`{"Gated": "Gated(amount: action.amount)"}`): the closure's
// parameters are `state, action, ctx` (HandleAction) or `state, ctx` (OnInitialize, OnFinalize),
// each `_` when the value doesn't use it. Their declarations aren't edited.
//
// `--restore` holds one `path#ordinal` per line: the entry call's position among the file's
// entry calls, in source order, which the rewrite doesn't change.

import Foundation
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

let entryNames: Set<String> = [
    "HandleAction", "HandleEvent", "HandleServerInput", "CanJoin", "OnJoin", "OnLeave", "OnInitialize",
    "OnFinalize", "AfterFinalize", "Tick", "StateSync", "DestroyWhenEmpty", "PersistSnapshot",
]
/// The entries whose resolvers become values, with their builder closure's arity.
let valueEntries: [String: Int] = ["HandleAction": 3, "OnInitialize": 2, "OnFinalize": 2]
/// The entries that keep `ContextResolver` metatypes until #769 R3, with their handler's
/// parameter count before the outputs parameter is added.
let joinEntries: [String: Int] = ["OnJoin": 2, "OnLeave": 2, "CanJoin": 3]

func outputIndex(_ entry: String) -> Int { entry == "HandleAction" || entry == "CanJoin" ? 2 : 1 }

/// `ProductInfoResolver` -> `productInfo`, as `ResolverExecutor.convertResolverTypeToPropertyName`.
func propertyName(_ typeName: String) -> String {
    var name = typeName
    if name.hasSuffix("Resolver") { name = String(name.dropLast(8)) }
    guard let first = name.first else { return name }
    return first.lowercased() + name.dropFirst()
}

func calleeName(_ call: FunctionCallExprSyntax) -> String? {
    call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
}

/// The resolver type names of a `resolvers:` metatype argument (`X.self`, `(X.self, Y.self)`).
func metatypeNames(_ expr: ExprSyntax) -> [String]? {
    func one(_ e: ExprSyntax) -> String? {
        guard let member = e.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "self",
              let base = member.base?.as(DeclReferenceExprSyntax.self) else { return nil }
        return base.baseName.text
    }
    if let name = one(expr) { return [name] }
    if let tuple = expr.as(TupleExprSyntax.self) {
        let names = tuple.elements.map { one($0.expression) }
        return names.allSatisfy { $0 != nil } ? names.map { $0! } : nil
    }
    return nil
}

// MARK: - Pass 1: the ContextResolver declarations and their uses

struct ResolverInfo {
    var file: String
    var line: Int
    var readsContext: Bool
    var outputType: String?
    var entryUses: Set<String> = []
    var otherUses: [String] = []
}

final class DeclarationCollector: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    var found: [String: ResolverInfo] = [:]

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let inherits = node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "ContextResolver"
        } ?? false
        guard inherits else { return .visitChildren }
        var reads = false
        var output: String?
        for member in node.memberBlock.members {
            if let alias = member.decl.as(TypeAliasDeclSyntax.self), alias.name.text == "Output" {
                output = alias.initializer.value.trimmedDescription
            }
            if let function = member.decl.as(FunctionDeclSyntax.self), function.name.text == "resolve" {
                if output == nil { output = function.signature.returnClause?.type.trimmedDescription }
                let ctxName = function.signature.parameterClause.parameters.first.map {
                    ($0.secondName ?? $0.firstName).text
                } ?? "ctx"
                if let body = function.body {
                    reads = body.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .identifier(ctxName) }
                }
            }
        }
        found[node.name.text] = ResolverInfo(
            file: file,
            line: node.startLocation(converter: converter).line,
            readsContext: reads,
            outputType: output
        )
        return .visitChildren
    }
}

final class UseCollector: SyntaxVisitor {
    let file: String
    let names: Set<String>
    let converter: SourceLocationConverter
    var entryUses: [String: Set<String>] = [:]
    var otherUses: [String: [String]] = [:]

    init(file: String, tree: SourceFileSyntax, names: Set<String>) {
        self.file = file
        self.names = names
        converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        guard case .identifier(let text) = token.tokenKind, names.contains(text) else { return .visitChildren }
        // The declaration's own name, and references inside its own body.
        var node: Syntax? = token.parent
        var entry: String?
        while let current = node {
            if let decl = current.as(StructDeclSyntax.self), decl.name.text == text { return .visitChildren }
            if let labeled = current.as(LabeledExprSyntax.self), labeled.label?.text == "resolvers",
               let call = labeled.parent?.parent?.as(FunctionCallExprSyntax.self), let name = calleeName(call),
               entryNames.contains(name) {
                entry = name
                break
            }
            node = current.parent
        }
        if let entry {
            entryUses[text, default: []].insert(entry)
        } else if let member = token.parent?.parent?.as(MemberAccessExprSyntax.self),
                  member.base?.as(DeclReferenceExprSyntax.self)?.baseName.id == token.id,
                  !["self", "resolve"].contains(member.declName.baseName.text) {
            // A static member (a test's gate): the converted type keeps it.
        } else {
            otherUses[text, default: []].append("\(file):\(token.startLocation(converter: converter).line)")
        }
        return .visitChildren
    }
}

// MARK: - Pass 2: the rewrite

struct Listing {
    var lines: [String] = []
    mutating func add(_ file: String, _ line: Int, _ text: String) { lines.append("\(file):\(line): \(text)") }
}

/// Replaces `ctx.<name>` reads of resolver outputs with the outputs parameter.
final class OutputReads: SyntaxRewriter {
    let contextName: String
    let replacements: [String: String]
    var used: Set<String> = []

    init(contextName: String, replacements: [String: String]) {
        self.contextName = contextName
        self.replacements = replacements
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MemberAccessExprSyntax) -> ExprSyntax {
        if let base = node.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == contextName,
           let replacement = replacements[node.declName.baseName.text] {
            used.insert(node.declName.baseName.text)
            let expr: ExprSyntax = "\(raw: replacement)"
            return expr.with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)
        }
        return super.visit(node)
    }
}

final class Rewriter: SyntaxRewriter {
    let file: String
    let converter: SourceLocationConverter
    let resolvers: [String: ResolverInfo]
    let autoResolvers: Set<String>
    let values: [String: String]
    let restore: Set<Int>
    var listing: Listing
    var ordinal = 0
    var stripped = 0
    var restored = 0

    init(file: String, tree: SourceFileSyntax, resolvers: [String: ResolverInfo], autoResolvers: Set<String>, values: [String: String], restore: Set<Int>, listing: Listing) {
        self.file = file
        converter = SourceLocationConverter(fileName: file, tree: tree)
        self.resolvers = resolvers
        self.autoResolvers = autoResolvers
        self.values = values
        self.restore = restore
        self.listing = listing
        super.init(viewMode: .sourceAccurate)
    }

    func line(_ node: some SyntaxProtocol) -> Int { node.startLocation(converter: converter).line }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard autoResolvers.contains(node.name.text) else { return super.visit(node) }
        return convertResolver(node)
    }

    /// `struct X: ContextResolver { static func resolve(ctx: ResolverContext) … }` ->
    /// `@PlainData struct X: Resolver { typealias Dependencies = NoServices; func resolve(_ deps: NoServices) … }`.
    func convertResolver(_ node: StructDeclSyntax) -> DeclSyntax {
        var text = node.trimmedDescription
        let indent = String(node.leadingTrivia.description.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
        text = text.replacingOccurrences(
            of: #"struct (\w+)\s*:\s*ContextResolver"#, with: "struct $1: Resolver", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"static func resolve\(\s*ctx: ResolverContext\s*\)"#, with: "func resolve(_ deps: NoServices)",
            options: .regularExpression
        )
        let isPublic = node.modifiers.contains { $0.name.tokenKind == .keyword(.public) }
        if let open = text.firstIndex(of: "{") {
            let after = text.index(after: open)
            text.insert(contentsOf: "\n\(indent)    \(isPublic ? "public " : "")typealias Dependencies = NoServices", at: after)
        }
        text = "@PlainData\n\(indent)" + text
        let parsed = Parser.parse(source: text)
        guard let first = parsed.statements.first, let decl = Syntax(first.item).as(DeclSyntax.self) else {
            listing.add(file, line(node), "\(node.name.text): conversion didn't parse; not edited")
            return DeclSyntax(node)
        }
        return decl.with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        guard let entry = calleeName(node), entryNames.contains(entry) else { return super.visit(node) }
        ordinal += 1
        let myOrdinal = ordinal
        let callLine = line(node)
        guard let visited = super.visit(node).as(FunctionCallExprSyntax.self) else { return super.visit(node) }
        return ExprSyntax(rewriteEntry(visited, entry: entry, restoreCall: restore.contains(myOrdinal), callLine: callLine))
    }

    func rewriteEntry(_ call: FunctionCallExprSyntax, entry: String, restoreCall: Bool, callLine: Int) -> FunctionCallExprSyntax {
        var call = call
        // 1. The resolvers.
        var outputs: (names: [String], types: [String?])?
        if let index = call.arguments.firstIndex(where: { $0.label?.text == "resolvers" }),
           let names = metatypeNames(call.arguments[index].expression) {
            let types = names.map { resolvers[$0]?.outputType }
            if let arity = valueEntries[entry] {
                let blocked = names.filter { !autoResolvers.contains($0) && values[$0] == nil }
                if blocked.isEmpty {
                    let built = names.map { values[$0] ?? "\($0)()" }
                    let body = built.count == 1 ? built[0] : "(" + built.joined(separator: ", ") + ")"
                    let parameterNames = arity == 3 ? ["state", "action", "ctx"] : ["state", "ctx"]
                    let bodyTokens = Set(Parser.parse(source: body).tokens(viewMode: .sourceAccurate).map(\.text))
                    let parameters = parameterNames.map { bodyTokens.contains($0) ? $0 : "_" }.joined(separator: ", ")
                    let closure: ExprSyntax = "{ \(raw: parameters) in \(raw: body) }"
                    var argument = call.arguments[index]
                    argument.expression = closure.with(\.leadingTrivia, argument.expression.leadingTrivia)
                        .with(\.trailingTrivia, argument.expression.trailingTrivia)
                    call.arguments[index] = argument
                    outputs = (names, types)
                } else {
                    let reasons = blocked.map { name -> String in
                        guard let info = resolvers[name] else { return "\(name) (no declaration found)" }
                        var why: [String] = []
                        if info.readsContext { why.append("reads its context") }
                        if !info.otherUses.isEmpty { why.append("named elsewhere: \(info.otherUses.joined(separator: ", "))") }
                        let joins = info.entryUses.subtracting(valueEntries.keys)
                        if !joins.isEmpty { why.append("also on \(joins.sorted().joined(separator: ", "))") }
                        return "\(name) (\(why.joined(separator: "; ")))"
                    }
                    listing.add(file, callLine, "\(entry): resolvers not converted: \(reasons.joined(separator: ", "))")
                }
            } else if joinEntries[entry] != nil {
                outputs = (names, types)
            }
        }

        func strip(_ closure: ClosureExprSyntax, names: [String], typed: Bool, inserted: (name: String, type: String)?, restoreCall: Bool) -> ClosureExprSyntax {
            guard var signature = closure.signature, let clause = signature.parameterClause else { return closure }
            var closure = closure
            if typed && restoreCall {
                restored += 1
                // Keep the annotations: insert a typed outputs parameter where needed.
                guard let inserted, case .parameterClause(var parameters) = clause else { return closure }
                let at = min(outputIndex(entry), parameters.parameters.count)
                var list = Array(parameters.parameters)
                let parameter: ClosureParameterSyntax = ClosureParameterSyntax(
                    firstName: .identifier(inserted.name),
                    colon: .colonToken(trailingTrivia: .space),
                    type: TypeSyntax(stringLiteral: inserted.type),
                    trailingComma: .commaToken(trailingTrivia: .space)
                )
                list.insert(parameter, at: at)
                for i in list.indices {
                    list[i].trailingComma = i == list.count - 1 ? nil : .commaToken(trailingTrivia: .space)
                }
                parameters.parameters = ClosureParameterListSyntax(list)
                signature.parameterClause = .parameterClause(parameters)
                closure.signature = signature
                return closure
            }
            if typed { stripped += 1 }
            let leading: Trivia
            switch clause {
            case .simpleInput(let list): leading = list.first?.leadingTrivia ?? []
            case .parameterClause(let parameters): leading = parameters.leadingTrivia
            }
            if !typed, inserted == nil { return closure }
            let shorthand = ClosureShorthandParameterListSyntax(names.enumerated().map { i, name in
                ClosureShorthandParameterSyntax(
                    name: .identifier(name),
                    trailingComma: i == names.count - 1 ? nil : .commaToken(trailingTrivia: .space)
                )
            })
            signature.parameterClause = .simpleInput(shorthand.with(\.leadingTrivia, leading))
            if typed { signature.returnClause = nil }
            signature.inKeyword = signature.inKeyword.with(\.leadingTrivia, .space)
            if var effects = signature.effectSpecifiers {
                effects = effects.with(\.leadingTrivia, .space).with(\.trailingTrivia, [])
                signature.effectSpecifiers = effects
            }
            closure.signature = signature
            return closure
        }

        // 2. The handler closures.
        func process(_ closure: ClosureExprSyntax, role: String) -> ClosureExprSyntax {
            var closure = closure
            var names: [String]? = nil
            var typed = false
            if let clause = closure.signature?.parameterClause {
                switch clause {
                case .simpleInput(let list):
                    names = list.map(\.name.text)
                case .parameterClause(let parameters):
                    names = parameters.parameters.map { ($0.secondName ?? $0.firstName).text }
                    typed = parameters.parameters.contains { $0.type != nil }
                }
            }
            var inserted: (name: String, type: String)? = nil
            if let outputs {
                guard var current = names else {
                    listing.add(file, callLine, "\(entry) \(role): a closure without named parameters; outputs not added")
                    return closure
                }
                if let old = joinEntries[entry], current.count != old {
                    // Already has its outputs parameter (a re-run), or a shape this tool doesn't know.
                    return strip(closure, names: current, typed: typed, inserted: nil, restoreCall: restoreCall)
                }
                let contextName = current.last ?? "_"
                let properties = outputs.names.map(propertyName)
                var replacements: [String: String] = [:]
                let single = properties.count == 1
                for (i, property) in properties.enumerated() {
                    replacements[property] = single ? property : "resolved.\(i)"
                }
                var usedAny = false
                if contextName != "_", let body = Optional(closure.statements) {
                    let reads = OutputReads(contextName: contextName, replacements: replacements)
                    let rewritten = reads.rewrite(body).as(CodeBlockItemListSyntax.self) ?? body
                    usedAny = !reads.used.isEmpty
                    closure.statements = rewritten
                }
                let name = usedAny ? (single ? properties[0] : "resolved") : "_"
                let typeText = single
                    ? "\(outputs.types[0] ?? "\(outputs.names[0]).Output")?"
                    : "(" + zip(outputs.names, outputs.types).map { "\($1 ?? "\($0).Output")?" }.joined(separator: ", ") + ")"
                let at = min(outputIndex(entry), current.count)
                current.insert(name, at: at)
                names = current
                inserted = (name, typeText)
                _ = at
            }
            guard let names else { return closure }
            return strip(closure, names: names, typed: typed, inserted: inserted, restoreCall: restoreCall)
        }

        var arguments = Array(call.arguments)
        for i in arguments.indices {
            guard let closure = arguments[i].expression.as(ClosureExprSyntax.self) else { continue }
            let label = arguments[i].label?.text
            if label == "resolvers" { continue }
            arguments[i].expression = ExprSyntax(process(closure, role: label ?? "body"))
        }
        call.arguments = LabeledExprListSyntax(arguments)
        if let trailing = call.trailingClosure {
            call.trailingClosure = process(trailing, role: "body")
        }
        return call
    }
}

/// The entry calls of a file, in source order, with their line ranges.
final class EntryLocator: SyntaxVisitor {
    let converter: SourceLocationConverter
    var calls: [(ordinal: Int, start: Int, end: Int)] = []
    var ordinal = 0

    init(file: String, tree: SourceFileSyntax) {
        converter = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = calleeName(node), entryNames.contains(name) {
            ordinal += 1
            calls.append((ordinal, node.startLocation(converter: converter).line, node.endLocation(converter: converter).line))
        }
        return .visitChildren
    }
}

// MARK: - Main

func swiftFiles(under paths: [String]) -> [String] {
    var files: [String] = []
    for path in paths {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if !isDirectory.boolValue {
            if path.hasSuffix(".swift") { files.append(path) }
            continue
        }
        let enumerator = FileManager.default.enumerator(atPath: path)
        while let item = enumerator?.nextObject() as? String {
            if item.hasPrefix(".build") || item.contains("/.build/") { continue }
            if item.hasSuffix(".swift") { files.append((path as NSString).appendingPathComponent(item)) }
        }
    }
    return files.sorted()
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--locate" {
    for spec in arguments.dropFirst() {
        guard let colon = spec.lastIndex(of: ":"), let line = Int(spec[spec.index(after: colon)...]) else { continue }
        let path = String(spec[..<colon])
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let tree = Parser.parse(source: source)
        let locator = EntryLocator(file: path, tree: tree)
        locator.walk(tree)
        let containing = locator.calls.filter { $0.start <= line && line <= $0.end }
        if let innermost = containing.min(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            print("\(path)#\(innermost.ordinal)")
        } else {
            FileHandle.standardError.write(Data("no entry call at \(spec)\n".utf8))
        }
    }
    exit(0)
}

var dryRun = false
var restoreFile: String?
var valuesFile: String?
var reportFile: String?
var paths: [String] = []
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--dry-run": dryRun = true
    case "--restore": restoreFile = arguments.removeFirst()
    case "--values": valuesFile = arguments.removeFirst()
    case "--report": reportFile = arguments.removeFirst()
    default: paths.append(argument)
    }
}

var restoreByFile: [String: Set<Int>] = [:]
if let restoreFile, let text = try? String(contentsOfFile: restoreFile, encoding: .utf8) {
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "#")
        if parts.count == 2, let ordinal = Int(parts[1]) { restoreByFile[String(parts[0]), default: []].insert(ordinal) }
    }
}

var values: [String: String] = [:]
if let valuesFile, let data = FileManager.default.contents(atPath: valuesFile) {
    values = (try JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
}

/// The module a file belongs to, for telling apart resolvers of one name in two test targets:
/// `Tests/<target>`, `Sources/<target>`, or `Examples/<package>` (its targets import each other).
func moduleOf(_ file: String) -> String {
    file.split(separator: "/").prefix(2).joined(separator: "/")
}

let files = swiftFiles(under: paths)
var trees: [String: SourceFileSyntax] = [:]
/// Keyed by `module|name`.
var resolvers: [String: ResolverInfo] = [:]
for file in files {
    guard let source = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
    let tree = Parser.parse(source: source)
    trees[file] = tree
    let collector = DeclarationCollector(file: file, tree: tree)
    collector.walk(tree)
    for (plain, info) in collector.found {
        let name = moduleOf(file) + "|" + plain
        if let existing = resolvers[name] {
            FileHandle.standardError.write(Data("two declarations of \(name): \(existing.file):\(existing.line), \(info.file):\(info.line); neither is converted\n".utf8))
            resolvers[name]?.otherUses.append("\(info.file):\(info.line) (a second declaration)")
        } else {
            resolvers[name] = info
        }
    }
}
func plainNames(in module: String, of resolvers: [String: ResolverInfo]) -> Set<String> {
    Set(resolvers.keys.filter { $0.hasPrefix(module + "|") }.map { String($0.dropFirst(module.count + 1)) })
}
for file in files {
    guard let tree = trees[file] else { continue }
    let module = moduleOf(file)
    let uses = UseCollector(file: file, tree: tree, names: plainNames(in: module, of: resolvers))
    uses.walk(tree)
    for (name, entries) in uses.entryUses { resolvers[module + "|" + name]?.entryUses.formUnion(entries) }
    for (name, lines) in uses.otherUses { resolvers[module + "|" + name]?.otherUses += lines }
}
let autoResolvers = Set(resolvers.filter { _, info in
    !info.readsContext && info.otherUses.isEmpty && !info.entryUses.isEmpty
        && info.entryUses.isSubset(of: Set(valueEntries.keys))
}.keys)

var listing = Listing()
var changedFiles: [String] = []
var strippedTotal = 0
var restoredTotal = 0
for file in files {
    guard let tree = trees[file] else { continue }
    let module = moduleOf(file)
    var local: [String: ResolverInfo] = [:]
    for (key, info) in resolvers where key.hasPrefix(module + "|") { local[String(key.dropFirst(module.count + 1))] = info }
    let localAuto = Set(autoResolvers.filter { $0.hasPrefix(module + "|") }.map { String($0.dropFirst(module.count + 1)) })
    let rewriter = Rewriter(
        file: file, tree: tree, resolvers: local, autoResolvers: localAuto, values: values,
        restore: restoreByFile[file] ?? [], listing: listing
    )
    let rewritten = rewriter.rewrite(tree)
    listing = rewriter.listing
    strippedTotal += rewriter.stripped
    restoredTotal += rewriter.restored
    let text = rewritten.description
    if text != tree.description {
        changedFiles.append(file)
        if !dryRun { try text.write(toFile: file, atomically: true, encoding: .utf8) }
    }
}

for (key, info) in resolvers.sorted(by: { $0.key < $1.key }) where !autoResolvers.contains(key) {
    let name = String(key.split(separator: "|").last ?? "")
    if values[name] != nil { continue }
    let joins = info.entryUses.subtracting(valueEntries.keys)
    if !info.entryUses.isEmpty, joins == info.entryUses { continue }  // CanJoin/OnJoin/OnLeave only: stays until R3
    var why: [String] = []
    if info.readsContext { why.append("reads its context") }
    if !info.otherUses.isEmpty { why.append("named elsewhere: \(info.otherUses.joined(separator: ", "))") }
    if !joins.isEmpty { why.append("also on \(joins.sorted().joined(separator: ", "))") }
    if info.entryUses.isEmpty { why.append("on no entry") }
    listing.add(info.file, info.line, "resolver \(name) not converted: \(why.joined(separator: "; "))")
}

var report = listing.lines
report.append("summary: \(changedFiles.count) files changed, \(strippedTotal) closures stripped, \(restoredTotal) kept annotated (restore list), \(autoResolvers.count) resolvers converted, \(listing.lines.count) listed")
if dryRun { report.append(contentsOf: changedFiles.map { "would change: \($0)" }) }
let reportText = report.joined(separator: "\n") + "\n"
if let reportFile { try reportText.write(toFile: reportFile, atomically: true, encoding: .utf8) }
print(reportText, terminator: "")
