// Sources/SwiftStateTreeMacros/StateMacro.swift

@preconcurrency import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Macro that validates State types conform to StateProtocol.
///
/// This macro ensures that all State types:
/// - Conform to `StateProtocol` (which requires `Codable` and `Sendable`)
/// - Are struct types (not classes)
///
/// The macro performs compile-time validation and does not generate any code.
/// It serves as a marker and validation tool to ensure type safety.
///
/// Example:
/// ```swift
/// @State
/// struct PlayerState: StateProtocol {
///     var name: String
///     var hpCurrent: Int
///     var hpMax: Int
/// }
/// ```
public struct StateMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Only support struct declarations
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            let error = StateMacroError.onlyStructsSupported(node: Syntax(declaration))
            error.diagnose(context: context)
            throw error
        }
        
        // Check if struct conforms to StateProtocol
        let inheritedTypes = structDecl.inheritanceClause?.inheritedTypes ?? []
        let hasStateProtocol = inheritedTypes.contains { inherited in
            if let type = inherited.type.as(IdentifierTypeSyntax.self) {
                return type.name.text == "StateProtocol"
            }
            return false
        }
        
        if !hasStateProtocol {
            let error = StateMacroError.missingStateProtocol(node: Syntax(structDecl))
            error.diagnose(context: context)
            throw error
        }
        
        // This macro only validates, doesn't generate code
        return []
    }
}

/// Information about a property in a State
private struct PropertyInfo {
    let name: String
    let typeName: String?
}

/// Macro errors
private enum StateMacroError: Error, @unchecked Sendable {
    case onlyStructsSupported(node: Syntax)
    case missingStateProtocol(node: Syntax)
    
    func diagnose(context: some MacroExpansionContext) {
        switch self {
        case .onlyStructsSupported(let node):
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: StateMacroDiagnostic.onlyStructsSupported
                )
            )
        case .missingStateProtocol(let node):
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: StateMacroDiagnostic.missingStateProtocol
                )
            )
        }
    }
}

/// Diagnostic messages for State macro
private struct StateMacroDiagnostic: DiagnosticMessage, @unchecked Sendable {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
    
    static let onlyStructsSupported: StateMacroDiagnostic = StateMacroDiagnostic(
        message: "@State can only be applied to struct declarations",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "stateOnlyStructs"),
        severity: .error
    )
    
    static let missingStateProtocol: StateMacroDiagnostic = StateMacroDiagnostic(
        message: "Struct marked with @State must conform to StateProtocol",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "stateMissingProtocol"),
        severity: .error
    )
}

