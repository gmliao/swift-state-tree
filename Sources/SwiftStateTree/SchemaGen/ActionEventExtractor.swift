import Foundation

/// Extracts JSON Schema from Action and Event types.
public struct ActionEventExtractor {
    /// Extract schema from an ActionPayload type.
    ///
    /// - Parameters:
    ///   - type: The ActionPayload type to extract schema from.
    ///   - definitions: Dictionary to store nested type definitions.
    ///   - visitedTypes: Set of already visited types to prevent infinite recursion.
    /// - Returns: A JSONSchema representation of the action payload.
    public static func extractAction(
        _ type: Any.Type,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        let typeName = String(describing: type)
        
        // Check if type conforms to SchemaMetadataProvider
        if let metadataProvider = type as? any SchemaMetadataProvider.Type {
            let fieldMetadata = metadataProvider.getFieldMetadata()
            
            var properties: [String: JSONSchema] = [:]
            var required: [String] = []
            
            for field in fieldMetadata {
                let fieldSchema = TypeToSchemaConverter.convert(
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
                xStateTree: StateTreeMetadata(nodeKind: .leaf)
            )
            
            // Store the detailed schema in definitions and return a $ref
            definitions[typeName] = schema
            return JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        // Fallback: use TypeToSchemaConverter
        return TypeToSchemaConverter.convert(
            type,
            metadata: nil,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
    }
    
    /// Extract schema from an EventPayload type.
    ///
    /// - Parameters:
    ///   - type: The EventPayload type to extract schema from.
    ///   - definitions: Dictionary to store nested type definitions.
    ///   - visitedTypes: Set of already visited types to prevent infinite recursion.
    /// - Returns: A JSONSchema representation of the event payload.
    public static func extractEvent<E: Codable & Sendable>(
        _ type: E.Type,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        let typeName = String(describing: type)
        
        // Check if type conforms to SchemaMetadataProvider
        if let metadataProvider = type as? any SchemaMetadataProvider.Type {
            let fieldMetadata = metadataProvider.getFieldMetadata()
            
            var properties: [String: JSONSchema] = [:]
            var required: [String] = []
            
            for field in fieldMetadata {
                let fieldSchema = TypeToSchemaConverter.convert(
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
                xStateTree: StateTreeMetadata(nodeKind: .leaf)
            )
            
            // Store the detailed schema in definitions and return a $ref
            definitions[typeName] = schema
            return JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        // Handle enum types (common for events)
        if let enumSchema = extractEnumEvent(type, definitions: &definitions, visitedTypes: &visitedTypes) {
            return enumSchema
        }
        
        // Fallback: use TypeToSchemaConverter
        return TypeToSchemaConverter.convert(
            type,
            metadata: nil,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
    }
    
    /// Extract schema from an enum event type.
    ///
    /// This handles enum-based events (e.g., `enum MyEvent { case case1(String), case2(Int) }`).
    private static func extractEnumEvent(
        _ type: Any.Type,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema? {
        // For enum types, we create a schema with enum values
        // In a full implementation, you'd extract the enum cases using reflection
        // For now, we'll return nil and let the fallback handle it
        
        // TODO: Implement enum case extraction
        // This would require:
        // 1. Using Swift's reflection to get all enum cases
        // 2. Or requiring enums to conform to a protocol that provides case information
        // 3. Or using a macro to generate case information
        
        return nil
    }
}
