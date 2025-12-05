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
    
    /// Attempt to extract the value type from a Dictionary type.
    ///
    /// Returns `nil` if the provided type is not a Dictionary.
    public static func dictionaryValueType(from type: Any.Type) -> Any.Type? {
        func extract<T: DictionaryProtocol>(_ t: T.Type) -> Any.Type {
            T.Value.self
        }
        guard let dictType = type as? any DictionaryProtocol.Type else {
            return nil
        }
        return _openExistential(dictType, do: extract)
    }
}

// Helper protocols for type checking
public protocol DictionaryProtocol {
    associatedtype Key
    associatedtype Value
}
extension Dictionary: DictionaryProtocol {}

public protocol ArrayProtocol {}
extension Array: ArrayProtocol {}
