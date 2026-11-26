// Tests/SwiftStateTurnsMacrosTests/ModelHoldsLintTests.swift
//
// The model-holds rule (#881), on SwiftSyntax's tree. A turn body holds `LandKeeper.model` for
// its whole call: the keeper passes it `inout` to a closure (`withHandlerStep`, `withTurn`), and
// the functions that body calls take it as a `KeeperModel` parameter. While the hold is open, any
// other access to the actor's stored `model` overlaps it, and Swift's run-time exclusivity check
// stops the process, in release builds too. The compiler can't see it, and a test finds it only
// on a path the test runs. This rule checks every path, by name and argument labels.
//
// - A *holder* is a keeper member function with a parameter of type `KeeperModel<…>` (`inout` or
//   not), or a closure passed to a keeper member whose function-typed parameter takes a
//   `KeeperModel`. The type decides, not the name `m`.
// - A member *reaches* the model when its body names the stored `model` (`model` not shadowed
//   by a local or a parameter, or `self.model`), or when it calls or reads a member that does,
//   transitively. Overloads are told apart by their argument labels.
// - A holder must not name `model`, and must not call or read a member that reaches it, except
//   a holder overload called with the hold first (`f(&m, …)`, `f(m, …)`).
// - A closure passed in a call that also passes `&model` runs under that hold too: it's a
//   holder whatever the callee.
// - Not checked, because it runs after the hold ends: the body of a closure passed to
//   `Task { … }` or `Task.detached { … }`, and an `await` expression. A task's capture list is
//   checked: it's evaluated when the task is made, under the hold. Any other closure in a holder
//   (`forEach`, `map`, `removeAll(where:)`) is taken to run during it.
//
// Limits: a call through another receiver (`other.f()`, a port's witness that calls back into
// the keeper) isn't followed; the keeper's re-entry sentinel and `callOut` guard that path at
// run time. A member is matched by name, not by resolved declaration. The run-time check in the debug test suite stays the
// proof for the paths the tests run. Once the keeper's model moves into the turn core (#700
// K2-2), a re-entry goes through the core's borrow rule instead; K2-2 decides whether this rule
// moves to the facade's forwarding or is retired.

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// A member of the keeper, by name and, for a function, its argument labels (`_` for none).
struct KeeperMemberKey: Hashable, CustomStringConvertible {
    let name: String
    /// nil for a property.
    let labels: [String]?

    var description: String { name }
}

/// A place a body holds the model: its name, where it opens, and the names the hold goes by.
struct ModelHolder {
    let name: String
    let path: String
    let line: Int
    let holdNames: Set<String>
    let body: Syntax
    let converter: SourceLocationConverter
}

enum ModelHoldsLint {
    /// The allow marker for this rule: a `//` comment that starts with it, followed by a reason
    /// of at least ten characters, allows its line. Allowed under Tests/ only; the repository
    /// test refuses one in Sources/. Built in two parts, so this file holds no marker itself.
    static let marker = "// lint-" + "allow: model-holds:"

