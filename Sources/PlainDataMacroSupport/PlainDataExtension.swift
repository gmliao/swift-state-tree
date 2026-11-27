// The extension `@PlainData` writes, shared with `@Payload`: one builder, so the two
// macros check a type's stored values the same way and give the witness the same access.

@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// The `PlainData` extension that `@PlainData` and `@Payload` write: the conformance (when the
/// compiler asks for it) and the `_plainDataCheck` witness with one check per stored value.
public enum PlainDataExtension {
    /// - Parameters:
    ///   - constrainGenerics: whether the extension adds `where T: PlainData` for the generic
    ///     parameters, the type's and the enclosing ones, that its stored values name. `@Payload` passes false
    ///     when its type conforms through a payload protocol: that conformance is unconditional,
    ///     so a conditional witness couldn't satisfy it, and the parameters carry the constraint
    ///     themselves.
    public static func build(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        constrainGenerics: Bool = true,
        in context: some MacroExpansionContext
    ) -> [ExtensionDeclSyntax] {
        let generics: GenericParameterClauseSyntax?
        var failed = false
        let checks: String

        if let structDecl = declaration.as(StructDeclSyntax.self) {
            generics = structDecl.genericParameterClause
            checks = PlainDataWalk.checkLines(structDecl.memberBlock.members, isEnum: false, failed: &failed, context)
        } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            generics = enumDecl.genericParameterClause
            diagnoseSharedCaseNames(enumDecl.memberBlock.members, failed: &failed, context)
            checks = PlainDataWalk.checkLines(enumDecl.memberBlock.members, isEnum: true, failed: &failed, context)
        } else {
            context.diagnose(Diagnostic(node: node, message: PlainDataDiagnostic.notValue))
            return []
        }
        if failed { return [] }

