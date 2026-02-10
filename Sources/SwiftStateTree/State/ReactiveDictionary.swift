// Sources/SwiftStateTree/State/ReactiveDictionary.swift

/// A reactive dictionary that tracks changes and supports change notifications.
///
/// This dictionary maintains both:
/// - **Dirty tracking** (`_isDirty`, `_dirtyKeys`): Required even when incremental sync is on.
///   TransportAdapter uses `getDirtyFields()` for (1) safety check that all dirty broadcast
///   fields are covered by patches before using the incremental path, and (2) snapshot mode
///   (`.dirtyTracking`) when falling back to the diff path. Do not remove dirty tracking.
/// - **Patch recording** (when `_$patchRecorder` is set): Feeds incremental sync so the server
///   can send only changed keys instead of full diff.
///
/// When values are set, removed, or updated, the dictionary marks itself as dirty
/// and records a patch when a recorder is available.
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

    // MARK: - Patch Recording Context

    /// Path to this dictionary from root state.
    /// Injected by parent container or LandKeeper.
    ///
    /// Must be `public`: macro-generated `_$propagatePatchContext()` runs in the consumer module
    /// (e.g. GameDemo) and assigns to this on values cast as `any PatchableState`; cross-module
    /// access requires public API.
    public var _$parentPath: String = ""

    /// Shared patch recorder reference.
    /// Injected by parent container or LandKeeper.
    ///
    /// Must be `public`: same cross-module requirement as `_$parentPath` (see above).
    public var _$patchRecorder: PatchRecorder? = nil
    
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
    /// - Getting: Returns the value with injected path context if it's a `PatchableState`.
    /// - Setting: Marks the dictionary as dirty, records patch, and triggers onChange.
    public subscript(key: Key) -> Value? {
        get {
            guard let value = _storage[key] else { return nil }
            let path = makePath(for: key)

            // Inject path context for PatchableState values
            if var patchable = value as? any PatchableState {
                patchable._$parentPath = path
                patchable._$patchRecorder = _$patchRecorder
                if let castedValue = patchable as? Value {
                    return castedValue
                }
            }

            return value
        }
        set {
            _storage[key] = newValue
            _isDirty = true
            _dirtyKeys.insert(key)

            // Record patch if recorder is available
            if let recorder = _$patchRecorder {
                let path = makePath(for: key)

                if let newValue {
                    do {
                        let snapshotValue = try SnapshotValue.make(from: newValue)
                        recorder.record(StatePatch(path: path, operation: .set(snapshotValue)))
                    } catch {
                        let message = "ReactiveDictionary failed to convert value to SnapshotValue at path '\(path)'. Recording null fallback. Error: \(error)"
                        print("⚠️ Warning: \(message)")
                        recorder.record(StatePatch(path: path, operation: .set(.null)))
                    }
                } else {
                    recorder.record(StatePatch(path: path, operation: .delete))
                }
            }

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

        // Inject path context for PatchableState values
        if var patchable = value as? any PatchableState {
            let path = makePath(for: key)
            patchable._$parentPath = path
            patchable._$patchRecorder = _$patchRecorder
            if let castedValue = patchable as? Value {
                value = castedValue
            }
        }

        body(&value)
        _storage[key] = value
        _isDirty = true
        _dirtyKeys.insert(key)

        // Record patch so incremental sync sees this mutation (same as subscript setter)
        if let recorder = _$patchRecorder {
            let path = makePath(for: key)
            do {
                let snapshotValue = try SnapshotValue.make(from: value)
                recorder.record(StatePatch(path: path, operation: .set(snapshotValue)))
            } catch {
                let message = "ReactiveDictionary failed to convert value to SnapshotValue at path '\(path)'. Recording null fallback. Error: \(error)"
                print("⚠️ Warning: \(message)")
                recorder.record(StatePatch(path: path, operation: .set(.null)))
            }
        }

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

    private func makePath(for key: Key) -> String {
        "\(_$parentPath)/\(Self.escapeJsonPointerSegment(String(describing: key)))"
    }

    private static func escapeJsonPointerSegment(_ segment: String) -> String {
        segment
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }
}

// MARK: - PatchableState Conformance

extension ReactiveDictionary: PatchableState {}

// MARK: - SnapshotValueConvertible Conformance

extension ReactiveDictionary: SnapshotValueConvertible {
    public func toSnapshotValue() throws -> SnapshotValue {
        try SnapshotValue.make(from: _storage)
    }
}