    static func isMarker(_ comment: String) -> Bool {
        guard comment.hasPrefix(marker) else { return false }
        return comment.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).count >= 10
    }

    /// The files the rule reads: Swift files under Runtime/ that declare the keeper or extend it.
    static func inScope(_ path: String, _ text: String) -> Bool {
        path.hasPrefix("Sources/SwiftStateTree/Runtime/") && text.contains("LandKeeper")
    }

    struct Report {
        var holders: [ModelHolder] = []
        /// `path:line: in <holder>: <why>`, by path and line.
        var findings: [String] = []
    }

    /// The rule over `files` (path, source) taken together: a member in one file may reach the
    /// model through a member in another.
    static func check(_ files: [(path: String, source: String)]) -> Report {
        var members: [KeeperMember] = []
        var marked: [String: Set<Int>] = [:]
        for file in files {
            let tree = Parser.parse(source: file.source)
            let converter = SourceLocationConverter(fileName: file.path, tree: tree)
            marked[file.path] = markedLines(tree, converter)
            for item in tree.statements {
                if let actor = item.item.as(ActorDeclSyntax.self), actor.name.text == "LandKeeper" {
                    collect(actor.memberBlock.members, file.path, converter, into: &members)
                } else if let ext = item.item.as(ExtensionDeclSyntax.self),
                          ext.extendedType.trimmedDescription.hasPrefix("LandKeeper") {
                    collect(ext.memberBlock.members, file.path, converter, into: &members)
                }
            }
        }
        let graph = MemberGraph(members)
        var report = Report()
        report.holders = graph.holders()
        var findings: Set<Finding> = []
        for holder in report.holders {
            let uses = UseVisitor(graph: graph, holdNames: holder.holdNames, root: holder.body)
            uses.walk(holder.body)
            for model in uses.modelReferences {
                let line = holder.converter.location(for: model.positionAfterSkippingLeadingTrivia).line
                guard !(marked[holder.path]?.contains(line) ?? false) else { continue }
                let hold = holder.holdNames.sorted().first ?? "the hold"
                findings.insert(Finding(path: holder.path, line: line, text: "in \(holder.name): names `model` while the hold is open; use `\(hold)`"))
            }
            for use in uses.uses {
                guard let reached = use.targets.sorted(by: { $0.name < $1.name }).first(where: graph.reaches.contains) else { continue }
                let line = holder.converter.location(for: use.at.positionAfterSkippingLeadingTrivia).line
                guard !(marked[holder.path]?.contains(line) ?? false) else { continue }
                let path = ([holder.name] + graph.path(from: reached)).joined(separator: " → ")
                findings.insert(Finding(path: holder.path, line: line, text: "in \(holder.name): `\(reached)` reaches the model while the hold is open: \(path)"))
            }
        }
        report.findings = findings.sorted { ($0.path, $0.line, $0.text) < ($1.path, $1.line, $1.text) }
            .map { "\($0.path):\($0.line): \($0.text)" }
        return report
    }

    private struct Finding: Hashable {
        let path: String
        let line: Int
        let text: String
    }

    /// The lines holding this rule's marker, from the tree's trivia.
    private static func markedLines(_ tree: SourceFileSyntax, _ converter: SourceLocationConverter) -> Set<Int> {
        var lines: Set<Int> = []
        for token in tree.tokens(viewMode: .sourceAccurate) {
            var position = token.position
            for piece in token.leadingTrivia {
                if case .lineComment(let text) = piece, isMarker(text) { lines.insert(converter.location(for: position).line) }
                position += piece.sourceLength
            }
            position = token.endPositionBeforeTrailingTrivia
            for piece in token.trailingTrivia {
                if case .lineComment(let text) = piece, isMarker(text) { lines.insert(converter.location(for: position).line) }
                position += piece.sourceLength
            }
        }
        return lines
    }

    private static func collect(_ list: MemberBlockItemListSyntax, _ path: String, _ converter: SourceLocationConverter,
                                into members: inout [KeeperMember]) {
        for item in list {
            if let config = item.decl.as(IfConfigDeclSyntax.self) {
                for clause in config.clauses {
                    if case .decls(let decls) = clause.elements { collect(decls, path, converter, into: &members) }
                }
            } else if let function = item.decl.as(FunctionDeclSyntax.self) {
                members.append(KeeperMember(function: function, path: path, converter: converter))
            } else if let variable = item.decl.as(VariableDeclSyntax.self) {
                let lazy = variable.modifiers.contains { $0.name.tokenKind == .keyword(.lazy) }
                for binding in variable.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    let body: Syntax? = binding.accessorBlock.map(Syntax.init) ?? (lazy ? binding.initializer.map(Syntax.init) : nil)
                    members.append(KeeperMember(property: name, body: body, path: path, converter: converter))
                }
            }
        }
    }
}

/// A keeper member: a function or a property, with the body that runs when it's used.
struct KeeperMember {
    let key: KeeperMemberKey
    let body: Syntax?
    let path: String
    let converter: SourceLocationConverter
    /// A function with a `KeeperModel` parameter: the names that parameter goes by.
    let holdNames: Set<String>
    /// The function-typed parameters that take a `KeeperModel`, by argument label: the index of
    /// that argument among the closure's parameters. A closure passed to one holds the model.
    let givesHold: [(label: String, index: Int)]

    var isHolder: Bool { !holdNames.isEmpty }

