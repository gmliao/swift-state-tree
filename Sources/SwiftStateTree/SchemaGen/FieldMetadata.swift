import Foundation

/// Metadata for a field in a StateNode or Action/Event.
/// Used by the Schema Generator to extract schema information.
public struct FieldMetadata: Sendable {
    /// The name of the field.
    public let name: String
    
    /// The Swift type of the field.
    public let type: Any.Type
    
    /// The sync policy (if applicable).
    public let policy: PolicyType?
    
    /// The kind of node this field represents.
    public let nodeKind: NodeKind
    
    public init(name: String, type: Any.Type, policy: PolicyType? = nil, nodeKind: NodeKind) {
        self.name = name
        self.type = type
        self.policy = policy
        self.nodeKind = nodeKind
    }
}
