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
// The bare-port rule rides on the same holders and members. A port is a value of a
// `LandKeeper…Transport` or `LandKeeper…Port` type: the keeper's port properties, and the locals
// and parameters bound to one. A member access on a port is a call out of the keeper, and the
// port may call back in. Inside a holder it must go through `callOut` (flush, check, call,
// check), so a holder must not make one outside a closure passed to `callOut`, directly or
// through a member that does (a computed property such as `syncsInTurn` included). A
// `// lint-allow: bare-port: <reason>` marker on the call's line allows it, in Sources/ too.
// A closure passed to `callOut` is the call-out's own, and its port calls aren't findings; so
// is one passed to `callOut` on the hold (`m.callOut(…)`, the model's call-out).
//
// Limits: a call through another receiver (`other.f()`, a port's witness that calls back into
// the keeper) isn't followed; the bare-port rule makes every port call in a hold go through
// `callOut`, whose checks catch that re-entry at run time. A member is matched by name, not by
// resolved declaration. The port tracker reads bindings, not types: a local is a port by how
// it's bound, anywhere in its member, and it doesn't see a port that comes out of an operator
// (`transport ?? boundSyncRequester`), out of a tuple (`let (gate, port) = …`), or through a
// port passed to a helper that isn't a keeper member (`audit(port)`). The run-time check in the debug test suite stays the
// proof for the paths the tests run. Once the keeper's model moves into the turn core (#700
// K2-2), a re-entry goes through the core's borrow rule instead; K2-2 decides whether this rule
// moves to the facade's forwarding or is retired.

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

/// The type a member is declared on (#700 K1b-5 C5): the keeper, its model, or the turn side.
/// A model member's hold is `self`; a side member is reached from a hold through the side.
enum KeeperOwner: Hashable {
    case keeper, model, side

    /// The owner a declaration's type name gives, or nil for a type the rule doesn't read.
    init?(typeName: String) {
        switch typeName {
        case "LandKeeper": self = .keeper
        case "KeeperModel": self = .model
        case "KeeperTurnSide": self = .side
        default: return nil
        }
    }
}

/// A member of the keeper, by name and, for a function, its argument labels (`_` for none).
struct KeeperMemberKey: Hashable, CustomStringConvertible {
    let name: String
    /// nil for a property.
    let labels: [String]?
    var owner: KeeperOwner = .keeper

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
    /// The member the holder is in, for the names that hold a port there.
    let scope: Syntax
    /// A closure passed to `callOut`: the port calls it makes are the call-out's own.
    let isCallOut: Bool
    /// The type the holder's member is declared on.
    var owner: KeeperOwner = .keeper
}

enum ModelHoldsLint {
    /// The allow marker for this rule: a `//` comment that starts with it, followed by a reason
    /// of at least ten characters, allows its line. Allowed under Tests/ only; the repository
    /// test refuses one in Sources/. Built in two parts, so this file holds no marker itself.
    static let marker = "// lint-" + "allow: model-holds:"

    static func isMarker(_ comment: String) -> Bool { hasReason(comment, after: marker) }

    /// The bare-port rule's marker (#884's review, agreed with the step-2 work): a port call on
    /// its line is allowed without `callOut`. The line is the port access itself (in a holder or
    /// a member a holder reaches), or a holder's call of a member that reaches the port. Allowed
    /// in Sources/, with a reason that says why the call can't go through `callOut`.
    static let portMarker = "// lint-" + "allow: bare-port:"

    static func isPortMarker(_ comment: String) -> Bool { hasReason(comment, after: portMarker) }

    /// The side-store rule's exceptions (#700 K2-1): the step frame, the only members whose own
    /// bodies borrow a core's `KeeperSideStore`, by file and name, each with its reason. A closure
    /// holder inside one is checked on its own. The repository test checks that each one exists.
    static let sideStoreFrame: [String: String] = [
        "handle": "the machine's step entry: reads the box from the behavior and passes it to the step",
        "answer": "the machine's query entry: the same, for queries",
        "answerQuery": "the query's routes: each intake as a step",
        "step": "the turn frame: borrows the side for the body, the flush and the late re-entry",
        "tickDueStep": "the tick's driver segments (tickAdmit, tickStart, tickEnd, debugEndWork) around its steps",
        "syncDueStep": "the sync loop's driver segments (the handler, the fold decision, the failure guard) around its step",
        "ticklessTickStep": "the tickless tick's driver segments (tickAdmit, scheduleInputDrain, debugEndWork)",
        "inputDrainStep": "the input drain's loop: the batch, the record's submission and the waiters' resume around its steps",
        "stepSubmitting": "the turn frame, returning the submission: borrows the side for the body, the flush and the late re-entry",
        "joinDrive": "the join's driver loop: its segments as steps, the transport's admission between two of them, its awaits as runs or waits",
        "joinStepped": "the join's resumes after its resolvers: the next segment as a step, or the rollback and the end",
        "finishJoin": "the join's end: the reservation's end as a step, then the reply",
        "leaveDrive": "the leave's driver: its next await as a run or a wait, or its end",
        "continueAfterLeave": "a leave's end: the reply, or the kicking join's J3 and the rest of the join",
        "awaitCoreInputTurn": "a flow's input-turn wait: kept on the side, with the drain's schedule",
        "answerCoreInputWaits": "the recorded turn's waits, answered in batch order",
        "answerCoreInputWait": "one wait's answer: the join's end, or the leave's L3 as a step and its continuation",
        "runCoreJobEffects": "the job lane's starts, releases and slot replies a step left on the side, as effects and replies",
        "answerDroppedCoreInputWaits": "the waits a drop failed, taken off the side and answered landClosed",
        "actionStep": "a tickless action's driver: the closed-land check, the intake as a step, the dropped-input check, its wait",
        "clientEventStep": "a tickless client event's driver: the closed-land check, the intake as a step, the dropped-input check, its wait",
        "holdAtFreezeBarrier": "the freeze's barrier in an intake's step: the held intake goes on the side",
        "releaseCoreHeldIntakes": "the barrier's release: the held intakes taken off the side and stepped again",
        "acceptsSyncTurnState": "a sync query's land check before its frame: reads the side's failure and drain flag, outside any body",
        "initializeDrive": "the initialization's driver loop: each request as an effect, a step, an owner output, or the waiters' answer",
        "answerInitializationWaits": "the initialization's end: its waiters answered, outside any body, after the step that ended it",
        "initializationAnswer": "a waiter's answer once the initialization ended: reads the side's failure by the model's ID, outside any body",
    ]
    static let sideStoreFramePath = "Sources/SwiftStateTree/Runtime/KeeperMachine.swift"

