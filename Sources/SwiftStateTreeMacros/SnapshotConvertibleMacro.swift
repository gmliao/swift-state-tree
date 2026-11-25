// Sources/SwiftStateTreeMacros/SnapshotConvertibleMacro.swift

@preconcurrency import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import PlainDataMacroSupport

/// Macro that automatically generates `SnapshotValueConvertible` and `SnapshotValueDecodable`
/// protocol conformances.
///
/// This macro analyzes the struct's stored properties and generates:
/// 1. A `toSnapshotValue()` method (always generated).
/// 2. An `init(fromSnapshotValue:)` initializer (only when ALL stored properties are `var`).
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
///
/// extension PlayerState: SnapshotValueDecodable {
///     public init(fromSnapshotValue value: SnapshotValue) throws {
///         guard case .object(let _dict) = value else {
///             throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
///         }
///         self.init()
///         if let _v = _dict["name"] { self.name = try _snapshotDecode(_v) }
///         if let _v = _dict["hpCurrent"] { self.hpCurrent = try _snapshotDecode(_v) }
///         if let _v = _dict["hpMax"] { self.hpMax = try _snapshotDecode(_v) }
///     }
/// }
/// ```
///
/// Note: `init(fromSnapshotValue:)` is only generated when ALL stored properties are `var`.
/// Structs with `let` properties (immutable) do not get the decoder conformance automatically.
/// Those types must provide `SnapshotValueDecodable` conformance manually if needed.
/// The type must also have a no-argument `init()` for the generated decoder to compile.
public struct SnapshotConvertibleMacro: ExtensionMacro {

    /// Whether the type declares a static `snapshotFieldMetadata` itself (#566): the generated
    /// `SnapshotFieldListProvider` conformance is skipped, so the two don't clash.
    private static func declaresSnapshotFieldMetadata(_ declaration: some DeclGroupSyntax) -> Bool {
        declaration.memberBlock.members.contains { member in
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { return false }
            return variable.bindings.contains {
                $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "snapshotFieldMetadata"
            }
        }
    }

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

        // Every stored property is converted, so none may hold a value of any type (#535 D8 (b)).
        if diagnoseRefusedFieldTypes(in: structDecl, onlySynced: false, context: context) {
            throw RefusedFieldTypeError()
        }

        // Generate toSnapshotValue() method
        let toSnapshotValueMethod = try generateToSnapshotValueMethod(properties: properties)

        let toFullSnapshotValueMethod = try generateToFullSnapshotValueMethod(properties: properties)

