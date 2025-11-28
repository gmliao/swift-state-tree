import Foundation

public struct SchemaHelper {
    public static func determineNodeKind(from type: Any.Type) -> NodeKind {
        // Check for Dictionary
        if type is any DictionaryProtocol.Type {
            return .map
        }
        
        // Check for Array
        if type is any ArrayProtocol.Type {
            return .array
        }
        
        // Check for StateNodeProtocol
        if type is any StateNodeProtocol.Type {
            return .object
        }
        
        // Default to leaf (primitive/Codable)
        return .leaf
    }
}

// Helper protocols for type checking
public protocol DictionaryProtocol {}
extension Dictionary: DictionaryProtocol {}

public protocol ArrayProtocol {}
extension Array: ArrayProtocol {}
