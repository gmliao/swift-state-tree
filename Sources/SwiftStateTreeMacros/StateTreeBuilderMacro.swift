// Sources/SwiftStateTreeMacros/StateTreeBuilderMacro.swift

@preconcurrency import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Macro that validates and generates code for StateTree types.
///
/// This macro:
/// 1. Validates that all stored properties have @Sync or @Internal markers
/// 2. Generates `getSyncFields()` method implementation
/// 3. Generates `validateSyncFields()` method implementation
public struct StateTreeBuilderMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Only support struct declarations
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            let error = MacroError.onlyStructsSupported(node: Syntax(declaration))
            error.diagnose(context: context)
            throw error
        }
        
        // Collect all stored properties
        let propertiesWithNodes = collectStoredProperties(from: structDecl)
        let properties = propertiesWithNodes.map { $0.0 }
        
        // Validate all stored properties have @Sync or @Internal
        try validateProperties(propertiesWithNodes, context: context)
        
        // Generate getSyncFields() method
        let getSyncFieldsMethod = try generateGetSyncFields(properties: properties)
        
        // Generate validateSyncFields() method
        let validateSyncFieldsMethod = try generateValidateSyncFields(properties: properties)
        
        return [
            DeclSyntax(getSyncFieldsMethod),
            DeclSyntax(validateSyncFieldsMethod)
        ]
    }
    
    /// Collect all stored properties from a struct declaration
    private static func collectStoredProperties(from structDecl: StructDeclSyntax) -> [(PropertyInfo, Syntax)] {
        var properties: [(PropertyInfo, Syntax)] = []
        
        for member in structDecl.memberBlock.members {
            guard let variableDecl = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            
            // Skip computed properties (they don't have bindings with initializers or are marked with get/set)
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
                
                // Check for @Sync or @Internal attribute
                let hasSync = variableDecl.attributes.contains { attr in
                    if let attribute = attr.as(AttributeSyntax.self) {
                        let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
                        return name == "Sync"
                    }
                    return false
                }
                
                let hasInternal = variableDecl.attributes.contains { attr in
                    if let attribute = attr.as(AttributeSyntax.self) {
                        let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
                        return name == "Internal"
                    }
                    return false
                }
                
                // Extract policy type from @Sync attribute
                var policyType: String? = nil
                if hasSync {
                    if let attribute = variableDecl.attributes.first(where: { attr in
                        if let attr = attr.as(AttributeSyntax.self) {
                            return attr.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Sync"
                        }
                        return false
                    })?.as(AttributeSyntax.self) {
                        policyType = extractPolicyType(from: attribute)
                    }
                }
                
                properties.append((
                    PropertyInfo(
                        name: propertyName,
                        hasSync: hasSync,
                        hasInternal: hasInternal,
                        policyType: policyType
                    ),
                    Syntax(variableDecl)
                ))
            }
        }
        
        return properties
    }
    
    /// Extract policy type from @Sync attribute
    private static func extractPolicyType(from attribute: AttributeSyntax) -> String? {
        guard let argument = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return nil
        }
        
        // Look for the first argument (the policy)
        if let firstArg = argument.first {
            // Try to extract the policy type from the argument
            // Examples: .broadcast, .serverOnly, .perPlayerDictionaryValue()
            if let memberAccess = firstArg.expression.as(MemberAccessExprSyntax.self) {
                return memberAccess.declName.baseName.text
            }
            
            // Handle function calls like .perPlayerDictionaryValue()
            if let functionCall = firstArg.expression.as(FunctionCallExprSyntax.self) {
                if let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) {
                    return memberAccess.declName.baseName.text
                }
            }
        }
        
        return "unknown"
    }
    
    /// Validate that all stored properties have @Sync or @Internal markers
    private static func validateProperties(
        _ properties: [(PropertyInfo, Syntax)],
        context: some MacroExpansionContext
    ) throws {
        for (property, node) in properties {
            if !property.hasSync && !property.hasInternal {
                let error = MacroError.missingMarker(
                    propertyName: property.name,
                    structName: "StateTree",
                    node: node
                )
                error.diagnose(context: context)
                throw error
            }
        }
    }
    
    /// Generate getSyncFields() method
    private static func generateGetSyncFields(properties: [PropertyInfo]) throws -> FunctionDeclSyntax {
        let syncProperties = properties.filter { $0.hasSync }
        
        var arrayElements: [ArrayElementSyntax] = []
        
        for (index, property) in syncProperties.enumerated() {
            let policyType = property.policyType ?? "unknown"
            let trailingComma = index < syncProperties.count - 1 ? TokenSyntax.commaToken() : nil
            let element = ArrayElementSyntax(
                expression: ExprSyntax(
                    """
                    SyncFieldInfo(name: "\(raw: property.name)", policyType: "\(raw: policyType)")
                    """
                ),
                trailingComma: trailingComma
            )
            arrayElements.append(element)
        }
        
        let arrayExpr = ArrayExprSyntax(elements: ArrayElementListSyntax(arrayElements))
        
        return try FunctionDeclSyntax(
            """
            public func getSyncFields() -> [SyncFieldInfo] {
                return \(arrayExpr)
            }
            """
        )
    }
    
    /// Generate validateSyncFields() method
    private static func generateValidateSyncFields(properties: [PropertyInfo]) throws -> FunctionDeclSyntax {
        // Since we validate at compile time, this can always return true
        return try FunctionDeclSyntax(
            """
            public func validateSyncFields() -> Bool {
                return true
            }
            """
        )
    }
}

/// Information about a property in a StateTree
private struct PropertyInfo {
    let name: String
    let hasSync: Bool
    let hasInternal: Bool
    let policyType: String?
}

/// Macro errors
private enum MacroError: Error, @unchecked Sendable {
    case onlyStructsSupported(node: Syntax)
    case missingMarker(propertyName: String, structName: String, node: Syntax)
    
    func diagnose(context: some MacroExpansionContext) {
        switch self {
        case .onlyStructsSupported(let node):
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: StateTreeBuilderDiagnostic.onlyStructsSupported
                )
            )
        case .missingMarker(let propertyName, let structName, let node):
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: StateTreeBuilderDiagnostic.missingMarker(propertyName: propertyName, structName: structName)
                )
            )
        }
    }
}

/// Diagnostic messages for StateTreeBuilder macro
private struct StateTreeBuilderDiagnostic: DiagnosticMessage, @unchecked Sendable {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
    
    static let onlyStructsSupported: StateTreeBuilderDiagnostic = StateTreeBuilderDiagnostic(
        message: "@StateTreeBuilder can only be applied to struct declarations",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "onlyStructsSupported"),
        severity: .error
    )
    
    static func missingMarker(propertyName: String, structName: String) -> StateTreeBuilderDiagnostic {
        StateTreeBuilderDiagnostic(
            message: "Stored property '\(propertyName)' in \(structName) must be marked with @Sync or @Internal",
            diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "missingMarker"),
            severity: .error
        )
    }
}

@main
struct SwiftStateTreeMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StateTreeBuilderMacro.self
    ]
}