    init(function: FunctionDeclSyntax, path: String, converter: SourceLocationConverter) {
        let parameters = Array(function.signature.parameterClause.parameters)
        key = KeeperMemberKey(name: function.name.text, labels: parameters.map { $0.firstName.text })
        body = function.body.map(Syntax.init)
        self.path = path
        self.converter = converter
        holdNames = Set(parameters.filter { isKeeperModel($0.type) }.map { ($0.secondName ?? $0.firstName).text })
        givesHold = parameters.compactMap { parameter -> (label: String, index: Int)? in
            guard let function = unwrap(parameter.type).as(FunctionTypeSyntax.self),
                  let index = Array(function.parameters).firstIndex(where: { isKeeperModel($0.type) }) else { return nil }
            return (parameter.firstName.text, index)
        }
    }

    init(property: String, body: Syntax?, path: String, converter: SourceLocationConverter) {
        key = KeeperMemberKey(name: property, labels: nil)
        self.body = body
        self.path = path
        self.converter = converter
        holdNames = []
        givesHold = []
    }
}

/// `inout`, attributes and parentheses removed.
private func unwrap(_ type: TypeSyntax) -> TypeSyntax {
    if let attributed = type.as(AttributedTypeSyntax.self) { return unwrap(attributed.baseType) }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first { return unwrap(only.type) }
    return type
}

private func isKeeperModel(_ type: TypeSyntax) -> Bool {
    unwrap(type).as(IdentifierTypeSyntax.self)?.name.text == "KeeperModel"
}

/// The members, which of them reach the model, and how.
final class MemberGraph {
    let members: [KeeperMember]
    let byName: [String: [KeeperMember]]
    /// The members that reach the model.
    private(set) var reaches: Set<KeeperMemberKey> = []
    /// For a member that reaches the model through another, that other; absent when it names
    /// `model` itself.
    private var via: [KeeperMemberKey: KeeperMemberKey] = [:]

    init(_ members: [KeeperMember]) {
        self.members = members
        byName = Dictionary(grouping: members, by: \.key.name)
        var uses: [KeeperMemberKey: Set<KeeperMemberKey>] = [:]
        for member in members where !member.isHolder {
            guard let body = member.body else { continue }
            let visitor = UseVisitor(graph: self, holdNames: [], root: body)
            visitor.walk(body)
            if !visitor.modelReferences.isEmpty { reaches.insert(member.key) }
            uses[member.key, default: []].formUnion(visitor.uses.flatMap(\.targets))
        }
        var changed = true
        while changed {
            changed = false
            for (key, used) in uses.sorted(by: { $0.key.name < $1.key.name }) where !reaches.contains(key) {
                if let next = used.sorted(by: { $0.name < $1.name }).first(where: reaches.contains) {
                    reaches.insert(key)
                    via[key] = next
                    changed = true
                }
            }
        }
    }

    /// `key → … → model`.
    func path(from key: KeeperMemberKey) -> [String] {
        var out = [key.name]
        var current = key
        while let next = via[current], out.count < 64 {
            out.append(next.name)
            current = next
        }
        return out + ["model"]
    }

    /// The members a use of `name` may name. A call names the overloads its labels fit (every
    /// plain overload when none fits); a holder overload reached only with the hold isn't a use.
    /// A bare name is a property of that name, or else a function passed as a value.
    func targets(_ name: String, callLabels: [String]?, trailingClosures: Int) -> Set<KeeperMemberKey> {
        guard let candidates = byName[name] else { return [] }
        let properties = candidates.filter { $0.key.labels == nil }
        let functions = candidates.filter { $0.key.labels != nil }
        guard let callLabels else {
            if !properties.isEmpty { return Set(properties.map(\.key)) }
            return Set(functions.filter { !$0.isHolder }.map(\.key))
        }
        var fitting = functions.filter { fits(callLabels, trailingClosures, $0.key.labels ?? []) }
        // An overload whose parameters the call fills exactly wins over one that needs defaults.
        let exact = fitting.filter { ($0.key.labels ?? []).count == callLabels.count + trailingClosures }
        if !exact.isEmpty { fitting = exact }
        if fitting.isEmpty {
            // A stored closure property called as a function: a read of the property.
            if !properties.isEmpty { return Set(properties.map(\.key)) }
            return Set(functions.filter { !$0.isHolder }.map(\.key))
        }
        return Set(fitting.filter { !$0.isHolder }.map(\.key))
    }

