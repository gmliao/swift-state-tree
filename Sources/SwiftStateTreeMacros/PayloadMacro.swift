import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Macro that generates `getFieldMetadata()` for Actions and Events.
///
/// This macro analyzes the struct's stored properties and generates a `static func getFieldMetadata()`
/// method that returns metadata for schema generation.
///
/// Example:
/// ```swift
/// @Payload
/// struct MyAction: ActionPayload {
///     let id: String
///     let count: Int
/// }
/// ```
///
/// The macro generates:
/// ```swift
/// extension MyAction {
///     static func getFieldMetadata() -> [FieldMetadata] {
///         return [
///             FieldMetadata(name: "id", type: String.self, policy: nil, nodeKind: .leaf),
///             FieldMetadata(name: "count", type: Int.self, policy: nil, nodeKind: .leaf)
///         ]
///     }
/// }
/// ```
public struct PayloadMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Only support struct declarations
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            let error = PayloadDiagnostics.onlyStructsSupported
            context.diagnose(Diagnostic(node: Syntax(declaration), message: error))
            throw DiagnosticsError(diagnostics: [Diagnostic(node: Syntax(declaration), message: error)])
        }
        
        // Collect all stored properties
        var diagnostics: [Diagnostic] = []
        let properties = collectStoredProperties(from: structDecl, diagnostics: &diagnostics)
        
        if !diagnostics.isEmpty {
            throw DiagnosticsError(diagnostics: diagnostics)
        }
        
        // Generate getFieldMetadata() method
        let getFieldMetadataMethod = try generateGetFieldMetadata(properties: properties)
        
        return [DeclSyntax(getFieldMetadataMethod)]
    }
    
    /// Collect all stored properties from a struct declaration
    private static func collectStoredProperties(from structDecl: StructDeclSyntax, diagnostics: inout [Diagnostic]) -> [PropertyInfo] {
        var properties: [PropertyInfo] = []
        
        for member in structDecl.memberBlock.members {
            guard let variableDecl = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            
            // Skip computed properties
            let hasComputedProperty = variableDecl.bindings.contains { binding in
                return binding.accessorBlock != nil
            }
            
            if hasComputedProperty {
                continue
            }
            
            for binding in variableDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }
                
                let propertyName = pattern.identifier.text
                
                // Extract type information
                var typeName: String? = nil
                if let typeAnnotation = binding.typeAnnotation {
                    typeName = typeAnnotation.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                if let typeName, typeName.contains("?") {
                    diagnostics.append(
                        Diagnostic(
                            node: Syntax(binding.pattern),
                            message: PayloadDiagnostics.optionalNotSupported(propertyName: propertyName)
                        )
                    )
                }
                
                let initializer = binding.initializer?.value.description.trimmingCharacters(in: .whitespacesAndNewlines)
                
                properties.append(
                    PropertyInfo(
                        name: propertyName,
                        typeName: typeName,
                        initializer: initializer
                    )
                )
            }
        }
        
        return properties
    }
    
    /// Generate getFieldMetadata() method
    private static func generateGetFieldMetadata(properties: [PropertyInfo]) throws -> FunctionDeclSyntax {
        var arrayElements: [ArrayElementSyntax] = []
        
        for (index, property) in properties.enumerated() {
            let typeName = property.typeName ?? "Any"
            
            let defaultValueExpr: String
            if let initializer = property.initializer {
                if initializer == "nil" {
                    defaultValueExpr = "SnapshotValue.null"
                } else {
                    defaultValueExpr = "try? SnapshotValue.make(from: (\(initializer)) as Any)"
                }
            } else {
                defaultValueExpr = "nil"
            }
            
            let trailingComma = index < properties.count - 1 ? TokenSyntax.commaToken() : nil
            
            // We use SchemaHelper.determineNodeKind(from: Type.self) to get the node kind at runtime
            let element = ArrayElementSyntax(
                expression: ExprSyntax(
                    """
                    FieldMetadata(
                        name: "\(raw: property.name)",
                        type: \(raw: typeName).self,
                        policy: nil,
                        nodeKind: SchemaHelper.determineNodeKind(from: \(raw: typeName).self),
                        defaultValue: \(raw: defaultValueExpr)
                    )
                    """
                ),
                trailingComma: trailingComma
            )
            arrayElements.append(element)
        }
        
        let arrayExpr = ArrayExprSyntax(elements: ArrayElementListSyntax(arrayElements))
        
        return try FunctionDeclSyntax(
            """
            public static func getFieldMetadata() -> [FieldMetadata] {
                return \(arrayExpr)
            }
            """
        )
    }
}

/// Information about a property
private struct PropertyInfo {
    let name: String
    let typeName: String?
    let initializer: String?
}

private struct PayloadDiagnostics: DiagnosticMessage, @unchecked Sendable {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
    
    static let onlyStructsSupported: PayloadDiagnostics = PayloadDiagnostics(
        message: "@Payload can only be applied to struct declarations",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "payloadOnlyStructs"),
        severity: .error
    )
    
    static func optionalNotSupported(propertyName: String) -> PayloadDiagnostics {
        PayloadDiagnostics(
            message: "Payload field '\(propertyName)' cannot be Optional; use a concrete value with a default instead",
            diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "payloadOptionalNotSupported"),
            severity: .error
        )
    }
}
