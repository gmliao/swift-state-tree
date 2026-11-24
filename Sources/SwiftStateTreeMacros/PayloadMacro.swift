import SwiftCompilerPlugin
import PlainDataMacroSupport
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
        
        // The field types are checked by the extension role, through `@PlainData`'s walk: a
        // Decimal (#597), a class, a closure or an existential is refused there, once.
        if !diagnostics.isEmpty {
            throw DiagnosticsError(diagnostics: diagnostics)
        }

        // Generate getFieldMetadata() method
        let getFieldMetadataMethod = try generateGetFieldMetadata(properties: properties)
        
        var members: [DeclSyntax] = [DeclSyntax(getFieldMetadataMethod)]
        
        // The positional writer, its field forms and the wire name (#521), fields in name order
        members.append(contentsOf: generateWriterMembers(properties: properties))
        members.append(generateWireKeys(of: structDecl, properties: properties))
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
                        name: "\(raw: property.wireName)",
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
            .map { "_PayloadFieldFormEntry(\"\($0.wireName)\", _payloadFieldForm(of: \\Self.\($0.name)))" }
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

    /// `_payloadWireKeys` (#521 D15): each stored property whose `CodingKeys` case has a raw
    /// value other than its name. Only a `CodingKeys` enum in the struct's own body is read; one
    /// declared in an extension, and a custom `encode(to:)`, are outside the expansion.
    private static func generateWireKeys(of structDecl: StructDeclSyntax, properties: [PropertyInfo]) -> DeclSyntax {
        var keys: [(String, String)] = []
        let stored = Set(properties.map(\.wireName))
        for member in structDecl.memberBlock.members {
            guard let enumDecl = member.decl.as(EnumDeclSyntax.self), enumDecl.name.text == "CodingKeys" else { continue }
            for caseMember in enumDecl.memberBlock.members {
                guard let caseDecl = caseMember.decl.as(EnumCaseDeclSyntax.self) else { continue }
                for element in caseDecl.elements {
                    let name = String(element.name.text.filter { $0 != "`" })
                    guard stored.contains(name),
                          let literal = element.rawValue?.value.as(StringLiteralExprSyntax.self),
                          let raw = literal.representedLiteralValue,
                          raw != name
                    else { continue }
                    keys.append((name, raw))
                }
            }
        }
        let entries = keys.sorted { $0.0 < $1.0 }
            .map { "\(StringLiteralExprSyntax(content: $0.0)): \(StringLiteralExprSyntax(content: $0.1))" }
        let body = entries.isEmpty ? "[:]" : "[\(entries.joined(separator: ", "))]"
        return "public static var _payloadWireKeys: [String: String] { \(raw: body) }"
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

    /// The name a synthesized `Codable` gives the property: without the backticks a keyword
    /// name (`` `default` ``) is declared with.
    var wireName: String { String(name.filter { $0 != "`" }) }
}

// MARK: - The extension role: the type is PlainData

extension PayloadMacro: ExtensionMacro {
    /// The protocols a payload conforms through; each refines `PlainData`.
    static let payloadProtocols: Set<String> = [
        "ActionPayload", "ClientEventPayload", "ServerEventPayload", "ServerInputPayload", "ResponsePayload", "ResolverOutput",
    ]