    func hasHolderOverload(_ name: String) -> Bool {
        byName[name]?.contains(where: \.isHolder) ?? false
    }

    /// The closure parameters a member gives the model to, by argument label; nil when it gives
    /// none.
    func givesHold(_ name: String) -> [(label: String, index: Int)]? {
        let given = byName[name]?.flatMap(\.givesHold) ?? []
        return given.isEmpty ? nil : given
    }

    /// Whether a call's labels can bind to a declaration's: each call label in order matches a
    /// declared one, and the declared ones skipped are defaulted or taken by trailing closures.
    /// Defaults aren't read, so a skipped label is allowed anywhere.
    private func fits(_ call: [String], _ trailing: Int, _ declared: [String]) -> Bool {
        guard call.count + trailing <= declared.count else { return false }
        var index = declared.startIndex
        for label in call {
            guard let found = declared[index...].firstIndex(of: label) else { return false }
            index = found + 1
        }
        return true
    }

    /// Every holder: the functions that take the model, and the closures passed where a closure
    /// is given the model.
    func holders() -> [ModelHolder] {
        var out: [ModelHolder] = []
        for member in members {
            guard let body = member.body else { continue }
            if member.isHolder {
                let line = member.converter.location(for: body.positionAfterSkippingLeadingTrivia).line
                out.append(ModelHolder(name: member.key.name, path: member.path, line: line, holdNames: member.holdNames,
                                       body: body, converter: member.converter))
            }
            let finder = HoldClosureFinder(graph: self)
            finder.walk(body)
            for (giver, index, closure) in finder.found {
                let line = member.converter.location(for: closure.positionAfterSkippingLeadingTrivia).line
                out.append(ModelHolder(name: "\(giver) body in \(member.key.name)", path: member.path, line: line,
                                       holdNames: index.map { [closureParameterName(closure, at: $0)] } ?? [],
                                       body: Syntax(closure), converter: member.converter))
            }
        }
        return out.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }
}

private func closureParameterName(_ closure: ClosureExprSyntax, at index: Int) -> String {
    switch closure.signature?.parameterClause {
    case .simpleInput(let names):
        let list = Array(names)
        return index < list.count ? list[index].name.text : "$\(index)"
    case .parameterClause(let clause):
        let list = Array(clause.parameters)
        return index < list.count ? (list[index].secondName ?? list[index].firstName).text : "$\(index)"
    case nil:
        return "$\(index)"
    }
}

/// The name a call's callee gives a keeper member: `f(…)` or `self.f(…)`.
private func calleeName(_ expression: ExprSyntax) -> String? {
    if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
    if let member = expression.as(MemberAccessExprSyntax.self),
       member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) {
        return member.declName.baseName.text
    }
    return nil
}

/// Whether a call starts a task (`Task { … }`, `Task.detached { … }`, `Task<…>(…) { … }`).
private func isTaskCall(_ call: FunctionCallExprSyntax) -> Bool {
    var callee = call.calledExpression
    if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base { callee = base }
    if let generic = callee.as(GenericSpecializationExprSyntax.self) { callee = generic.expression }
    return callee.as(DeclReferenceExprSyntax.self)?.baseName.text == "Task"
}

/// A call's closure arguments, with the label each binds to (nil for the first trailing one).
private func labelledClosures(of call: FunctionCallExprSyntax) -> [(label: String?, closure: ClosureExprSyntax)] {
    call.arguments.compactMap { argument in
        argument.expression.as(ClosureExprSyntax.self).map { (argument.label?.text ?? "_", $0) }
    }
        + [call.trailingClosure].compactMap { $0 }.map { (nil, $0) }
        + call.additionalTrailingClosures.map { ($0.label.text, $0.closure) }
}

/// The closures passed to a member that gives them the model.
private final class HoldClosureFinder: SyntaxVisitor {
    let graph: MemberGraph
    var found: [(giver: String, index: Int?, closure: ClosureExprSyntax)] = []