    private static func hasReason(_ comment: String, after marker: String) -> Bool {
        guard comment.hasPrefix(marker) else { return false }
        return comment.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).count >= 10
    }

    /// The files the rule reads: Swift files under Sources/ that declare or extend the keeper,
    /// its model or its turn side, by declaration (#700 K1b-5 C5): a file's text that merely
    /// names one isn't enough, and a declaration in a file that never says `LandKeeper` counts.
    static func inScope(_ path: String, _ text: String) -> Bool {
        guard path.hasPrefix("Sources/") else { return false }
        let tree = Parser.parse(source: text)
        return tree.statements.contains { declaredOwner($0.item) != nil }
    }

    /// The owner a top-level declaration declares or extends.
    static func declaredOwner(_ item: CodeBlockItemSyntax.Item) -> (owner: KeeperOwner, members: MemberBlockItemListSyntax)? {
        if let actor = item.as(ActorDeclSyntax.self), let owner = KeeperOwner(typeName: actor.name.text) {
            return (owner, actor.memberBlock.members)
        }
        if let type = item.as(StructDeclSyntax.self), let owner = KeeperOwner(typeName: type.name.text) {
            return (owner, type.memberBlock.members)
        }
        if let ext = item.as(ExtensionDeclSyntax.self), let name = ext.extendedType.as(IdentifierTypeSyntax.self)?.name.text,
           let owner = KeeperOwner(typeName: name) {
            return (owner, ext.memberBlock.members)
        }
        return nil
    }

    struct Report {
        var holders: [ModelHolder] = []
        /// The members that give a closure the model: each holder family's name.
        var givers: [String] = []
        var graph: MemberGraph?
        /// `path:line: in <holder>: <why>`, by path and line.
        var findings: [String] = []
    }

    /// The rule over `files` (path, source) taken together: a member in one file may reach the
    /// model through a member in another.
    static func check(_ files: [(path: String, source: String)]) -> Report {
        var members: [KeeperMember] = []
        var marked: [String: Set<Int>] = [:]
        var portMarked: [String: Set<Int>] = [:]
        for file in files {
            let tree = Parser.parse(source: file.source)
            let converter = SourceLocationConverter(fileName: file.path, tree: tree)
            marked[file.path] = markedLines(tree, converter, isMarker)
            portMarked[file.path] = markedLines(tree, converter, isPortMarker)
            for item in tree.statements {
                if let (owner, list) = declaredOwner(item.item) {
                    collect(list, file.path, converter, owner: owner, into: &members)
                }
            }
        }
        let graph = MemberGraph(members, portMarked: portMarked)
        var report = Report()
        report.holders = graph.holders()
        report.givers = Set(members.filter { !$0.givesHold.isEmpty }.map(\.key.name)).sorted()
        report.graph = graph
        var findings: Set<Finding> = []
        for holder in report.holders {
            let sideNames = graph.sideNames(in: holder.scope, owner: holder.owner)
            let uses = UseVisitor(graph: graph, holdNames: holder.holdNames, root: holder.body,
                                  portNames: PortNames.of(holder.scope, properties: graph.portProperties(of: holder.owner, sideNames: sideNames)),
                                  sideNames: sideNames,
                                  portMarked: portMarked[holder.path] ?? [], converter: holder.converter, owner: holder.owner)
            uses.walk(holder.body)
            for model in uses.modelReferences {
                let line = holder.converter.location(for: model.positionAfterSkippingLeadingTrivia).line
                guard !(marked[holder.path]?.contains(line) ?? false) else { continue }
                let hold = holder.holdNames.sorted().first ?? "the hold"
                let named = model.lastToken(viewMode: .sourceAccurate)?.text ?? "model"
                let use = named == "turnSide" ? "side" : hold
                findings.insert(Finding(path: holder.path, line: line, text: "in \(holder.name): names `\(named)` while the hold is open; use `\(use)`"))
            }
            for use in uses.uses {
                guard let reached = use.targets.sorted(by: { $0.name < $1.name }).first(where: graph.reaches.contains) else { continue }
                let line = holder.converter.location(for: use.at.positionAfterSkippingLeadingTrivia).line
                guard !(marked[holder.path]?.contains(line) ?? false) else { continue }
                let path = ([holder.name] + graph.path(from: reached)).joined(separator: " → ")
                findings.insert(Finding(path: holder.path, line: line, text: "in \(holder.name): `\(reached)` reaches the model while the hold is open: \(path)"))
            }
            // The side-store rule (#700 K2-1): a core's side is borrowed only by the step frame,
            // the members `sideStoreFrame` lists; any other holder that reaches the box, through a
            // member chain (`turn.behavior.sideStore`), an alias or a parameter of its type, could
            // borrow it again while its step holds it.
            let isClosureHolder = holder.name.contains(" body in ")
            let isFrame = !isClosureHolder && holder.path == sideStoreFramePath && sideStoreFrame[holder.name] != nil
            if !isFrame {
                let stores = SideStoreUses(names: SideStoreUses.names(in: holder.scope))
                stores.walk(holder.body)
                for use in stores.uses {
                    let line = holder.converter.location(for: use.positionAfterSkippingLeadingTrivia).line
                    findings.insert(Finding(path: holder.path, line: line,
                                            text: "in \(holder.name): `\(use.trimmedDescription)` reaches a core's side store while the hold is open; only the step frame borrows it"))
                }
            }
            // The bare-port rule: a callOut closure's port calls are the call-out's own.
            guard !holder.isCallOut else { continue }
            for access in uses.portAccesses {
                let line = holder.converter.location(for: access.positionAfterSkippingLeadingTrivia).line
                findings.insert(Finding(path: holder.path, line: line,
                                        text: "in \(holder.name): `\(graph.describe(access))` calls a port while the hold is open; go through callOut"))
            }
            for use in uses.uses where !use.inCallOut {
                guard let reached = use.targets.sorted(by: { $0.name < $1.name }).first(where: graph.callsPort.contains) else { continue }
                let line = holder.converter.location(for: use.at.positionAfterSkippingLeadingTrivia).line
                // A marker on the holder's call allows that call, as one on the port access does.
                guard !(portMarked[holder.path]?.contains(line) ?? false) else { continue }
                let path = ([holder.name] + graph.portPath(from: reached)).joined(separator: " → ")
                findings.insert(Finding(path: holder.path, line: line,
                                        text: "in \(holder.name): `\(reached)` calls a port while the hold is open; go through callOut: \(path)"))
            }
        }
        // The frame's exception is by name: a second declaration of a listed name in the frame's
        // file (an overload) would share it unreviewed, so it is a finding of its own.
        let frameDeclarations = Dictionary(grouping: members.filter { $0.path == sideStoreFramePath && sideStoreFrame[$0.key.name] != nil }, by: \.key.name)
        for (name, declared) in frameDeclarations where declared.count > 1 {
            findings.insert(Finding(path: sideStoreFramePath, line: 0,
                                    text: "`\(name)` is declared \(declared.count) times in the frame's file; the side-store frame excepts one declaration per name"))
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
    private static func markedLines(_ tree: SourceFileSyntax, _ converter: SourceLocationConverter,
                                    _ isMarker: (String) -> Bool) -> Set<Int> {
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
                                owner: KeeperOwner, into members: inout [KeeperMember]) {
        for item in list {
            if let config = item.decl.as(IfConfigDeclSyntax.self) {
                for clause in config.clauses {
                    if case .decls(let decls) = clause.elements { collect(decls, path, converter, owner: owner, into: &members) }
                }
            } else if let function = item.decl.as(FunctionDeclSyntax.self) {
                members.append(KeeperMember(function: function, path: path, converter: converter, owner: owner))
            } else if let variable = item.decl.as(VariableDeclSyntax.self) {
                let lazy = variable.modifiers.contains { $0.name.tokenKind == .keyword(.lazy) }
                for binding in variable.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    let body: Syntax? = binding.accessorBlock.map(Syntax.init) ?? (lazy ? binding.initializer.map(Syntax.init) : nil)
                    let isPort = binding.typeAnnotation.map { PortNames.isPortType($0.type) } ?? false
                    members.append(KeeperMember(property: name, body: body, isPort: isPort, scope: Syntax(binding),
                                                path: path, converter: converter, owner: owner))
                }
            }
        }
    }
}

/// The uses of a core's `KeeperSideStore` in a body (#700 K2-1): any `.sideStore` member access,
/// whatever its base, and any reference to a parameter or local declared with the box's type.
final class SideStoreUses: SyntaxVisitor {
    let names: Set<String>
    var uses: [Syntax] = []

    init(names: Set<String>) {
        self.names = names
        super.init(viewMode: .sourceAccurate)
    }