    /// Writes `@PlainData`'s extension with the shared builder: the witness, and the conformance
    /// when the type doesn't already conform through a payload protocol.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // The member role reports a declaration that isn't a struct.
        guard let structDecl = declaration.as(StructDeclSyntax.self) else { return [] }
        var failed = false
        for attribute in structDecl.attributes {
            guard case .attribute(let other) = attribute else { continue }
            switch other.attributeName.trimmedDescription.split(separator: ".").last.map(String.init) {
            case "PlainData":
                context.diagnose(Diagnostic(node: other, message: PayloadDiagnostics.besidePlainData))
                failed = true
            case "SnapshotConvertible":
                context.diagnose(Diagnostic(node: other, message: PayloadDiagnostics.besideSnapshotConvertible))
                failed = true
            default:
                break
            }
        }
        let conformsThroughPayload = structDecl.inheritanceClause?.inheritedTypes.contains {
            payloadProtocols.contains(lastName($0.type))
        } ?? false
        if conformsThroughPayload { diagnoseUnconstrainedParameters(of: structDecl, failed: &failed, context) }
        if failed { return [] }
        return PlainDataExtension.build(
            of: node,
            attachedTo: declaration,
            providingExtensionsOf: type,
            conformingTo: protocols,
            constrainGenerics: !protocols.isEmpty,
            in: context
        )
    }

    /// A payload conforms unconditionally, so a generic parameter that a stored property names
    /// must be `PlainData` itself: declared on the parameter or in a `where` requirement on it,
    /// as `PlainData` or one of the payload protocols. The diagnostic fires only where the
    /// macro can tell: no constraint, or only standard protocols that don't refine `PlainData`.
    /// A spelling the macro can't read (an alias, another refining protocol) passes here and is
    /// left to the compiler.
    private static func diagnoseUnconstrainedParameters(
        of structDecl: StructDeclSyntax,
        failed: inout Bool,
        _ context: some MacroExpansionContext
    ) {
        let plain = payloadProtocols.union(["PlainData"])
        // Standard protocols that don't make a type PlainData, and the words around them.
        let notPlain: Set<String> = [
            "Codable", "Encodable", "Decodable", "Sendable", "Hashable", "Equatable", "Comparable",
            "Copyable", "Escapable", "BitwiseCopyable", "Swift", "any", "&", "~",
        ]
        for parameter in structDecl.genericParameterClause?.parameters ?? [] {
            let name = parameter.name.identifier?.name ?? parameter.name.text
            guard let field = storedProperty(naming: name, in: structDecl) else { continue }
            var constraints: [Syntax] = parameter.inheritedType.map { [Syntax($0)] } ?? []
            for requirement in structDecl.genericWhereClause?.requirements ?? [] {
                if case .conformanceRequirement(let conformance) = requirement.requirement,
                   conformance.leftType.trimmedDescription == name {
                    constraints.append(Syntax(conformance.rightType))
                }
            }
            let names = constraints.flatMap { $0.tokens(viewMode: .sourceAccurate).map { $0.identifier?.name ?? $0.text } }
            let constrained = names.contains { plain.contains($0) }
            let unreadable = names.contains { !notPlain.contains($0) && !plain.contains($0) }
            if !constrained && !unreadable {
                context.diagnose(Diagnostic(node: parameter.name, message: PayloadDiagnostics.unconstrainedParameter(name, field: field)))
                failed = true
            }
        }
    }

    /// The first stored property whose type names `parameter`.
    private static func storedProperty(naming parameter: String, in structDecl: StructDeclSyntax) -> String? {
        for member in structDecl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) else { continue }
            for binding in variable.bindings where binding.accessorBlock == nil {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      let type = binding.typeAnnotation?.type else { continue }
                if type.tokens(viewMode: .sourceAccurate).contains(where: { ($0.identifier?.name ?? $0.text) == parameter }) {
                    return pattern.identifier.identifier?.name ?? pattern.identifier.text
                }
            }
        }
        return nil
    }

    private static func lastName(_ type: TypeSyntax) -> String {
        if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
        return type.trimmedDescription
    }
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
    
    static let besidePlainData = PayloadDiagnostics(
        message: "@Payload already makes this type PlainData; remove @PlainData",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "payloadBesidePlainData"),
        severity: .error
    )

    static let besideSnapshotConvertible = PayloadDiagnostics(
        message: "@Payload and @SnapshotConvertible both write getFieldMetadata(); a payload uses @Payload only",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "payloadBesideSnapshotConvertible"),
        severity: .error
    )

    static func unconstrainedParameter(_ name: String, field: String) -> PayloadDiagnostics {
        PayloadDiagnostics(
            message: "generic parameter '\(name)' is stored in '\(field)'; a payload must declare '\(name): PlainData'",
            diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "payloadUnconstrainedParameter"),
            severity: .error
        )
    }

    static func optionalNotSupported(propertyName: String) -> PayloadDiagnostics {
        PayloadDiagnostics(
            message: "Payload field '\(propertyName)' cannot be Optional; use a concrete value with a default instead",
            diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "payloadOptionalNotSupported"),
            severity: .error
        )
    }
}
