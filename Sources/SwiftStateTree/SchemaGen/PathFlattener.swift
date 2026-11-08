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
///
/// A recursive type (one that holds itself, directly or through other types) has infinitely
/// many path patterns, so its path hashes can't cover it (#286). `flatten` stops where a type
/// re-enters itself; `flattenRejectingRecursion`, which schema generation uses, throws instead.
public struct PathFlattener {
    
    /// Flatten a schema starting from a root type name.
    ///
    /// A recursive type is followed down to where it re-enters itself: the paths below that
    /// point are left out (`flattenRejectingRecursion` refuses such a type instead).
    ///
    /// - Parameters:
    ///   - rootTypeName: The name of the root type to start from (e.g., "GameState")
    ///   - definitions: The schema definitions dictionary (from ProtocolSchema.defs)
    /// - Returns: Dictionary mapping path patterns to their FNV-1a hashes
    public static func flatten(
        rootTypeName: String,
        definitions: [String: JSONSchema]
    ) -> [String: UInt32] {
        walk(rootTypeName: rootTypeName, definitions: definitions).paths
    }

    /// `flatten`, refusing a recursive type (#286).
    ///
    /// - Throws: `RecursiveStateTypeError` naming the first type that re-enters itself (fields
    ///   in name order), and the path where it does.
    public static func flattenRejectingRecursion(
        rootTypeName: String,
        definitions: [String: JSONSchema]
    ) throws -> [String: UInt32] {
        let result = walk(rootTypeName: rootTypeName, definitions: definitions)
        if let recursion = result.recursion { throw recursion }
        return result.paths
    }

    private struct Walk {
        var paths: [String: UInt32] = [:]
        var visited: Set<String> = []
        /// The types being traversed, from the root to the current one.
        var typesOnPath: [String] = []
        /// The first re-entry met.
        var recursion: RecursiveStateTypeError?
    }

    private static func walk(rootTypeName: String, definitions: [String: JSONSchema]) -> Walk {
        var walk = Walk()
        traverse(typeName: rootTypeName, currentPath: [], definitions: definitions, walk: &walk)
        return walk
    }
    
    // MARK: - Private Traversal
    
    private static func traverse(
        typeName: String,
        currentPath: [String],
        definitions: [String: JSONSchema],
        walk: inout Walk
    ) {
        // A type inside itself: its paths would never end (#286).
        guard !walk.typesOnPath.contains(typeName) else {
            if walk.recursion == nil {
                walk.recursion = RecursiveStateTypeError(typeName: typeName, path: currentPath.joined(separator: "."))
            }
            return
        }
        let pathKey = "\(typeName)@\(currentPath.joined(separator: "."))"
        guard !walk.visited.contains(pathKey) else { return }
        walk.visited.insert(pathKey)
        
        guard let schema = definitions[typeName] else {
            return
        }
        
        walk.typesOnPath.append(typeName)
        defer { walk.typesOnPath.removeLast() }
        traverseSchema(
            schema: schema,
            currentPath: currentPath,
            definitions: definitions,
            walk: &walk
        )
    }
    
    private static func traverseSchema(
        schema: JSONSchema,
        currentPath: [String],
        definitions: [String: JSONSchema],
        walk: inout Walk
    ) {
        // Handle $ref
        if let ref = schema.ref {
            let typeName = extractTypeNameFromRef(ref)
            traverse(
                typeName: typeName,
                currentPath: currentPath,
                definitions: definitions,
                walk: &walk
            )
            return
        }
        
        // `Optional<T>`: the value is a `T` or null, so its paths are `T`'s (#287). Its definition
        // has no properties of its own, only `x-stateTree.innerType`. An optional atomic value
        // (`Position2?`) is one value on the wire and stays a leaf: nothing is added below it.
        if schema.properties == nil, schema.additionalProperties == nil, schema.items == nil,
           schema.xStateTree?.optional == true, schema.xStateTree?.atomic != true,
           let inner = schema.xStateTree?.innerType, definitions[inner]?.xStateTree?.atomic != true {
            traverse(
                typeName: inner,
                currentPath: currentPath,
                definitions: definitions,
                walk: &walk
            )
            return
        }

        // Handle object with properties
        if let properties = schema.properties {
            // In name order, so the first recursion found is the same in every process.
            for (propertyName, propertySchema) in properties.sorted(by: { $0.key < $1.key }) {
                let newPath = currentPath + [propertyName]
                
                // Add this path
                addPath(newPath, to: &walk.paths)
                
                // Recurse into property
                traverseSchema(
                    schema: propertySchema,
                    currentPath: newPath,
                    definitions: definitions,
                    walk: &walk
                )
            }
        }
        
        // Handle map (additionalProperties)
        if let additionalProps = schema.additionalProperties {
            let newPath = currentPath + ["*"]
            
            // Add wildcard path
            addPath(newPath, to: &walk.paths)
            
            // Recurse into value type
            traverseSchema(
                schema: additionalProps.value,
                currentPath: newPath,
                definitions: definitions,
                walk: &walk
            )
        }
        
        // Handle array (items)
        if let items = schema.items {
            let newPath = currentPath + ["*"]
            
            // Add wildcard path
            addPath(newPath, to: &walk.paths)
            
            // Recurse into item type
            traverseSchema(
                schema: items.value,
                currentPath: newPath,
                definitions: definitions,
                walk: &walk
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

/// A state type that holds itself, directly or through other types (#286). Schema generation
/// refuses it: a recursive type has infinitely many path patterns, so its path hashes can't
/// cover it.
public struct RecursiveStateTypeError: Error, CustomStringConvertible, Equatable, Sendable {
    /// The type that re-enters itself.
    public let typeName: String
    /// Where it does, as a path pattern from the land's state (`tree.children.*`).
    public let path: String

    public init(typeName: String, path: String) {
        self.typeName = typeName
        self.path = path
    }

    public var description: String {
        """
        The state type \(typeName) holds itself at \(path): schema generation doesn't support a \
        recursive state type, since its path patterns never end (#286). Bound the depth with \
        separate types, or keep the tree flat (for example a map from node ID to a node that holds \
        its children's IDs).
        """
    }
}
