import Foundation

/// Extracts JSON Schema from StateNodeProtocol types recursively.
public struct StateTreeSchemaExtractor {
    /// Extract schema from a StateNodeProtocol type.
    ///
    /// - Parameters:
    ///   - type: The StateNodeProtocol type to extract schema from.
    ///   - definitions: Dictionary to store nested type definitions.
    ///   - visitedTypes: Set of already visited types to prevent infinite recursion.
    /// - Returns: A JSONSchema representation of the state tree.
    public static func extract<State: StateNodeProtocol>(
        _ type: State.Type,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        return TypeToSchemaConverter.convert(
            type,
            metadata: nil,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
    }
    
    /// Extract schema from a StateNodeProtocol instance.
    ///
    /// This is a convenience method that uses the type's static getFieldMetadata().
    ///
    /// - Parameters:
    ///   - state: The StateNodeProtocol instance.
    ///   - definitions: Dictionary to store nested type definitions.
    ///   - visitedTypes: Set of already visited types to prevent infinite recursion.
    /// - Returns: A JSONSchema representation of the state tree.
    public static func extract<State: StateNodeProtocol>(
        from state: State,
        definitions: inout [String: JSONSchema],
        visitedTypes: inout Set<String>
    ) -> JSONSchema {
        return extract(
            State.self,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
    }
}

