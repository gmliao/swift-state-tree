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
    
    /// Attempt to extract the key type from a Dictionary type.
    ///
    /// Returns `nil` if the provided type is not a Dictionary.
    public static func dictionaryKeyType(from type: Any.Type) -> Any.Type? {
        func extract<T: DictionaryProtocol>(_ t: T.Type) -> Any.Type {
            T.Key.self
        }
        guard let dictType = type as? any DictionaryProtocol.Type else {
            return nil
        }
        return _openExistential(dictType, do: extract)
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
    
    /// Attempt to extract the element type from an Array type.
    ///
    /// Returns `nil` if the provided type is not an Array.
    public static func arrayElementType(from type: Any.Type) -> Any.Type? {
        func extract<T: ArrayProtocol>(_ t: T.Type) -> Any.Type {
            T.Element.self
        }
        guard let arrayType = type as? any ArrayProtocol.Type else {
            return nil
        }
        return _openExistential(arrayType, do: extract)
    }
}

// Helper protocols for type checking
public protocol DictionaryProtocol {
    associatedtype Key
    associatedtype Value
}
extension Dictionary: DictionaryProtocol {}

public protocol ArrayProtocol {
    associatedtype Element
}
extension Array: ArrayProtocol {}
