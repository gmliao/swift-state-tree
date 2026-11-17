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
        conformingTo protocols: [TypeSyntax],
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
        
        // The positional writer, its field forms and the wire name (#521), fields in name order
        members.append(contentsOf: generateWriterMembers(properties: properties))
        if let wireName = wireName(of: structDecl, in: context) {
            members.append("public static var _payloadWireName: String { \(literal: wireName) }")
        }
        
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
            // No `typealias Response` in the struct (a nested type or an extension declares it):
            // the associated type itself, which the conformance always has.
            return try FunctionDeclSyntax(
                """
                public static func getResponseType() -> Any.Type {
                    return Response.self
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
    
    /// The positional writer (#521): each field, in name order, handed to the encoder's writer,
    /// whose two `field(_:)` overloads pick the typed form or the `Codable` fallback from the
    /// field's declared type. `_payloadFieldForms` lists the same choice through the same
    /// overloads. The writer's generic parameter has a reserved name, so it can't shadow one of
    /// the payload's own.
    private static func generateWriterMembers(properties: [PropertyInfo]) -> [DeclSyntax] {
        let writes = properties.map { "    try writer.field(self.\($0.name))" }.joined(separator: "\n")
        let forms = properties
            .map { "_PayloadFieldFormEntry(\"\($0.name)\", _payloadFieldForm(of: \\Self.\($0.name)))" }
            .joined(separator: ", ")
        return [
            """
            public func _writePayloadFields<__PayloadWriter: _PayloadFieldWriter>(into writer: inout __PayloadWriter) throws {
            \(raw: writes)
            }
            """,
            "public static var _payloadHasTypedWriter: Bool { true }",
            "public static var _payloadFieldForms: [_PayloadFieldFormEntry] { [\(raw: forms)] }",
        ]
    }

    /// The schema's name for the type, fixed at expansion: an event's name without an `Event`
    /// suffix, an action's without `Action`. Nil (the protocol's runtime rule applies) when the
    /// conformance isn't in the struct's own inheritance clause, or when the type may be generic:
    /// its own parameters, or any enclosing context that isn't a plain non-generic type.
    private static func wireName(of structDecl: StructDeclSyntax, in context: some MacroExpansionContext) -> String? {
        guard structDecl.genericParameterClause == nil else { return nil }
        for enclosing in context.lexicalContext {
            if let decl = enclosing.as(StructDeclSyntax.self) {
                if decl.genericParameterClause != nil { return nil }
            } else if let decl = enclosing.as(ClassDeclSyntax.self) {
                if decl.genericParameterClause != nil { return nil }
            } else if let decl = enclosing.as(EnumDeclSyntax.self) {
                if decl.genericParameterClause != nil { return nil }
            } else if let decl = enclosing.as(ActorDeclSyntax.self) {
                if decl.genericParameterClause != nil { return nil }
            } else {
                return nil
            }
        }
        let name = structDecl.name.text
        let inherited = Set(structDecl.inheritanceClause?.inheritedTypes.compactMap {
            $0.type.trimmedDescription.split(separator: ".").last.map(String.init)
        } ?? [])
        let isEvent = inherited.contains("ServerEventPayload") || inherited.contains("ClientEventPayload")
        let isAction = inherited.contains("ActionPayload")
        if isEvent == isAction { return nil }
        let suffix = isAction ? "Action" : "Event"
        return name.hasSuffix(suffix) ? String(name.dropLast(suffix.count)) : name
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
