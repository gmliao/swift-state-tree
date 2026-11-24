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
    ///   - constrainGenerics: whether the extension adds `where T: PlainData` for the type's
    ///     generic parameters and the enclosing ones its members name. `@Payload` passes false
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
        let own = (generics?.parameters ?? []).map(\.name.text)
        let ownNames = Set(own.map { String($0.filter { $0 != "`" }) })
        let enclosing = enclosingParameters(usedIn: members, in: context).filter { !ownNames.contains(String($0.filter { $0 != "`" })) }
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

    /// Cases that share a base name (`case item(count: Int)` and `case item(label: String)`) are
    /// refused: `if case let .item(v0) = value` is ambiguous, and a labelled pattern doesn't
    /// pick one when the arities differ.
    private static func diagnoseSharedCaseNames(
        _ members: MemberBlockItemListSyntax,
        failed: inout Bool,
        _ context: some MacroExpansionContext
    ) {
        // Each `#if` clause starts from the names seen before it: only one clause is active in a
        // build, so two clauses may declare the same case. A name from any clause still clashes
        // with the enclosing list after the `#if`.
        func walk(_ members: MemberBlockItemListSyntax, _ seen: inout Set<String>) {
            for member in members {
                if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
                    var union = seen
                    for clause in ifConfig.clauses {
                        var local = seen
                        if case .decls(let nested) = clause.elements { walk(nested, &local) }
                        union.formUnion(local)
                    }
                    seen = union
                    continue
                }
                guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                for element in cases.elements {
                    // `item` and `` `item` `` are one name.
                    let name = element.name.identifier?.name ?? element.name.text
                    if !seen.insert(name).inserted {
                        context.diagnose(Diagnostic(node: element.name, message: PlainDataDiagnostic.sharedCaseName(name)))
                        failed = true
                    }
                }
            }
        }
        var seen: Set<String> = []
        walk(members, &seen)
    }

    /// The generic parameters of the enclosing types that the stored values' declarations name:
    /// a nested type's field of the parent's `T` is plain data only where `T` is (#782). Only
    /// what the checks read counts: a stored property's type and initializer, and an enum case's
    /// associated values. A parameter that only a method or a computed property names adds no
    /// constraint, so such a nested type stays unconditionally `PlainData`. A member must spell
    /// the parameter: the parent's alias for it, or a parameter of an enclosing extension's type,
    /// isn't read, and such a field stays refused.
    private static func enclosingParameters(usedIn members: MemberBlockItemListSyntax, in context: some MacroExpansionContext) -> [String] {
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
        // Compared by name (`T` and `` `T` ``are one), emitted as spelled: a keyword name such
        // as `` `repeat` `` keeps its backticks in the `where` clause.
        var found: [String] = []
        var foundNames: Set<String> = []
        for enclosing in context.lexicalContext {
            let clause = enclosing.as(StructDeclSyntax.self)?.genericParameterClause
                ?? enclosing.as(EnumDeclSyntax.self)?.genericParameterClause
                ?? enclosing.as(ClassDeclSyntax.self)?.genericParameterClause
                ?? enclosing.as(ActorDeclSyntax.self)?.genericParameterClause
            for parameter in clause?.parameters ?? [] {
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
