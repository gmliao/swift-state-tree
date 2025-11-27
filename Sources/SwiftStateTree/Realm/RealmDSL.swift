// Sources/SwiftStateTree/Realm/RealmDSL.swift

import Foundation

// MARK: - Realm Node Protocol

/// Protocol for all Realm DSL nodes
/// 
/// All nodes in Realm DSL must conform to this protocol.
public protocol RealmNode: Sendable {}

// MARK: - Config Node

/// Configuration node for Realm DSL
/// 
/// Contains realm configuration settings such as max players, tick interval, and idle timeout.
public struct ConfigNode: RealmNode {
    public let config: RealmConfig
    
    public init(_ config: RealmConfig) {
        self.config = config
    }
}

// MARK: - Action Handler Nodes

/// Action handler node for handling unified action types
/// 
/// Used to handle all actions of a specific type with a single handler.
/// 
/// Example:
/// ```swift
/// Action(GameAction.self) { state, action, ctx -> ActionResult in
///     switch action {
///     case .join(let id, let name):
///         // handle join
///     case .attack(let attacker, let target, let damage):
///         // handle attack
///     }
/// }
/// ```
public struct ActionHandlerNode<State: StateNodeProtocol, Action: Codable & Sendable>: RealmNode {
    public let handler: @Sendable (inout State, Action, RealmContext) async -> ActionResult
    
    public init(handler: @escaping @Sendable (inout State, Action, RealmContext) async -> ActionResult) {
        self.handler = handler
    }
}

/// Type-erased action handler node for runtime use
/// 
/// Note: This is an internal type used for runtime type erasure.
/// The actual handler execution will be done at the RealmActor level with proper type information.
internal struct AnyActionHandlerNode: RealmNode {
    let actionType: Any.Type
    
    init<State: StateNodeProtocol, Action: Codable & Sendable>(
        _ node: ActionHandlerNode<State, Action>
    ) {
        self.actionType = Action.self
        // Note: The actual handler is stored in the typed node
        // Runtime will cast and call the handler with proper type information
    }
}

/// Specific action case handler node
/// 
/// Used to handle a specific action case with a dedicated handler.
/// This requires using a KeyPath or similar mechanism to extract the case.
/// 
/// Note: Due to Swift's limitations with enum case extraction, this node
/// will need to be implemented at the RealmActor level with proper type information.
public struct SpecificActionHandlerNode<State: StateNodeProtocol, ActionCase>: RealmNode {
    public let handler: @Sendable (inout State, ActionCase, RealmContext) async -> ActionResult
    public let actionType: Any.Type
    
    public init<Action: Codable & Sendable>(
        actionType: Action.Type,
        handler: @escaping @Sendable (inout State, ActionCase, RealmContext) async -> ActionResult
    ) {
        self.handler = handler
        self.actionType = actionType
    }
}

// MARK: - Event Handler Nodes

/// Event handler node for handling unified event types
/// 
/// Used to handle all events of a specific type with a single handler.
/// 
/// Example:
/// ```swift
/// On(GameEvent.self) { state, event, ctx in
///     switch event {
///     case .fromClient(let clientEvent):
///         // handle client event
///     case .fromServer(let serverEvent):
///         // handle server event
///     }
/// }
/// ```
public struct OnEventNode<State: StateNodeProtocol, Event: Sendable>: RealmNode {
    public let handler: @Sendable (inout State, Event, RealmContext) async -> Void
    
    public init(handler: @escaping @Sendable (inout State, Event, RealmContext) async -> Void) {
        self.handler = handler
    }
}

/// Specific event case handler node
/// 
/// Used to handle a specific event case with a dedicated handler.
/// 
/// Note: Similar to SpecificActionHandlerNode, this requires proper type handling
/// at the RealmActor level.
public struct OnSpecificEventNode<State: StateNodeProtocol, EventCase>: RealmNode {
    public let handler: @Sendable (inout State, EventCase, RealmContext) async -> Void
    public let eventType: Any.Type
    
    public init<Event: Sendable>(
        eventType: Event.Type,
        handler: @escaping @Sendable (inout State, EventCase, RealmContext) async -> Void
    ) {
        self.handler = handler
        self.eventType = eventType
    }
}

// MARK: - Allowed Client Events Node