        // Create extension that conforms to SnapshotValueConvertible, and to
        // FullSnapshotValueConvertible for the replay state hash (#180)
        let convertibleExtension = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): SnapshotValueConvertible, FullSnapshotValueConvertible {
                \(toSnapshotValueMethod)

                \(toFullSnapshotValueMethod)

                public func toSnapshotValue() throws -> SnapshotValue {
                    try toSnapshotValue(budget: NestingBudget())
                }

                public func toFullSnapshotValue() throws -> SnapshotValue {
                    try toFullSnapshotValue(budget: NestingBudget())
                }
            }
            """
        )

        // The stored properties as `toSnapshotValue()` converts them, for the registration check
        // (#535): it looks into this type's storage through these declared types, not the
        // value's. A property without a type annotation is listed as `Any`; the check takes its
        // value's type instead.
        let storedFieldEntries = properties.map { property in
            "(\"\(property.wireName)\", \(property.typeName.map { "(\(metatypeSpelling($0))).self" } ?? "Any.self"))"
        }
        let storedFieldsBody = storedFieldEntries.isEmpty ? "[]" : "[\n        " + storedFieldEntries.joined(separator: ",\n        ") + "\n    ]"
        let storedFieldsExtension = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): SnapshotConvertibleStoredFields {
                public static var _snapshotStoredFields: [(name: String, type: Any.Type)] {
                    \(raw: storedFieldsBody)
                }
            }
            """
        )

        var extensions: [ExtensionDeclSyntax] = [convertibleExtension, storedFieldsExtension]

        // A state value type is PlainData: this macro writes the conformance and the
        // checks, as `@Payload` does, unless `@PlainData` or `@Payload` beside it writes them.
        // Beside `@StateNodeBuilder`, whose member is the witness, it writes only the
        // conformance: the compiler leaves a conformance this macro's role declares to its
        // expansion, even one `StateNodeProtocol` implies, so an expansion without it doesn't
        // conform. Any spelling of each name.
        let attributes = declaration.attributes
        if PlainDataWalk.hasAttribute(named: "PlainData", in: attributes)
            || PlainDataWalk.hasAttribute(named: "Payload", in: attributes) {
            // The sibling writes the conformance and the checks.
        } else if PlainDataWalk.hasAttribute(named: "StateNodeBuilder", in: attributes) {
            if protocols.contains(where: { $0.trimmedDescription.hasSuffix("PlainData") }) {
                extensions.append(try ExtensionDeclSyntax("extension \(type.trimmed): SwiftStateTurns.PlainData {}"))
            }
        } else {
            extensions += PlainDataExtension.build(
                of: node,
                attachedTo: declaration,
                providingExtensionsOf: type,
                conformingTo: protocols.filter { $0.trimmedDescription.hasSuffix("PlainData") },
                in: context
            )
        }

        // `@SnapshotConvertible(atomic: true)`: declare the value atomic, with its leaf paths in
        // declaration order (a nested atomic value contributes its own leaves, prefixed).
        if isAtomicRequested(node) {
            var leafEntries: [String] = []
            var metadataEntries: [String] = []
            for property in properties {
                guard let typeName = property.typeName, isAllowedAtomicLeafType(typeName) else {
                    let error = SnapshotConvertibleError.invalidAtomicProperty(
                        node: Syntax(declaration), name: property.name, typeName: property.typeName
                    )
                    error.diagnose(context: context)
                    throw error
                }
                leafEntries.append("_atomicLeafPaths(of: \(typeName).self, named: \"\(property.wireName)\")")
                metadataEntries.append(
                    "FieldMetadata(name: \"\(property.wireName)\", type: \(typeName).self, policy: nil, nodeKind: .leaf, defaultValue: nil)"
                )
            }
            let leafBody = leafEntries.isEmpty
                ? "[]"
                : "[\n        " + leafEntries.joined(separator: ",\n        ") + "\n    ].flatMap { $0 }"
            let metadataBody = metadataEntries.isEmpty
                ? "[]"
                : "[\n        " + metadataEntries.joined(separator: ",\n        ") + "\n    ]"
            // The schema describes the value from these fields, so its leaf check in
            // AtomicLayoutTable needs no sample instance (a type that isn't Codable, or has no
            // `init()`, is described too).
            extensions.append(try ExtensionDeclSyntax(
                """
                extension \(type.trimmed): AtomicSnapshotValue {
                    public static var atomicLeafPaths: [[String]] {
                        \(raw: leafBody)
                    }

                    public static func getFieldMetadata() -> [FieldMetadata] {
                        \(raw: metadataBody)
                    }
                }
                """
            ))
        }

        // Only generate init(fromSnapshotValue:) when ALL stored properties are var (mutable).
        // Structs with let properties cannot use the self.init() + assignment pattern.
        let allPropertiesAreMutable = properties.allSatisfy { $0.isMutable }

        guard allPropertiesAreMutable else {
            // Skip SnapshotValueDecodable generation for immutable structs. Without a decoder the
            // schema has no sample instance to read its properties from, so they are declared
            // here (#566): otherwise the schema lists none, and the paths the diff produces
            // below the value have no path hash. An atomic value declares its own (above); a
            // property without a type annotation can't be named, and keeps the old schema. A type
            // that declares its own `snapshotFieldMetadata` keeps it: nothing is generated.
            // The type name is parenthesized before `.self`: `any P.self` doesn't parse as the
            // existential's metatype, `(any P).self` does.
            if !isAtomicRequested(node), properties.allSatisfy({ $0.typeName != nil }),
               !declaresSnapshotFieldMetadata(declaration) {
                let entries = properties.map { property in
                    let typeName = metatypeSpelling(property.typeName!)
                    return "FieldMetadata(name: \"\(property.wireName)\", type: (\(typeName)).self, policy: nil, nodeKind: SchemaHelper.determineNodeKind(from: (\(typeName)).self), defaultValue: nil)"
                }
                let body = entries.isEmpty ? "[]" : "[\n        " + entries.joined(separator: ",\n        ") + "\n    ]"
                extensions.append(try ExtensionDeclSyntax(
                    """
                    extension \(type.trimmed): SnapshotFieldListProvider {
                        public static var snapshotFieldMetadata: [FieldMetadata] {
                            \(raw: body)
                        }
                    }
                    """
                ))
            }
            return extensions
        }

        // Generate init(fromSnapshotValue:) assignments
        var assignmentLines: [String] = []
        for prop in properties {
            assignmentLines.append(
                "        if let _v = _dict[\"\(prop.wireName)\"] { self.\(prop.name) = try _snapshotDecode(_v) }"
            )
        }
        let assignmentBody = assignmentLines.joined(separator: "\n")

        // Create extension that conforms to SnapshotValueDecodable
        let decodableExtension = try ExtensionDeclSyntax(
            """
            extension \(type.trimmed): SnapshotValueDecodable {
                public init(fromSnapshotValue value: SnapshotValue) throws {
                    guard case .object(let _dict) = value else {
                        throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
                    }
                    self.init()
            \(raw: assignmentBody)
                }
            }
            """
        )

        extensions.append(decodableExtension)
        return extensions
    }

    /// Whether the attribute is written `@SnapshotConvertible(atomic: true)`.
    private static func isAtomicRequested(_ node: AttributeSyntax) -> Bool {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            return false
        }
        return arguments.contains { argument in
            argument.label?.text == "atomic"
                && argument.expression.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.true)
        }
    }

    /// An atomic value's leaves are scalars or nested atomic values: no optionals, no collections.
    private static func isAllowedAtomicLeafType(_ typeName: String) -> Bool {
        let name = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("?") || name.hasSuffix("!") || name.hasPrefix("[") { return false }
        for prefix in ["Optional<", "Array<", "Dictionary<", "Set<", "ContiguousArray<"] where name.hasPrefix(prefix) {
            return false
        }
        return true
    }

    /// Collect all stored properties from a struct declaration
    private static func collectStoredProperties(from structDecl: StructDeclSyntax) -> [PropertyInfo] {
        var properties: [PropertyInfo] = []

        for member in structDecl.memberBlock.members {
            guard let variableDecl = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }

            // Skip computed properties. Observers keep a property stored, and converted, as the
            // PlainData check counts it.
            let hasComputedProperty = variableDecl.bindings.contains(where: PlainDataWalk.isComputed)

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

            // Determine if the property is mutable (var) or immutable (let)
            let isMutable = variableDecl.bindingSpecifier.text == "var"

            for binding in variableDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    continue
                }

                let propertyName = pattern.identifier.text

                // Extract type information
                var typeName: String? = nil
                if let typeAnnotation = binding.typeAnnotation {
                    typeName = typeAnnotation.type.trimmedDescription  // without trivia: a trailing comment would land in generated code
                }

                properties.append(
                    PropertyInfo(
                        name: propertyName,
                        typeName: typeName,
                        isMutable: isMutable
                    )
                )
            }
        }

        return properties
    }

    /// Generate toFullSnapshotValue(): every stored property through `SnapshotValue.makeFull`, so a
    /// state node held by this value contributes its full state to the replay hash.
    private static func generateToFullSnapshotValueMethod(properties: [PropertyInfo]) throws -> FunctionDeclSyntax {
        let entries = properties.map { "\"\($0.wireName)\": try SnapshotValue.makeFull(from: self.\($0.name) as Any, budget: inner)" }
        let enter = entries.isEmpty ? "_ = try budget.enteringContainer()" : "let inner = try budget.enteringContainer()"
        let body = enter + "\n" + (entries.isEmpty ? "return .object([:])" : "return .object([\n    " + entries.joined(separator: ",\n    ") + "\n])")
        return try FunctionDeclSyntax(
            """
            public func toFullSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                \(raw: body)
            }
            """
        )
    }

    /// Generate toSnapshotValue() method implementation
    private static func generateToSnapshotValueMethod(properties: [PropertyInfo]) throws -> FunctionDeclSyntax {
        guard !properties.isEmpty else {
            // Empty struct: return empty object
            return try FunctionDeclSyntax(
                """
                public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                    _ = try budget.enteringContainer()
                    return .object([:])
                }
                """
            )
        }

        // Through `self.`: a property named like the generated `budget` or `inner` would otherwise
        // read the local instead (#716).
        let conversions = properties.map {
            generatePropertyConversionCode(for: $0.typeName, propertyName: "self.\($0.name)")
        }
        var codeLines: [String] = []
        // The object is a container either way; `inner` only when a property converts inside it,
        // so an all-primitive type gets no unused local (and no warning in its adopter's build).
        let usesInner = conversions.contains { $0.contains("budget: inner") }
        codeLines.append(usesInner ? "let inner = try budget.enteringContainer()" : "_ = try budget.enteringContainer()")
        codeLines.append("return .object([")

        for (index, (property, conversionCode)) in zip(properties, conversions).enumerated() {
            let comma = index < properties.count - 1 ? "," : ""
            codeLines.append("    \"\(property.wireName)\": \(conversionCode)\(comma)")
        }

        codeLines.append("])")

        let body = codeLines.joined(separator: "\n")

        return try FunctionDeclSyntax(
            """
            public func toSnapshotValue(budget: NestingBudget) throws -> SnapshotValue {
                \(raw: body)
            }
            """
        )
    }

    /// Generate conversion code for a property
    private static func generatePropertyConversionCode(for typeName: String?, propertyName: String) -> String {
        guard let typeName = typeName else {
            // Unknown type, use make(from:) as fallback
            return "try SnapshotValue.make(from: \(propertyName), budget: inner)"
        }

        let normalizedType = typeName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's an Optional type
        if normalizedType.hasSuffix("?") {
            // Optional type: use make(from:) to handle nil properly
            return "try SnapshotValue.make(from: \(propertyName), budget: inner)"
        }

        if normalizedType.hasPrefix("Optional<") && normalizedType.hasSuffix(">") {
            // Optional<Type> format: use make(from:) to handle nil properly
            return "try SnapshotValue.make(from: \(propertyName), budget: inner)"
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
            return "SnapshotValue.unsigned(\(propertyName))"
        case "UInt8":
            return ".int(Int(\(propertyName)))"
        case "UInt16":
            return ".int(Int(\(propertyName)))"
        case "UInt32":
            return ".int(Int(\(propertyName)))"
        case "UInt64":
            return "SnapshotValue.unsigned(\(propertyName))"
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
            return "try SnapshotValue.make(from: \(propertyName), budget: inner)"
        }
    }
}

