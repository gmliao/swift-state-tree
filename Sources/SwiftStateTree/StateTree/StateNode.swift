// Sources/SwiftStateTree/StateTree/StateNode.swift

/// A simple StateTree node type that can be extended to your desired architecture
public struct StateNode<ID: Hashable & Sendable>: Sendable {
    public let id: ID
    public var children: [StateNode]

    public init(id: ID, children: [StateNode] = []) {
        self.id = id
        self.children = children
    }
}