/// Node for specifying allowed client events
/// 
/// Used to restrict which client events are allowed in the realm.
/// Only Client->Server events are restricted; Server events are not restricted.
/// 
/// Example:
/// ```swift
/// AllowedClientEvents {
///     MyClientEvent.playerReady
///     MyClientEvent.heartbeat
/// }
/// ```
public struct AllowedClientEventsNode: RealmNode {
    /// Type information for allowed client event types
    /// 
    /// Note: Due to Swift's protocol limitations, we store type information
    /// and check at runtime in the RealmActor.
    public let allowedEventTypes: [Any.Type]
    
    public init(allowedEventTypes: [Any.Type]) {
        self.allowedEventTypes = allowedEventTypes
    }
}

// MARK: - Tick Handler Node

/// Tick handler node for periodic updates
/// 
/// Used to define logic that runs on each tick when tick interval is configured.
/// 
/// Example:
/// ```swift
/// OnTick { state, ctx in
///     await handleTick(&state, ctx)
/// }
/// ```
public struct OnTickNode<State: StateNodeProtocol>: RealmNode {
    public let handler: @Sendable (inout State, RealmContext) async -> Void
    
    public init(handler: @escaping @Sendable (inout State, RealmContext) async -> Void) {
        self.handler = handler
    }
}

// MARK: - Realm DSL Builder

/// Result builder for Realm DSL
/// 
/// Builds an array of RealmNode components from DSL syntax.
@resultBuilder
public enum RealmDSL {
    public static func buildBlock(_ components: RealmNode...) -> [RealmNode] {
        Array(components)
    }
    
    public static func buildArray(_ components: [[RealmNode]]) -> [RealmNode] {
        components.flatMap { $0 }
    }
    
    public static func buildOptional(_ component: [RealmNode]?) -> [RealmNode] {
        component ?? []
    }
    
    public static func buildEither(first component: [RealmNode]) -> [RealmNode] {
        component
    }
    
    public static func buildEither(second component: [RealmNode]) -> [RealmNode] {
        component
    }
}

/// Extension to allow Config directly in DSL
extension RealmDSL {
    /// Build block that accepts RealmConfig and converts it to ConfigNode
    public static func buildBlock(_ config: RealmConfig) -> ConfigNode {
        ConfigNode(config)
    }
    
    /// Build block that accepts multiple components including Config
    public static func buildBlock(_ config: RealmConfig, _ components: RealmNode...) -> [RealmNode] {
        [ConfigNode(config)] + components
    }
    
    /// Build block that accepts Config and other components
    public static func buildBlock(_ component: RealmNode, _ config: RealmConfig, _ components: RealmNode...) -> [RealmNode] {
        [component, ConfigNode(config)] + components
    }
}

// MARK: - Realm Definition

/// Realm definition structure
/// 
/// Contains the realm ID, state type, and all configured nodes.
public struct RealmDefinition<State: StateNodeProtocol>: Sendable {
    /// Realm identifier
    public let id: String
    
    /// State type for this realm
    public let stateType: State.Type
    
    /// All configured nodes
    public let nodes: [RealmNode]
    
    /// Configuration extracted from nodes
    public var config: RealmConfig {
        for node in nodes {
            if let configNode = node as? ConfigNode {
                return configNode.config
            }
        }
        return RealmConfig()
    }
    
    internal init(id: String, stateType: State.Type, nodes: [RealmNode]) {
        self.id = id
        self.stateType = stateType
        self.nodes = nodes
    }
}

// MARK: - Realm DSL Functions

/// Create a Realm definition
/// 
/// This is the main function for defining a Realm using DSL syntax.
/// 
/// Example:
/// ```swift
/// let matchRealm = Realm("match-3", using: GameStateTree.self) {
///     Config {
///         MaxPlayers(4)
///         Tick(every: .milliseconds(100))
///     }
///     
///     Action(GameAction.self) { state, action, ctx -> ActionResult in
///         // handle action
///     }
///     
///     On(ClientEvent.heartbeat) { state, timestamp, ctx in
///         // handle heartbeat
///     }
/// }
/// ```
/// 
/// - Parameters:
///   - id: Realm identifier
///   - stateType: State type for this realm (must conform to StateNodeProtocol)
///   - content: DSL content block
/// - Returns: RealmDefinition instance
public func Realm<State: StateNodeProtocol>(
    _ id: String,
    using stateType: State.Type,
    @RealmDSL _ content: () -> [RealmNode]
) -> RealmDefinition<State> {
    RealmDefinition(id: id, stateType: stateType, nodes: content())
}

