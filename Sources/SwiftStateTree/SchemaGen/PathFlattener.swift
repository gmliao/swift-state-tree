import Foundation

/// Flattens a JSON Schema tree into a list of all possible paths.
///
/// This traverses the schema definitions and generates path patterns like:
/// - `round` (simple field)
/// - `players.*.hp` (map with wildcard)
/// - `players.*.inventory.*.itemId` (nested maps)
/// - `units.*.position.x` (object field in map)
///
/// The paths use dot notation with `*` for dynamic segments (map keys, array indices).
public struct PathFlattener {
    
    /// Flatten a schema starting from a root type name.
    ///
    /// - Parameters:
    ///   - rootTypeName: The name of the root type to start from (e.g., "GameState")
    ///   - definitions: The schema definitions dictionary (from ProtocolSchema.defs)
    /// - Returns: Dictionary mapping path patterns to their FNV-1a hashes
    public static func flatten(
        rootTypeName: String,
        definitions: [String: JSONSchema]
    ) -> [String: UInt32] {
        var paths: [String: UInt32] = [:]
        var visited: Set<String> = []
        
        // Start traversal from root
        traverse(
            typeName: rootTypeName,
            currentPath: [],
            definitions: definitions,
            paths: &paths,
            visited: &visited
        )
        
        return paths
    }
    
    // MARK: - Private Traversal
    
    private static func traverse(
        typeName: String,
        currentPath: [String],
        definitions: [String: JSONSchema],
        paths: inout [String: UInt32],
        visited: inout Set<String>
    ) {
        // Prevent infinite recursion for circular references
        let pathKey = "\(typeName)@\(currentPath.joined(separator: "."))"
        guard !visited.contains(pathKey) else { return }
        visited.insert(pathKey)
        
        guard let schema = definitions[typeName] else {
            return
        }
        
        traverseSchema(
            schema: schema,
            currentPath: currentPath,
            definitions: definitions,
            paths: &paths,
            visited: &visited
        )
    }
    
    private static func traverseSchema(
        schema: JSONSchema,
        currentPath: [String],
        definitions: [String: JSONSchema],
        paths: inout [String: UInt32],
        visited: inout Set<String>
    ) {
        // Handle $ref
        if let ref = schema.ref {
            let typeName = extractTypeNameFromRef(ref)
            traverse(
                typeName: typeName,
                currentPath: currentPath,
                definitions: definitions,
                paths: &paths,
                visited: &visited
            )
            return
        }
        
        // Handle object with properties
        if let properties = schema.properties {
            for (propertyName, propertySchema) in properties {
                let newPath = currentPath + [propertyName]
                
                // Add this path
                addPath(newPath, to: &paths)
                
                // Recurse into property
                traverseSchema(
                    schema: propertySchema,
                    currentPath: newPath,
                    definitions: definitions,
                    paths: &paths,
                    visited: &visited
                )
            }
        }
        
        // Handle map (additionalProperties)
        if let additionalProps = schema.additionalProperties {
            let newPath = currentPath + ["*"]
            
            // Add wildcard path
            addPath(newPath, to: &paths)
            
            // Recurse into value type
            traverseSchema(
                schema: additionalProps.value,
                currentPath: newPath,
                definitions: definitions,
                paths: &paths,
                visited: &visited
            )
        }
        
        // Handle array (items)
        if let items = schema.items {
            let newPath = currentPath + ["*"]
            
            // Add wildcard path
            addPath(newPath, to: &paths)
            
            // Recurse into item type
            traverseSchema(
                schema: items.value,
                currentPath: newPath,
                definitions: definitions,
                paths: &paths,
                visited: &visited
            )
        }
    }
    
    // MARK: - Helpers
    
    private static func addPath(_ pathComponents: [String], to paths: inout [String: UInt32]) {
        let pathString = pathComponents.joined(separator: ".")
        let hash = DeterministicHash.fnv1a32(pathString)
        paths[pathString] = hash
    }
    
    private static func extractTypeNameFromRef(_ ref: String) -> String {
        // Extract type name from "#/defs/TypeName"
        if let range = ref.range(of: "#/defs/") {
            return String(ref[range.upperBound...])
        }
        return ref
    }
}