    /// The names declared with the box's type in `scope`: parameters, closure parameters and
    /// annotated locals.
    static func names(in scope: Syntax) -> Set<String> {
        final class Finder: SyntaxVisitor {
            var names: Set<String> = []
            override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
                if isSideStore(node.type) { names.insert((node.secondName ?? node.firstName).text) }
                return .visitChildren
            }
            override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
                if let type = node.type, isSideStore(type) { names.insert((node.secondName ?? node.firstName).text) }
                return .visitChildren
            }
            override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
                guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
                if let type = node.typeAnnotation?.type, isSideStore(type) {
                    names.insert(name)
                } else if let value = node.initializer?.value, reachesBox(value) {
                    // An unannotated local bound to the box (`let s = behavior.sideStore`, or an
                    // alias of a name already found).
                    names.insert(name)
                }
                return .visitChildren
            }
            // `guard let store = behavior.sideStore`, `if let store = …`: an optional binding of
            // the box, with or without an annotation.
            override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
                guard let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return .visitChildren }
                if let type = node.typeAnnotation?.type, isSideStore(type) {
                    names.insert(name)
                } else if let value = node.initializer?.value, reachesBox(value) {
                    names.insert(name)
                }
                return .visitChildren
            }
            /// Whether `value` is the box: a `.sideStore` member access, or a name found so far.
            private func reachesBox(_ value: ExprSyntax) -> Bool {
                if let access = value.as(MemberAccessExprSyntax.self), access.declName.baseName.text == "sideStore" { return true }
                if let forced = value.as(ForceUnwrapExprSyntax.self) { return reachesBox(forced.expression) }
                if let reference = value.as(DeclReferenceExprSyntax.self) { return names.contains(reference.baseName.text) }
                return false
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(scope)
        return finder.names
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == "sideStore" { uses.append(Syntax(node)) }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let isMemberName = node.parent?.as(MemberAccessExprSyntax.self).map { $0.declName.id == node.id } ?? false
        if !isMemberName, names.contains(node.baseName.text) { uses.append(Syntax(node)) }
        return .visitChildren
    }
}

private func isSideStore(_ type: TypeSyntax) -> Bool {
    unwrap(type).as(IdentifierTypeSyntax.self)?.name.text == "KeeperSideStore"
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
    /// The same for `KeeperTurnSide`: a closure passed there is given the side at that index.
    let givesSide: [(label: String, index: Int)]
    /// The parameters of type `KeeperTurnSide`: the names the side goes by in this member.
    let sideParameters: Set<String>
    /// Every parameter in order, by argument label, with the index of the `KeeperTurnSide`
    /// parameter of a function-typed one (nil otherwise): a closure argument binds by position.
    let parameterSides: [(label: String, isFunction: Bool, side: Int?)]
    /// A stored or computed property of a port type.
    let isPort: Bool
    /// The declaration, for the names bound in it (parameters, locals).
    let scope: Syntax

    var isHolder: Bool { !holdNames.isEmpty }

    init(function: FunctionDeclSyntax, path: String, converter: SourceLocationConverter, owner: KeeperOwner = .keeper) {
        let parameters = Array(function.signature.parameterClause.parameters)
        key = KeeperMemberKey(name: function.name.text, labels: parameters.map { $0.firstName.text }, owner: owner)
        body = function.body.map(Syntax.init)
        isPort = false
        scope = Syntax(function)
        self.path = path
        self.converter = converter
        // A model method holds the model as `self` (#700 K1b-5 C5).
        holdNames = Set(parameters.filter { isKeeperModel($0.type) }.map { ($0.secondName ?? $0.firstName).text })
            .union(owner == .model ? ["self"] : [])
        givesHold = parameters.compactMap { parameter -> (label: String, index: Int)? in
            guard let function = unwrap(parameter.type).as(FunctionTypeSyntax.self),
                  let index = Array(function.parameters).firstIndex(where: { isKeeperModel($0.type) }) else { return nil }
            return (parameter.firstName.text, index)
        }
        givesSide = parameters.compactMap { parameter -> (label: String, index: Int)? in
            guard let function = unwrap(parameter.type).as(FunctionTypeSyntax.self),
                  let index = Array(function.parameters).firstIndex(where: { isKeeperTurnSide($0.type) }) else { return nil }
            return (parameter.firstName.text, index)
        }
        sideParameters = Set(parameters.filter { isKeeperTurnSide($0.type) }.map { ($0.secondName ?? $0.firstName).text })
        parameterSides = parameters.map { parameter in
            let function = unwrap(parameter.type).as(FunctionTypeSyntax.self)
            return (parameter.firstName.text, function != nil,
                    function.flatMap { Array($0.parameters).firstIndex(where: { isKeeperTurnSide($0.type) }) })
        }
    }

    init(property: String, body: Syntax?, isPort: Bool, scope: Syntax, path: String, converter: SourceLocationConverter,
         owner: KeeperOwner = .keeper) {
        key = KeeperMemberKey(name: property, labels: nil, owner: owner)
        self.body = body
        self.isPort = isPort
        self.scope = scope
        self.path = path
        self.converter = converter
        holdNames = []
        givesHold = []
        givesSide = []
        sideParameters = []
        parameterSides = []
    }
}

/// `inout`, attributes, parentheses and `Optional` (`T?`, `T!`, `Optional<T>`) removed.
private func unwrap(_ type: TypeSyntax) -> TypeSyntax {
    if let attributed = type.as(AttributedTypeSyntax.self) { return unwrap(attributed.baseType) }
    if let optional = type.as(OptionalTypeSyntax.self) { return unwrap(optional.wrappedType) }
    if let forced = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return unwrap(forced.wrappedType) }
    if let generic = type.as(IdentifierTypeSyntax.self), generic.name.text == "Optional",
       let argument = generic.genericArgumentClause?.arguments.first, case let .type(wrapped) = argument.argument { return unwrap(wrapped) }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first { return unwrap(only.type) }
    return type
}

private func isKeeperModel(_ type: TypeSyntax) -> Bool {
    unwrap(type).as(IdentifierTypeSyntax.self)?.name.text == "KeeperModel"
}