    init(graph: MemberGraph) {
        self.graph = graph
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let name = calleeName(node.calledExpression), let given = graph.givesHold(name) {
            // A labelled closure takes the parameter of its label; a trailing one, the last.
            for (label, closure) in labelledClosures(of: node) {
                let parameter = given.last { $0.label == label } ?? (label == nil ? given.last : nil)
                if let parameter { found.append((name, parameter.index, closure)) }
            }
        } else if node.arguments.contains(where: { passesModel($0.expression) }) {
            let name = node.calledExpression.trimmedDescription
            for (_, closure) in labelledClosures(of: node) { found.append((name, nil, closure)) }
        }
        return .visitChildren
    }

    /// `&model` or `&self.model`.
    private func passesModel(_ expression: ExprSyntax) -> Bool {
        guard let inner = expression.as(InOutExprSyntax.self)?.expression else { return false }
        if let reference = inner.as(DeclReferenceExprSyntax.self) { return reference.baseName.text == "model" }
        return calleeName(inner) == "model"
    }
}

/// One use of a member in a body.
struct MemberUse {
    let at: Syntax
    let targets: Set<KeeperMemberKey>
}

/// The uses of `model` and of keeper members in a body, outside tasks and `await`.
final class UseVisitor: SyntaxVisitor {
    let graph: MemberGraph
    let holdNames: Set<String>
    let root: Syntax
    var modelReferences: [Syntax] = []
    var uses: [MemberUse] = []

    init(graph: MemberGraph, holdNames: Set<String>, root: Syntax) {
        self.graph = graph
        self.holdNames = holdNames
        self.root = root
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard isTaskCall(node) else { return .visitChildren }
        // The task's body runs later; its capture list is evaluated now, under the hold.
        for (_, closure) in labelledClosures(of: node) {
            for capture in closure.signature?.capture?.items ?? [] {
                if let initializer = capture.initializer { walk(initializer) }
            }
        }
        return .skipChildren
    }

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        guard node.baseName.tokenKind != .keyword(.self) else { return .visitChildren }
        // The node a use is: the reference, or `self.name` around it.
        var use = Syntax(node)
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
            // `x.name`: a keeper member only through `self`.
            guard member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) else { return .visitChildren }
            use = Syntax(member)
        } else if Shadowing.binds(name, above: Syntax(node), within: root) {
            return .visitChildren
        }
        if name == "model" {
            modelReferences.append(use)
            return .visitChildren
        }
        guard graph.byName[name] != nil else { return .visitChildren }
        if let call = use.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == use.id {
            if graph.hasHolderOverload(name), let first = call.arguments.first?.expression, passesHold(first) {
                return .visitChildren
            }
            let labels = call.arguments.map { $0.label?.text ?? "_" }
            let trailing = (call.trailingClosure == nil ? 0 : 1) + call.additionalTrailingClosures.count
            uses.append(MemberUse(at: use, targets: graph.targets(name, callLabels: labels, trailingClosures: trailing)))
        } else {
            uses.append(MemberUse(at: use, targets: graph.targets(name, callLabels: nil, trailingClosures: 0)))
        }
        return .visitChildren
    }

    /// `m` or `&m`, where `m` is the hold.
    private func passesHold(_ expression: ExprSyntax) -> Bool {
        let inner = expression.as(InOutExprSyntax.self)?.expression ?? expression
        guard let reference = inner.as(DeclReferenceExprSyntax.self) else { return false }
        return holdNames.contains(reference.baseName.text)
    }
}

/// Whether a name is bound by a local or a parameter in scope at a reference.
enum Shadowing {
    static func binds(_ name: String, above node: Syntax, within root: Syntax) -> Bool {
        var child = node
        while let parent = child.parent {
            if bound(by: parent, before: child).contains(name) { return true }
            if parent.id == root.id { break }
            child = parent
        }
        // A function's or an accessor's parameters, when the root is its body.
        if let function = root.parent?.as(FunctionDeclSyntax.self) {
            return function.signature.parameterClause.parameters.contains { ($0.secondName ?? $0.firstName).text == name }
        }
        return false
    }