        // The expansion names the core's module, so a namesake type in the user's module can't
        // stand in for `PlainData` or `PlainDataCheck`.
        let members = declaration.memberBlock.members
        let requirements = declaration.as(StructDeclSyntax.self)?.genericWhereClause
            ?? declaration.as(EnumDeclSyntax.self)?.genericWhereClause
        let parameters = generics?.parameters ?? []
        let ownNames = Set(parameters.map(name(of:)))
        let named = closedOverSameType(
            storedNames(members), requirements,
            parameters: ownNames.union(enclosingParameterNames(in: context))
        )
        // A field of a type or typealias declared in the body may stand for any parameter, so
        // it constrains them all.
        let all = !named.isDisjoint(with: localTypeNames(members))
        let own = parameters.filter { all || named.contains(name(of: $0)) }.map(\.name.text)
        let enclosing = enclosingParameters(named: named, in: context).filter { !ownNames.contains(String($0.filter { $0 != "`" })) }
        let constraints = constrainGenerics ? (own + enclosing).map { "\($0): SwiftStateTurns.PlainData" } : []
        let whereClause = constraints.isEmpty ? "" : " where " + constraints.joined(separator: ", ")
        let conformance = protocols.isEmpty ? "" : ": SwiftStateTurns.PlainData"
        let access = witnessAccess(of: declaration, in: context)
        // A local function, not a closure: the compiler checks each statement of a function on
        // its own, so every field that isn't plain data gets its error, where a closure's body
        // stops at the first. `inout`, so a `lazy` property's mutating getter can be read.
        // Deprecated, so reading a deprecated field or case inside it doesn't warn; it is never
        // called, so it warns about nothing itself.
        let body = checks.isEmpty ? "" : """
            @available(*, deprecated, message: "the @PlainData checks; never called")
            func check(_ value: inout Self) {
            \(checks)
            }
            """
        let decl: DeclSyntax = """
            extension \(type.trimmed)\(raw: conformance)\(raw: whereClause) {
                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                \(raw: access)static func _plainDataCheck() {
                    \(raw: body)
                }
            }
            """
        guard let ext = decl.as(ExtensionDeclSyntax.self) else { return [] }
        return [ext]
    }

    /// The `_plainDataCheck` witness as a member of `declaration`, for a member macro
    /// (`@StateNodeBuilder`): the same checks and the same access as `build`'s extension, with
    /// the wrappers in `readThrough` read through (`PlainDataWalk.checkLines`). A generic type
    /// gets no `where` clause: a member can't carry one, so its parameters carry the constraint
    /// themselves (the wrappers' `Value: PlainData` asks for it at the field). Nil after a
    /// diagnostic.
    public static func memberWitness(
        of declaration: StructDeclSyntax,
        readThrough: Set<String>,
        in context: some MacroExpansionContext
    ) -> DeclSyntax? {
        var failed = false
        let checks = PlainDataWalk.checkLines(
            declaration.memberBlock.members, isEnum: false, readThrough: readThrough, failed: &failed, context)
        if failed { return nil }
        let access = witnessAccess(of: declaration, in: context)
        let body = checks.isEmpty ? "" : """
            @available(*, deprecated, message: "the PlainData checks; never called")
            func check(_ value: inout Self) {
            \(checks)
            }
            """
        return """
            /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
            \(raw: access)static func _plainDataCheck() {
                \(raw: body)
            }
            """
    }

    /// Cases that share a base name (`case item(count: Int)` and `case item(label: String)`) are
    /// refused: `if case let .item(v0) = value` is ambiguous, and a labelled pattern doesn't
    /// pick one when the arities differ.
    ///
    /// A name may repeat only when every declaration of it is inside an `#if`: in the clauses of
    /// one block, or in separate blocks (#797). The macro can't evaluate the conditions, so it
    /// can't tell that separate blocks exclude each other; the user must make them so. If two
    /// such cases are active in one build, the expansion's per-case `if case let .name(…) = value`
    /// lines fail to compile (an ambiguous use, or a tuple binding that isn't plain data), and
    /// Swift refuses a case without a payload beside one with a payload as a redeclaration. So a
    /// payload is never left unchecked; the error is only less clear than this diagnostic. That
    /// argument rests on those per-case lines: an expansion that stops writing one line per case
    /// must revisit this rule.
    private static func diagnoseSharedCaseNames(
        _ members: MemberBlockItemListSyntax,
        failed: inout Bool,
        _ context: some MacroExpansionContext
    ) {
        // `direct` holds the names every build of this list declares: its own cases and the
        // enclosing lists' direct names. `inIf` holds the names its `#if` blocks declare. A case
        // clashes with either. A clause starts from the current `direct`, so it clashes with the
        // list's cases before the block; its names go into `inIf`, so they clash with the list's
        // cases after it, but never with another clause's or another block's names. Returns the
        // names the list declares, direct or in a block, beyond `enclosing`.
        func walk(_ members: MemberBlockItemListSyntax, enclosing: Set<String>) -> Set<String> {
            var direct = enclosing
            var inIf: Set<String> = []
            for member in members {
                if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
                    for clause in ifConfig.clauses {
                        if case .decls(let nested) = clause.elements {
                            inIf.formUnion(walk(nested, enclosing: direct))
                        }
                    }
                    continue
                }
                guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                for element in cases.elements {
                    // `item` and `` `item` `` are one name.
                    let name = element.name.identifier?.name ?? element.name.text
                    if inIf.contains(name) || !direct.insert(name).inserted {
                        context.diagnose(Diagnostic(node: element.name, message: PlainDataDiagnostic.sharedCaseName(name)))
                        failed = true
                    }
                }
            }
            return direct.subtracting(enclosing).union(inIf)
        }
        _ = walk(members, enclosing: [])
    }

    /// A generic parameter's name without backticks: `T` and `` `T` `` are one.
    private static func name(of parameter: GenericParameterSyntax) -> String {
        parameter.name.identifier?.name ?? parameter.name.text
    }

    /// The names the stored values' declarations spell, which decide the generic parameters the
    /// conformance requires to be `PlainData`: a parameter named nowhere in them is stored
    /// nowhere, so the value is plain data whatever its argument (a resolver generic over the
    /// services it doesn't store, #769). Only what the checks read counts: a stored property's
    /// type and initializer, and an enum case's associated values. A parameter that only a
    /// method or a computed property names adds no constraint. A name is a whole identifier
    /// anywhere in them: `D`, `[D]`, `Box<D>` and `D.Element` all name `D`. Any identifier
    /// counts, an argument label (`case value(T: Int)`) or a member name (`Limits.T`) included,
    /// which constrains a parameter the value may not store: conservative, as for every
    /// parameter before #769. The checks still read every stored value, so a parameter this
    /// misses is a field that fails to compile, never one that conforms unchecked.
    private static func storedNames(_ members: MemberBlockItemListSyntax) -> Set<String> {
        var names: Set<String> = []
        func collect(_ syntax: some SyntaxProtocol) {
            for token in syntax.tokens(viewMode: .sourceAccurate) {
                if let name = token.identifier?.name { names.insert(name) }
            }
        }
        func walk(_ members: MemberBlockItemListSyntax) {
            for member in members {
                if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
                    for clause in ifConfig.clauses {
                        if case .decls(let nested) = clause.elements { walk(nested) }
                    }
                } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                    if variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }) { continue }
                    for binding in variable.bindings {
                        // A computed property stores nothing; observers alone keep it stored.
                        if let block = binding.accessorBlock {
                            guard case .accessors(let accessors) = block.accessors,
                                  accessors.allSatisfy({ [.keyword(.willSet), .keyword(.didSet)].contains($0.accessorSpecifier.tokenKind) })
                            else { continue }
                        }
                        if let type = binding.typeAnnotation { collect(type) }
                        if let initializer = binding.initializer { collect(initializer) }
                    }
                } else if let cases = member.decl.as(EnumCaseDeclSyntax.self) {
                    for element in cases.elements {
                        if let parameters = element.parameterClause { collect(parameters) }
                    }
                }
            }
        }
        walk(members)
        return names
    }

    /// `named` with each same-type requirement of the declaration's `where` clause followed: when
    /// one side names a named generic parameter, the other side's generic parameters are named
    /// too, until nothing changes. In `struct First<C: Collection, T> where C.Element == T
    /// { let first: C.Element? }` the field names `C`, and `T` is what proves `C.Element` plain
    /// data, so `T` is constrained. Only the generic parameters in scope (`parameters`: the
    /// type's and the enclosing types') take part, as in the compiler's equivalence classes of
    /// type parameters: a concrete type is a binding, not a member. So `where D.ID == Int`
    /// doesn't constrain `D` because a field is an `Int`.
    private static func closedOverSameType(
        _ named: Set<String>,
        _ clause: GenericWhereClauseSyntax?,
        parameters: Set<String>
    ) -> Set<String> {
        func names(_ syntax: some SyntaxProtocol) -> Set<String> {
            Set(syntax.tokens(viewMode: .sourceAccurate).compactMap { $0.identifier?.name }).intersection(parameters)
        }
        let pairs: [(Set<String>, Set<String>)] = (clause?.requirements ?? []).compactMap {
            guard case .sameTypeRequirement(let same) = $0.requirement else { return nil }
            return (names(same.leftType), names(same.rightType))
        }
        var result = named.intersection(parameters)
        var changed = true
        while changed {
            changed = false
            for (left, right) in pairs {
                if !left.isDisjoint(with: result), !right.isSubset(of: result) { result.formUnion(right); changed = true }
                if !right.isDisjoint(with: result), !left.isSubset(of: result) { result.formUnion(left); changed = true }
            }
        }
        return named.union(result)
    }

    /// The types and typealiases the body declares, `#if` clauses included. The macro can't see
    /// which parameters such a type captures, so a field that names one constrains them all.
    private static func localTypeNames(_ members: MemberBlockItemListSyntax) -> Set<String> {
        var names: Set<String> = []
        func walk(_ members: MemberBlockItemListSyntax) {
            for member in members {
                let decl = member.decl
                if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                    for clause in ifConfig.clauses {
                        if case .decls(let nested) = clause.elements { walk(nested) }
                    }
                    continue
                }
                let declared: TokenSyntax?
                if let d = decl.as(StructDeclSyntax.self) { declared = d.name }
                else if let d = decl.as(EnumDeclSyntax.self) { declared = d.name }
                else if let d = decl.as(ClassDeclSyntax.self) { declared = d.name }
                else if let d = decl.as(ActorDeclSyntax.self) { declared = d.name }
                else if let d = decl.as(TypeAliasDeclSyntax.self) { declared = d.name }
                else { declared = nil }
                if let declared { names.insert(declared.identifier?.name ?? declared.text) }
            }
        }
        walk(members)
        return names
    }

    /// The generic parameters of the enclosing types that the stored values' declarations name
    /// (`named`, from `storedNames`): a nested type's field of the parent's `T` is plain data
    /// only where `T` is (#782). A member must spell the parameter: the parent's alias for it,
    /// or a parameter of an enclosing extension's type, isn't read, and such a field stays
    /// refused.
    /// The generic parameters of the enclosing types, by name.
    private static func enclosingParameterNames(in context: some MacroExpansionContext) -> Set<String> {
        var names: Set<String> = []
        for enclosing in context.lexicalContext {
            for parameter in genericParameters(of: enclosing) { names.insert(name(of: parameter)) }
        }
        return names
    }

    /// A struct's, an enum's, a class's or an actor's generic parameters; none for anything else.
    private static func genericParameters(of syntax: Syntax) -> GenericParameterListSyntax {
        if let d = syntax.as(StructDeclSyntax.self) { return d.genericParameterClause?.parameters ?? [] }
        if let d = syntax.as(EnumDeclSyntax.self) { return d.genericParameterClause?.parameters ?? [] }
        if let d = syntax.as(ClassDeclSyntax.self) { return d.genericParameterClause?.parameters ?? [] }
        if let d = syntax.as(ActorDeclSyntax.self) { return d.genericParameterClause?.parameters ?? [] }
        return []
    }

    private static func enclosingParameters(named names: Set<String>, in context: some MacroExpansionContext) -> [String] {
        // Compared by name (`T` and `` `T` ``are one), emitted as spelled: a keyword name such
        // as `` `repeat` `` keeps its backticks in the `where` clause.
        var found: [String] = []
        var foundNames: Set<String> = []
        for enclosing in context.lexicalContext {
            for parameter in genericParameters(of: enclosing) {
                let name = parameter.name.identifier?.name ?? parameter.name.text
                if names.contains(name), foundNames.insert(name).inserted { found.append(parameter.name.text) }
            }
        }
        return found
    }

    /// The witness is as visible as the type: a public type's conformance needs a public one, and
    /// an internal type's can't have one when the extension carries internal requirements. A
    /// type with no access modifier of its own that is a member of an extension takes the
    /// extension's (`public extension Outer { struct Inner }` makes `Inner` public), and a
    /// `@usableFromInline` type's witness is `@usableFromInline` too.
    private static func witnessAccess(of declaration: some DeclGroupSyntax, in context: some MacroExpansionContext) -> String {
        let inlinable = declaration.attributes.contains {
            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "usableFromInline"
        }
        let prefix = inlinable ? "@usableFromInline " : ""
        if let own = explicitAccess(declaration.modifiers) { return prefix + own }
        if let parent = context.lexicalContext.first?.as(ExtensionDeclSyntax.self),
           let inherited = explicitAccess(parent.modifiers) {
            return prefix + inherited
        }
        return prefix
    }

    /// The witness's modifier for an access modifier in `modifiers`, or nil if there is none.
    private static func explicitAccess(_ modifiers: DeclModifierListSyntax) -> String? {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            case .keyword(.internal), .keyword(.fileprivate), .keyword(.private): return ""
            default: continue
            }
        }
        return nil
    }

}
