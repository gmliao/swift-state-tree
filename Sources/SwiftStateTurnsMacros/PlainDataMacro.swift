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
        let constraints = (generics?.parameters ?? []).map { "\($0.name.text): SwiftStateTurns.PlainData" }
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
    /// pick one when the arities differ. Cases in `#if` clauses count as one list, so two
    /// exclusive clauses that declare the same case are refused too.
    private static func diagnoseSharedCaseNames(
        _ members: MemberBlockItemListSyntax,
        failed: inout Bool,
        _ context: some MacroExpansionContext
    ) {
        var seen: Set<String> = []
        func walk(_ members: MemberBlockItemListSyntax) {
            for member in members {
                if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
                    for clause in ifConfig.clauses {
                        if case .decls(let nested) = clause.elements { walk(nested) }
                    }
                    continue
                }
                guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
                for element in cases.elements where !seen.insert(element.name.text).inserted {
                    context.diagnose(Diagnostic(node: element.name, message: PlainDataDiagnostic.sharedCaseName(element.name.text)))
                    failed = true
                }
            }
        }
        walk(members)
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
