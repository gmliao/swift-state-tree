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
        // Another macro on the type could add members the witness doesn't see (#837).
        if PlainDataAttributes.checks("PlainData", on: declaration.attributes) {
            PlainDataAttributes.diagnoseType(declaration.attributes, rule: PlainDataAttributes.plainData, in: context)
        }
        return PlainDataExtension.build(of: node, attachedTo: declaration, providingExtensionsOf: type, conformingTo: protocols, in: context)
    }
}

@main
struct SwiftStateTurnsMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PlainDataMacro.self]
}
