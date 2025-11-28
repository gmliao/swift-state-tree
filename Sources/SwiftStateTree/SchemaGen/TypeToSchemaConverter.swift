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
            // For arrays, we need to extract element type from metadata or use a generic approach
            // Since we have metadata, we can use it, but for now we'll create a generic schema
            // In a full implementation, you'd extract the element type from the FieldMetadata
            return JSONSchema(
                type: .array,
                items: JSONSchema(type: .object), // Placeholder - should extract from metadata
                xStateTree: StateTreeMetadata(
                    nodeKind: .array,
                    sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) }
                )
            )
        }
        
        // Handle Dictionary/Map types (based on nodeKind from metadata)
        if nodeKind == .map {
            // For dictionaries, create a schema with additionalProperties
            // The value type should be extracted from metadata in a full implementation
            return JSONSchema(
                type: .object,
                additionalProperties: JSONSchema(type: .object), // Placeholder - should extract from metadata
                xStateTree: StateTreeMetadata(
                    nodeKind: .map,
                    sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) }
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
            let fieldSchema = convert(
                field.type,
                metadata: field,
                definitions: &definitions,
                visitedTypes: &visitedTypes
            )
            
            properties[field.name] = fieldSchema
            
            // All @Sync fields are required (they're part of the state tree)
            required.append(field.name)
        }
        
        let schema = JSONSchema(
            type: .object,
            properties: properties,
            required: required,
            xStateTree: StateTreeMetadata(
                nodeKind: .object,
                sync: metadata?.policy.map { SyncMetadata(policy: $0.rawValue) }
            )
        )
        
        // Store in definitions for $ref usage
        definitions[typeName] = schema
        
        return JSONSchema(ref: "#/defs/\(typeName)")
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
                let fieldSchema = convert(
                    field.type,
                    metadata: field,
                    definitions: &definitions,
                    visitedTypes: &visitedTypes
                )
                
                properties[field.name] = fieldSchema
                required.append(field.name)
            }
            
            let schema = JSONSchema(
                type: .object,
                properties: properties,
                required: required,
                xStateTree: metadata.map { StateTreeMetadata(nodeKind: $0.nodeKind, sync: $0.policy.map { SyncMetadata(policy: $0.rawValue) }) }
            )
            
            definitions[typeName] = schema
            return JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        // Fallback: create a basic object schema
        // In production, you might want to:
        // 1. Use Codable introspection
        // 2. Require types to provide metadata via protocol
        // 3. Use macros to generate schema information
        
        let schema = JSONSchema(
            type: .object,
            xStateTree: metadata.map { StateTreeMetadata(nodeKind: $0.nodeKind, sync: $0.policy.map { SyncMetadata(policy: $0.rawValue) }) }
        )
        
        definitions[typeName] = schema
        
        return JSONSchema(ref: "#/defs/\(typeName)")
    }
}

