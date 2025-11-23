// Sources/SwiftStateTree/StateTree/StateTree.swift

import Foundation

/// Information about a sync field in a StateTree
public struct SyncFieldInfo: Sendable {
    /// The name of the field
    public let name: String
    
    /// The sync policy applied to this field
    public let policyType: String
    
    public init(name: String, policyType: String) {
        self.name = name
        self.policyType = policyType
    }
}

extension StateTreeProtocol {
    /// Get all fields marked with @Sync in this StateTree
    /// 
    /// Returns an array of `SyncFieldInfo` containing the name and policy type
    /// of each field marked with `@Sync`.
    ///
    /// Example:
    /// ```swift
    /// let fields = gameState.getSyncFields()
    /// // Returns: [SyncFieldInfo(name: "players", policyType: "broadcast"), ...]
    /// ```
    public func getSyncFields() -> [SyncFieldInfo] {
        let mirror = Mirror(reflecting: self)
        var fields: [SyncFieldInfo] = []
        
        for child in mirror.children {
            guard let label = child.label else { continue }
            
            // Check if the value is a Sync property wrapper
            // Sync property wrappers have a "policy" property
            if isSyncPropertyWrapper(child.value) {
                let normalizedLabel = label.hasPrefix("_") ? String(label.dropFirst()) : label
                
                // Determine policy type by checking the value
                let policyType = getPolicyType(from: child.value)
                fields.append(SyncFieldInfo(name: normalizedLabel, policyType: policyType))
            }
        }
        
        return fields
    }
    
    /// Validate that all stored properties have @Sync or @Internal markers
    /// 
    /// Returns `true` if all stored properties are marked with `@Sync` or `@Internal`,
    /// `false` otherwise. This is useful for ensuring StateTree consistency.
    ///
    /// Note: This validation is optional and may not catch all cases.
    /// It's recommended to use this as a development-time check.
    /// 
    /// Validation rules:
    /// - ✅ `@Sync` marked fields: require synchronization
    /// - ✅ `@Internal` marked fields: server-only use, skip validation
    /// - ✅ Computed properties: automatically skipped
    /// - ❌ Unmarked stored properties: validation fails
    public func validateSyncFields() -> Bool {
        let mirror = Mirror(reflecting: self)
        
        for child in mirror.children {
            guard let label = child.label else { continue }
            
            // Skip computed properties (they don't have labels starting with _)
            // Only check stored properties
            if !label.hasPrefix("_") {
                continue
            }
            
            // Check if it's a Sync or Internal property wrapper
            if !isSyncPropertyWrapper(child.value) && !isInternalPropertyWrapper(child.value) {
                // Found a stored property without @Sync or @Internal
                return false
            }
        }
        
        return true
    }
    
    /// Get the policy type string from a Sync property wrapper
    private func getPolicyType(from value: Any) -> String {
        // Use reflection to determine the policy type
        let mirror = Mirror(reflecting: value)
        
        // Try to find the policy property in the Sync wrapper
        for child in mirror.children {
            if child.label == "policy" {
                let policyValue = child.value
                let policyMirror = Mirror(reflecting: policyValue)
                
                // Try to get the enum case name
                if let caseName = policyMirror.children.first?.label {
                    return caseName
                }
                
                // Fallback: describe the type
                return String(describing: type(of: policyValue))
            }
        }
        
        return "unknown"
    }
}

    /// Check if a value is a Sync property wrapper
    /// Sync property wrappers have a "policy" property of type SyncPolicy
    private func isSyncPropertyWrapper(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        
        // Check if it has a "policy" property (Sync property wrappers have this)
        for child in mirror.children {
            if child.label == "policy" {
                // Check if the policy type matches SyncPolicy
                let policyType = String(describing: type(of: child.value))
                if policyType.contains("SyncPolicy") {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Check if a value is an Internal property wrapper
    /// Internal property wrappers are simple wrappers without a "policy" property
    private func isInternalPropertyWrapper(_ value: Any) -> Bool {
        let typeName = String(describing: type(of: value))
        // Internal property wrappers are named "Internal<...>"
        return typeName.contains("Internal<")
    }