    /// The names `parent` binds where `child` sits in it.
    private static func bound(by parent: Syntax, before child: Syntax) -> Set<String> {
        if let items = parent.as(CodeBlockItemListSyntax.self) {
            var names: Set<String> = []
            for item in items where item.endPosition <= child.position {
                if let variable = item.item.as(VariableDeclSyntax.self) {
                    for binding in variable.bindings { names.formUnion(patternNames(binding.pattern)) }
                } else if let function = item.item.as(FunctionDeclSyntax.self) {
                    names.insert(function.name.text)
                } else if let guardStatement = item.item.as(GuardStmtSyntax.self) {
                    names.formUnion(conditionNames(guardStatement.conditions, before: nil))
                }
            }
            return names
        }
        if let conditions = parent.as(ConditionElementListSyntax.self) {
            return conditionNames(conditions, before: child)
        }
        if let ifExpression = parent.as(IfExprSyntax.self), ifExpression.body.id == child.id {
            return conditionNames(ifExpression.conditions, before: nil)
        }
        if let whileStatement = parent.as(WhileStmtSyntax.self), whileStatement.body.id == child.id {
            return conditionNames(whileStatement.conditions, before: nil)
        }
        if let forStatement = parent.as(ForStmtSyntax.self), forStatement.body.id == child.id {
            return patternNames(forStatement.pattern)
        }
        if let switchCase = parent.as(SwitchCaseSyntax.self), switchCase.statements.id == child.id,
           case .case(let label) = switchCase.label {
            return label.caseItems.reduce(into: []) { $0.formUnion(patternNames($1.pattern)) }
        }
        if let catchClause = parent.as(CatchClauseSyntax.self), catchClause.body.id == child.id {
            let names = catchClause.catchItems.reduce(into: Set<String>()) { names, item in
                if let pattern = item.pattern { names.formUnion(patternNames(pattern)) }
            }
            return catchClause.catchItems.isEmpty ? ["error"] : names
        }
        // A closure's parameters and captures are bound in its statements, not in its capture list.
        if let closure = parent.as(ClosureExprSyntax.self), closure.statements.id == child.id, let signature = closure.signature {
            var names: Set<String> = []
            switch signature.parameterClause {
            case .simpleInput(let list): names.formUnion(list.map(\.name.text))
            case .parameterClause(let clause): names.formUnion(clause.parameters.map { ($0.secondName ?? $0.firstName).text })
            case nil: break
            }
            for capture in signature.capture?.items ?? [] { names.insert(capture.name.text) }
            return names
        }
        return []
    }

    private static func conditionNames(_ conditions: ConditionElementListSyntax, before child: Syntax?) -> Set<String> {
        var names: Set<String> = []
        for element in conditions {
            if let child, element.endPosition > child.position { break }
            switch element.condition {
            case .optionalBinding(let binding): names.formUnion(patternNames(binding.pattern))
            case .matchingPattern(let matching): names.formUnion(patternNames(matching.pattern))
            default: break
            }
        }
        return names
    }

    private static func patternNames(_ pattern: some SyntaxProtocol) -> Set<String> {
        let finder = PatternNameFinder(viewMode: .sourceAccurate)
        finder.walk(pattern)
        return finder.names
    }
}

private final class PatternNameFinder: SyntaxVisitor {
    var names: Set<String> = []

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }
}

// MARK: - Tests

