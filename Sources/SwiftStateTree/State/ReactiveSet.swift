// Sources/SwiftStateTree/State/ReactiveSet.swift

/// A reactive set that tracks changes and supports change notifications.
///
/// This set maintains dirty state tracking for efficient synchronization.
/// It tracks which elements have been inserted or removed, allowing for
/// efficient diff computation.
///
/// Example:
/// ```swift
/// var set = ReactiveSet<String>(onChange: { print("Changed!") })
/// set.insert("element")  // Triggers onChange callback
/// print(set.isDirty)  // true
/// print(set.insertedElements)  // ["element"]
/// set.clearDirty()
/// ```
public struct ReactiveSet<Element: Hashable & Sendable>: @unchecked Sendable {
    // MARK: - Storage
    
    /// Internal storage for the set
    private var _storage: Set<Element>
    
    /// Flag indicating if the set has been modified
    private var _isDirty: Bool = false
    
    /// Set of elements that have been inserted
    private var _inserted: Set<Element> = []
    
    /// Set of elements that have been removed
    private var _removed: Set<Element> = []
    
    /// Optional callback invoked when the set changes
    private var onChange: (@Sendable () -> Void)?
    
    // MARK: - Initialization
    
    /// Creates a new reactive set.
    ///
    /// - Parameters:
    ///   - set: Initial set contents (default: empty)
    ///   - onChange: Optional callback invoked when the set changes
    public init(
        _ set: Set<Element> = [],
        onChange: (@Sendable () -> Void)? = nil
    ) {
        self._storage = set
        self.onChange = onChange
    }
    
    // MARK: - Basic Access
    
    /// The underlying set value
    public var rawValue: Set<Element> {
        _storage
    }
    
    /// The number of elements in the set
    public var count: Int {
        _storage.count
    }
    
    /// A Boolean value indicating whether the set is empty
    public var isEmpty: Bool {
        _storage.isEmpty
    }
    
    /// Returns a Boolean value indicating whether the set contains the given element
    ///
    /// - Parameter member: An element to look for in the set
    /// - Returns: `true` if the set contains `member`; otherwise, `false`
    public func contains(_ member: Element) -> Bool {
        _storage.contains(member)
    }
    
    /// Returns all elements in the set
    public var allElements: Set<Element> {
        _storage
    }
    
    // MARK: - Dirty State Query
    
    /// A Boolean value indicating whether the set has been modified
    public var isDirty: Bool {
        _isDirty
    }
    
    /// Elements that have been inserted in this round
    public var insertedElements: Set<Element> {
        _inserted
    }
    
    /// Elements that have been removed in this round
    public var removedElements: Set<Element> {
        _removed
    }
    
    /// Elements that have changed (inserted ∪ removed)
    public var dirtyElements: Set<Element> {
        _inserted.union(_removed)
    }
    
    /// Clears the dirty state and removes all tracked changes.
    ///
    /// This should typically be called after synchronization is complete.
    public mutating func clearDirty() {
        _isDirty = false
        _inserted.removeAll()
        _removed.removeAll()
    }
    
    // MARK: - Mutation Operations
    
    /// Inserts the given element into the set.
    ///
    /// - Parameter newMember: The element to insert
    /// - Returns: A tuple `(inserted: Bool, memberAfterInsert: Element)` where
    ///   `inserted` indicates whether the element was newly inserted, and
    ///   `memberAfterInsert` is the element that was actually inserted
    @discardableResult
    public mutating func insert(_ newMember: Element) -> (inserted: Bool, memberAfterInsert: Element) {
        let (inserted, member) = _storage.insert(newMember)
        guard inserted else {
            // Element already exists, not considered dirty
            return (false, member)
        }
        
        // Element was actually inserted
        _isDirty = true
        _inserted.insert(newMember)
        // If this element was previously marked for removal, remove it from removed set
        _removed.remove(newMember)
        onChange?()
        
        return (true, member)
    }
    
    /// Removes the given element from the set.
    ///
    /// - Parameter member: The element to remove
    /// - Returns: The element that was removed, or `nil` if the element was not present
    @discardableResult
    public mutating func remove(_ member: Element) -> Element? {
        guard let removed = _storage.remove(member) else {
            // Element was not present, not considered dirty
            return nil
        }
        
        _isDirty = true
        _removed.insert(member)
        // If this element was just inserted in this round, remove it from inserted set
        _inserted.remove(member)
        onChange?()
        
        return removed
    }
    
    /// Updates the set with the given element.
    ///
    /// For sets, this is equivalent to insert, but we treat it as insert/overwrite.
    ///
    /// - Parameter newMember: The element to insert or update
    /// - Returns: The element that was replaced, or `nil` if the element was not present
    @discardableResult
    public mutating func update(with newMember: Element) -> Element? {
        let old = _storage.update(with: newMember)
        
        // Whether it's a new insertion or an update, mark as dirty
        _isDirty = true
        _inserted.insert(newMember)
        if let old = old {
            _removed.remove(old)
        }
        onChange?()
        
        return old
    }
    
    // MARK: - Batch Operations
    
    /// Forms the union of the set and the given set.
    ///
    /// - Parameter other: The set to form a union with
    public mutating func formUnion(_ other: Set<Element>) {
        guard !other.isEmpty else { return }
        
        for e in other {
            _ = insert(e) // Use insert logic to naturally update dirty state
        }
    }
    
    /// Removes the elements of the given set from this set.
    ///
    /// - Parameter other: The set of elements to remove
    public mutating func subtract(_ other: Set<Element>) {
        guard !other.isEmpty else { return }
        
        for e in other {
            _ = remove(e) // Use remove logic to naturally update dirty state
        }
    }
}

