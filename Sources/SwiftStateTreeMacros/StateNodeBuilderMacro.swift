// Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift

import Foundation
@preconcurrency import SwiftCompilerPlugin
@preconcurrency import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Macro that validates and generates code for StateNode types.
///
/// This macro:
/// 1. Validates that all stored properties have @Sync or @Internal markers
/// 2. Generates `getSyncFields()` method implementation
/// 3. Generates `validateSyncFields()` method implementation
/// 4. Generates `init(fromBroadcastSnapshot:)` (via extension) satisfying `StateFromSnapshotDecodable`
public struct StateNodeBuilderMacro: MemberMacro, ExtensionMacro {
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

        // Generate snapshot(for:) method
        let snapshotMethod = try generateSnapshotMethod(propertiesWithNodes: propertiesWithNodes)

        // Generate broadcastSnapshot() method
        let broadcastSnapshotMethod = try generateBroadcastSnapshotMethod(propertiesWithNodes: propertiesWithNodes)

        // Generate snapshotForSync() method (one-pass broadcast + per-player extraction)
        let snapshotForSyncMethod = try generateSnapshotForSyncMethod(propertiesWithNodes: propertiesWithNodes)

        // Generate dirty tracking methods (isDirty, getDirtyFields, clearDirty)
        let isDirtyMethod = try generateIsDirtyMethod(propertiesWithNodes: propertiesWithNodes)
        let getDirtyFieldsMethod = try generateGetDirtyFieldsMethod(propertiesWithNodes: propertiesWithNodes)
        let clearDirtyMethod = try generateClearDirtyMethod(propertiesWithNodes: propertiesWithNodes)

        // Generate helper methods for container types (Dictionary, Array, Set)
        let containerHelperMethods = try generateContainerHelperMethods(propertiesWithNodes: propertiesWithNodes)

        return [
            DeclSyntax(getSyncFieldsMethod),
            DeclSyntax(validateSyncFieldsMethod),
            DeclSyntax(snapshotMethod),
            DeclSyntax(broadcastSnapshotMethod),
            DeclSyntax(snapshotForSyncMethod),
            DeclSyntax(isDirtyMethod),
            DeclSyntax(getDirtyFieldsMethod),
            DeclSyntax(clearDirtyMethod),
            DeclSyntax(try generateGetFieldMetadata(properties: properties))
        ] + containerHelperMethods
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

                // Extract type information
                var typeName: String? = nil
                if let typeAnnotation = binding.typeAnnotation {
                    // Get the type as a string
                    typeName = typeAnnotation.type.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                }

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
                var policyType: LocalPolicyType? = nil
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