/// The repository's root, from this file's path.
private let modelHoldsRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The text helper's self-test (scripts/lint-model-holds.py, K1b-5a step 2), ported.
private let modelHoldsFixture = #"""
actor LandKeeper<State> {
    private var model: KeeperModel<State>

    private func withTurn<R>(_ body: (inout KeeperModel<State>) -> R) -> R {
        body(&model)
    }

    private func touches() { model.count += 1 }

    private func reachesThroughACall() { touches() }

    private var readsTheModel: Int { model.count }

    private var shared: Int { 0 }

    private func shared(_ n: Int) -> Int { model.count + n }

    private func clean() {}

    private func lookup(of id: Int) -> Int { model.count + id }

    private func lookup(of id: Int, entry: Int) -> Int { entry }

    private nonisolated var submitter: Submitter {
        Submitter { [weak self] in await self?.touches() }
    }

    private func overloadAndAsync(_ m: inout KeeperModel<State>) {
        let x = lookup(of: 1, entry: 2)
        let s = submitter
    }

    private func badLabelledOverload(_ m: inout KeeperModel<State>) {
        let x = lookup(of: 1)
    }

    private func logsAName(_ m: inout KeeperModel<State>) {
        log("touches() reachesThroughACall")
    }

    private func badInterpolation(_ m: inout KeeperModel<State>) {
        log("count: \(model.count)")
    }

    private func helper() { helper(&model) }

    private func helper(_ m: inout KeeperModel<State>) { m.count += 1 }

    private func goodHolder(_ m: inout KeeperModel<State>) {
        // model is named in a comment only.
        helper(&m)
        clean()
        let s = shared
        Task { await self.touches() }
        drainTask = Task {
            self.model.count = 0
        }
    }

    private func badDirect(_ m: inout KeeperModel<State>) {
        model.count += 1
    }

    private func badTransitive(_ m: inout KeeperModel<State>) {
        reachesThroughACall()
    }

    private func badOverload(_ m: KeeperModel<State>) {
        helper()
    }

    private func badProperty(_ m: inout KeeperModel<State>) {
        let n = readsTheModel
    }

    func entry() {
        withTurn { m in
            helper(&m)
        }
        withTurn { m in
            touches()
        }
    }
}
"""#

/// A keeper with one holder whose body is `body`.
private func holderFixture(_ body: String) -> String {
    """
    actor LandKeeper<State> {
        private var model: KeeperModel<State>
        private var maybe: Int? { nil }
        private func touches() { model.count += 1 }
        private var count: Int { model.count }
        private func holder(_ m: inout KeeperModel<State>) {
    \(body)
        }
    }
    """
}

@Suite("Model-holds rule (lint on SwiftSyntax)")
struct ModelHoldsLintTests {
    @Test("The text helper's fixture: the same findings, one per bad holder, with the path that reaches the model")
    func helperFixture() {
        let report = ModelHoldsLint.check([(path: "LandKeeper.swift", source: modelHoldsFixture)])
        let holders = Set(report.holders.map(\.name))
        #expect(Set(["goodHolder", "helper", "logsAName", "overloadAndAsync", "withTurn body in entry"]).isSubset(of: holders))
        // `path:line: in <holder>: …`: one finding per bad holder, none in the clean ones.
        let failed = report.findings.map { $0.split(separator: ":")[2].trimmingCharacters(in: .whitespaces) }
        #expect(failed.sorted() == ["in badDirect", "in badInterpolation", "in badLabelledOverload", "in badOverload",
                                    "in badProperty", "in badTransitive", "in withTurn body in entry"],
                "\(report.findings.joined(separator: "\n"))")
        #expect(report.findings.contains { $0.hasSuffix("badTransitive → reachesThroughACall → touches → model") },
                "\(report.findings.joined(separator: "\n"))")
    }

    @Test("Cases a text reader gets wrong", arguments: [
        // A local named `model`, and a closure parameter named `model`: not the stored property.
        ("let model = 3\n_ = model", 0),
        ("_ = [1].map { model in model }", 0),
        ("if let model = maybe { _ = model }", 0),
        ("if let model = maybe {}\n_ = model", 1),
        // In an interpolation it's code; in a multi-line raw string and in a nested comment it isn't.
        ("_ = \"count: \\(model.count)\"", 1),
        ("let text = #\"\"\"\n    model.count\n    \"\"\"#\n_ = text", 0),
        ("/* outer /* model */ touches() */", 0),
        // A local that shares a member's name, and a member through another receiver.
        ("let touches = 1\n_ = touches", 0),
        ("other.touches()", 0),
        // Through `self`, as a property, as a function value.
        ("self.touches()", 1),
        ("_ = count", 1),
        ("let f = touches", 1),
        // A task's body runs after the hold.
        ("Task.detached { self.touches() }", 0),
        ("Task<Void, Never> { self.touches() }", 0),
        // A task's capture list is evaluated under the hold; a capture binds only the body.
        ("Task { [n = self.model.count] in _ = n }", 1),
        ("_ = { [n = model.count] in n }", 1),
        ("_ = { [model = maybe] in model }", 0),
        // A closure that runs during the hold, and a use after `await`.
        ("[1].forEach { _ in touches() }", 1),
        ("await touches()", 0),
    ])
    func syntaxCases(body: String, expected: Int) {
        let report = ModelHoldsLint.check([(path: "LandKeeper.swift", source: holderFixture(body))])
        #expect(report.findings.count == expected, "\(report.findings.joined(separator: "\n"))")
    }

    @Test("A parameter that shares a member's name, and a closure passed beside `&model`")
    func parametersAndClosuresBesideTheModel() {
        let parameter = ModelHoldsLint.check([(path: "LandKeeper.swift", source: """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private func touches() { model.count += 1 }
            private func holder(_ m: inout KeeperModel<State>, touches: Int) { _ = touches }
        }
        """)])
        #expect(parameter.findings.isEmpty, "\(parameter.findings.joined(separator: "\n"))")
        // `run` isn't a keeper member, and its closure's type isn't read: passed with `&model`,
        // the closure runs under the hold.
        let beside = ModelHoldsLint.check([(path: "LandKeeper.swift", source: """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private func touches() { model.count += 1 }
            private func plain() { other.run(&model) { touches() } }
            private func two(_ a: (inout KeeperModel<State>) -> Void, then b: (Int, inout KeeperModel<State>) -> Void) {}
            private func both() {
                two({ m in touches() },
                    then: { n, m in touches() })
            }
        }
        """)])
        // One finding per line: the two closures of `both` are on lines of their own.
        #expect(beside.findings.count == 3, "\(beside.findings.joined(separator: "\n"))")
        #expect(Set(beside.holders.flatMap(\.holdNames)) == ["m"])
    }

    @Test("A marker with a reason allows its line; a marker without one doesn't")
    func marker() {
        let allowed = ModelHoldsLint.check([(path: "LandKeeper.swift", source: holderFixture("touches() \(ModelHoldsLint.marker) the fixture shows a marked line"))])
        #expect(allowed.findings.isEmpty, "\(allowed.findings.joined(separator: "\n"))")
        let bare = ModelHoldsLint.check([(path: "LandKeeper.swift", source: holderFixture("touches() \(ModelHoldsLint.marker) x"))])
        #expect(bare.findings.count == 1)
    }

    /// The keeper's files, read from the repository.
    private func keeperFiles() throws -> [(path: String, source: String)] {
        try swiftFiles(under: modelHoldsRepositoryRoot, in: ["Sources/SwiftStateTree/Runtime"]).compactMap { path in
            let text = try String(contentsOf: modelHoldsRepositoryRoot.appendingPathComponent(path), encoding: .utf8)
            return ModelHoldsLint.inScope(path, text) ? (path, text) : nil
        }
    }

    @Test("The repository: no holder touches the keeper's model outside its hold")
    func repository() throws {
        let files = try keeperFiles()
        // A path change that finds nothing would pass vacuously.
        try #require(files.contains { $0.path == "Sources/SwiftStateTree/Runtime/LandKeeper.swift" })
        let report = ModelHoldsLint.check(files)
        #expect(report.holders.count >= 10, "found \(report.holders.count) holders")
        #expect(report.findings.isEmpty, "\(report.findings.joined(separator: "\n"))")
        for file in files {
            #expect(!file.source.contains(ModelHoldsLint.marker), "\(file.path): a model-holds marker is allowed under Tests/ only")
        }
    }

    @Test("The repository with `model` named in its first holder: found, at that line")
    func repositoryMutant() throws {
        let files = try keeperFiles()
        let report = ModelHoldsLint.check(files)
        let first = try #require(report.holders.first)
        let mutated = files.map { file -> (path: String, source: String) in
            guard file.path == first.path else { return file }
            var lines = file.source.components(separatedBy: "\n")
            lines.insert("        _ = model.players.count", at: first.line)
            return (file.path, lines.joined(separator: "\n"))
        }
        let found = ModelHoldsLint.check(mutated).findings
        #expect(found == ["\(first.path):\(first.line + 1): in \(first.name): names `model` while the hold is open; use `\(first.holdNames.sorted()[0])`"],
                "\(found.joined(separator: "\n"))")
    }
}
