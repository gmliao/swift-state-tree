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
        from landDefinition: LandDefinition<State>,
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
            
            // Extract Response type if available
            if let responseType = handler.getResponseType() {
                // Extract Response schema and add to definitions
                _ = ActionEventExtractor.extractEvent(
                    responseType,
                    definitions: &definitions,
                    visitedTypes: &visitedTypes
                )
                
                // Response type is now in definitions with its type name
                // The response schema can be referenced via its type name in defs
            }
            
            // ActionEventExtractor.extractAction already handles SchemaMetadataProvider
            // and creates the detailed schema in definitions, so we don't need to duplicate that logic here.
            // However, we ensure the definition is properly stored if it wasn't already.
            let typeName = String(describing: actionType)
            if let provider = actionType as? any SchemaMetadataProvider.Type,
               definitions[typeName] == nil {
                // If for some reason the definition wasn't created, create it now
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
        
        // Extract client events from registry (Client → Server)
        var clientEvents: [String: JSONSchema] = [:]
        for descriptor in landDefinition.clientEventRegistry.registered {
            // Use ActionEventExtractor.extractEvent which properly handles SchemaMetadataProvider
            _ = ActionEventExtractor.extractEvent(
                descriptor.type,
                definitions: &definitions,
                visitedTypes: &visitedTypes
            )
            
            let typeName = String(describing: descriptor.type)
            
            // Generate event ID from type name (e.g., "ChatEvent" -> "chat")
            let eventID = generateEventID(from: descriptor.type)
            // Always use a reference to the definition
            clientEvents[eventID] = JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        // Extract server events from registry (Server → Client)
        var events: [String: JSONSchema] = [:]
        for descriptor in landDefinition.serverEventRegistry.registered {
            // Use ActionEventExtractor.extractEvent which properly handles SchemaMetadataProvider
            // This will correctly extract fields from @Payload macro via getFieldMetadata()
            _ = ActionEventExtractor.extractEvent(
                descriptor.type,
                definitions: &definitions,
                visitedTypes: &visitedTypes
            )
            
            // ActionEventExtractor.extractEvent already handles SchemaMetadataProvider
            // and creates the detailed schema in definitions, so we don't need to duplicate that logic here.
            let typeName = String(describing: descriptor.type)
            
            // Generate event ID from type name (e.g., "WelcomeEvent" -> "welcome")
            let eventID = generateEventID(from: descriptor.type)
            // Always use a reference to the definition
            events[eventID] = JSONSchema(ref: "#/defs/\(typeName)")
        }
        
        // Create sync schema
        let snapshotSchema = JSONSchema(ref: "#/defs/\(stateTypeName)")
        // For diff schema, we'll create a placeholder
        // In a full implementation, you'd define the actual diff format
        let diffSchema = createDiffSchema(definitions: &definitions)
        
        let syncSchema = SyncSchema(
            snapshot: snapshotSchema,
            diff: diffSchema
        )
        
        // Generate path hashes for state update compression
        let pathHashes = PathFlattener.flatten(
            rootTypeName: stateTypeName,
            definitions: definitions
        )
        
        // Create land schema
        let landSchema = LandSchema(
            stateType: stateTypeName,
            actions: actions,
            clientEvents: clientEvents,
            events: events,
            sync: syncSchema,
            pathHashes: pathHashes
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
    /// Example: "AddGoldAction" -> "AddGold" (removes "Action" suffix, keeps camelCase)
    /// In a full implementation, you'd want to:
    /// 1. Require actions to have a static actionID property
    /// 2. Or use a more sophisticated naming convention
    private static func generateActionID(from actionType: Any.Type) -> String {
        let typeName = String(describing: actionType)
        
        // Remove module prefix if present (e.g., "Module.AddGoldAction" -> "AddGoldAction")
        let baseTypeName: String
        if let lastComponent = typeName.split(separator: ".").last {
            baseTypeName = String(lastComponent)
        } else {
            baseTypeName = typeName
        }
        
        // Remove "Action" suffix if present, keep camelCase format
        // Example: "AddGoldAction" -> "AddGold"
        var actionID = baseTypeName
        if actionID.hasSuffix("Action") {
            actionID = String(actionID.dropLast(6))
        }
        
        // Return camelCase format (e.g., "AddGold")
        return actionID
    }
    
    /// Generate event ID from server event type.
    ///
    /// Mirrors the behavior of `generateActionID` but uses the "Event" suffix.
    private static func generateEventID(from eventType: Any.Type) -> String {
        let typeName = String(describing: eventType)
        
        // Extract base type name (handle module prefixes)
        var baseTypeName: String
        if let lastComponent = typeName.split(separator: ".").last {
            baseTypeName = String(lastComponent)
        } else {
            baseTypeName = typeName
        }
        
        // Remove "Event" suffix if present, keep camelCase format
        // Example: "ChatEvent" -> "Chat", "PingEvent" -> "Ping"
        var eventID = baseTypeName
        if eventID.hasSuffix("Event") {
            eventID = String(eventID.dropLast(5))
        }
        
        // Return camelCase format (e.g., "Chat", "Ping", "ChatMessage")
        return eventID
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