                // Capture the initializer expression (if any) for default value extraction
                // Remove comments from the initializer string
                var initializer = binding.initializer?.value.description.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if let initStr = initializer {
                    // Remove inline comments (everything after //)
                    if let commentIndex = initStr.range(of: "//") {
                        initializer = String(initStr[..<commentIndex.lowerBound]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    }
                }

                properties.append((
                    PropertyInfo(
                        name: propertyName,
                        hasSync: hasSync,
                        hasInternal: hasInternal,
                        policyType: policyType,
                        typeName: typeName,
                        initializer: initializer
                    ),
                    Syntax(variableDecl)
                ))
            }
        }

        return properties
    }

    /// Extract policy type from @Sync attribute
    private static func extractPolicyType(from attribute: AttributeSyntax) -> LocalPolicyType? {
        guard let argument = attribute.arguments?.as(LabeledExprListSyntax.self) else {
            return nil
        }

        // Look for the first argument (the policy)
        if let firstArg = argument.first {
            var policyTypeString: String?

            // Try to extract the policy type from the argument
            // Examples: .broadcast, .serverOnly, .perPlayerSlice()
            if let memberAccess = firstArg.expression.as(MemberAccessExprSyntax.self) {
                policyTypeString = memberAccess.declName.baseName.text
            } else if let functionCall = firstArg.expression.as(FunctionCallExprSyntax.self) {
                // Handle function calls like .perPlayerSlice()
                if let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self) {
                    policyTypeString = memberAccess.declName.baseName.text
                }
            }

            // Convert string to LocalPolicyType enum
            if let policyString = policyTypeString {
                return LocalPolicyType(rawValue: policyString) ?? .unknown
            }
        }

        return .unknown
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
                    structName: "StateNode",
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
            let policyType = property.policyType ?? .unknown
            // Use rawValue to get the string representation for code generation
            let policyTypeName = policyType.rawValue

            let trailingComma = index < syncProperties.count - 1 ? TokenSyntax.commaToken() : nil
            let element = ArrayElementSyntax(
                expression: ExprSyntax(
                    """
                    SyncFieldInfo(name: "\(raw: property.name)", policyType: .\(raw: policyTypeName))
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

    /// Generate snapshot(for:) method
    /// If dirtyFields is provided, only dirty fields are serialized for optimization
    private static func generateSnapshotMethod(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> FunctionDeclSyntax {
        let syncProperties = propertiesWithNodes.filter { $0.0.hasSync }

        var codeLines: [String] = []
        // Use var only if there are properties to process, otherwise use let
        if syncProperties.isEmpty {
            codeLines.append("let result: [String: SnapshotValue] = [:]")
        } else {
            codeLines.append("var result: [String: SnapshotValue] = [:]")
        }
        codeLines.append("")

        // Generate code for each @Sync field
        // Note: Property wrappers are stored as _propertyName, but we access them via propertyName
        // The property wrapper itself has .policy and .wrappedValue
        for (property, _) in syncProperties {
            let propertyName = property.name
            let fieldName = propertyName
            // Property wrapper storage name (Swift automatically creates _propertyName for @Sync)
            let storageName = "_\(propertyName)"

            // Check if field should be included (either no dirtyFields filter, or field is dirty)
            codeLines.append("// Include \(fieldName) if no dirtyFields filter or if field is dirty")
            codeLines.append("if dirtyFields == nil || dirtyFields?.contains(\"\(fieldName)\") == true {")
            codeLines.append("    if let value = self.\(storageName).policy.filteredValue(self.\(storageName).wrappedValue, for: playerID) {")

            // Generate optimized conversion code based on type
            // value is Value? from filteredValue (same type as the field), maintaining type safety
            // Pass playerID for recursive filtering support
            // Note: generateConversionCode will handle optional type casting to Any
            let (conversionCode, needsTry) = generateConversionCode(for: property.typeName, valueName: "value", isAnyType: false, playerID: "playerID")
            if needsTry {
                codeLines.append("        result[\"\(fieldName)\"] = try \(conversionCode)")
            } else {
                codeLines.append("        result[\"\(fieldName)\"] = \(conversionCode)")
            }
            codeLines.append("    }")
            codeLines.append("}")
            codeLines.append("")
        }

        codeLines.append("return StateSnapshot(values: result)")

        let body = codeLines.joined(separator: "\n")

        return try FunctionDeclSyntax(
            """
            public func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                \(raw: body)
            }
            """
        )
    }

    /// Generate broadcastSnapshot() method
    /// This method generates a snapshot containing only broadcast fields, avoiding runtime reflection
    /// If dirtyFields is provided, only dirty fields are serialized for optimization
    private static func generateBroadcastSnapshotMethod(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> FunctionDeclSyntax {
        let syncProperties = propertiesWithNodes.filter { $0.0.hasSync }
        let broadcastProperties = syncProperties.filter { property, _ in
            // Check if the property has broadcast policy
            // We need to check the policy type from the property info
            property.policyType == .broadcast
        }

        var codeLines: [String] = []
        if broadcastProperties.isEmpty {
            codeLines.append("let result: [String: SnapshotValue] = [:]")
        } else {
            codeLines.append("var result: [String: SnapshotValue] = [:]")
        }
        codeLines.append("")

        // Generate code for each broadcast @Sync field
        // Directly access the property wrapper's wrappedValue without filtering
        for (property, _) in broadcastProperties {
            let propertyName = property.name
            let fieldName = propertyName
            let storageName = "_\(propertyName)"

            // Check if field should be included (either no dirtyFields filter, or field is dirty)
            codeLines.append("// Include \(fieldName) if no dirtyFields filter or if field is dirty")
            codeLines.append("if dirtyFields == nil || dirtyFields?.contains(\"\(fieldName)\") == true {")

            // For broadcast fields, we directly access wrappedValue without filtering
            // wrappedValue is the actual typed value, not Any?
            // Note: generateConversionCode will handle optional type casting to Any
            let (conversionCode, needsTry) = generateConversionCode(for: property.typeName, valueName: "self.\(storageName).wrappedValue", isAnyType: false)

            if needsTry {
                // Complex types that may throw - use do-catch
                codeLines.append("    do {")
                codeLines.append("        result[\"\(fieldName)\"] = try \(conversionCode)")
                codeLines.append("    } catch {")
                codeLines.append("        throw error")
                codeLines.append("    }")
            } else {
                // Basic types that don't throw - no do-catch needed
                codeLines.append("    result[\"\(fieldName)\"] = \(conversionCode)")
            }
            codeLines.append("}")
            codeLines.append("")
        }

        codeLines.append("return StateSnapshot(values: result)")

        let body = codeLines.joined(separator: "\n")

        return try FunctionDeclSyntax(
            """
            public func broadcastSnapshot(dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                \(raw: body)
            }
            """
        )
    }

    /// Generate snapshotForSync(playerIDs:dirtyFields:) method
    /// One-pass extraction: broadcast fields and per-player fields in a single tree walk.
    /// For nested single StateNode (not container), calls snapshotForSync recursively; otherwise uses SnapshotValue conversion.
    private static func generateSnapshotForSyncMethod(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> FunctionDeclSyntax {
        let syncProperties = propertiesWithNodes.filter { $0.0.hasSync }
        let broadcastProperties = syncProperties.filter { $0.0.policyType == .broadcast }
        let perPlayerProperties = syncProperties.filter { prop in
            guard let pt = prop.0.policyType else { return false }
            return pt != .broadcast && pt != .serverOnly
        }

        var codeLines: [String] = []
        if broadcastProperties.isEmpty {
            codeLines.append("let broadcastResult: [String: SnapshotValue] = [:]")
        } else {
            codeLines.append("var broadcastResult: [String: SnapshotValue] = [:]")
        }
        if perPlayerProperties.isEmpty {
            codeLines.append("let perPlayerResult: [PlayerID: [String: SnapshotValue]] = [:]")
        } else {
            codeLines.append("var perPlayerResult: [PlayerID: [String: SnapshotValue]] = [:]")
            codeLines.append("for playerID in playerIDs {")
            codeLines.append("    perPlayerResult[playerID] = [:]")
            codeLines.append("}")
        }
        codeLines.append("")

        // Broadcast part: same dirty check as broadcastSnapshot; per field either recursive snapshotForSync or generateConversionCode
        for (property, _) in broadcastProperties {
            let propertyName = property.name
            let fieldName = propertyName
            let storageName = "_\(propertyName)"
            let typeName = property.typeName

            codeLines.append("if dirtyFields == nil || dirtyFields?.contains(\"\(fieldName)\") == true {")
            if let typeName = typeName, isSingleStateNodeType(typeName) {
                // Runtime check: only call snapshotForSync when value conforms to StateNodeProtocol (e.g. BaseState).
                // Otherwise use SnapshotValue.make (e.g. Vec2, Position2).
                let normalizedType = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
                let isOptional = normalizedType.hasSuffix("?") || (normalizedType.hasPrefix("Optional<") && normalizedType.hasSuffix(">"))
                if isOptional {
                    codeLines.append("    if let unwrapped = \(storageName).wrappedValue {")
                    codeLines.append("        if let node = (unwrapped as Any) as? any StateNodeProtocol {")
                    codeLines.append("            // Parent dirtyFields contains parent-level names (e.g. \"base\"),")
                    codeLines.append("            // which do not match nested field names (e.g. \"position\").")
                    codeLines.append("            // Pass nil here to avoid producing empty nested objects like {}.")
                    codeLines.append("            let (subB, _) = try node.snapshotForSync(playerIDs: playerIDs, dirtyFields: nil)")
                    codeLines.append("            broadcastResult[\"\(fieldName)\"] = .object(subB.values)")
                    codeLines.append("        } else {")
                    codeLines.append("            broadcastResult[\"\(fieldName)\"] = try SnapshotValue.make(from: unwrapped as Any)")
                    codeLines.append("        }")
                    codeLines.append("    } else {")
                    codeLines.append("        broadcastResult[\"\(fieldName)\"] = .null")
                    codeLines.append("    }")
                } else {
                    codeLines.append("    if let node = (self.\(storageName).wrappedValue as Any) as? any StateNodeProtocol {")
                    codeLines.append("        // Parent dirtyFields contains parent-level names (e.g. \"base\"),")
                    codeLines.append("        // which do not match nested field names (e.g. \"position\").")
                    codeLines.append("        // Pass nil here to avoid producing empty nested objects like {}.")
                    codeLines.append("        let (subB, _) = try node.snapshotForSync(playerIDs: playerIDs, dirtyFields: nil)")
                    codeLines.append("        broadcastResult[\"\(fieldName)\"] = .object(subB.values)")
                    codeLines.append("    } else {")
                    codeLines.append("        broadcastResult[\"\(fieldName)\"] = try SnapshotValue.make(from: self.\(storageName).wrappedValue as Any)")
                    codeLines.append("    }")
                }
            } else {
                let (conversionCode, needsTry) = generateConversionCode(for: typeName, valueName: "self.\(storageName).wrappedValue", isAnyType: false, playerID: nil)
                if needsTry {
                    codeLines.append("    do {")
                    codeLines.append("        broadcastResult[\"\(fieldName)\"] = try \(conversionCode)")
                    codeLines.append("    } catch {")
                    codeLines.append("        throw error")
                    codeLines.append("    }")
                } else {
                    codeLines.append("    broadcastResult[\"\(fieldName)\"] = \(conversionCode)")
                }
            }
            codeLines.append("}")
            codeLines.append("")
        }

        // Per-player part: for each per-player property and each playerID, filteredValue then convert
        for (property, _) in perPlayerProperties {
            let propertyName = property.name
            let fieldName = propertyName
            let storageName = "_\(propertyName)"

            codeLines.append("for playerID in playerIDs {")
            codeLines.append("    if let value = self.\(storageName).policy.filteredValue(self.\(storageName).wrappedValue, for: playerID) {")
            let (conversionCode, needsTry) = generateConversionCode(for: property.typeName, valueName: "value", isAnyType: false, playerID: "playerID")
            if needsTry {
                codeLines.append("        do {")
                codeLines.append("            perPlayerResult[playerID]![\"\(fieldName)\"] = try \(conversionCode)")
                codeLines.append("        } catch {")
                codeLines.append("            throw error")
                codeLines.append("        }")
            } else {
                codeLines.append("        perPlayerResult[playerID]![\"\(fieldName)\"] = \(conversionCode)")
            }
            codeLines.append("    }")
            codeLines.append("}")
            codeLines.append("")
        }

        codeLines.append("return (StateSnapshot(values: broadcastResult), perPlayerResult.mapValues { StateSnapshot(values: $0) })")
        let body = codeLines.joined(separator: "\n")

        return try FunctionDeclSyntax(
            """
            public func snapshotForSync(playerIDs: [PlayerID], dirtyFields: Set<String>?) throws -> (broadcast: StateSnapshot, perPlayer: [PlayerID: StateSnapshot]) {
                \(raw: body)
            }
            """
        )
    }

    /// Returns true if the type is a single (non-container) non-primitive type, i.e. possibly a StateNode for recursive snapshotForSync.
    private static func isSingleStateNodeType(_ typeName: String) -> Bool {
        if isPrimitiveType(typeName) { return false }
        if case .none = detectContainerType(from: typeName) { return true }
        return false
    }

    /// Generate isDirty() method
    private static func generateIsDirtyMethod(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> FunctionDeclSyntax {
        let syncProperties = propertiesWithNodes.filter { $0.0.hasSync }

        if syncProperties.isEmpty {
            return try FunctionDeclSyntax(
                """
                public func isDirty() -> Bool {
                    return false
                }
                """
            )
        }

        var codeLines: [String] = []
        var conditions: [String] = []

        for (property, _) in syncProperties {
            let storageName = "_\(property.name)"
            conditions.append("\(storageName).isDirty")
        }

        codeLines.append("return \(conditions.joined(separator: " || "))")

        let body = codeLines.joined(separator: "\n")

        return try FunctionDeclSyntax(
            """
            public func isDirty() -> Bool {
                \(raw: body)
            }
            """
        )
    }

    /// Generate getDirtyFields() method
    private static func generateGetDirtyFieldsMethod(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> FunctionDeclSyntax {
        let syncProperties = propertiesWithNodes.filter { $0.0.hasSync }

        if syncProperties.isEmpty {
            return try FunctionDeclSyntax(
                """
                public func getDirtyFields() -> Set<String> {
                    return []
                }
                """
            )
        }

        var codeLines: [String] = []
        codeLines.append("var dirtyFields: Set<String> = []")
        codeLines.append("")

        for (property, _) in syncProperties {
            let propertyName = property.name
            let storageName = "_\(propertyName)"

            codeLines.append("if \(storageName).isDirty {")
            codeLines.append("    dirtyFields.insert(\"\(propertyName)\")")
            codeLines.append("}")
        }

        codeLines.append("")
        codeLines.append("return dirtyFields")

        let body = codeLines.joined(separator: "\n")

        return try FunctionDeclSyntax(
            """
            public func getDirtyFields() -> Set<String> {
                \(raw: body)
            }
            """
        )
    }

    /// Generate clearDirty() method
    /// This method clears dirty flags for all @Sync fields, and recursively clears
    /// dirty flags for nested StateNodeProtocol instances.
    ///
    /// **Important**: This recursively clears dirty flags in nested StateNode instances
    /// to prevent unnecessary comparisons in subsequent syncs when nested state hasn't changed.
    private static func generateClearDirtyMethod(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> FunctionDeclSyntax {
        let syncProperties = propertiesWithNodes.filter { $0.0.hasSync }

        if syncProperties.isEmpty {
            return try FunctionDeclSyntax(
                """
                public mutating func clearDirty() {
                }
                """
            )
        }

        var codeLines: [String] = []
        for (property, _) in syncProperties {
            let propertyName = property.name
            let storageName = "_\(propertyName)"

            // Clear the @Sync wrapper's dirty flag first
            codeLines.append("\(storageName).clearDirty()")

            // Then, recursively clear nested StateNode's dirty flags (if it's a StateNodeProtocol)
            // NOTE: We always attempt recursive clear for non-primitive types, regardless of wrapper's dirty state,
            // because nested StateNode might have internal dirty flags even if wrapper wasn't dirty.
            // This ensures all nested dirty flags are cleared, preventing accumulation.
            if let typeName = property.typeName, !isPrimitiveType(typeName) {
                let normalizedType = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
                let isOptional = normalizedType.hasSuffix("?") || (normalizedType.hasPrefix("Optional<") && normalizedType.hasSuffix(">"))

                codeLines.append("// Recursively clear dirty flags for nested StateNode (if applicable)")
                codeLines.append("// Always attempt recursive clear for non-primitive types to ensure nested dirty flags are cleared")

                if isOptional {
                    // For optional types, unwrap first then attempt StateNodeProtocol cast via Any
                    // Use Any to avoid compile-time always-true/always-succeed warnings
                    codeLines.append("if let unwrapped = \(storageName).wrappedValue, var nestedState = (unwrapped as Any) as? any StateNodeProtocol {")
                } else {
                    // For non-optional types, directly check if it's a StateNodeProtocol
                    // Note: Not all non-primitive types conform to StateNodeProtocol (e.g., DeterministicMath types, collections)
                    // Use Any to avoid compile-time always-true/always-succeed warnings
                    codeLines.append("if var nestedState = (\(storageName).wrappedValue as Any) as? any StateNodeProtocol {")
                }
                codeLines.append("    nestedState.clearDirty()")
                codeLines.append("    // Update value without marking as dirty (using internal method)")
                codeLines.append("    if let typedState = nestedState as? \(typeName) {")
                codeLines.append("        \(storageName).updateValueWithoutMarkingDirty(typedState)")
                codeLines.append("    }")
                codeLines.append("}")
            }
        }

        let body = codeLines.joined(separator: "\n")

        return try FunctionDeclSyntax(
            """
            public mutating func clearDirty() {
                \(raw: body)
            }
            """
        )
    }

    /// Check if a type is a primitive type or collection type that cannot be a StateNodeProtocol
    /// Returns true for primitive types, collections, and other non-StateNode types
    private static func isPrimitiveType(_ typeName: String) -> Bool {
        let primitiveTypes: Set<String> = [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Bool", "String",
            "Character", "Date", "UUID", "PlayerID",
            // DeterministicMath types (Codable structs, not StateNodeProtocol)
            "IVec2", "IVec3", "Position2", "Velocity2", "Acceleration2", "Angle"
        ]

        // Remove optional markers and check base type
        var baseType = typeName
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .trimmingCharacters(in: .whitespaces)

        if baseType.hasPrefix("Optional<") && baseType.hasSuffix(">") {
            baseType = String(baseType.dropFirst("Optional<".count).dropLast())
        } else if baseType.hasPrefix("Swift.Optional<") && baseType.hasSuffix(">") {
            baseType = String(baseType.dropFirst("Swift.Optional<".count).dropLast())
        }

        // Collections themselves cannot be StateNodeProtocol, but their elements/values might be
        // The recursive clearDirty logic should not apply to collections
        if case .none = detectContainerType(from: baseType) {
            // fall through
        } else {
            return true
        }

        // Check if base type is in primitive types set
        return primitiveTypes.contains(baseType)
    }

    /// Generate getFieldMetadata() method
    private static func generateGetFieldMetadata(properties: [PropertyInfo]) throws -> FunctionDeclSyntax {
        let syncProperties = properties.filter { $0.hasSync }

        var arrayElements: [ArrayElementSyntax] = []

        for (index, property) in syncProperties.enumerated() {
            let policyType = property.policyType ?? .unknown
            let policyTypeName = policyType.rawValue
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

            let trailingComma = index < syncProperties.count - 1 ? TokenSyntax.commaToken() : nil

            // We use SchemaHelper.determineNodeKind(from: Type.self) to get the node kind at runtime
            let element = ArrayElementSyntax(
                expression: ExprSyntax(
                    """
                    FieldMetadata(
                        name: "\(raw: property.name)",
                        type: \(raw: typeName).self,
                        policy: .\(raw: policyTypeName),
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

    /// Generate init(fromBroadcastSnapshot:) method as DeclSyntax.
    ///
    /// Only generates `_snapshotDecode` calls for broadcast properties whose types are
    /// statically known to conform to `SnapshotValueDecodable`. Properties with complex or
    /// unknown types are skipped (they keep their default values).
    private static func generateFromBroadcastSnapshotInit(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> DeclSyntax {
        let broadcastProperties = propertiesWithNodes.filter { $0.0.hasSync && $0.0.policyType == .broadcast }

        var codeLines: [String] = []
        codeLines.append("self.init()")

        for (property, _) in broadcastProperties {
            let name = property.name
            // Only emit _snapshotDecode for types known to conform to SnapshotValueDecodable.
            // Unknown/complex types keep their defaults from self.init().
            guard isKnownSnapshotValueDecodable(property.typeName) else {
                continue
            }
            codeLines.append("if let _v = snapshot.values[\"\(name)\"] { self.\(name) = try _snapshotDecode(_v) }")
        }

        let body = codeLines.joined(separator: "\n")

        return DeclSyntax(
            """
            public init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
                \(raw: body)
            }
            """
        )
    }

    /// Returns true if the type is statically known to conform to SnapshotValueDecodable.
    /// Used by generateFromBroadcastSnapshotInit to avoid generating invalid decode calls.
    private static func isKnownSnapshotValueDecodable(_ typeName: String?) -> Bool {
        guard let typeName = typeName else { return false }
        let normalized = typeName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for Optional<T> wrapping a known type
        if normalized.hasSuffix("?") {
            let inner = String(normalized.dropLast()).trimmingCharacters(in: .whitespaces)
            return isKnownSnapshotValueDecodable(inner)
        }
        if normalized.hasPrefix("Optional<") && normalized.hasSuffix(">") {
            let inner = String(normalized.dropFirst("Optional<".count).dropLast())
                .trimmingCharacters(in: .whitespaces)
            return isKnownSnapshotValueDecodable(inner)
        }

        // Check for Array<T> or [T]
        if normalized.hasPrefix("Array<") && normalized.hasSuffix(">") {
            let inner = String(normalized.dropFirst("Array<".count).dropLast())
                .trimmingCharacters(in: .whitespaces)
            return isKnownSnapshotValueDecodable(inner)
        }
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") && !normalized.contains(":") {
            let inner = String(normalized.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            return isKnownSnapshotValueDecodable(inner)
        }

        // Check for Dictionary<K, V> or [K: V] — requires key to be SnapshotKeyDecodable
        // and value to be SnapshotValueDecodable.
        if normalized.hasPrefix("Dictionary<") && normalized.hasSuffix(">") {
            let content = String(normalized.dropFirst("Dictionary<".count).dropLast())
            let parts = content.split(separator: ",", maxSplits: 1)
            if parts.count == 2 {
                let keyType = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let valueType = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return isKnownSnapshotKeyDecodable(keyType) && isKnownSnapshotValueDecodable(valueType)
            }
        }
        if normalized.hasPrefix("[") && normalized.hasSuffix("]") && normalized.contains(":") {
            let content = String(normalized.dropFirst().dropLast())
            let parts = content.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let keyType = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let valueType = String(parts[1]).trimmingCharacters(in: .whitespaces)
                return isKnownSnapshotKeyDecodable(keyType) && isKnownSnapshotValueDecodable(valueType)
            }
        }

        // Primitive types with known SnapshotValueDecodable conformance
        let knownTypes: Set<String> = [
            "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
            "Float", "Double", "Bool", "String",
            "PlayerID"
        ]
        return knownTypes.contains(normalized)
    }

    /// Returns true if the type is statically known to conform to SnapshotKeyDecodable.
    private static func isKnownSnapshotKeyDecodable(_ typeName: String) -> Bool {
        let knownKeyTypes: Set<String> = ["String", "Int", "PlayerID"]
        return knownKeyTypes.contains(typeName.trimmingCharacters(in: .whitespaces))
    }

    /// Generate helper methods for container types (Dictionary, Array, Set)
    /// These methods automatically mark the field as dirty when modifying containers
    private static func generateContainerHelperMethods(propertiesWithNodes: [(PropertyInfo, Syntax)]) throws -> [DeclSyntax] {
        let syncProperties = propertiesWithNodes.filter { $0.0.hasSync }
        var methods: [DeclSyntax] = []

        for (property, _) in syncProperties {
            let propertyName = property.name
            let storageName = "_\(propertyName)"
            let containerType = detectContainerType(from: property.typeName)

            switch containerType {
            case .dictionary(let keyType, let valueType):
                // Generate helper methods for Dictionary
                methods.append(contentsOf: try generateDictionaryHelperMethods(
                    propertyName: propertyName,
                    storageName: storageName,
                    keyType: keyType,
                    valueType: valueType
                ))

            case .array(let elementType):
                // Generate helper methods for Array
                methods.append(contentsOf: try generateArrayHelperMethods(
                    propertyName: propertyName,
                    storageName: storageName,
                    elementType: elementType
                ))

            case .set(let elementType):
                // Generate helper methods for Set
                methods.append(contentsOf: try generateSetHelperMethods(
                    propertyName: propertyName,
                    storageName: storageName,
                    elementType: elementType
                ))

            case .none:
                // Not a container type, skip
                break
            }
        }

        return methods
    }

    /// Generate helper methods for Dictionary container type
    private static func generateDictionaryHelperMethods(
        propertyName: String,
        storageName: String,
        keyType: String,
        valueType: String
    ) throws -> [DeclSyntax] {
        var methods: [DeclSyntax] = []

        // Method: updateValue(_:forKey:) - Update or insert a value
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Update or insert a value in \(raw: propertyName) dictionary and mark as dirty
            /// Note: This method always marks the field as dirty, even if the value didn't change
            public mutating func update\(raw: capitalizeFirst(propertyName))(_ value: \(raw: valueType), forKey key: \(raw: keyType)) {
                \(raw: storageName).wrappedValue[key] = value
                \(raw: storageName).markDirty()
            }
            """
        )))

        // Method: removeValue(forKey:) - Remove a value
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Remove a value from \(raw: propertyName) dictionary and mark as dirty
            /// Note: This method always marks the field as dirty, even if the key didn't exist
            @discardableResult
            public mutating func remove\(raw: capitalizeFirst(propertyName))(forKey key: \(raw: keyType)) -> \(raw: valueType)? {
                let result = \(raw: storageName).wrappedValue.removeValue(forKey: key)
                \(raw: storageName).markDirty()
                return result
            }
            """
        )))

        // Method: setValue(_:forKey:) - Alias for updateValue
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Set a value in \(raw: propertyName) dictionary and mark as dirty (alias for update\(raw: capitalizeFirst(propertyName)))
            public mutating func set\(raw: capitalizeFirst(propertyName))(_ value: \(raw: valueType), forKey key: \(raw: keyType)) {
                update\(raw: capitalizeFirst(propertyName))(value, forKey: key)
            }
            """
        )))

        return methods
    }

    /// Generate helper methods for Array container type
    private static func generateArrayHelperMethods(
        propertyName: String,
        storageName: String,
        elementType: String
    ) throws -> [DeclSyntax] {
        var methods: [DeclSyntax] = []

        // Method: append(_:) - Append an element
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Append an element to \(raw: propertyName) array and mark as dirty
            /// Note: This method always marks the field as dirty
            public mutating func append\(raw: capitalizeFirst(propertyName))(_ element: \(raw: elementType)) {
                \(raw: storageName).wrappedValue.append(element)
                \(raw: storageName).markDirty()
            }
            """
        )))

        // Method: remove(at:) - Remove an element at index
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Remove an element from \(raw: propertyName) array at index and mark as dirty
            /// Note: This method always marks the field as dirty
            @discardableResult
            public mutating func remove\(raw: capitalizeFirst(propertyName))(at index: Int) -> \(raw: elementType) {
                let result = \(raw: storageName).wrappedValue.remove(at: index)
                \(raw: storageName).markDirty()
                return result
            }
            """
        )))

        // Method: insert(_:at:) - Insert an element at index
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Insert an element into \(raw: propertyName) array at index and mark as dirty
            /// Note: This method always marks the field as dirty
            public mutating func insert\(raw: capitalizeFirst(propertyName))(_ element: \(raw: elementType), at index: Int) {
                \(raw: storageName).wrappedValue.insert(element, at: index)
                \(raw: storageName).markDirty()
            }
            """
        )))

        return methods
    }

    /// Generate helper methods for Set container type
    private static func generateSetHelperMethods(
        propertyName: String,
        storageName: String,
        elementType: String
    ) throws -> [DeclSyntax] {
        var methods: [DeclSyntax] = []

        // Method: insert(_:) - Insert an element
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Insert an element into \(raw: propertyName) set and mark as dirty
            /// Note: This method always marks the field as dirty, even if the element already exists (inserted == false)
            @discardableResult
            public mutating func insert\(raw: capitalizeFirst(propertyName))(_ element: \(raw: elementType)) -> (inserted: Bool, memberAfterInsert: \(raw: elementType)) {
                let result = \(raw: storageName).wrappedValue.insert(element)
                \(raw: storageName).markDirty()
                return result
            }
            """
        )))

        // Method: remove(_:) - Remove an element
        methods.append(DeclSyntax(try FunctionDeclSyntax(
            """
            /// Remove an element from \(raw: propertyName) set and mark as dirty
            /// Note: This method always marks the field as dirty, even if the element didn't exist
            @discardableResult
            public mutating func remove\(raw: capitalizeFirst(propertyName))(_ element: \(raw: elementType)) -> \(raw: elementType)? {
                let result = \(raw: storageName).wrappedValue.remove(element)
                \(raw: storageName).markDirty()
                return result
            }
            """
        )))

        return methods
    }

    /// Generate optimized conversion code based on type
    /// For basic types, generates direct conversion; for complex types, uses make(from:for:)
    /// Returns a tuple: (code, needsTry) where needsTry indicates if the code can throw
    /// valueName is expected to be of the same type as the field (Value) for snapshot method
    /// filteredValue now returns Value? instead of Any?, maintaining type safety
    /// valueName is expected to be the actual typed value for broadcastSnapshot method
    /// playerID is passed for recursive filtering support in nested StateNode structures
    /// Note: The returned code does NOT include 'try' keyword - it should be added by the caller if needsTry is true
    private static func generateConversionCode(for typeName: String?, valueName: String, isAnyType: Bool = true, playerID: String? = nil) -> (code: String, needsTry: Bool) {
        guard let typeName = typeName else {
            // Unknown type, use make(from:for:) as fallback
            if let playerID = playerID {
                return ("SnapshotValue.make(from: \(valueName), for: \(playerID))", true)
            } else {
                return ("SnapshotValue.make(from: \(valueName))", true)
            }
        }

        let normalizedType = typeName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        // Check if it's an Optional type (handle first)
        if normalizedType.hasSuffix("?") {
            // Optional type: use make(from:for:) to handle nil properly
            // Explicitly cast to Any to silence implicit coercion warning
            // Note: Only one 'as Any' is needed here since we removed the duplicate in generateSnapshotMethod/generateBroadcastSnapshotMethod
            if let playerID = playerID {
                return ("SnapshotValue.make(from: \(valueName) as Any, for: \(playerID))", true)
            } else {
                return ("SnapshotValue.make(from: \(valueName) as Any)", true)
            }
        }

        if normalizedType.hasPrefix("Optional<") && normalizedType.hasSuffix(">") {
            // Optional<Type> format: use make(from:for:) to handle nil properly
            // Explicitly cast to Any to silence implicit coercion warning
            // Note: Only one 'as Any' is needed here since we removed the duplicate in generateSnapshotMethod/generateBroadcastSnapshotMethod
            if let playerID = playerID {
                return ("SnapshotValue.make(from: \(valueName) as Any, for: \(playerID))", true)
            } else {
                return ("SnapshotValue.make(from: \(valueName) as Any)", true)
            }
        }

        // Handle basic types with direct conversion (no Mirror needed)
        // If valueName is Any?, we need to cast it first
        switch normalizedType {
        case "Bool":
            if isAnyType {
                return (".bool(\(valueName) as! Bool)", false)
            } else {
                return (".bool(\(valueName))", false)
            }
        case "Int":
            if isAnyType {
                return (".int(\(valueName) as! Int)", false)
            } else {
                return (".int(\(valueName))", false)
            }
        case "Int8":
            if isAnyType {
                return (".int(Int(\(valueName) as! Int8))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "Int16":
            if isAnyType {
                return (".int(Int(\(valueName) as! Int16))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "Int32":
            if isAnyType {
                return (".int(Int(\(valueName) as! Int32))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "Int64":
            if isAnyType {
                return (".int(Int(\(valueName) as! Int64))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "UInt":
            if isAnyType {
                return (".int(Int(\(valueName) as! UInt))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "UInt8":
            if isAnyType {
                return (".int(Int(\(valueName) as! UInt8))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "UInt16":
            if isAnyType {
                return (".int(Int(\(valueName) as! UInt16))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "UInt32":
            if isAnyType {
                return (".int(Int(\(valueName) as! UInt32))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "UInt64":
            if isAnyType {
                return (".int(Int(\(valueName) as! UInt64))", false)
            } else {
                return (".int(Int(\(valueName)))", false)
            }
        case "Double":
            if isAnyType {
                return (".double(\(valueName) as! Double)", false)
            } else {
                return (".double(\(valueName))", false)
            }
        case "Float":
            if isAnyType {
                return (".double(Double(\(valueName) as! Float))", false)
            } else {
                return (".double(Double(\(valueName)))", false)
            }
        case "String":
            if isAnyType {
                return (".string(\(valueName) as! String)", false)
            } else {
                return (".string(\(valueName))", false)
            }
        case "PlayerID":
            if isAnyType {
                return (".string((\(valueName) as! PlayerID).rawValue)", false)
            } else {
                return (".string(\(valueName).rawValue)", false)
            }
        default:
            // Complex types (structs, classes, arrays, dictionaries, etc.)
            // Use make(from:for:) which will:
            // 1. Check for StateNodeProtocol first (for recursive filtering)
            // 2. Check for SnapshotValueConvertible protocol
            // 3. Fall back to Mirror for nested structures
            if let playerID = playerID {
                return ("SnapshotValue.make(from: \(valueName), for: \(playerID))", true)
            } else {
                return ("SnapshotValue.make(from: \(valueName))", true)
            }
        }
    }
}

/// Local policy type enum for macro internal use (maps to PolicyType at runtime)
///
/// **IMPORTANT**: Must be kept in sync with `PolicyType` enum in `StateTree.swift`.
/// When adding a new case to `PolicyType`, add the same case here.
private enum LocalPolicyType: String {
    case broadcast = "broadcast"
    case serverOnly = "serverOnly"
    case perPlayer = "perPlayer"
    case perPlayerSlice = "perPlayerSlice"
    case masked = "masked"
    case custom = "custom"
    case unknown = "unknown"
}

/// Information about a property in a StateNode
private struct PropertyInfo {
    let name: String
    let hasSync: Bool
    let hasInternal: Bool
    let policyType: LocalPolicyType?
    let typeName: String?  // Type name for optimization
    let initializer: String?
}

/// Container type information
private enum ContainerType {
    case dictionary(keyType: String, valueType: String)
    case array(elementType: String)
    case set(elementType: String)
    case none
}

/// Capitalize first letter of a string
private func capitalizeFirst(_ str: String) -> String {
    guard !str.isEmpty else { return str }
    return str.prefix(1).uppercased() + str.dropFirst()
}

/// Detect if a type is a container type and extract its element types
private func detectContainerType(from typeName: String?) -> ContainerType {
    guard let typeName = typeName else { return .none }

    let normalized = typeName.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

    // Check for Dictionary: [Key: Value] or Dictionary<Key, Value>
    if normalized.hasPrefix("[") && normalized.contains(":") && normalized.hasSuffix("]") {
        // Format: [Key: Value]
        let content = String(normalized.dropFirst().dropLast()) // Remove [ and ]
        let parts = content.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            let keyType = String(parts[0]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let valueType = String(parts[1]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return .dictionary(keyType: keyType, valueType: valueType)
        }
    } else if normalized.hasPrefix("Dictionary<") && normalized.hasSuffix(">") {
        // Format: Dictionary<Key, Value>
        let content = String(normalized.dropFirst("Dictionary<".count).dropLast())
        let parts = content.split(separator: ",", maxSplits: 1)
        if parts.count == 2 {
            let keyType = String(parts[0]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let valueType = String(parts[1]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return .dictionary(keyType: keyType, valueType: valueType)
        }
    }

    // Check for Array: [Element] or Array<Element>
    if normalized.hasPrefix("[") && normalized.hasSuffix("]") && !normalized.contains(":") {
        // Format: [Element]
        let elementType = String(normalized.dropFirst().dropLast()).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return .array(elementType: elementType)
    } else if normalized.hasPrefix("Array<") && normalized.hasSuffix(">") {
        // Format: Array<Element>
        let elementType = String(normalized.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return .array(elementType: elementType)
    }

    // Check for Set: Set<Element>
    if normalized.hasPrefix("Set<") && normalized.hasSuffix(">") {
        // Format: Set<Element>
        let elementType = String(normalized.dropFirst("Set<".count).dropLast()).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return .set(elementType: elementType)
    }

    return .none
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
                    message: StateNodeBuilderDiagnostic.onlyStructsSupported
                )
            )
        case .missingMarker(let propertyName, let structName, let node):
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: StateNodeBuilderDiagnostic.missingMarker(propertyName: propertyName, structName: structName)
                )
            )
        }
    }
}

/// Diagnostic messages for StateNodeBuilder macro
private struct StateNodeBuilderDiagnostic: DiagnosticMessage, @unchecked Sendable {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    static let onlyStructsSupported: StateNodeBuilderDiagnostic = StateNodeBuilderDiagnostic(
        message: "@StateNodeBuilder can only be applied to struct declarations",
        diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "onlyStructsSupported"),
        severity: .error
    )

    static func missingMarker(propertyName: String, structName: String) -> StateNodeBuilderDiagnostic {
        StateNodeBuilderDiagnostic(
            message: "Stored property '\(propertyName)' in \(structName) must be marked with @Sync or @Internal",
            diagnosticID: MessageID(domain: "SwiftStateTreeMacros", id: "missingMarker"),
            severity: .error
        )
    }
}

@main
struct SwiftStateTreeMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StateNodeBuilderMacro.self,
        SnapshotConvertibleMacro.self,
        LandMacro.self,
        PayloadMacro.self
    ]
}