private func isKeeperTurnSide(_ type: TypeSyntax) -> Bool {
    unwrap(type).as(IdentifierTypeSyntax.self)?.name.text == "KeeperTurnSide"
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
    /// The held storage a member names itself (`model` or `turnSide`), for the path's end.
    private var heldName: [KeeperMemberKey: String] = [:]

    /// The keeper's port properties.
    let portProperties: Set<String>
    /// The side's port properties (`attachedTransport`).
    let sidePortProperties: Set<String>

    /// The names that hold a port in a member of `owner`, before its locals: the owner's own
    /// port properties, the side's reached through the side (`side.attachedTransport`), and
    /// the bound requester's port (`….sharedBoundRequester.port`).
    func portProperties(of owner: KeeperOwner, sideNames: Set<String>) -> Set<String> {
        var names: Set<String> = ["sharedBoundRequester.port"]
        switch owner {
        case .keeper: names.formUnion(portProperties)
        case .side: names.formUnion(sidePortProperties)
        case .model: break
        }
        for name in sidePortProperties {
            for side in sideNames { names.insert("\(side).\(name)") }
        }
        return names
    }
    /// Lines a bare-port marker allows, per file.
    let portMarked: [String: Set<Int>]
    /// The members that call a port outside `callOut`, directly or through other members.
    private(set) var callsPort: Set<KeeperMemberKey> = []
    private var portVia: [KeeperMemberKey: KeeperMemberKey] = [:]
    /// For a member that calls a port itself, the first such access.
    private var portAccess: [KeeperMemberKey: String] = [:]

    init(_ members: [KeeperMember], portMarked: [String: Set<Int>] = [:]) {
        self.members = members
        byName = Dictionary(grouping: members, by: \.key.name)
        portProperties = Set(members.filter { $0.isPort && $0.key.owner == .keeper }.map(\.key.name))
        sidePortProperties = Set(members.filter { $0.isPort && $0.key.owner == .side }.map(\.key.name))
        self.portMarked = portMarked
        var uses: [KeeperMemberKey: Set<KeeperMemberKey>] = [:]
        var portUses: [KeeperMemberKey: Set<KeeperMemberKey>] = [:]
        for member in members where !member.isHolder {
            guard let body = member.body else { continue }
            let visitor = useVisitor(member: member, body: body, holdNames: [])
            visitor.walk(body)
            if let first = visitor.modelReferences.first {
                reaches.insert(member.key)
                heldName[member.key] = Self.storageName(first)
            }
            uses[member.key, default: []].formUnion(visitor.uses.flatMap(\.targets))
            if let first = visitor.portAccesses.first {
                callsPort.insert(member.key)
                portAccess[member.key] = describe(first)
            }
            portUses[member.key, default: []].formUnion(visitor.uses.filter { !$0.inCallOut }.flatMap(\.targets))
        }
        Self.close(&reaches, &via, over: uses)
        Self.close(&callsPort, &portVia, over: portUses)
    }

    /// Adds to `set` every member that uses one already in it, transitively.
    private static func close(_ set: inout Set<KeeperMemberKey>, _ via: inout [KeeperMemberKey: KeeperMemberKey],
                              over uses: [KeeperMemberKey: Set<KeeperMemberKey>]) {
        var changed = true
        while changed {
            changed = false
            for (key, used) in uses.sorted(by: { $0.key.name < $1.key.name }) where !set.contains(key) {
                if let next = used.sorted(by: { $0.name < $1.name }).first(where: set.contains) {
                    set.insert(key)
                    via[key] = next
                    changed = true
                }
            }
        }
    }

    func useVisitor(member: KeeperMember, body: Syntax, holdNames: Set<String>) -> UseVisitor {
        let sideNames = sideNames(in: member.scope, owner: member.key.owner)
        return UseVisitor(graph: self, holdNames: holdNames, root: body,
                   portNames: PortNames.of(member.scope, properties: portProperties(of: member.key.owner, sideNames: sideNames)),
                   sideNames: sideNames,
                   portMarked: portMarked[member.path] ?? [], converter: member.converter, owner: member.key.owner)
    }

    /// `port?.call` from an access, its arguments left out.
    func describe(_ access: MemberAccessExprSyntax) -> String {
        "\(access.base?.trimmedDescription ?? "").\(access.declName.baseName.text)"
    }

    /// `key → … → port.call`.
    func portPath(from key: KeeperMemberKey) -> [String] {
        var out = [key.name]
        var current = key
        while let next = portVia[current], out.count < 64 {
            out.append(next.name)
            current = next
        }
        return out + [portAccess[current] ?? "a port"]
    }

    /// `key → … → model`.
    func path(from key: KeeperMemberKey) -> [String] {
        var out = [key.name]
        var current = key
        while let next = via[current], out.count < 64 {
            out.append(next.name)
            current = next
        }
        return out + [heldName[current] ?? "model"]
    }

    /// The name a held-storage reference names: `model`, `self.turnSide`, a `[model]` capture.
    private static func storageName(_ reference: Syntax) -> String {
        if let member = reference.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
        if let name = reference.as(DeclReferenceExprSyntax.self) { return name.baseName.text }
        if let capture = reference.as(ClosureCaptureSyntax.self) { return capture.name.text }
        return "model"
    }

    /// The members a bare name may name: a property of that name, or else a function passed as
    /// a value (any of its plain overloads).
    func readTargets(_ name: String, owner: KeeperOwner = .keeper) -> Set<KeeperMemberKey> {
        guard let candidates = byName[name]?.filter({ $0.key.owner == owner }), !candidates.isEmpty else { return [] }
        let properties = candidates.filter { $0.key.labels == nil }
        if !properties.isEmpty { return Set(properties.map(\.key)) }
        return Set(candidates.filter { !$0.isHolder }.map(\.key))
    }

    /// The members a call may name, or nil when it is a holder overload called with the hold.
    /// - The overloads the call's labels fit are the candidates; nothing is dropped by type.
    /// - With the hold passed first, a fitting holder overload is the one called (a plain
    ///   overload would need a `KeeperModel` first parameter), so the call holds nothing new.
    ///   The exemption needs a holder that fits: `f(m, risky: true)` with only a plain overload
    ///   taking `risky:` is a use of that overload.
    /// - Without the hold, a holder overload can't be the one called, so every fitting plain
    ///   overload is a target. Among them, an exact fit wins over one that needs defaults; a
    ///   holder that fits exactly doesn't hide a plain one that needs a default.
    /// - When nothing fits, every plain overload, or the property of that name (a stored closure
    ///   called as a function).
    func callTargets(_ name: String, labels: [String], trailingClosures: Int, passesHold: Bool,
                     owner: KeeperOwner = .keeper) -> Set<KeeperMemberKey>? {
        guard let candidates = byName[name]?.filter({ $0.key.owner == owner }), !candidates.isEmpty else { return [] }
        let functions = candidates.filter { $0.key.labels != nil }
        let fitting = functions.filter { fits(labels, trailingClosures, $0.key.labels ?? []) }
        if passesHold, fitting.contains(where: \.isHolder) { return nil }
        var plain = fitting.filter { !$0.isHolder }
        let exact = plain.filter { ($0.key.labels ?? []).count == labels.count + trailingClosures }
        if !exact.isEmpty { plain = exact }
        if !plain.isEmpty { return Set(plain.map(\.key)) }
        // Only holder overloads fit, and the hold isn't passed: a holder isn't a member that
        // reaches the model (its own body is checked as a holder).
        if !fitting.isEmpty { return [] }
        return readTargets(name, owner: owner)
    }

    /// The closure parameters a member gives the model to, by argument label; nil when it gives
    /// none.
    /// The parameter lists of the members named `name` that give a closure the side.
    func sideGivers(_ name: String) -> [[(label: String, isFunction: Bool, side: Int?)]] {
        (byName[name] ?? []).filter { !$0.givesSide.isEmpty }.map(\.parameterSides)
    }

    /// The names the turn side goes by in a member, found by type, not by spelling (#914
    /// review): its `KeeperTurnSide` parameters, the closure parameters a member that gives the
    /// side binds it to, and on the keeper its stored `turnSide`. Flow-insensitive, as
    /// `PortNames.of`.
    func sideNames(in scope: Syntax, owner: KeeperOwner) -> Set<String> {
        var names: Set<String> = owner == .keeper ? ["turnSide"] : []
        if let function = scope.as(FunctionDeclSyntax.self) {
            for parameter in function.signature.parameterClause.parameters where isKeeperTurnSide(parameter.type) {
                names.insert((parameter.secondName ?? parameter.firstName).text)
            }
        }
        let finder = SideClosureFinder(graph: self)
        finder.walk(scope)
        names.formUnion(finder.names)
        return names
    }

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
                                       body: body, converter: member.converter, scope: member.scope, isCallOut: false,
                                       owner: member.key.owner))
            }
            let finder = HoldClosureFinder(graph: self)
            finder.walk(body)
            for (giver, index, closure) in finder.found {
                let line = member.converter.location(for: closure.positionAfterSkippingLeadingTrivia).line
                out.append(ModelHolder(name: "\(giver) body in \(member.key.name)", path: member.path, line: line,
                                       holdNames: index.map { [closureParameterName(closure, at: $0)] } ?? [],
                                       body: Syntax(closure), converter: member.converter, scope: member.scope,
                                       isCallOut: giver == "callOut", owner: member.key.owner))
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
        // `f(…)`, `self.f(…)`, or a model method on the hold (`m.f(…)`, #700 K1b-5 C5).
        let name = calleeName(node.calledExpression)
            ?? node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
        if let name, let given = graph.givesHold(name) {
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

/// The closure parameters bound to the side: a closure passed to a member that gives it the
/// side, at that parameter's index.
private final class SideClosureFinder: SyntaxVisitor {
    let graph: MemberGraph
    var names: Set<String> = []

    init(graph: MemberGraph) {
        self.graph = graph
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let name = calleeName(node.calledExpression)
            ?? node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
        if let name {
            for parameters in graph.sideGivers(name) {
                for (closure, index) in Self.bind(node, to: parameters) {
                    names.insert(closureParameterName(closure, at: index))
                }
            }
        }
        return .visitChildren
    }

    /// A closure's own parameter declared as `KeeperTurnSide` (`{ (s: KeeperTurnSide) in … }`),
    /// passed anywhere or nowhere.
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        if case .parameterClause(let clause)? = node.signature?.parameterClause {
            for parameter in clause.parameters {
                if let type = parameter.type, isKeeperTurnSide(type) {
                    names.insert((parameter.secondName ?? parameter.firstName).text)
                }
            }
        }
        return .visitChildren
    }

    /// The closure arguments of `call` that a declaration with `parameters` gives the side, with
    /// the side's index among each closure's parameters. Arguments bind in order: a labelled one
    /// to the next parameter of its label, an unlabelled one to the next `_` parameter, the first
    /// trailing closure to the next function-typed parameter after them (Swift's forward scan),
    /// and a labelled trailing closure to the next parameter of its label.
    static func bind(_ call: FunctionCallExprSyntax,
                     to parameters: [(label: String, isFunction: Bool, side: Int?)]) -> [(ClosureExprSyntax, Int)] {
        var out: [(ClosureExprSyntax, Int)] = []
        var cursor = 0
        func next(_ matches: ((label: String, isFunction: Bool, side: Int?)) -> Bool) -> Int? {
            guard let found = parameters[min(cursor, parameters.count)...].firstIndex(where: matches) else { return nil }
            cursor = found + 1
            return found
        }
        for argument in call.arguments {
            let label = argument.label?.text ?? "_"
            guard let index = next({ $0.label == label }) else { return out }
            if let closure = argument.expression.as(ClosureExprSyntax.self), let side = parameters[index].side {
                out.append((closure, side))
            }
        }
        if let trailing = call.trailingClosure, let index = next({ $0.isFunction }), let side = parameters[index].side {
            out.append((trailing, side))
        }
        for extra in call.additionalTrailingClosures {
            if let index = next({ $0.label == extra.label.text }), let side = parameters[index].side {
                out.append((extra.closure, side))
            }
        }
        return out
    }
}

/// One use of a member in a body.
struct MemberUse {
    let at: Syntax
    let targets: Set<KeeperMemberKey>
    /// Inside a closure passed to `callOut`: the port rule allows it, the model rule doesn't.
    let inCallOut: Bool
}

/// The uses of `model` and of keeper members in a body, outside tasks and `await`.
final class UseVisitor: SyntaxVisitor {
    let graph: MemberGraph
    let holdNames: Set<String>
    let root: Syntax
    /// The names that hold a port in this body (see `PortNames`).
    let portNames: Set<String>
    /// The names the turn side goes by in this body (`MemberGraph.sideNames(in:owner:)`).
    let sideNames: Set<String>
    /// Lines a bare-port marker allows.
    let portMarked: Set<Int>
    let converter: SourceLocationConverter
    var modelReferences: [Syntax] = []
    var uses: [MemberUse] = []
    /// Member accesses on a port outside `callOut`, on lines no marker allows.
    var portAccesses: [MemberAccessExprSyntax] = []
    private var callOutDepth = 0
    /// The type the body's member is declared on: a bare name or `self.name` resolves there.
    let owner: KeeperOwner
    /// The keeper's stored properties a turn holds `inout` (#700 K1b-5 C5): the model, and the
    /// turn side `withTurn` passes beside it. A keeper member only.
    var heldStorage: Set<String> { owner == .keeper ? ["model", "turnSide"] : [] }

    init(graph: MemberGraph, holdNames: Set<String>, root: Syntax, portNames: Set<String>, sideNames: Set<String>,
         portMarked: Set<Int>, converter: SourceLocationConverter, owner: KeeperOwner = .keeper) {
        self.owner = owner
        self.sideNames = sideNames
        self.graph = graph
        self.holdNames = holdNames
        self.root = root
        self.portNames = portNames
        self.portMarked = portMarked
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if isKeeperCallOut(node) {
            // A port call in the closure's statements goes through the call-out's checks (flush,
            // check, call, check). Its other arguments and its capture list are evaluated before
            // them, so they're checked as any other code under the hold.
            walk(node.calledExpression)
            for argument in node.arguments where argument.expression.as(ClosureExprSyntax.self) == nil {
                walk(argument.expression)
            }
            for (_, closure) in labelledClosures(of: node) {
                if let capture = closure.signature?.capture { walk(capture) }
                callOutDepth += 1
                walk(closure.statements)
                callOutDepth -= 1
            }
            return .skipChildren
        }
        guard isTaskCall(node) else { return .visitChildren }
        // The task's body runs later. Its other arguments (`priority:`) and its closure's capture
        // list are evaluated now, under the hold.
        for argument in node.arguments where argument.expression.as(ClosureExprSyntax.self) == nil {
            walk(argument.expression)
        }
        for (_, closure) in labelledClosures(of: node) {
            if let capture = closure.signature?.capture { walk(capture) }
        }
        return .skipChildren
    }

    override func visit(_ node: AwaitExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    /// A capture with no initializer (`[model]`, `[count]`) reads the name it captures when the
    /// closure is made.
    override func visit(_ node: ClosureCaptureSyntax) -> SyntaxVisitorContinueKind {
        guard node.initializer == nil, node.name.tokenKind != .keyword(.self) else { return .visitChildren }
        let name = node.name.text
        guard !Shadowing.binds(name, above: Syntax(node), within: root) else { return .visitChildren }
        if heldStorage.contains(name) {
            modelReferences.append(Syntax(node))
        } else if graph.byName[name] != nil {
            uses.append(MemberUse(at: Syntax(node), targets: graph.readTargets(name), inCallOut: callOutDepth > 0))
        }
        return .visitChildren
    }

    /// `callOut(…)` or `self.callOut(…)` naming the keeper's member, not a local of that name,
    /// or `m.callOut(…)` on the hold: the model's call-out (#700 K1b-5's move puts it there).
    private func isKeeperCallOut(_ node: FunctionCallExprSyntax) -> Bool {
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "callOut",
           let base = member.base?.as(DeclReferenceExprSyntax.self), holdNames.contains(base.baseName.text) {
            // The hold's own name: `Shadowing` counts the hold's parameter as a binding, so it
            // isn't asked. A local that rebinds the hold's name isn't seen (a limit).
            return true
        }
        guard calleeName(node.calledExpression) == "callOut", graph.byName["callOut"] != nil else { return false }
        if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            return !Shadowing.binds("callOut", above: Syntax(reference), within: root)
        }
        return true
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard callOutDepth == 0, let base = node.base, PortNames.holdsPort(base, portNames) else { return .visitChildren }
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        if !portMarked.contains(line) { portAccesses.append(node) }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        guard node.baseName.tokenKind != .keyword(.self) else { return .visitChildren }
        // The node a use is: the reference, or `self.name` (or `side.name`) around it.
        var use = Syntax(node)
        var target = owner
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
            // `x.name`: a member of the body's own type through `self`, a side member through
            // the side (#700 K1b-5 C5).
            guard let base = member.base?.as(DeclReferenceExprSyntax.self) else { return .visitChildren }
            if base.baseName.tokenKind == .keyword(.self) {
                use = Syntax(member)
            } else if sideNames.contains(base.baseName.text) {
                use = Syntax(member)
                target = .side
            } else {
                return .visitChildren
            }
        } else if Shadowing.binds(name, above: Syntax(node), within: root) {
            return .visitChildren
        }
        if heldStorage.contains(name), target == .keeper {
            modelReferences.append(use)
            return .visitChildren
        }
        guard graph.byName[name] != nil else { return .visitChildren }
        if let call = use.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == use.id {
            let labels = call.arguments.map { $0.label?.text ?? "_" }
            let trailing = (call.trailingClosure == nil ? 0 : 1) + call.additionalTrailingClosures.count
            let holds = call.arguments.first.map { passesHold($0.expression) } ?? false
            // nil: a holder overload that fits, called with the hold.
            guard let targets = graph.callTargets(name, labels: labels, trailingClosures: trailing, passesHold: holds,
                                                  owner: target) else {
                return .visitChildren
            }
            uses.append(MemberUse(at: use, targets: targets, inCallOut: callOutDepth > 0))
        } else {
            uses.append(MemberUse(at: use, targets: graph.readTargets(name, owner: target), inCallOut: callOutDepth > 0))
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

/// The keeper's ports: values of a `LandKeeper…Transport` or `LandKeeper…Port` type. A member
/// access on one is a call out of the keeper (the port may call back in), which a holder makes
/// only through `callOut`.
enum PortNames {
    static func isPortType(_ syntax: some SyntaxProtocol) -> Bool {
        syntax.tokens(viewMode: .sourceAccurate).contains { token in
            guard case .identifier(let text) = token.tokenKind else { return false }
            return text.hasPrefix("LandKeeper") && (text.hasSuffix("Transport") || text.hasSuffix("Port"))
        }
    }

    /// `port`, `self.port`, `port?`, `port!`, with `port` one of `names`.
    static func holdsPort(_ expression: ExprSyntax, _ names: Set<String>) -> Bool {
        var inner = expression
        while true {
            if let chained = inner.as(OptionalChainingExprSyntax.self) { inner = chained.expression; continue }
            if let forced = inner.as(ForceUnwrapExprSyntax.self) { inner = forced.expression; continue }
            if let parens = inner.as(TupleExprSyntax.self), parens.elements.count == 1, let only = parens.elements.first {
                inner = only.expression; continue
            }
            break
        }
        if let reference = inner.as(DeclReferenceExprSyntax.self) { return names.contains(reference.baseName.text) }
        if let member = inner.as(MemberAccessExprSyntax.self) {
            if member.base?.as(DeclReferenceExprSyntax.self)?.baseName.tokenKind == .keyword(.self) {
                return names.contains(member.declName.baseName.text)
            }
            // A qualified name (`side.attachedTransport`, `….sharedBoundRequester.port`): the
            // access itself, or its tail after any base.
            let text = member.trimmedDescription.filter { !$0.isWhitespace }
            return names.contains { $0.contains(".") && (text == $0 || text.hasSuffix("." + $0)) }
        }
        return false
    }

    /// The names that hold a port in a member: the keeper's port properties, the member's
    /// port-typed parameters, and the locals bound to a port (`let attached = transport`,
    /// `guard let transport`, `port as? any LandKeeperSettlePort`, a port-typed annotation).
    /// Flow-insensitive: a name bound to a port anywhere in the member counts everywhere in it.
    static func of(_ scope: Syntax, properties: Set<String>) -> Set<String> {
        var names = properties
        if let function = scope.as(FunctionDeclSyntax.self) {
            for parameter in function.signature.parameterClause.parameters where isPortType(parameter.type) {
                names.insert((parameter.secondName ?? parameter.firstName).text)
            }
        }
        let finder = PortBindingFinder(viewMode: .sourceAccurate)
        finder.walk(scope)
        var changed = true
        while changed {
            changed = false
            for binding in finder.bindings where !names.contains(binding.name) {
                let isPort: Bool
                if let type = binding.type, isPortType(type) {
                    isPort = true
                } else if let value = binding.value {
                    isPort = isPortType(value) || holdsPort(value, names) || castsPort(value, names) || coalescesPort(value, names)
                } else {
                    // `if let transport`, `guard let transport`: the shorthand binds the name it unwraps.
                    isPort = binding.shorthand && names.contains(binding.name)
                }
                if isPort {
                    names.insert(binding.name)
                    changed = true
                }
            }
        }
        return names
    }

    /// `port ?? other` before operator folding: a sequence that starts with a port and
    /// coalesces it (`side.attachedTransport ?? side.sharedBoundRequester.port`).
    private static func coalescesPort(_ value: ExprSyntax, _ names: Set<String>) -> Bool {
        guard let sequence = value.as(SequenceExprSyntax.self), let first = sequence.elements.first else { return false }
        return holdsPort(first, names) && sequence.elements.contains {
            $0.as(BinaryOperatorExprSyntax.self)?.operator.text == "??"
        }
    }

    /// `port as? T` before operator folding: a sequence that starts with a port and casts it.
    private static func castsPort(_ value: ExprSyntax, _ names: Set<String>) -> Bool {
        guard let sequence = value.as(SequenceExprSyntax.self), let first = sequence.elements.first else { return false }
        return holdsPort(first, names) && sequence.elements.contains { $0.is(UnresolvedAsExprSyntax.self) }
    }
}

/// A name bound in a member, with what it's bound to.
private struct PortBinding {
    let name: String
    let type: TypeSyntax?
    let value: ExprSyntax?
    let shorthand: Bool
}

private final class PortBindingFinder: SyntaxVisitor {
    var bindings: [PortBinding] = []

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            bindings.append(PortBinding(name: name, type: node.typeAnnotation?.type, value: node.initializer?.value, shorthand: false))
        }
        return .visitChildren
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let name = node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
            bindings.append(PortBinding(name: name, type: node.typeAnnotation?.type, value: node.initializer?.value,
                                        shorthand: node.initializer == nil))
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        if let type = node.type {
            bindings.append(PortBinding(name: (node.secondName ?? node.firstName).text, type: type, value: nil, shorthand: false))
        }
        return .visitChildren
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

/// The self-test of the text helper this rule replaced (K1b-5a step 2), ported.
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
        // A task's other arguments are evaluated under the hold too.
        ("Task(priority: level(model.count)) { self.touches() }", 1),
        ("Task(priority: level(count)) {}", 1),
        // A capture with no initializer reads what it names, under the hold.
        ("Task { [model] in _ = model }", 1),
        ("_ = { [count] in count }", 1),
        ("let model = 0\n_ = { [model] in model }", 0),
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

    @Test("Overloads: a plain overload that needs a default, and the hold passed to a plain overload")
    func overloadsAgainstTheHold() {
        let report = ModelHoldsLint.check([(path: "LandKeeper.swift", source: """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private func f(_ m: inout KeeperModel<State>) {}
            private func f(_ n: Int, audit: Bool = false) -> Int { model.count + n }
            private func g(_ m: inout KeeperModel<State>) {}
            private func g(_ x: KeeperModel<State>.Snapshot, risky: Bool) -> Int { model.count }
            private func holder(_ m: inout KeeperModel<State>) {
                f(&m)
                _ = f(0)
                g(&m)
                _ = g(m, risky: true)
            }
        }
        """)])
        // `f(0)` takes the plain overload (a holder can't be called without the hold), and
        // `g(m, risky: true)` the plain one (no holder takes `risky:`).
        #expect(report.findings.map { $0.split(separator: ":")[1] } == ["9", "11"], "\(report.findings.joined(separator: "\n"))")
    }

    @Test("Bare port calls in a holder", arguments: [
        ("transport?.note()", 1),
        ("self.transport?.note()", 1),
        ("let n = transport?.count\n_ = n", 1),
        // Through a member, a computed property included.
        ("note()", 1),
        ("_ = syncs", 1),
        // Locals bound to a port.
        ("guard let transport else { return }\ntransport.note()", 1),
        ("let attached = transport\nattached?.note()", 1),
        ("if let port = transport as? any LandKeeperSettlePort { port.settle() }", 1),
        // Through callOut, the call-out's own: not a finding.
        ("_ = callOut(&m) { _ in syncs }", 0),
        ("_ = callOut(&m, { _ in transport?.note() })", 0),
        ("_ = callOut(&m) { _ in 0 }\nnote()", 1),
        // The model's call-out, on the hold.
        ("_ = m.callOut(behavior, &side, &outputs) { _, _ in syncs }", 0),
        ("_ = m.callOut(behavior, &side, &outputs, { _, _ in transport?.note() })", 0),
        ("_ = other.callOut(behavior, &side, &outputs) { _, _ in transport?.note() }", 1),
        // The call-out's capture list runs before its checks; a local `callOut` isn't the keeper's.
        ("_ = callOut(&m) { [n = transport?.count] _ in n }", 1),
        ("func callOut(_ f: () -> Void) { f() }\ncallOut { transport?.note() }", 1),
        // Not a member access on the port, a task's body, and a marked call in a member.
        ("_ = transport == nil", 0),
        ("Task { transport?.note() }", 0),
        ("closeGate()", 0),
        ("note() \(ModelHoldsLint.portMarker) outside a body until the port moves into callOut", 0),
    ])
    func barePort(body: String, expected: Int) {
        let source = """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private var transport: LandKeeperTransport?
            private var syncs: Bool { transport?.runs(of: self) ?? false }
            private func note() { transport?.note() }
            private func closeGate() {
                transport?.close() \(ModelHoldsLint.portMarker) closing the gate can't call out again
            }
            private func callOut<A>(_ m: inout KeeperModel<State>, _ call: (KeeperModel<State>) -> A) -> A { call(m) }
            private func holder(_ m: inout KeeperModel<State>) {
        \(body)
            }
        }
        """
        let report = ModelHoldsLint.check([(path: "LandKeeper.swift", source: source)])
        #expect(report.findings.count == expected, "\(report.findings.joined(separator: "\n"))")
    }

    /// The model's and the side's members (#700 K1b-5 C5): a model method is a holder with
    /// `self` as the hold, a side method is a member reached from a hold, and a file counts by
    /// what it declares.
    private static let ownerFiles: [(path: String, source: String)] = [
        (path: "Sources/SwiftStateTree/Runtime/LandKeeper.swift", source: """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private var turnSide: KeeperTurnSide
        }
        """),
        (path: "Sources/SwiftStateTree/Runtime/KeeperTurnSide.swift", source: """
        struct KeeperTurnSide {
            var attachedTransport: (any LandKeeperTransport)?
            func notes() { attachedTransport?.note() }
            func plain() -> Int { 0 }
        }
        """),
    ]

    @Test("Model and side members", arguments: [
        // A port call in a model method, through the side's properties.
        ("_ = side.attachedTransport?.count", 1),
        ("_ = side.sharedBoundRequester.port?.count", 1),
        ("let transport = side.attachedTransport ?? side.sharedBoundRequester.port\n_ = transport?.count", 1),
        // Through a side method that calls a port, and one that doesn't.
        ("side.notes()", 1),
        ("_ = side.plain()", 0),
        // The model's call-out, on `self` and bare.
        ("_ = self.callOut { _, _ in side.notes() }", 0),
        ("_ = callOut { _, _ in side.attachedTransport?.note() }", 0),
    ])
    func modelAndSideMembers(body: String, expected: Int) {
        // A new Runtime/ file that never names the keeper: in scope by its declaration.
        let model = """
        extension KeeperModel {
            mutating func callOut<A>(_ call: (KeeperModel<State>, KeeperTurnSide) -> A) -> A { fatalError() }
            mutating func body(_ side: inout KeeperTurnSide) {
        \(body)
            }
        }
        """
        let path = "Sources/SwiftStateTree/Runtime/KeeperModelBodies.swift"
        #expect(ModelHoldsLint.inScope(path, model))
        let report = ModelHoldsLint.check(Self.ownerFiles + [(path: path, source: model)])
        #expect(report.findings.count == expected, "\(report.findings.joined(separator: "\n"))")
    }

    /// The side is found by its type, not by its name (#914 review): a side parameter named
    /// anything, and a call-out closure's side parameter, whatever it's called.
    @Test("The side by type", arguments: [
        ("_ = s.attachedTransport?.count", 1),
        ("s.notes()", 1),
        ("_ = s.plain()", 0),
        // A closure given the model and the side: its side parameter, by the giver's type. Found
        // in the closure's hold and in the method's, which holds `self` around it.
        ("step { _, t in _ = t.attachedTransport?.count }", 2),
        ("step { _, t in t.notes() }", 2),
        ("_ = callOut { _, t in t.notes() }", 0),
        ("let other = 0\n_ = other", 0),
        // A closure's own parameter typed as the side, given by no known member.
        ("_ = { (q: inout KeeperTurnSide) in _ = q.attachedTransport?.count }", 1),
        // An unlabelled trailing closure binds to the first closure parameter, not the last
        // one that gives the side (there at index 0, which would bind `_`).
        ("pair { _, t in _ = t.attachedTransport?.count } then: { _ in }", 2),
    ])
    func sideByType(body: String, expected: Int) {
        let model = """
        extension KeeperModel {
            mutating func callOut<A>(_ call: (KeeperModel<State>, KeeperTurnSide) -> A) -> A { fatalError() }
            mutating func step(_ body: (inout KeeperModel<State>, inout KeeperTurnSide) -> Void) {}
            mutating func pair(_ first: (inout KeeperModel<State>, inout KeeperTurnSide) -> Void, then: (KeeperTurnSide) -> Void) {}
            mutating func body(_ s: inout KeeperTurnSide) {
        \(body)
            }
        }
        """
        let report = ModelHoldsLint.check(Self.ownerFiles + [(path: "Sources/SwiftStateTree/Runtime/KeeperModelBodies.swift", source: model)])
        #expect(report.findings.count == expected, "\(report.findings.joined(separator: "\n"))")
    }

    @Test("A core's side store is reached only by the step frame (#700 K2-1)", arguments: [
        // The member chain, an alias of it, and the alias's use.
        ("_ = turn.behavior.sideStore", 1),
        ("let s = behavior.sideStore\n_ = s", 2),
        ("behavior.sideStore?.withSide { _ in }", 1),
        // A parameter of the box's type, and a closure parameter of it.
        ("_ = store", 1),
        ("let f = { (x: KeeperSideStore) in _ = x }\nf(store)", 2),
        // Through a body given the model: the closure holder is checked on its own, and the
        // member around it reports it too.
        ("lend { m, _ in _ = m.behavior.sideStore }", 2),
        // The side the step lends is not the box.
        ("_ = side.count", 0),
        // Review round 1 on #938: an optional binding of the box, annotated or not, and its use
        // inside a closure the member hands out; an unannotated alias of a found name; an
        // optional-typed parameter.
        ("guard let s = behavior.sideStore else { return }\nlend { _, _ in s.withSide { _ in } }", 3),
        ("if let s: KeeperSideStore = behavior.sideStore { _ = s }", 2),
        ("let t = store\n_ = t", 2),
        ("let f = { (x: KeeperSideStore?) in _ = x }\nf(store)", 2),
    ])
    func sideStoreOnlyInTheFrame(body: String, expected: Int) {
        let model = """
        extension KeeperModel {
            mutating func lend(_ body: (inout KeeperModel<State>, inout KeeperTurnSide) -> Void) {}
            mutating func body(_ side: inout KeeperTurnSide, _ store: KeeperSideStore, turn: Turn, behavior: Behavior) {
        \(body)
            }
        }
        """
        // A listed frame member, in the frame's file, borrows the box without a finding; the same
        // name in another file is a holder like any other.
        let frame = """
        extension KeeperModel {
            mutating func step(_ store: KeeperSideStore) { store.withSide { _ in } }
        }
        """
        let report = ModelHoldsLint.check(Self.ownerFiles + [
            (path: "Sources/SwiftStateTree/Runtime/KeeperModelBodies.swift", source: model),
            (path: ModelHoldsLint.sideStoreFramePath, source: frame),
        ])
        #expect(report.findings.count == expected, "\(report.findings.joined(separator: "\n"))")
    }

    @Test("An overload of a listed frame member, in the frame's file, is a finding: the exception is one declaration per name")
    func sideStoreFrameOverloadIsAFinding() {
        let report = ModelHoldsLint.check(Self.ownerFiles + [(path: ModelHoldsLint.sideStoreFramePath, source: """
        extension KeeperModel {
            mutating func step(_ store: KeeperSideStore) { store.withSide { _ in } }
            mutating func step(_ store: KeeperSideStore, again: Int) { store.withSide { _ in } }
        }
        """)])
        #expect(report.findings.contains { $0.contains("`step` is declared 2 times") }, "\(report.findings.joined(separator: "\n"))")
    }

    @Test("An unlisted member in the frame's file is checked: the list, not the file, is the exception")
    func sideStoreFrameIsTheList() {
        let report = ModelHoldsLint.check(Self.ownerFiles + [(path: ModelHoldsLint.sideStoreFramePath, source: """
        extension KeeperModel {
            mutating func step(_ store: KeeperSideStore) { store.withSide { _ in } }
            mutating func helper(_ store: KeeperSideStore) { store.withSide { _ in } }
        }
        """)])
        #expect(report.findings.count == 1, "\(report.findings.joined(separator: "\n"))")
        #expect(report.findings.first?.contains("in helper:") == true, "\(report.findings.joined(separator: "\n"))")
    }

    @Test("The keeper's turn side is held as its model is", arguments: [
        ("_ = turnSide.count", 1),
        ("_ = self.turnSide.count", 1),
        // A keeper member that reads it, called under the hold (the step scope's old wrapper).
        ("_ = opensScope()", 1),
        // The side the turn passes, and a local of that name.
        ("_ = side.count", 0),
        ("let turnSide = 0\n_ = turnSide", 0),
    ])
    func turnSideIsHeld(body: String, expected: Int) {
        let report = ModelHoldsLint.check([(path: "Sources/SwiftStateTree/Runtime/LandKeeper.swift", source: """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private var turnSide: KeeperTurnSide
            private func opensScope() -> Int { turnSide.count }
            private func holder(_ m: inout KeeperModel<State>, _ side: inout KeeperTurnSide) {
        \(body)
            }
        }
        """)])
        #expect(report.findings.count == expected, "\(report.findings.joined(separator: "\n"))")
    }

    @Test("A finding through the side names turnSide at its end, not the model")
    func turnSidePathEnd() {
        let report = ModelHoldsLint.check([(path: "Sources/SwiftStateTree/Runtime/LandKeeper.swift", source: """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private var turnSide: KeeperTurnSide
            private func opensScope() -> Int { turnSide.count }
            private func holder(_ m: inout KeeperModel<State>) { _ = opensScope() }
        }
        """)])
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.hasSuffix("holder → opensScope → turnSide") == true,
                "\(report.findings.joined(separator: "\n"))")
    }

    @Test("The scope is by declaration, not by a word in the text")
    func scopeByDeclaration() {
        #expect(ModelHoldsLint.inScope("Sources/SwiftStateTree/Runtime/X.swift", "extension KeeperTurnSide {}"))
        #expect(ModelHoldsLint.inScope("Sources/SwiftStateTree/Runtime/X.swift", "struct KeeperModel<State> {}"))
        #expect(!ModelHoldsLint.inScope("Sources/SwiftStateTree/Runtime/X.swift", "// LandKeeper, KeeperModel\nstruct Other {}"))
        #expect(!ModelHoldsLint.inScope("Tests/X.swift", "extension KeeperModel {}"))
    }

    @Test("A bare-port finding names the path to the port")
    func barePortPath() {
        let report = ModelHoldsLint.check([(path: "LandKeeper.swift", source: """
        actor LandKeeper<State> {
            private var model: KeeperModel<State>
            private var transport: LandKeeperTransport?
            private var syncs: Bool { transport?.runs(of: self) ?? false }
            private var records: Bool { syncs }
            private func holder(_ m: inout KeeperModel<State>) { _ = records }
        }
        """)])
        #expect(report.findings.count == 1)
        #expect(report.findings.first?.hasSuffix("holder → records → syncs → transport?.runs") == true,
                "\(report.findings.joined(separator: "\n"))")
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
        try swiftFiles(under: modelHoldsRepositoryRoot, in: ["Sources"]).compactMap { path in
            let text = try String(contentsOf: modelHoldsRepositoryRoot.appendingPathComponent(path), encoding: .utf8)
            return ModelHoldsLint.inScope(path, text) ? (path, text) : nil
        }
    }

    @Test("The repository: no holder touches the keeper's model or calls a port outside callOut")
    func repository() throws {
        let files = try keeperFiles()
        // A path change that finds nothing would pass vacuously.
        try #require(files.contains { $0.path == "Sources/SwiftStateTree/Runtime/LandKeeper.swift" })
        // The turn machine's file (#700 K2-1): in scope by its `extension KeeperModel`, and its
        // steps are holders of the model.
        let machine = "Sources/SwiftStateTree/Runtime/KeeperMachine.swift"
        try #require(files.contains { $0.path == machine })
        // The drivers' segments (#700 K2-1): in scope by their `extension KeeperModel`, and each
        // segment is a holder of the model.
        let drivers = "Sources/SwiftStateTree/Runtime/KeeperModel+Drivers.swift"
        try #require(files.contains { $0.path == drivers })
        let report = ModelHoldsLint.check(files)
        #expect(report.holders.contains { $0.path == machine && $0.name == "handle" },
                "holders in \(machine): \(report.holders.filter { $0.path == machine }.map(\.name))")
        // The side-store frame (#700 K2-1): every listed member is a holder in its file, so a
        // renamed one can't leave a stale exception.
        let frame = Set(report.holders.filter { $0.path == ModelHoldsLint.sideStoreFramePath && !$0.name.contains(" body in ") }.map(\.name))
        #expect(Set(ModelHoldsLint.sideStoreFrame.keys).isSubset(of: frame), "frame members missing: \(Set(ModelHoldsLint.sideStoreFrame.keys).subtracting(frame).sorted())")
        #expect(ModelHoldsLint.sideStoreFrame.count == 27, "the side-store frame: \(ModelHoldsLint.sideStoreFrame.keys.sorted())")
        #expect(report.holders.contains { $0.path == drivers && $0.name == "tickStart" },
                "holders in \(drivers): \(report.holders.filter { $0.path == drivers }.map(\.name))")
        // Each family of closure holders is found: every member that gives a closure the model
        // has at least one, and `withHandlerStep` (every handler) has one per handler kind.
        let families = Dictionary(grouping: report.holders.filter { $0.name.contains(" body in ") }) {
            String($0.name.prefix { $0 != " " })
        }.mapValues(\.count)
        #expect(report.givers.contains("withHandlerStep"), "givers: \(report.givers)")
        for giver in report.givers {
            #expect(families[giver, default: 0] >= 1, "no holder passed to \(giver); families: \(families)")
        }
        #expect(families["withHandlerStep", default: 0] >= 10, "families: \(families)")
        #expect(report.findings.isEmpty, "\(report.findings.joined(separator: "\n"))")
        for file in files {
            #expect(!file.source.contains(ModelHoldsLint.marker), "\(file.path): a model-holds marker is allowed under Tests/ only")
        }
    }

    /// The repository with `line` inserted at the top of the first `withHandlerStep` body.
    private func mutated(_ line: String) throws -> (holder: ModelHolder, findings: [String]) {
        let files = try keeperFiles()
        let report = ModelHoldsLint.check(files)
        let first = try #require(report.holders.first { $0.name.hasPrefix("withHandlerStep body in ") })
        let changed = files.map { file -> (path: String, source: String) in
            guard file.path == first.path else { return file }
            var lines = file.source.components(separatedBy: "\n")
            lines.insert("        " + line, at: first.line)
            return (file.path, lines.joined(separator: "\n"))
        }
        return (first, ModelHoldsLint.check(changed).findings)
    }

    @Test("Mutant: `model` named in a handler body is found at that line")
    func repositoryMutantDirect() throws {
        let (holder, found) = try mutated("_ = model.players.count")
        #expect(found == ["\(holder.path):\(holder.line + 1): in \(holder.name): names `model` while the hold is open; use `\(holder.holdNames.sorted()[0])`"],
                "\(found.joined(separator: "\n"))")
    }

    @Test("Mutant: a real member that reaches the model through another, called in a handler body")
    func repositoryMutantTransitive() throws {
        let report = ModelHoldsLint.check(try keeperFiles())
        let graph = try #require(report.graph)
        // A function with no parameters whose path to the model passes through another member.
        let transitive = try #require(graph.reaches.filter { $0.labels == [] && graph.path(from: $0).count >= 3 }
            .sorted { $0.name < $1.name }.first)
        let (holder, all) = try mutated("_ = \(transitive.name)()")
        // The member may also call a port; only its model finding is this check's.
        let found = all.filter { $0.contains("reaches the model") }
        let path = ([holder.name] + graph.path(from: transitive)).joined(separator: " → ")
        #expect(found == ["\(holder.path):\(holder.line + 1): in \(holder.name): `\(transitive.name)` reaches the model while the hold is open: \(path)"],
                "\(found.joined(separator: "\n"))")
    }

    @Test("Mutant: a bare call on the keeper's transport in a handler body")
    func repositoryMutantPort() throws {
        let (holder, found) = try mutated("_ = transport?.hasJoinsAwaitingSync")
        #expect(found == ["\(holder.path):\(holder.line + 1): in \(holder.name): `transport?.hasJoinsAwaitingSync` calls a port while the hold is open; go through callOut"],
                "\(found.joined(separator: "\n"))")
    }
}
