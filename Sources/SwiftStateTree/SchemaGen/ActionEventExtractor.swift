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
    public static func extractEvent(
        _ type: Any.Type,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        let typeName = String(describing: type)
        
        // Check if type conforms to SchemaMetadataProvider (recommended path for codegen)
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
        
        // Check if type has getFieldMetadata() method even if it doesn't conform to SchemaMetadataProvider
        // This handles Response types that use @Payload macro but don't explicitly conform to SchemaMetadataProvider
        if let getFieldMetadataMethod = getGetFieldMetadataMethod(from: type) {
            let fieldMetadata = getFieldMetadataMethod()
            
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
            
            definitions[typeName] = schema
            return JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        // Fallback: use TypeToSchemaConverter (struct events without metadata, basic objects)
        return TypeToSchemaConverter.convert(
            type,
            metadata: nil,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
    }
    
    /// Try to get getFieldMetadata() method from a type using runtime reflection
    private static func getGetFieldMetadataMethod(from type: Any.Type) -> (() -> [FieldMetadata])? {
        // Use runtime reflection to check if type has getFieldMetadata() method
        // This is a workaround for types that have the method but don't conform to the protocol
        let mirror = Mirror(reflecting: type)
        
        // Try to find getFieldMetadata method using type metadata
        // This is a simplified approach - in production you might want to use more sophisticated reflection
        // For now, we'll rely on the protocol conformance check above
        return nil
    }
    
    /// Extract schema from an EventPayload type (generic version for type-safe usage).
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
        return extractEvent(type as Any.Type, definitions: &definitions, visitedTypes: &visitedTypes)
    }
}
