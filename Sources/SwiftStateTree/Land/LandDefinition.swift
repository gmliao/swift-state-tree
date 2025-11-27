import Foundation

// MARK: - Land Definition

/// Land definition structure
///
/// Contains the land ID, state type, and all configured nodes.
/// Now generic over ClientEvent, ServerEvent, and Action.
public struct LandDefinition<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload,
    Action: ActionPayload
>: Sendable {
    /// Land identifier
    public let id: String

    /// State type for this land
    public let stateType: State.Type

    /// Client event type
    public let clientEventType: ClientE.Type

    /// Server event type
    public let serverEventType: ServerE.Type

    /// Action type
    public let actionType: Action.Type

    /// All configured nodes
    public let nodes: [LandNode]

    /// Configuration extracted from nodes
    public var config: LandConfig {
        for node in nodes {
            if let configNode = node as? ConfigNode {
                return configNode.config
            }
        }
        return LandConfig()
    }

    public init(
        id: String,
        stateType: State.Type,
        clientEventType: ClientE.Type,
        serverEventType: ServerE.Type,
        actionType: Action.Type,
        nodes: [LandNode]
    ) {
        self.id = id
        self.stateType = stateType
        self.clientEventType = clientEventType
        self.serverEventType = serverEventType
        self.actionType = actionType
        self.nodes = nodes
    }
}
