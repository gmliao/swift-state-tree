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
        // Collect all stored properties and sort them by name (ASCII)
        var diagnostics: [Diagnostic] = []
        let properties = collectStoredProperties(from: structDecl, diagnostics: &diagnostics)
            .sorted { $0.name < $1.name }
        
        if !diagnostics.isEmpty {
            throw DiagnosticsError(diagnostics: diagnostics)
        }
        
        // Generate getFieldMetadata() method
        let getFieldMetadataMethod = try generateGetFieldMetadata(properties: properties)
        
        var members: [DeclSyntax] = [DeclSyntax(getFieldMetadataMethod)]
        
        // Generate encodeAsArray() method for PayloadCompression protocol
        // This ensures correct field order for opcode-based compression
        let encodeAsArrayMethod = try generateEncodeAsArray(properties: properties, structName: structDecl.name.text)
        members.append(DeclSyntax(encodeAsArrayMethod))
        
        // Always generate getResponseType() for ActionPayload types
        // This ensures the macro declaration covers it
        if conformsToActionPayload(structDecl) {
            // Always generate the method, even if Response typealias is not found
            // This satisfies Swift macro system's requirement that all generated symbols are declared
            let responseTypeMethod = try generateGetResponseTypeOrFallback(from: structDecl)
            members.append(DeclSyntax(responseTypeMethod))
        }
        
        return members
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
    
    /// Check if struct conforms to ActionPayload
    private static func conformsToActionPayload(_ structDecl: StructDeclSyntax) -> Bool {
        guard let inheritanceClause = structDecl.inheritanceClause else {
            return false
        }
        
        return inheritanceClause.inheritedTypes.contains { inheritedType in
            let typeName = inheritedType.type.trimmedDescription
            if typeName.split(separator: ".").last == "ActionPayload" {
                return true
            }
            
            if let identifier = inheritedType.type.as(IdentifierTypeSyntax.self)?.name.text {
                return identifier == "ActionPayload"
            }
            
            return false
        }
    }
    
    /// Extract Response type from ActionPayload typealias
    private static func extractResponseType(from structDecl: StructDeclSyntax) -> String? {
        for member in structDecl.memberBlock.members {
            // Check for typealias Response = ...
            if let typeAlias = member.decl.as(TypeAliasDeclSyntax.self) {
                if typeAlias.name.text == "Response" {
                    // Extract the type from the initializer
                    let initializer = typeAlias.initializer
                    return initializer.value.trimmedDescription
                }
            }
        }
        return nil
    }
    
    /// Generate getResponseType() method for ActionPayload
    private static func generateGetResponseTypeOrFallback(from structDecl: StructDeclSyntax) throws -> FunctionDeclSyntax {
        if let responseTypeName = extractResponseType(from: structDecl) {
            // Generate implementation with extracted Response type
            return try FunctionDeclSyntax(
                """
                public static func getResponseType() -> Any.Type {
                    return \(raw: responseTypeName).self
                }
                """
            )
        } else {
            // Generate a fallback that throws an error
            // This ensures the method is always generated for ActionPayload types
            return try FunctionDeclSyntax(
                """
                public static func getResponseType() -> Any.Type {
                    fatalError("getResponseType() must have a typealias Response = ... in \(raw: structDecl.name.text)")
                }
                """
            )
        }
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
    
    /// Generate encodeAsArray() method for PayloadCompression protocol
    /// This method encodes the payload as an array using the exact field order from the struct declaration
    private static func generateEncodeAsArray(properties: [PropertyInfo], structName: String) throws -> FunctionDeclSyntax {
        guard !properties.isEmpty else {
            // Empty struct - return empty array
            return try FunctionDeclSyntax(
                """
                public func encodeAsArray() -> [AnyCodable] {
                    return []
                }
                """
            )
        }
        
        // Generate array elements in declaration order
        var arrayElements: [String] = []
        for property in properties {
            arrayElements.append("AnyCodable(self.\(property.name))")
        }
        
        let arrayBody = arrayElements.joined(separator: ", ")
        
        return try FunctionDeclSyntax(
            """
            public func encodeAsArray() -> [AnyCodable] {
                return [\(raw: arrayBody)]
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
