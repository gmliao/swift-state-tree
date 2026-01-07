import Foundation

/// Converts Swift types to JSON Schema representations.
public struct TypeToSchemaConverter {
    /// Convert a Swift type to JSON Schema.
    ///
    /// - Parameters:
    ///   - type: The Swift type to convert.
    ///   - metadata: Optional field metadata (for sync policy, nodeKind, etc.).
    ///   - definitions: Dictionary to store nested type definitions (for $ref).
    ///   - visitedTypes: Set of already visited types to prevent infinite recursion.
    /// - Returns: A JSONSchema representation of the type.
    public static func convert(
        _ type: Any.Type,
        metadata: FieldMetadata? = nil,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        // Use metadata's nodeKind if available (from getFieldMetadata)
        let nodeKind = metadata?.nodeKind ?? SchemaHelper.determineNodeKind(from: type)
        
        // Handle primitive types
        if let primitive = convertPrimitiveType(type) {
            return primitive
        }
        
        // Handle StateNodeProtocol types (recursive) - check this before other container types
        if let stateNodeType = type as? any StateNodeProtocol.Type {
            return convertStateNodeType(
                stateNodeType,
                metadata: metadata,
                definitions: &definitions,
                visitedTypes: &visitedTypes
            )
        }
        
        // Handle Array types (based on nodeKind from metadata)
        if nodeKind == .array {
            // Extract element type from the array
            let elementSchema: JSONSchema
            if let elementType = SchemaHelper.arrayElementType(from: type) {
                // Recursively convert the element type, determining its nodeKind
                let elementNodeKind = SchemaHelper.determineNodeKind(from: elementType)
                elementSchema = convert(
                    elementType,
                    metadata: FieldMetadata(
                        name: "",
                        type: elementType,
                        policy: nil,
                        nodeKind: elementNodeKind,
                        defaultValue: nil
                    ),
                    definitions: &definitions,
                    visitedTypes: &visitedTypes
                )
            } else {
                // Fallback to a generic object if we can't extract element type
                elementSchema = JSONSchema(type: .object)
            }
            
            return JSONSchema(
                type: .array,
                items: elementSchema,
                xStateTree: StateTreeMetadata(
                    nodeKind: .array,
                    sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) },
                    atomic: nil
                )
            )
        }
        
        // Handle Dictionary/Map types (based on nodeKind from metadata)
        if nodeKind == .map {
            // For dictionaries, create a schema with additionalProperties describing
            // the value type when possible.
            let valueSchema: JSONSchema
            if let valueType = SchemaHelper.dictionaryValueType(from: type) {
                // Recursively convert the value type, determining its nodeKind
                let valueNodeKind = SchemaHelper.determineNodeKind(from: valueType)
                valueSchema = convert(
                    valueType,
                    metadata: FieldMetadata(
                        name: "",
                        type: valueType,
                        policy: nil,
                        nodeKind: valueNodeKind,
                        defaultValue: nil
                    ),
                    definitions: &definitions,
                    visitedTypes: &visitedTypes
                )
            } else {
                // Fallback to a generic object
                valueSchema = JSONSchema(type: .object)
            }
            
            return JSONSchema(
                type: .object,
                additionalProperties: valueSchema,
                xStateTree: StateTreeMetadata(
                    nodeKind: .map,
                    sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) },
                    atomic: nil
                )
            )
        }
        
        // Handle Enum types (try to extract cases)
        if let enumSchema = convertEnumType(type, definitions: &definitions, visitedTypes: &visitedTypes) {
            return enumSchema
        }
        
        // Default: treat as Codable object (use Mirror as fallback)
        return convertCodableType(
            type,
            metadata: metadata,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
    }
    
    // MARK: - Primitive Types
    
    private static func convertPrimitiveType(_ type: Any.Type) -> JSONSchema? {
        switch type {
        case is String.Type:
            return JSONSchema(type: .string)
        case is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type,
             is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type:
            return JSONSchema(type: .integer)
        case is Double.Type, is Float.Type:
            return JSONSchema(type: .number)
        case is Bool.Type:
            return JSONSchema(type: .boolean)
        default:
            return nil
        }
    }
    
    // MARK: - Type Extraction Helpers
    // Note: Swift's runtime type system has limitations for extracting generic parameters.
    // We rely on getFieldMetadata() from macros to provide accurate type information.
    
    // MARK: - StateNodeProtocol Conversion
    
    private static func convertStateNodeType(
        _ type: any StateNodeProtocol.Type,
        metadata: FieldMetadata?,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        let typeName = String(describing: type)
        
        // Check if we've already processed this type (prevent infinite recursion)
        if visitedTypes.contains(typeName) {
            return JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        visitedTypes.insert(typeName)
        
        // Get field metadata from the type
        let fieldMetadata = type.getFieldMetadata()
        
        var properties: [String: JSONSchema] = [:]
        var required: [String] = []
        
        for field in fieldMetadata {
            var fieldSchema = convert(
                field.type,
                metadata: field,
                definitions: &definitions,
                visitedTypes: &visitedTypes
            )
            
            if let defaultValue = field.defaultValue {
                fieldSchema.defaultValue = defaultValue
            }
            
            properties[field.name] = fieldSchema
            
            // All @Sync fields are required (they're part of the state tree)
            required.append(field.name)
        }
        
        // Check if this is an atomic type (DeterministicMath types)
        let isAtomic = isAtomicType(type)
        
        let schema = JSONSchema(
            type: .object,
            properties: properties,
            required: required,
            xStateTree: StateTreeMetadata(
                nodeKind: .object,
                sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) },
                atomic: isAtomic ? true : nil
            )
        )
        
        // Store in definitions for $ref usage
        definitions[typeName] = schema
        
        return JSONSchema(ref: "#/defs/\(typeName)")
    }
    
    // MARK: - Atomic Type Detection
    
    /// Check if a type is an atomic DeterministicMath type.
    /// Atomic types should be updated as a whole unit, not field-by-field.
    private static func isAtomicType(_ type: Any.Type) -> Bool {
        let typeName = String(describing: type)
        // Check for DeterministicMath types
        return typeName.contains("IVec2") ||
               typeName.contains("IVec3") ||
               typeName.contains("Position2") ||
               typeName.contains("Velocity2") ||
               typeName.contains("Acceleration2") ||
               typeName.contains("Angle")
    }
    
    // MARK: - Enum Type Conversion
    
    private static func convertEnumType(
        _ type: Any.Type,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema? {
        // Try to extract enum cases using Mirror
        // This is a simplified approach - in production, you might want to use more sophisticated reflection
        // or require types to conform to a protocol that provides case information
        
        // For now, we'll handle enums as strings with enum values
        // In a real implementation, you'd need to:
        // 1. Use Swift's reflection to get all cases
        // 2. Or require enums to conform to a protocol that provides case names
        // 3. Or use a macro to generate case information
        
        return nil
    }
    
    // MARK: - Codable Type Conversion (Fallback)
    
    private static func convertCodableType(
        _ type: Any.Type,
        metadata: FieldMetadata?,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        let typeName = String(describing: type)
        
        // Check if we've already processed this type
        if visitedTypes.contains(typeName) {
            return JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        visitedTypes.insert(typeName)
        
        // Check if type conforms to SchemaMetadataProvider (has getFieldMetadata)
        if let metadataProvider = type as? any SchemaMetadataProvider.Type {
            let fieldMetadata = metadataProvider.getFieldMetadata()
            
            var properties: [String: JSONSchema] = [:]
            var required: [String] = []
            
            for field in fieldMetadata {
                var fieldSchema = convert(
                    field.type,
                    metadata: field,
                    definitions: &definitions,
                    visitedTypes: &visitedTypes
                )
                
                if let defaultValue = field.defaultValue {
                    fieldSchema.defaultValue = defaultValue
                }
                
                properties[field.name] = fieldSchema
                required.append(field.name)
            }
            
            // Check if this is an atomic type (DeterministicMath types)
            let isAtomic = isAtomicType(type)
            
            let schema = JSONSchema(
                type: .object,
                properties: properties,
                required: required,
                xStateTree: StateTreeMetadata(
                    nodeKind: metadata?.nodeKind ?? .leaf,
                    sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) },
                    atomic: isAtomic ? true : nil
                )
            )
            
            definitions[typeName] = schema
            return JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        // Fallback: use Mirror to extract properties from Codable types
        // This allows us to extract schema for Response types and other Codable structs
        // that don't use @Payload macro
        var properties: [String: JSONSchema] = [:]
        var required: [String] = []
        
        // Try to extract properties using JSONDecoder error information
        // When decoding fails, Swift's DecodingError contains information about missing keys
        if let codableType = type as? any Codable.Type {
            // Alternative: Try to create an instance and use Mirror
            // This works for types with default initializers or optional properties
            if let instance = createSampleInstance(of: codableType) {
                let mirror = Mirror(reflecting: instance)
                
                for child in mirror.children {
                    if let propertyName = child.label {
                        // Get the type of the property
                        let propertyType = Swift.type(of: child.value)
                        
                        // Convert the property type to schema
                        let propertySchema = convert(
                            propertyType,
                            metadata: FieldMetadata(
                                name: propertyName,
                                type: propertyType,
                                policy: nil,
                                nodeKind: SchemaHelper.determineNodeKind(from: propertyType),
                                defaultValue: nil
                            ),
                            definitions: &definitions,
                            visitedTypes: &visitedTypes
                        )
                        
                        properties[propertyName] = propertySchema
                        required.append(propertyName)
                    }
                }
            } else {
                // If we can't create an instance, try to extract from CodingKeys using reflection
                // This is more complex and may not work in all cases
                // For now, we'll leave properties empty and return a basic object schema
            }
        }
        
        // Check if this is an atomic type (DeterministicMath types)
        let isAtomic = isAtomicType(type)
        
        let schema = JSONSchema(
            type: .object,
            properties: properties.isEmpty ? nil : properties,
            required: required.isEmpty ? nil : required,
            xStateTree: StateTreeMetadata(
                nodeKind: metadata?.nodeKind ?? .leaf,
                sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) },
                atomic: isAtomic ? true : nil
            )
        )
        
        definitions[typeName] = schema
        
        return JSONSchema(ref: "#/defs/\(typeName)")
    }
    
    /// Create a sample instance of a Codable type for Mirror inspection.
    ///
    /// This is a workaround to extract property information from types
    /// that don't provide SchemaMetadataProvider.
    private static func createSampleInstance(of type: any Codable.Type) -> Any? {
        // Try to decode from an empty JSON object
        // This will fail for types that require all properties, but we can
        // extract property names from the error message or CodingKeys
        let emptyJSON = "{}"
        guard let data = emptyJSON.data(using: .utf8) else {
            return nil
        }
        
        do {
            // Try to decode - if it succeeds, we have an instance
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            // If decoding fails, try to extract property information from the error
            // For now, we'll return nil and handle it differently
            // In the future, we could parse the error to extract CodingKeys
            return nil
        } catch {
            return nil
        }
    }
}