// MARK: - Semantic Aliases

// Note: Semantic aliases are defined after the Realm function to avoid forward reference issues

// MARK: - Action DSL Functions

/// Create an action handler for a specific action type
/// 
/// Handles all actions of the specified type.
/// 
/// Example:
/// ```swift
/// Action(GameAction.self) { state, action, ctx -> ActionResult in
///     switch action {
///     case .join(let id, let name):
///         return await handleJoin(&state, id, name, ctx)
///     case .attack(let attacker, let target, let damage):
///         return await handleAttack(&state, attacker, target, damage, ctx)
///     }
/// }
/// ```
public func Action<State: StateNodeProtocol, Action: Codable & Sendable>(
    _ actionType: Action.Type,
    handler: @escaping @Sendable (inout State, Action, RealmContext) async -> ActionResult
) -> ActionHandlerNode<State, Action> {
    ActionHandlerNode(handler: handler)
}

// MARK: - Event DSL Functions

/// Create an event handler for a specific event type
/// 
/// Handles all events of the specified type.
/// 
/// Example:
/// ```swift
/// On(GameEvent.self) { state, event, ctx in
///     switch event {
///     case .fromClient(let clientEvent):
///         // handle client event
///     case .fromServer(let serverEvent):
///         // handle server event
///     }
/// }
/// ```
public func On<State: StateNodeProtocol, Event: Sendable>(
    _ eventType: Event.Type,
    handler: @escaping @Sendable (inout State, Event, RealmContext) async -> Void
) -> OnEventNode<State, Event> {
    OnEventNode(handler: handler)
}

// MARK: - Tick DSL Functions

/// Create a tick handler
/// 
/// Defines logic that runs on each tick when tick interval is configured.
/// 
/// Example:
/// ```swift
/// OnTick { state, ctx in
///     await handleTick(&state, ctx)
/// }
/// ```
public func OnTick<State: StateNodeProtocol>(
    handler: @escaping @Sendable (inout State, RealmContext) async -> Void
) -> OnTickNode<State> {
    OnTickNode(handler: handler)
}

// MARK: - Allowed Client Events DSL Function

/// Create an allowed client events node
/// 
/// Restricts which client events are allowed in the realm.
/// 
/// Example:
/// ```swift
/// AllowedClientEvents {
///     MyClientEvent.self
/// }
/// ```
/// 
/// Note: This is a simplified version. Full implementation will require
/// proper type checking at runtime in RealmActor.
/// Users should pass concrete event types, not protocol types.
@resultBuilder
public enum AllowedClientEventsBuilder {
    public static func buildBlock(_ types: Any.Type...) -> AllowedClientEventsNode {
        AllowedClientEventsNode(allowedEventTypes: types)
    }
    
    public static func buildExpression<T: ClientEvent>(_ type: T.Type) -> Any.Type {
        type
    }
}

public func AllowedClientEvents(@AllowedClientEventsBuilder _ content: () -> AllowedClientEventsNode) -> AllowedClientEventsNode {
    content()
}

// MARK: - Semantic Aliases

/// Semantic alias for Realm (App scenario)
/// 
/// `App` is a function alias for `Realm`, suitable for App scenarios.
/// 
/// Example:
/// ```swift
/// let app = App("my-app", using: AppState.self) {
///     Config { ... }
/// }
/// ```
public func App<State: StateNodeProtocol>(
    _ id: String,
    using stateType: State.Type,
    @RealmDSL _ content: () -> [RealmNode]
) -> RealmDefinition<State> {
    Realm(id, using: stateType, content)
}

/// Semantic alias for Realm (Feature scenario)
/// 
/// `Feature` is a function alias for `Realm`, suitable for feature module scenarios.
/// 
/// Example:
/// ```swift
/// let feature = Feature("my-feature", using: FeatureState.self) {
///     Config { ... }
/// }
/// ```
public func Feature<State: StateNodeProtocol>(
    _ id: String,
    using stateType: State.Type,
    @RealmDSL _ content: () -> [RealmNode]
) -> RealmDefinition<State> {
    Realm(id, using: stateType, content)
}

// MARK: - Errors

/// Realm DSL errors
internal enum RealmDSLError: Error {
    case actionTypeMismatch
    case eventTypeMismatch
    case notImplemented
    case invalidNodeType
}

