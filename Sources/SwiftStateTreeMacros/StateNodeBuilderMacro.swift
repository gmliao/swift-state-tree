// Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift

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
public struct StateNodeBuilderMacro: MemberMacro {
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
            DeclSyntax(isDirtyMethod),
            DeclSyntax(getDirtyFieldsMethod),
            DeclSyntax(clearDirtyMethod)
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
                    typeName = typeAnnotation.type.description.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        policyType: policyType,
                        typeName: typeName
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
            // Examples: .broadcast, .serverOnly, .perPlayerSlice()
            if let memberAccess = firstArg.expression.as(MemberAccessExprSyntax.self) {
                return memberAccess.declName.baseName.text
            }
            
            // Handle function calls like .perPlayerSlice()
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
            // value is Any? from filteredValue, so we need to cast it
            // Explicitly cast to Any to avoid implicit coercion warnings
            // Pass playerID for recursive filtering support
            let (conversionCode, needsTry) = generateConversionCode(for: property.typeName, valueName: "value as Any", isAnyType: true, playerID: "playerID")
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
            property.policyType == "broadcast"
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
            // For optional types, explicitly cast to Any to avoid implicit coercion warnings
            let valueExpression: String
            if let typeName = property.typeName, (typeName.hasSuffix("?") || (typeName.hasPrefix("Optional<") && typeName.hasSuffix(">"))) {
                // Optional type: explicitly cast to Any to avoid implicit coercion warnings
                valueExpression = "self.\(storageName).wrappedValue as Any"
            } else {
                valueExpression = "self.\(storageName).wrappedValue"
            }
            let (conversionCode, needsTry) = generateConversionCode(for: property.typeName, valueName: valueExpression, isAnyType: false)
            
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
            
            codeLines.append("\(storageName).clearDirty()")
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
    /// valueName is expected to be of type Any? (from filteredValue) for snapshot method
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
        
        let normalizedType = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if it's an Optional type (handle first)
        if normalizedType.hasSuffix("?") {
            // Optional type: use make(from:for:) to handle nil properly
            if let playerID = playerID {
                return ("SnapshotValue.make(from: \(valueName), for: \(playerID))", true)
            } else {
                return ("SnapshotValue.make(from: \(valueName))", true)
            }
        }
        
        if normalizedType.hasPrefix("Optional<") && normalizedType.hasSuffix(">") {
            // Optional<Type> format: use make(from:for:) to handle nil properly
            if let playerID = playerID {
                return ("SnapshotValue.make(from: \(valueName), for: \(playerID))", true)
            } else {
                return ("SnapshotValue.make(from: \(valueName))", true)
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

/// Information about a property in a StateNode
private struct PropertyInfo {
    let name: String
    let hasSync: Bool
    let hasInternal: Bool
    let policyType: String?
    let typeName: String?  // Type name for optimization
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
    
    let normalized = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Check for Dictionary: [Key: Value] or Dictionary<Key, Value>
    if normalized.hasPrefix("[") && normalized.contains(":") && normalized.hasSuffix("]") {
        // Format: [Key: Value]
        let content = String(normalized.dropFirst().dropLast()) // Remove [ and ]
        let parts = content.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            let keyType = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueType = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return .dictionary(keyType: keyType, valueType: valueType)
        }
    } else if normalized.hasPrefix("Dictionary<") && normalized.hasSuffix(">") {
        // Format: Dictionary<Key, Value>
        let content = String(normalized.dropFirst("Dictionary<".count).dropLast())
        let parts = content.split(separator: ",", maxSplits: 1)
        if parts.count == 2 {
            let keyType = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valueType = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return .dictionary(keyType: keyType, valueType: valueType)
        }
    }
    
    // Check for Array: [Element] or Array<Element>
    if normalized.hasPrefix("[") && normalized.hasSuffix("]") && !normalized.contains(":") {
        // Format: [Element]
        let elementType = String(normalized.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return .array(elementType: elementType)
    } else if normalized.hasPrefix("Array<") && normalized.hasSuffix(">") {
        // Format: Array<Element>
        let elementType = String(normalized.dropFirst("Array<".count).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return .array(elementType: elementType)
    }
    
    // Check for Set: Set<Element>
    if normalized.hasPrefix("Set<") && normalized.hasSuffix(">") {
        // Format: Set<Element>
        let elementType = String(normalized.dropFirst("Set<".count).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
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
        SnapshotConvertibleMacro.self
    ]
}
