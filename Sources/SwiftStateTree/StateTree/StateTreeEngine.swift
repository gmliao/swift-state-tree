// Sources/SwiftStateTree/StateTree/StateTreeEngine.swift

/// The SwiftStateTree Engine that can be extended with your implementation
public struct StateTreeEngine<ID: Hashable & Sendable>: Sendable {
    public var root: StateNode<ID>

    public init(root: StateNode<ID>) {
        self.root = root
    }

    /// Placeholder evaluation function
    /// Override this to implement your state tree evaluation logic
    public func evaluate() -> StateNode<ID> {
        // TODO: Implement next frame state calculation here
        root
    }
}