/// Information about a property in a struct
private struct PropertyInfo {
    /// The source spelling, for generated code: a keyword property keeps its backticks.
    let name: String
    /// The name in string literals (field metadata, snapshot keys): without backticks, as a
    /// synthesized `Codable` names it.
    var wireName: String { String(name.filter { $0 != "`" }) }
    let typeName: String?
    /// Whether the property is declared with `var` (mutable) vs `let` (immutable).
    let isMutable: Bool
}

/// Macro errors
private enum SnapshotConvertibleError: Error, @unchecked Sendable {
    case onlyStructsSupported(node: Syntax)
    case invalidAtomicProperty(node: Syntax, name: String, typeName: String?)

    func diagnose(context: some MacroExpansionContext) {
        switch self {
        case .invalidAtomicProperty(let node, let name, let typeName):
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: SnapshotConvertibleDiagnostic(
                        message: "@SnapshotConvertible(atomic: true): property '\(name)' "
                            + (typeName.map { "of type \($0) " } ?? "without a type annotation ")
                            + "can't be an atomic leaf; leaves are annotated scalars or atomic values, not optionals or collections",
                        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "snapshotConvertibleInvalidAtomicProperty"),
                        severity: .error
                    )
                )
            )
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

/// A property's declared type as a type expression for `(T).self`. An implicitly unwrapped
/// optional (`Int!`) is only a declaration attribute, and `(Int!).self` doesn't compile; its type
/// is `Int?`.
private func metatypeSpelling(_ typeName: String) -> String {
    typeName.hasSuffix("!") ? String(typeName.dropLast()) + "?" : typeName
}
