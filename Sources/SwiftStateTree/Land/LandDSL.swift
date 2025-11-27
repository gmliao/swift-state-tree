import Foundation

// MARK: - Land Node Protocol

/// Protocol for all Land DSL nodes
///
/// All nodes in Land DSL must conform to this protocol.
public protocol LandNode: Sendable {}

// MARK: - Config Node

/// Configuration node for Land DSL
///
/// Contains land configuration settings such as max players, tick interval, and idle timeout.
public struct ConfigNode: LandNode {
    public let config: LandConfig

    public init(_ config: LandConfig) {
        self.config = config
    }
}

// MARK: - Action Handler Nodes

/// Action handler node for handling unified action types
///
/// Used to handle all actions of a specific type with a single handler.
public struct ActionHandlerNode<State: StateNodeProtocol, Act: ActionPayload>: LandNode {
    public let handler: @Sendable (inout State, Act, LandContext) async throws -> Act.Response

    public init(handler: @escaping @Sendable (inout State, Act, LandContext) async throws -> Act.Response) {
        self.handler = handler
    }
}

// MARK: - Event Handler Nodes

/// Event handler node for handling unified event types
///
/// Used to handle all events of a specific type with a single handler.
/// Currently mainly used for Client events.
public struct OnEventNode<State: StateNodeProtocol, Event: ClientEventPayload>: LandNode {
    public let handler: @Sendable (inout State, Event, LandContext) async -> Void

    public init(handler: @escaping @Sendable (inout State, Event, LandContext) async -> Void) {
        self.handler = handler
    }
}

// MARK: - Allowed Client Events Node

/// Node for specifying allowed client events
///
/// Used to restrict which client events are allowed in the land.
/// Only Client->Server events are restricted; Server events are not restricted.
public struct AllowedClientEventsNode: LandNode {
    /// Type information for allowed client event types
    public let allowedEventTypes: [Any.Type]

    public init(allowedEventTypes: [Any.Type]) {
        self.allowedEventTypes = allowedEventTypes
    }
}

// MARK: - Tick Handler Node

/// Tick handler node for periodic updates
///
/// Used to define logic that runs on each tick when tick interval is configured.
public struct OnTickNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (inout State, LandContext) async -> Void

    public init(handler: @escaping @Sendable (inout State, LandContext) async -> Void) {
        self.handler = handler
    }
}

// MARK: - Land DSL Builder

/// Result builder for Land DSL
///
/// Builds an array of LandNode components from DSL syntax.
@resultBuilder
public enum LandDSL {
    public static func buildBlock(_ components: LandNode...) -> [LandNode] {
        Array(components)
    }

    public static func buildArray(_ components: [[LandNode]]) -> [LandNode] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [LandNode]?) -> [LandNode] {
        component ?? []
    }

    public static func buildEither(first component: [LandNode]) -> [LandNode] {
        component
    }

    public static func buildEither(second component: [LandNode]) -> [LandNode] {
        component
    }
}

/// Extension to allow Config directly in DSL
extension LandDSL {
    /// Build block that accepts LandConfig and converts it to ConfigNode
    public static func buildBlock(_ config: LandConfig) -> ConfigNode {
        ConfigNode(config)
    }

    /// Build block that accepts multiple components including Config
    public static func buildBlock(_ config: LandConfig, _ components: LandNode...) -> [LandNode] {
        [ConfigNode(config)] + components
    }

    /// Build block that accepts Config and other components
    public static func buildBlock(_ component: LandNode, _ config: LandConfig, _ components: LandNode...) -> [LandNode] {
        [component, ConfigNode(config)] + components
    }
}

// MARK: - Land DSL Functions

/// Create a Land definition
///
/// This is the main function for defining a Land using DSL syntax.
///
/// Example:
/// ```swift
/// let matchLand = Land(
///     "match-3",
///     using: GameStateTree.self,
///     clientEvents: MyClientEvents.self,
///     serverEvents: MyServerEvents.self,
///     actions: GameAction.self
/// ) {
///     Config { ... }
///     Action(GameAction.self) { ... }
///     On(MyClientEvents.self) { ... }
/// }
/// ```
public func Land<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload,
    Action: ActionPayload
>(
    _ id: String,
    using stateType: State.Type,
    clientEvents: ClientE.Type,
    serverEvents: ServerE.Type,
    actions: Action.Type,
    @LandDSL _ content: () -> [LandNode]
) -> LandDefinition<State, ClientE, ServerE, Action> {
    LandDefinition(
        id: id,
        stateType: stateType,
        clientEventType: clientEvents,
        serverEventType: serverEvents,
        actionType: actions,
        nodes: content()
    )
}

// MARK: - Action DSL Functions

/// Create an action handler for a specific action type
///
/// Handles all actions of the specified type.
public func Action<State: StateNodeProtocol, Act: ActionPayload>(
    _ actionType: Act.Type,
    handler: @escaping @Sendable (inout State, Act, LandContext) async throws -> Act.Response
) -> ActionHandlerNode<State, Act> {
    ActionHandlerNode(handler: handler)
}

// MARK: - Event DSL Functions

/// Create an event handler for a specific event type
///
/// Handles all events of the specified type.
public func On<State: StateNodeProtocol, Event: ClientEventPayload>(
    _ eventType: Event.Type,
    handler: @escaping @Sendable (inout State, Event, LandContext) async -> Void
) -> OnEventNode<State, Event> {
    OnEventNode(handler: handler)
}

// MARK: - Tick DSL Functions

/// Create a tick handler
///
/// Defines logic that runs on each tick when tick interval is configured.
public func OnTick<State: StateNodeProtocol>(
    handler: @escaping @Sendable (inout State, LandContext) async -> Void
) -> OnTickNode<State> {
    OnTickNode(handler: handler)
}

// MARK: - Allowed Client Events DSL Function

/// Create an allowed client events node
///
/// Restricts which client events are allowed in the land.
@resultBuilder
public enum AllowedClientEventsBuilder {
    public static func buildBlock(_ types: Any.Type...) -> AllowedClientEventsNode {
        AllowedClientEventsNode(allowedEventTypes: types)
    }

    public static func buildExpression<T: ClientEventPayload>(_ type: T.Type) -> Any.Type {
        type
    }
}

public func AllowedClientEvents(@AllowedClientEventsBuilder _ content: () -> AllowedClientEventsNode) -> AllowedClientEventsNode {
    content()
}

// MARK: - Errors

/// Land DSL errors
internal enum LandDSLError: Error {
    case actionTypeMismatch
    case eventTypeMismatch
    case notImplemented
    case invalidNodeType
}
