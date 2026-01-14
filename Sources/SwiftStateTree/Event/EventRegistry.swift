import Foundation

// MARK: - Event Descriptor

/// Describes a registered event type for schema generation and runtime validation.
public struct AnyEventDescriptor: Sendable {
    /// The Swift type of the event.
    public let type: Any.Type
    
    /// The event name (typically the type name, e.g., "WelcomeEvent").
    public let eventName: String
    
    /// The direction of the event (client or server).
    public let direction: EventDirection
    
    public init(type: Any.Type, eventName: String, direction: EventDirection) {
        self.type = type
        self.eventName = eventName
        self.direction = direction
    }
}

/// Direction of an event (client-to-server or server-to-client).
public enum EventDirection: Sendable {
    case client
    case server
}

// MARK: - Event Registry

/// Registry for tracking registered event types.
///
/// This registry is used for:
/// - Schema generation (knowing which events to include in the schema)
/// - Runtime validation (warning when unregistered events are sent)
/// - Event name resolution (mapping Swift types to event names)
public struct EventRegistry<E: Codable & Sendable>: Sendable {
    /// List of registered event descriptors.
    public let registered: [AnyEventDescriptor]
    
    /// Mapping from event name to descriptor for quick lookup.
    private let nameToDescriptor: [String: AnyEventDescriptor]
    
    public init(registered: [AnyEventDescriptor]) {
        self.registered = registered
        var mapping: [String: AnyEventDescriptor] = [:]
        for descriptor in registered {
            mapping[descriptor.eventName] = descriptor
        }
        self.nameToDescriptor = mapping
    }
    
    /// Register a server event type.
    ///
    /// - Parameter type: The server event payload type to register.
    /// - Returns: A new registry with the event added.
    public func register<EventType: ServerEventPayload>(_ type: EventType.Type) -> EventRegistry<E> {
        let eventName = Self.eventName(for: type)
        let descriptor = AnyEventDescriptor(
            type: type,
            eventName: eventName,
            direction: .server
        )
        var newRegistered = registered
        newRegistered.append(descriptor)
        return EventRegistry(registered: newRegistered)
    }
    
    /// Register a server event type from an erased type.
    ///
    /// This is a helper method for registering types that are already type-erased.
    /// The type must conform to ServerEventPayload.
    ///
    /// - Parameter type: The server event payload type to register (as Any.Type).
    /// - Returns: A new registry with the event added, or the same registry if the type doesn't conform to ServerEventPayload.
    public func registerErased(_ type: Any.Type) -> EventRegistry<E> {
        // Check if the type conforms to ServerEventPayload protocol
        // We can't directly check protocol conformance at runtime in a type-safe way,
        // so we'll create a descriptor and let the caller handle validation
        let eventName = Self.eventName(for: type)
        
        // Validate that @Payload macro was used
        // If getFieldMetadata() returns empty array, it means the default implementation was used (no @Payload)
        if let metadataProvider = type as? any SchemaMetadataProvider.Type {
            let metadata = metadataProvider.getFieldMetadata()
            if metadata.isEmpty {
                // Check if this is an empty struct (which is valid) or missing @Payload
                // For now, we'll only warn for non-empty structs
                // Empty structs are valid even without @Payload
                let mirror = Mirror(reflecting: type)
                if !mirror.children.isEmpty {
                    print("⚠️ Warning: Event type '\(eventName)' may be missing @Payload macro. getFieldMetadata() returned empty array.")
                }
            }
        }
        
        let descriptor = AnyEventDescriptor(
            type: type,
            eventName: eventName,
            direction: .server
        )
        var newRegistered = registered
        newRegistered.append(descriptor)
        return EventRegistry(registered: newRegistered)
    }
    
    /// Register a client event type.
    ///
    /// - Parameter type: The client event payload type to register.
    /// - Returns: A new registry with the event added.
    public func registerClientEvent<EventType: ClientEventPayload>(_ type: EventType.Type) -> EventRegistry<E> {
        let eventName = Self.eventName(for: type)
        let descriptor = AnyEventDescriptor(
            type: type,
            eventName: eventName,
            direction: .client
        )
        var newRegistered = registered
        newRegistered.append(descriptor)
        return EventRegistry(registered: newRegistered)
    }
    
    /// Register a client event type from an erased type.
    ///
    /// This is a helper method for registering types that are already type-erased.
    /// The type must conform to ClientEventPayload.
    ///
    /// - Parameter type: The client event payload type to register (as Any.Type).
    /// - Returns: A new registry with the event added.
    public func registerClientEventErased(_ type: Any.Type) -> EventRegistry<E> {
        let eventName = Self.eventName(for: type)
        
        // Validate that @Payload macro was used
        // If getFieldMetadata() returns empty array, it means the default implementation was used (no @Payload)
        if let metadataProvider = type as? any SchemaMetadataProvider.Type {
            let metadata = metadataProvider.getFieldMetadata()
            if metadata.isEmpty {
                // Check if this is an empty struct (which is valid) or missing @Payload
                // For now, we'll only warn for non-empty structs
                // Empty structs are valid even without @Payload
                let mirror = Mirror(reflecting: type)
                if !mirror.children.isEmpty {
                    print("⚠️ Warning: Event type '\(eventName)' may be missing @Payload macro. getFieldMetadata() returned empty array.")
                }
            }
        }
        
        let descriptor = AnyEventDescriptor(
            type: type,
            eventName: eventName,
            direction: .client
        )
        var newRegistered = registered
        newRegistered.append(descriptor)
        return EventRegistry(registered: newRegistered)
    }
    
    /// Get the event name for a given type.
    ///
    /// The event name is derived from the type name, removing the "Event" suffix
    /// to match schema generation and AnyServerEvent/AnyClientEvent naming.
    /// For example, "WelcomeEvent" -> "Welcome", "PlayerShootEvent" -> "PlayerShoot".
    ///
    /// - Parameter type: The event type.
    /// - Returns: The event name (without "Event" suffix if present).
    public static func eventName(for type: Any.Type) -> String {
        let typeName = String(describing: type)
        
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
        
        return eventID
    }
    
    /// Find a descriptor by event name.
    ///
    /// - Parameter eventName: The event name to look up.
    /// - Returns: The descriptor if found, nil otherwise.
    public func findDescriptor(for eventName: String) -> AnyEventDescriptor? {
        return nameToDescriptor[eventName]
    }
    
    /// Check if an event type is registered.
    ///
    /// - Parameter type: The event type to check.
    /// - Returns: True if the type is registered, false otherwise.
    public func isRegistered(_ type: Any.Type) -> Bool {
        let eventName = Self.eventName(for: type)
        return nameToDescriptor[eventName] != nil
    }
}

