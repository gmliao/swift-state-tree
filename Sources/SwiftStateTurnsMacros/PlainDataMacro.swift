// `@PlainData`: the conformance, and one compile-time check per stored property or associated
// value. A syntactic macro can't see types, so what it can't check it refuses with a diagnostic.
// The checks read the stored values, never a spelled type: the extension is at file scope, where
// a type name can resolve to something else than in the declaration's own scope (a namesake at
// file scope, or a sibling nested in the same outer type that isn't visible there at all).

import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import PlainDataMacroSupport
import SwiftSyntaxMacros

public struct PlainDataMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
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
        let enclosing = enclosingParameters(usedIn: members, in: context).filter { !own.contains($0) }
        let constraints = (own + enclosing).map { "\($0): SwiftStateTurns.PlainData" }
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

    /// The generic parameters of the enclosing types that the members name: a nested type's
    /// field of the parent's `T` is plain data only where `T` is (#782). One the members don't
    /// name adds no constraint, so a nested type that doesn't use it stays unconditionally
    /// `PlainData`. A parameter of an enclosing extension's type isn't spelled there, so it
    /// can't be read; such a field stays refused.
    private static func enclosingParameters(usedIn members: MemberBlockItemListSyntax, in context: some MacroExpansionContext) -> [String] {
        let names = Set(members.tokens(viewMode: .sourceAccurate).compactMap { $0.identifier?.name })
        var found: [String] = []
        for enclosing in context.lexicalContext {
            let clause = enclosing.as(StructDeclSyntax.self)?.genericParameterClause
                ?? enclosing.as(EnumDeclSyntax.self)?.genericParameterClause
                ?? enclosing.as(ClassDeclSyntax.self)?.genericParameterClause
                ?? enclosing.as(ActorDeclSyntax.self)?.genericParameterClause
            for parameter in clause?.parameters ?? [] {
                let name = parameter.name.identifier?.name ?? parameter.name.text
                if names.contains(name), !found.contains(name) { found.append(name) }
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

@main
struct SwiftStateTurnsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PlainDataMacro.self]
}
