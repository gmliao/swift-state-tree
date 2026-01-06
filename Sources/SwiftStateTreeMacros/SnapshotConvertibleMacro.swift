// Sources/SwiftStateTreeMacros/SnapshotConvertibleMacro.swift

@preconcurrency import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Macro that automatically generates `SnapshotValueConvertible` protocol conformance.
///
/// This macro analyzes the struct's stored properties and generates a `toSnapshotValue()` method
/// that efficiently converts the struct to `SnapshotValue` without using runtime reflection.
///
/// Example:
/// ```swift
/// @SnapshotConvertible
/// struct PlayerState: Codable {
///     var name: String
///     var hpCurrent: Int
///     var hpMax: Int
/// }
/// ```
///
/// The macro generates:
/// ```swift
/// extension PlayerState: SnapshotValueConvertible {
///     func toSnapshotValue() throws -> SnapshotValue {
///         return .object([
///             "name": .string(name),
///             "hpCurrent": .int(hpCurrent),
///             "hpMax": .int(hpMax)
///         ])
///     }
/// }
/// ```
public struct SnapshotConvertibleMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Only support struct declarations
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            let error = SnapshotConvertibleError.onlyStructsSupported(node: Syntax(declaration))
            error.diagnose(context: context)
            throw error
        }
        
        // Collect all stored properties
        let properties = collectStoredProperties(from: structDecl)
        
        // Generate toSnapshotValue() method
        let toSnapshotValueMethod = try generateToSnapshotValueMethod(properties: properties)
        
        // Create extension that conforms to SnapshotValueConvertible
        let extensionDecl = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): SnapshotValueConvertible {
                \(toSnapshotValueMethod)
            }
            """
        )
        
        return [extensionDecl]
    }
    
    /// Collect all stored properties from a struct declaration
    private static func collectStoredProperties(from structDecl: StructDeclSyntax) -> [PropertyInfo] {
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
            
            // Skip static properties (they're not part of the instance)
            let isStatic = variableDecl.modifiers.contains { modifier in
                modifier.name.text == "static"
            }
            if isStatic {
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
                
                properties.append(
                    PropertyInfo(
                        name: propertyName,
                        typeName: typeName
                    )
                )
            }
        }
        
        return properties
    }
    
    /// Generate toSnapshotValue() method implementation
    private static func generateToSnapshotValueMethod(properties: [PropertyInfo]) throws -> FunctionDeclSyntax {
        guard !properties.isEmpty else {
            // Empty struct: return empty object
            return try FunctionDeclSyntax(
                """
                public func toSnapshotValue() throws -> SnapshotValue {
                    return .object([:])
                }
                """
            )
        }
        
        var codeLines: [String] = []
        codeLines.append("return .object([")
        
        // Generate code for each property
        for (index, property) in properties.enumerated() {
            let propertyName = property.name
            let conversionCode = generatePropertyConversionCode(for: property.typeName, propertyName: propertyName)
            
            let comma = index < properties.count - 1 ? "," : ""
            codeLines.append("    \"\(propertyName)\": \(conversionCode)\(comma)")
        }
        
        codeLines.append("])")
        
        let body = codeLines.joined(separator: "\n")
        
        return try FunctionDeclSyntax(
            """
            public func toSnapshotValue() throws -> SnapshotValue {
                \(raw: body)
            }
            """
        )
    }
    
    /// Generate conversion code for a property
    private static func generatePropertyConversionCode(for typeName: String?, propertyName: String) -> String {
        guard let typeName = typeName else {
            // Unknown type, use make(from:) as fallback
            return "try SnapshotValue.make(from: \(propertyName))"
        }
        
        let normalizedType = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if it's an Optional type
        if normalizedType.hasSuffix("?") {
            // Optional type: use make(from:) to handle nil properly
            return "try SnapshotValue.make(from: \(propertyName))"
        }
        
        if normalizedType.hasPrefix("Optional<") && normalizedType.hasSuffix(">") {
            // Optional<Type> format: use make(from:) to handle nil properly
            return "try SnapshotValue.make(from: \(propertyName))"
        }
        
        // Handle basic types with direct conversion (no Mirror needed)
        switch normalizedType {
        case "Bool":
            return ".bool(\(propertyName))"
        case "Int":
            return ".int(\(propertyName))"
        case "Int8":
            return ".int(Int(\(propertyName)))"
        case "Int16":
            return ".int(Int(\(propertyName)))"
        case "Int32":
            return ".int(Int(\(propertyName)))"
        case "Int64":
            return ".int(Int(\(propertyName)))"
        case "UInt":
            return ".int(Int(\(propertyName)))"
        case "UInt8":
            return ".int(Int(\(propertyName)))"
        case "UInt16":
            return ".int(Int(\(propertyName)))"
        case "UInt32":
            return ".int(Int(\(propertyName)))"
        case "UInt64":
            return ".int(Int(\(propertyName)))"
        case "Double":
            return ".double(\(propertyName))"
        case "Float":
            return ".double(Double(\(propertyName)))"
        case "String":
            return ".string(\(propertyName))"
        case "PlayerID":
            return ".string(\(propertyName).rawValue)"
        default:
            // Complex types (structs, classes, arrays, dictionaries, etc.)
            // Use make(from:) which will:
            // 1. Check for SnapshotValueConvertible protocol first
            // 2. Fall back to Mirror for nested structures
            return "try SnapshotValue.make(from: \(propertyName))"
        }
    }
}

/// Information about a property in a struct
private struct PropertyInfo {
    let name: String
    let typeName: String?
}

/// Macro errors
private enum SnapshotConvertibleError: Error, @unchecked Sendable {
    case onlyStructsSupported(node: Syntax)
    
    func diagnose(context: some MacroExpansionContext) {
        switch self {
        case .onlyStructsSupported(let node):
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: SnapshotConvertibleDiagnostic.onlyStructsSupported
                )
            )
        }
    }
}

/// Diagnostic messages for SnapshotConvertible macro
private struct SnapshotConvertibleDiagnostic: DiagnosticMessage, @unchecked Sendable {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity
    
    static let onlyStructsSupported: SnapshotConvertibleDiagnostic = SnapshotConvertibleDiagnostic(
        message: "@SnapshotConvertible can only be applied to struct declarations",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "snapshotConvertibleOnlyStructs"),
        severity: .error
    )
}

