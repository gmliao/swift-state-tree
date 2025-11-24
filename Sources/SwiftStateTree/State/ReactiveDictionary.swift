// Sources/SwiftStateTree/State/ReactiveDictionary.swift

/// A reactive dictionary that tracks changes and supports change notifications.
///
/// This dictionary maintains dirty state tracking for efficient synchronization.
/// When values are set, removed, or updated, the dictionary marks itself as dirty
/// and tracks which keys have been modified.
///
/// Example:
/// ```swift
/// var dict = ReactiveDictionary<String, Int>(onChange: { print("Changed!") })
/// dict["key"] = 42  // Triggers onChange callback
/// print(dict.isDirty)  // true
/// dict.clearDirty()
/// print(dict.isDirty)  // false
/// ```
public struct ReactiveDictionary<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    // MARK: - Storage
    
    /// Internal storage for the dictionary
    private var _storage: [Key: Value]
    
    /// Flag indicating if the dictionary has been modified
    private var _isDirty: Bool = false
    
    /// Set of keys that have been modified
    private var _dirtyKeys: Set<Key> = []
    
    /// Optional callback invoked when the dictionary changes
    private var onChange: (@Sendable () -> Void)?
    
    // MARK: - Initialization
    
    /// Creates a new reactive dictionary.
    ///
    /// - Parameters:
    ///   - dictionary: Initial dictionary contents (default: empty)
    ///   - onChange: Optional callback invoked when the dictionary changes
    public init(_ dictionary: [Key: Value] = [:], onChange: (@Sendable () -> Void)? = nil) {
        self._storage = dictionary
        self.onChange = onChange
    }
    
    // MARK: - Subscript Access
    
    /// Accesses the value associated with the given key for reading and writing.
    ///
    /// Setting a value marks the dictionary as dirty and adds the key to dirtyKeys.
    /// Getting a value does not affect dirty state.
    public subscript(key: Key) -> Value? {
        get {
            _storage[key]
        }
        set {
            _storage[key] = newValue
            // Simplified: mark as dirty on any set, without == comparison
            _isDirty = true
            _dirtyKeys.insert(key)
            onChange?()
        }
    }
    
    // MARK: - Dictionary Operations
    
    /// Removes the given key and its associated value from the dictionary.
    ///
    /// - Parameter key: The key to remove
    /// - Returns: The value that was removed, or `nil` if the key was not present
    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        let value = _storage.removeValue(forKey: key)
        if value != nil {
            _isDirty = true
            _dirtyKeys.insert(key)
            onChange?()
        }
        return value
    }
    
    /// Updates the value stored in the dictionary for the given key.
    ///
    /// - Parameters:
    ///   - value: The new value to store
    ///   - key: The key to update
    /// - Returns: The value that was replaced, or `nil` if the key was not present
    @discardableResult
    public mutating func updateValue(_ value: Value, forKey key: Key) -> Value? {
        let oldValue = _storage.updateValue(value, forKey: key)
        _isDirty = true
        _dirtyKeys.insert(key)
        onChange?()
        return oldValue
    }
    
    /// Safely mutates a value for the given key.
    ///
    /// If the key exists, the closure is called with an inout reference to the value.
    /// If the key does not exist, this method does nothing.
    ///
    /// - Parameters:
    ///   - key: The key to mutate
    ///   - body: Closure that mutates the value
    public mutating func mutateValue(for key: Key, _ body: (inout Value) -> Void) {
        guard var value = _storage[key] else { return }
        body(&value)
        _storage[key] = value
        _isDirty = true
        _dirtyKeys.insert(key)
        onChange?()
    }
    
    // MARK: - Collection Properties
    
    /// A collection containing just the keys of the dictionary
    public var keys: Dictionary<Key, Value>.Keys {
        _storage.keys
    }
    
    /// A collection containing just the values of the dictionary
    public var values: Dictionary<Key, Value>.Values {
        _storage.values
    }
    
    /// The number of key-value pairs in the dictionary
    public var count: Int {
        _storage.count
    }
    
    /// A Boolean value indicating whether the dictionary is empty
    public var isEmpty: Bool {
        _storage.isEmpty
    }
    
    // MARK: - Dirty State
    
    /// A Boolean value indicating whether the dictionary has been modified
    public var isDirty: Bool {
        _isDirty
    }
    
    /// A set of keys that have been modified
    public var dirtyKeys: Set<Key> {
        _dirtyKeys
    }
    
    /// Clears the dirty state and removes all tracked dirty keys.
    ///
    /// This should typically be called after synchronization is complete.
    public mutating func clearDirty() {
        _isDirty = false
        _dirtyKeys.removeAll()
    }
    
    // MARK: - Conversion
    
    /// Returns a standard dictionary representation of the reactive dictionary
    ///
    /// - Returns: A dictionary containing all key-value pairs
    public func toDictionary() -> [Key: Value] {
        _storage
    }
}

