import Foundation

/// Main extractor that generates ProtocolSchema from LandDefinition.
public struct SchemaExtractor {
    /// Extract protocol schema from a LandDefinition.
    ///
    /// - Parameters:
    ///   - landDefinition: The LandDefinition to extract schema from.
    ///   - version: Schema version string (default: "0.1.0").
    /// - Returns: A ProtocolSchema containing all land definitions, actions, events, and state tree schemas.
    public static func extract<State: StateNodeProtocol>(
        from landDefinition: LandDefinition<State, some ClientEventPayload, some ServerEventPayload>,
        version: String = "0.1.0"
    ) -> ProtocolSchema {
        var definitions: [String: JSONSchema] = [:]
        var visitedTypes: Set<String> = []
        
        // Extract state tree schema
        let stateTypeName = String(describing: State.self)
        let stateSchema = StateTreeSchemaExtractor.extract(
            State.self,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
        
        // Ensure state type is in definitions
        if definitions[stateTypeName] == nil {
            // If not already added, add it
            definitions[stateTypeName] = stateSchema
        }
        
        // Extract actions
        var actions: [String: JSONSchema] = [:]
        for handler in landDefinition.actionHandlers {
            let actionType = handler.getActionType()
            let actionSchema = ActionEventExtractor.extractAction(
                actionType,
                definitions: &definitions,
                visitedTypes: &visitedTypes
            )
            
            // Ensure we always have a fully expanded definition for action payloads.
            // This guarantees defs[ActionType] contains all fields even if other
            // converters added a placeholder earlier.
            if let provider = actionType as? any SchemaMetadataProvider.Type {
                let typeName = String(describing: actionType)
                let fieldMetadata = provider.getFieldMetadata()
                
                var properties: [String: JSONSchema] = [:]
                var required: [String] = []
                
                for field in fieldMetadata {
                    var fieldSchema = TypeToSchemaConverter.convert(
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
                
                let detailed = JSONSchema(
                    type: .object,
                    properties: properties,
                    required: required,
                    xStateTree: StateTreeMetadata(nodeKind: .leaf)
                )
                
                definitions[typeName] = detailed
            }
            
            // Generate action ID from type name
            // Convert type name to action ID format: "TypeName" -> "typeName" or use a custom mapping
            let actionID = generateActionID(from: actionType)
            actions[actionID] = actionSchema
        }
        
        // Extract server events
        var events: [String: JSONSchema] = [:]
        let serverEventSchema = ActionEventExtractor.extractEvent(
            landDefinition.serverEventType,
            definitions: &definitions,
            visitedTypes: &visitedTypes
        )
        
        // For enum-based events, we might want to extract individual cases
        // For now, we'll add the whole event type
        let eventTypeName = String(describing: landDefinition.serverEventType)
        events[eventTypeName] = serverEventSchema
        
        // Create sync schema
        let snapshotSchema = JSONSchema(ref: "#/defs/\(stateTypeName)")
        // For diff schema, we'll create a placeholder
        // In a full implementation, you'd define the actual diff format
        let diffSchema = createDiffSchema(definitions: &definitions)
        
        let syncSchema = SyncSchema(
            snapshot: snapshotSchema,
            diff: diffSchema
        )
        
        // Create land schema
        let landSchema = LandSchema(
            stateType: stateTypeName,
            actions: actions,
            events: events,
            sync: syncSchema
        )
        
        return ProtocolSchema(
            version: version,
            lands: [landDefinition.id: landSchema],
            defs: definitions
        )
    }
    
    // MARK: - Helper Methods
    
    /// Generate action ID from action type.
    ///
    /// Converts type name to action ID format.
    /// In a full implementation, you'd want to:
    /// 1. Require actions to have a static actionID property
    /// 2. Or use a more sophisticated naming convention
    private static func generateActionID(from actionType: Any.Type) -> String {
        let typeName = String(describing: actionType)
        
        // Simple conversion: "JoinAction" -> "join"
        // Remove "Action" suffix if present
        var actionID = typeName
        if actionID.hasSuffix("Action") {
            actionID = String(actionID.dropLast(6))
        }
        
        // Convert to lowercase with dots (e.g., "MatchJoin" -> "match.join")
        // This is a simplified approach - in production, you'd want a more structured mapping
        let camelCase = actionID.prefix(1).lowercased() + actionID.dropFirst()
        
        // For now, just return the lowercase version
        // In a full implementation, you'd parse camelCase and insert dots
        return camelCase.lowercased()
    }
    
    /// Create a diff schema placeholder.
    ///
    /// In a full implementation, you'd define the actual diff format used by your sync engine.
    private static func createDiffSchema(definitions: inout [String: JSONSchema]) -> JSONSchema {
        let diffTypeName = "StateDiff"
        
        // Create a basic diff schema (JSON Patch format)
        let diffSchema = JSONSchema(
            type: .object,
            properties: [
                "patches": JSONSchema(
                    type: .array,
                    items: JSONSchema(
                        type: .object,
                        properties: [
                            "op": JSONSchema(type: .string),
                            "path": JSONSchema(type: .string),
                            "value": JSONSchema(type: .object)
                        ],
                        required: ["op", "path"]
                    )
                )
            ],
            required: ["patches"],
            xStateTree: StateTreeMetadata(nodeKind: .leaf)
        )
        
        definitions[diffTypeName] = diffSchema
        
        return JSONSchema(ref: "#/defs/\(diffTypeName)")
    }
}
