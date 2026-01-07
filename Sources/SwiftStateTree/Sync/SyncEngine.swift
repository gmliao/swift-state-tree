// Sources/SwiftStateTree/Sync/SyncEngine.swift

import Foundation

/// Snapshot generation mode for controlling which fields are included in the snapshot.
public enum SnapshotMode: Sendable {
    /// Include all fields (default, for late join scenarios).
    case all
    
    /// Include only specified fields (for optimization).
    case include(Set<String>)
    
    /// Include only dirty fields (for dirty tracking optimization).
    case dirtyTracking(Set<String>)
    
    /// Get the field set for internal use
    internal var fields: Set<String>? {
        switch self {
        case .all:
            return nil
        case .include(let fields), .dirtyTracking(let fields):
            return fields
        }
    }
}

/// SyncEngine filters StateNode according to SyncPolicy and outputs StateSnapshot.
///
/// Manages cache for efficient diff computation:
/// - Broadcast cache: Shared across all players
/// - Per-player cache: Individual cache per player
///
/// See [DESIGN_RUNTIME.md](../../../DESIGN_RUNTIME.md) for detailed documentation.
public struct SyncEngine: Sendable {
    /// Cache for broadcast snapshot (shared across all players)
    private var lastBroadcastSnapshot: StateSnapshot?
    
    /// Cache for per-player snapshots (individual cache per player)
    private var lastPerPlayerSnapshots: [PlayerID: StateSnapshot] = [:]
    
    /// Track which players have received firstSync signal
    /// This is separate from cache population to handle lateJoin scenarios:
    /// - lateJoinSnapshot populates cache but doesn't mark as firstSync received
    /// - First generateDiff after lateJoin will return firstSync signal
    private var hasReceivedFirstSync: Set<PlayerID> = []
    
    public init() {}

    /// Generate a full snapshot for a specific player or broadcast fields only.
    ///
    /// Used for late join scenarios. For incremental updates, use `generateDiff(for:from:useDirtyTracking:)`.
    /// **Note:** Does not populate cache. Use `lateJoinSnapshot(for:from:)` to also populate cache.
    ///
    /// - Parameters:
    ///   - playerID: Player ID. If `nil`, only broadcast fields are included.
    ///   - state: The StateNode instance.
    ///   - mode: Snapshot generation mode. Default is `.all`.
    /// - Returns: A `StateSnapshot` containing filtered fields based on sync policies.
    /// - Throws: `SyncError` if value conversion fails.
    public func snapshot<State: StateNodeProtocol>(
        for playerID: PlayerID? = nil,
        from state: State,
        mode: SnapshotMode = .all
    ) throws -> StateSnapshot {
        return try state.snapshot(for: playerID, dirtyFields: mode.fields)
    }
    
    /// Generate a full snapshot and merge into an existing container.
    ///
    /// Allows reusing a `StateSnapshot` container to avoid repeated allocations.
    ///
    /// - Parameters:
    ///   - playerID: Player ID. If `nil`, only broadcast fields are included.
    ///   - state: The StateNode instance.
    ///   - into: Container to reuse. Values will be merged (overwriting existing values).
    ///   - mode: Snapshot generation mode. Default is `.all`.
    /// - Returns: The same container with merged values.
    /// - Throws: `SyncError` if value conversion fails.
    public func snapshot<State: StateNodeProtocol>(
        for playerID: PlayerID?,
        from state: State,
        into container: inout StateSnapshot,
        mode: SnapshotMode = .all
    ) throws -> StateSnapshot {
        let newSnapshot = try state.snapshot(for: playerID, dirtyFields: mode.fields)
        container.merge(newSnapshot, overwrite: true)
        return container
    }
    
    // MARK: - Snapshot Extraction
    
    /// Extract broadcast fields snapshot (shared across all players).
    ///
    /// **Important:** Extract once and reuse for all players to reduce serialization overhead.
    ///
    /// - Parameters:
    ///   - state: The StateNode instance.
    ///   - mode: Snapshot generation mode. Default is `.all`.
    /// - Returns: A `StateSnapshot` containing only broadcast fields.
    /// - Throws: `SyncError` if value conversion fails.
    public func extractBroadcastSnapshot<State: StateNodeProtocol>(
        from state: State,
        mode: SnapshotMode = .all
    ) throws -> StateSnapshot {
        return try state.broadcastSnapshot(dirtyFields: mode.fields)
    }
    
    /// Extract per-player fields snapshot (differs per player).
    ///
    /// Must be called separately for each player. Excludes broadcast and serverOnly fields.
    ///
    /// - Parameters:
    ///   - playerID: The player ID.
    ///   - state: The StateNode instance.
    ///   - mode: Snapshot generation mode. Default is `.all`.
    /// - Returns: A `StateSnapshot` containing only per-player fields for the specified player.
    /// - Throws: `SyncError` if value conversion fails.
    public func extractPerPlayerSnapshot<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State,
        mode: SnapshotMode = .all
    ) throws -> StateSnapshot {
        // Generate full snapshot for the player (with mode if provided)
        let fullSnapshot = try state.snapshot(for: playerID, dirtyFields: mode.fields)
        
        // Get sync field definitions to identify per-player fields
        let syncFields = state.getSyncFields()
        let perPlayerFieldNames = Set(
            syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }
                .map { $0.name }
        )
        
        // Filter to only include per-player fields
        var perPlayerValues: [String: SnapshotValue] = [:]
        for (key, value) in fullSnapshot.values where perPlayerFieldNames.contains(key) {
            perPlayerValues[key] = value
        }
        
        return StateSnapshot(values: perPlayerValues)
    }
    
    // MARK: - Snapshot Comparison
    
    /// Compare two snapshots and generate patches.
    private func compareSnapshots(
        from oldSnapshot: StateSnapshot,
        to newSnapshot: StateSnapshot,
        onlyPaths: Set<String>? = nil
    ) -> [StatePatch] {
        compareSnapshots(
            from: oldSnapshot,
            to: newSnapshot,
            onlyPaths: onlyPaths,
            dirtyFields: nil
        )
    }
    
    /// Compare two snapshots and generate patches (with dirty tracking support).
    ///
    /// When `dirtyFields` is provided, only dirty fields are compared.
    private func compareSnapshots(
        from oldSnapshot: StateSnapshot,
        to newSnapshot: StateSnapshot,
        onlyPaths: Set<String>? = nil,
        dirtyFields: Set<String>?
    ) -> [StatePatch] {
        var patches: [StatePatch] = []
        // Get all keys from both snapshots to detect additions, deletions, and changes
        let allKeys = Set(oldSnapshot.values.keys).union(Set(newSnapshot.values.keys))
        
        for key in allKeys {
            let path = "/\(key)"
            
            // Filter by onlyPaths if specified
            if let onlyPaths = onlyPaths, !onlyPaths.contains(path) && !anyPathMatches(path, in: onlyPaths) {
                continue
            }
            
            let oldValue = oldSnapshot.values[key]
            let newValue = newSnapshot.values[key]
            
            if let oldValue = oldValue, let newValue = newValue {
                // Both exist - compare recursively
                // If dirtyFields is provided, only compare if this field is dirty
                if let dirtyFields = dirtyFields {
                    if dirtyFields.contains(key) {
                        patches.append(contentsOf: compareSnapshotValues(
                            from: oldValue,
                            to: newValue,
                            basePath: path,
                            onlyPaths: onlyPaths
                        ))
                    }
                    // If not dirty, skip comparison (assume unchanged)
                } else {
                    // No dirty tracking - compare all fields
                    patches.append(contentsOf: compareSnapshotValues(
                        from: oldValue,
                        to: newValue,
                        basePath: path,
                        onlyPaths: onlyPaths
                    ))
                }
            } else if oldValue != nil && newValue == nil {
                // Deleted: field exists in old but not in new
                // If dirtyFields is provided, only consider it a delete if the field is dirty
                if let dirtyFields = dirtyFields {
                    if dirtyFields.contains(key) {
                        patches.append(StatePatch(path: path, operation: .delete))
                    }
                    // If not dirty, skip (assume unchanged, not deleted)
                } else {
                    // No dirty tracking - treat as delete
                    patches.append(StatePatch(path: path, operation: .delete))
                }
            } else if oldValue == nil, let newValue = newValue {
                // Added: field exists in new but not in old
                // If dirtyFields is provided, only add if field is dirty
                if let dirtyFields = dirtyFields {
                    if dirtyFields.contains(key) {
                        patches.append(StatePatch(path: path, operation: .set(newValue)))
                    }
                    // If not dirty, skip (shouldn't happen, but safe to skip)
                } else {
                    // No dirty tracking - treat as add
                    patches.append(StatePatch(path: path, operation: .set(newValue)))
                }
            }
        }
        
        return patches
    }
    
    /// Recursively compare two SnapshotValues and generate patches.
    ///
    /// Arrays are treated as atomic values (whole array replacement).
    private func compareSnapshotValues(
        from oldValue: SnapshotValue,
        to newValue: SnapshotValue,
        basePath: String,
        onlyPaths: Set<String>? = nil
    ) -> [StatePatch] {
        var patches: [StatePatch] = []
        
        // If values are equal, no change
        if oldValue == newValue {
            return patches
        }
        
        // Handle different types or changed values
        switch (oldValue, newValue) {
        case (.object(let oldObj), .object(let newObj)):
            // Check if this is an atomic type (DeterministicMath types)
            // Atomic types should be updated as a whole unit, not field-by-field
            if isAtomicType(oldObj, newObj) {
                // Treat as atomic: update the whole object
                if oldObj != newObj {
                    patches.append(StatePatch(path: basePath, operation: .set(newValue)))
                }
                return patches
            }
            
            // Compare objects recursively - check all keys from both objects
            let allKeys = Set(oldObj.keys).union(Set(newObj.keys))
            
            for key in allKeys {
                let path = "\(basePath)/\(escapeJsonPointer(key))"
                
                // Filter by onlyPaths if specified
                if let onlyPaths = onlyPaths, !anyPathMatches(path, in: onlyPaths) {
                    continue
                }
                
                let oldVal = oldObj[key]
                let newVal = newObj[key]
                
                if let oldVal = oldVal, let newVal = newVal {
                    // Both exist - recurse to compare nested values
                    patches.append(contentsOf: compareSnapshotValues(
                        from: oldVal,
                        to: newVal,
                        basePath: path,
                        onlyPaths: onlyPaths
                    ))
                } else if oldVal != nil && newVal == nil {
                    // Deleted
                    patches.append(StatePatch(path: path, operation: .delete))
                } else if oldVal == nil, let newVal = newVal {
                    // Added
                    patches.append(StatePatch(path: path, operation: .set(newVal)))
                }
            }
            
        case (.array(let oldArr), .array(let newArr)):
            // For arrays, treat as a whole value change for simplicity
            // More sophisticated diffing (e.g., element-by-element) can be added later
            if oldArr != newArr {
                patches.append(StatePatch(path: basePath, operation: .set(newValue)))
            }
            
        default:
            // Different types or primitive value changed
            patches.append(StatePatch(path: basePath, operation: .set(newValue)))
        }
        
        return patches
    }
    
    /// Escape a key for JSON Pointer format (RFC 6901).
    private func escapeJsonPointer(_ key: String) -> String {
        return key.replacingOccurrences(of: "~", with: "~0")
                  .replacingOccurrences(of: "/", with: "~1")
    }
    
    /// Check if a path matches any path in the onlyPaths set (including prefix matches).
    private func anyPathMatches(_ path: String, in onlyPaths: Set<String>) -> Bool {
        for allowedPath in onlyPaths {
            if path == allowedPath || path.hasPrefix(allowedPath + "/") {
                return true
            }
        }
        return false
    }
    
    /// Check if an object represents an atomic DeterministicMath type.
    /// Atomic types should be updated as a whole unit, not field-by-field.
    private func isAtomicType(_ oldObj: [String: SnapshotValue], _ newObj: [String: SnapshotValue]) -> Bool {
        let allKeys = Set(oldObj.keys).union(Set(newObj.keys))
        
        // IVec2: { x: Int, y: Int }
        if allKeys == ["x", "y"] {
            if case .int = oldObj["x"], case .int = oldObj["y"],
               case .int = newObj["x"], case .int = newObj["y"] {
                return true
            }
        }
        
        // IVec3: { x: Int, y: Int, z: Int }
        if allKeys == ["x", "y", "z"] {
            if case .int = oldObj["x"], case .int = oldObj["y"], case .int = oldObj["z"],
               case .int = newObj["x"], case .int = newObj["y"], case .int = newObj["z"] {
                return true
            }
        }
        
        // Angle: { degrees: Int }
        if allKeys == ["degrees"] {
            if case .int = oldObj["degrees"], case .int = newObj["degrees"] {
                return true
            }
        }
        
        // Position2/Velocity2/Acceleration2: { v: { x: Int, y: Int } }
        if allKeys == ["v"] {
            if case .object(let oldV) = oldObj["v"],
               case .object(let newV) = newObj["v"] {
                let vKeys = Set(oldV.keys).union(Set(newV.keys))
                if vKeys == ["x", "y"] {
                    if case .int = oldV["x"], case .int = oldV["y"],
                       case .int = newV["x"], case .int = newV["y"] {
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    // MARK: - Diff Computation
    
    /// Compute broadcast diff (shared across all players).
    ///
    /// Returns empty array on first call (cache population).
    private mutating func computeBroadcastDiff<State: StateNodeProtocol>(
        from state: State,
        onlyPaths: Set<String>?,
        mode: SnapshotMode = .all
    ) throws -> [StatePatch] {
        // Check if we have cached broadcast snapshot
        guard let lastBroadcast = lastBroadcastSnapshot else {
            // First time: always seed cache with a full snapshot to avoid missing fields when using dirty tracking
            // We extract full snapshot directly instead of extracting partial snapshot first to avoid redundant work
            lastBroadcastSnapshot = try extractBroadcastSnapshot(from: state, mode: .all)
            return []
        }
        
        // Generate current broadcast snapshot (using specified mode)
        let currentBroadcast = try extractBroadcastSnapshot(from: state, mode: mode)
        
        // Compare and generate patches (with mode if provided)
        let patches = compareSnapshots(
            from: lastBroadcast,
            to: currentBroadcast,
            onlyPaths: onlyPaths,
            dirtyFields: mode.fields
        )
        
        // Update cache by merging dirty fields into existing cache
        // This avoids generating a full snapshot when using dirty tracking
        if case .dirtyTracking(let dirtyFields) = mode, !dirtyFields.isEmpty, var cachedSnapshot = lastBroadcastSnapshot {
            // Merge only dirty fields into cached snapshot (more efficient than regenerating full snapshot)
            for (key, value) in currentBroadcast.values {
                cachedSnapshot.values[key] = value
            }
            lastBroadcastSnapshot = cachedSnapshot
        } else {
            // No dirty tracking or no cache, update cache with current snapshot
            lastBroadcastSnapshot = currentBroadcast
        }
        
        return patches
    }
    
    /// Compute per-player diff (individual for each player).
    ///
    /// Returns empty array on first call (cache population).
    private mutating func computePerPlayerDiff<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State,
        onlyPaths: Set<String>?,
        mode: SnapshotMode = .all
    ) throws -> [StatePatch] {
        // If only broadcast fields are dirty, we can skip per-player diff when cache exists
        if case .dirtyTracking(let dirtyFields) = mode, dirtyFields.isEmpty, lastPerPlayerSnapshots[playerID] != nil {
            return []
        }
        
        // Check if we have cached per-player snapshot
        guard let lastPerPlayer = lastPerPlayerSnapshots[playerID] else {
            // First time: always seed cache with a full snapshot to avoid missing fields when using dirty tracking
            // We extract full snapshot directly instead of extracting partial snapshot first to avoid redundant work
            lastPerPlayerSnapshots[playerID] = try extractPerPlayerSnapshot(for: playerID, from: state, mode: .all)
            return []
        }
        
        // Generate current per-player snapshot (using specified mode)
        let currentPerPlayer = try extractPerPlayerSnapshot(for: playerID, from: state, mode: mode)
        
        // Compare and generate patches (with mode if provided)
        let patches = compareSnapshots(
            from: lastPerPlayer,
            to: currentPerPlayer,
            onlyPaths: onlyPaths,
            dirtyFields: mode.fields
        )
        
        // Update cache by merging dirty fields into existing cache
        // This avoids generating a full snapshot when using dirty tracking
        if case .dirtyTracking(let dirtyFields) = mode, !dirtyFields.isEmpty, var cachedSnapshot = lastPerPlayerSnapshots[playerID] {
            // Merge only dirty fields into cached snapshot (more efficient than regenerating full snapshot)
            for (key, value) in currentPerPlayer.values {
                cachedSnapshot.values[key] = value
            }
            lastPerPlayerSnapshots[playerID] = cachedSnapshot
        } else {
            // No dirty tracking or no cache, update cache with current snapshot
            lastPerPlayerSnapshots[playerID] = currentPerPlayer
        }
        
        return patches
    }
    
    /// Merge broadcast and per-player patches (per-player takes precedence).
    package func mergePatches(
        _ broadcast: [StatePatch],
        _ perPlayer: [StatePatch]
    ) -> [StatePatch] {
        var merged: [StatePatch] = []
        var seenPaths: Set<String> = []
        
        // Add broadcast patches first
        for patch in broadcast {
            if !seenPaths.contains(patch.path) {
                merged.append(patch)
                seenPaths.insert(patch.path)
            }
        }
        
        // Add per-player patches (may override broadcast)
        for patch in perPlayer {
            if !seenPaths.contains(patch.path) {
                merged.append(patch)
                seenPaths.insert(patch.path)
            } else {
                // Per-player takes precedence - replace existing patch
                if let index = merged.firstIndex(where: { $0.path == patch.path }) {
                    merged[index] = patch
                }
            }
        }
        
        return merged
    }
    
    // MARK: - Diff Computation with Pre-extracted Snapshots
    
    /// Compute broadcast diff using pre-extracted snapshot.
    ///
    /// This method is useful when you've already extracted a broadcast snapshot
    /// and want to compute the diff without re-extracting. The snapshot should
    /// be extracted using `extractBroadcastSnapshot(from:mode:)` with the same mode.
    ///
    /// - Parameters:
    ///   - currentBroadcast: Pre-extracted broadcast snapshot.
    ///   - onlyPaths: Optional set of paths to limit diff calculation (JSON Pointer format).
    ///   - mode: Snapshot generation mode. Should match the mode used to extract the snapshot.
    /// - Returns: Array of patches representing the changes.
    public mutating func computeBroadcastDiffFromSnapshot(
        currentBroadcast: StateSnapshot,
        onlyPaths: Set<String>? = nil,
        mode: SnapshotMode = .all
    ) -> [StatePatch] {
        // Check if we have cached broadcast snapshot
        guard let lastBroadcast = lastBroadcastSnapshot else {
            // First time: seed cache with the provided snapshot
            // If mode is dirtyTracking, we still need full snapshot for cache
            // But since we're using pre-extracted snapshot, we use what we have
            lastBroadcastSnapshot = currentBroadcast
            return []
        }
        
        // Compare and generate patches
        let patches = compareSnapshots(
            from: lastBroadcast,
            to: currentBroadcast,
            onlyPaths: onlyPaths,
            dirtyFields: mode.fields
        )
        
        // Update cache by merging dirty fields into existing cache
        if case .dirtyTracking(let dirtyFields) = mode, !dirtyFields.isEmpty, var cachedSnapshot = lastBroadcastSnapshot {
            // Merge only dirty fields into cached snapshot
            for (key, value) in currentBroadcast.values {
                cachedSnapshot.values[key] = value
            }
            lastBroadcastSnapshot = cachedSnapshot
        } else {
            // No dirty tracking or no cache, update cache with current snapshot
            lastBroadcastSnapshot = currentBroadcast
        }
        
        return patches
    }
    
    /// Compute per-player diff using pre-extracted snapshot.
    private mutating func computePerPlayerDiffFromSnapshot(
        for playerID: PlayerID,
        currentPerPlayer: StateSnapshot,
        onlyPaths: Set<String>?,
        mode: SnapshotMode = .all
    ) -> [StatePatch] {
        // If only broadcast fields are dirty, we can skip per-player diff when cache exists
        if case .dirtyTracking(let dirtyFields) = mode, dirtyFields.isEmpty, lastPerPlayerSnapshots[playerID] != nil {
            return []
        }
        
        // Check if we have cached per-player snapshot
        guard let lastPerPlayer = lastPerPlayerSnapshots[playerID] else {
            // First time: seed cache with the provided snapshot
            lastPerPlayerSnapshots[playerID] = currentPerPlayer
            return []
        }
        
        // Compare and generate patches
        let patches = compareSnapshots(
            from: lastPerPlayer,
            to: currentPerPlayer,
            onlyPaths: onlyPaths,
            dirtyFields: mode.fields
        )
        
        // Update cache by merging dirty fields into existing cache
        if case .dirtyTracking(let dirtyFields) = mode, !dirtyFields.isEmpty, var cachedSnapshot = lastPerPlayerSnapshots[playerID] {
            // Merge only dirty fields into cached snapshot
            for (key, value) in currentPerPlayer.values {
                cachedSnapshot.values[key] = value
            }
            lastPerPlayerSnapshots[playerID] = cachedSnapshot
        } else {
            // No dirty tracking or no cache, update cache with current snapshot
            lastPerPlayerSnapshots[playerID] = currentPerPlayer
        }
        
        return patches
    }
    
    // MARK: - Main Diff Generation
    
    /// Generate a diff update using pre-extracted snapshots with automatic dirty tracking.
    ///
    /// Allows locking state, extracting snapshots, unlocking, then computing diff.
    /// Ensures broadcast and per-player diffs use the same state version.
    ///
    /// **Automatic Dirty Tracking**: If `state.isDirty()` is `true`,
    /// automatically splits dirty fields into broadcast and per-player modes for optimization.
    /// This matches the behavior of `generateDiff(for:from:useDirtyTracking:)`.
    ///
    /// - Parameters:
    ///   - playerID: The player ID.
    ///   - broadcastSnapshot: Pre-extracted broadcast snapshot (shared across all players).
    ///   - perPlayerSnapshot: Pre-extracted per-player snapshot (specific to this player).
    ///   - onlyPaths: Optional set of paths to limit diff calculation (JSON Pointer format).
    ///   - state: State for automatic dirty tracking. If dirty, automatically
    ///            splits dirty fields into broadcast and per-player modes.
    /// - Returns: `.firstSync([StatePatch])` on first call, `.diff([StatePatch])` with changes, or `.noChange`.
    /// - Throws: `SyncError` if value conversion fails.
    public mutating func generateDiffFromSnapshots<State: StateNodeProtocol>(
        for playerID: PlayerID,
        broadcastSnapshot: StateSnapshot,
        perPlayerSnapshot: StateSnapshot,
        onlyPaths: Set<String>? = nil,
        state: State
    ) throws -> StateUpdate {
        // Check if this is the first sync for this player
        // This is separate from cache check to handle lateJoin scenarios
        let isFirstSyncForPlayer = !hasReceivedFirstSync.contains(playerID)
        
        // Automatically handle dirty tracking
        let broadcastMode: SnapshotMode
        let perPlayerMode: SnapshotMode
        
        if state.isDirty() {
            // Automatically use dirty tracking mode (same logic as generateDiff)
            let dirtyFields = state.getDirtyFields()
            let syncFields = state.getSyncFields()
            let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
            let perPlayerFieldNames = Set(syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }.map { $0.name })
            
            let broadcastFields = dirtyFields.intersection(broadcastFieldNames)
            let perPlayerFields = dirtyFields.intersection(perPlayerFieldNames)
            
            broadcastMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
            perPlayerMode = perPlayerFields.isEmpty ? .all : .dirtyTracking(perPlayerFields)
        } else {
            // No state provided or state is not dirty, use .all
            broadcastMode = .all
            perPlayerMode = .all
        }
        
        // Compute broadcast diff using pre-extracted snapshot
        let broadcastDiff = computeBroadcastDiffFromSnapshot(
            currentBroadcast: broadcastSnapshot,
            onlyPaths: onlyPaths,
            mode: broadcastMode
        )
        
        // Compute per-player diff using pre-extracted snapshot
        let perPlayerDiff = computePerPlayerDiffFromSnapshot(
            for: playerID,
            currentPerPlayer: perPlayerSnapshot,
            onlyPaths: onlyPaths,
            mode: perPlayerMode
        )
        
        // Merge patches (per-player takes precedence)
        let mergedPatches = mergePatches(broadcastDiff, perPlayerDiff)
        
        // Now that cache is populated, we can safely return firstSync signal
        if isFirstSyncForPlayer {
            hasReceivedFirstSync.insert(playerID)  // Mark as received
            return .firstSync(mergedPatches)
        }
        
        // Return result
        if mergedPatches.isEmpty {
            return .noChange
        } else {
            return .diff(mergedPatches)
        }
    }

    /// Generate a player update using a precomputed broadcast diff.
    ///
    /// This is useful when broadcasting the same broadcast diff to multiple players in a single sync cycle.
    /// It avoids re-computing (and re-applying) broadcast cache updates per player, while still computing
    /// per-player diffs and maintaining firstSync semantics per player.
    ///
    /// - Parameters:
    ///   - playerID: The player ID.
    ///   - broadcastDiff: Precomputed broadcast patches (same for all players).
    ///   - perPlayerSnapshot: Pre-extracted per-player snapshot for this player.
    ///   - perPlayerMode: Snapshot mode used to extract perPlayerSnapshot (for dirty tracking).
    ///   - onlyPaths: Optional set of paths to limit diff calculation (JSON Pointer format).
    /// - Returns: `.firstSync([StatePatch])` on first call, `.diff([StatePatch])` with changes, or `.noChange`.
    package mutating func generateUpdateFromBroadcastDiff(
        for playerID: PlayerID,
        broadcastDiff: [StatePatch],
        perPlayerSnapshot: StateSnapshot,
        perPlayerMode: SnapshotMode = .all,
        onlyPaths: Set<String>? = nil
    ) -> StateUpdate {
        let isFirstSyncForPlayer = !hasReceivedFirstSync.contains(playerID)
        
        let perPlayerDiff = computePerPlayerDiffFromSnapshot(
            for: playerID,
            currentPerPlayer: perPlayerSnapshot,
            onlyPaths: onlyPaths,
            mode: perPlayerMode
        )
        
        let mergedPatches = mergePatches(broadcastDiff, perPlayerDiff)
        
        if isFirstSyncForPlayer {
            hasReceivedFirstSync.insert(playerID)
            return .firstSync(mergedPatches)
        }
        
        if mergedPatches.isEmpty {
            return .noChange
        } else {
            return .diff(mergedPatches)
        }
    }
    
    /// Generate a diff update for a specific player.
    ///
    /// Computes differences between current state and cached snapshot, generating path-based patches.
    /// Automatically splits broadcast (shared) and per-player (individual) diffs for efficiency.
    ///
    /// **Return Values:**
    /// - `.firstSync([StatePatch])` - First call (cache populated)
    /// - `.diff([StatePatch])` - Changes detected
    /// - `.noChange` - No changes
    ///
    /// When `useDirtyTracking` is `true`, only dirty fields are compared. Missing fields are only
    /// considered deletes if marked as dirty.
    ///
    /// See [DESIGN_SYNC_FIRSTSYNC.md](../../../DESIGN_SYNC_FIRSTSYNC.md) for detailed documentation.
    ///
    /// - Parameters:
    ///   - playerID: The player ID.
    ///   - state: The current StateNode instance.
    ///   - onlyPaths: Optional set of paths to limit diff calculation (JSON Pointer format).
    ///   - useDirtyTracking: If `true`, only compare dirty fields. Default is `true`.
    /// - Returns: `.firstSync([StatePatch])`, `.diff([StatePatch])`, or `.noChange`.
    /// - Throws: `SyncError` if value conversion fails.
    public mutating func generateDiff<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State,
        onlyPaths: Set<String>? = nil,
        useDirtyTracking: Bool = true
    ) throws -> StateUpdate {
        // Check if this is the first sync for this player
        // This is separate from cache check to handle lateJoin scenarios
        let isFirstSyncForPlayer = !hasReceivedFirstSync.contains(playerID)
        
        // Get snapshot mode based on dirty tracking
        let snapshotMode: SnapshotMode
        if useDirtyTracking && state.isDirty() {
            let dirtyFields = state.getDirtyFields()
            snapshotMode = .dirtyTracking(dirtyFields)
        } else {
            snapshotMode = .all
        }
        
        // Split dirty fields by policy type for optimization
        let syncFields = state.getSyncFields()
        let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
        let perPlayerFieldNames = Set(syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }.map { $0.name })
        
        // Create mode-specific filters for broadcast and per-player
        let broadcastMode: SnapshotMode
        let perPlayerMode: SnapshotMode
        if case .dirtyTracking(let fields) = snapshotMode {
            let broadcastFields = fields.intersection(broadcastFieldNames)
            let perPlayerFields = fields.intersection(perPlayerFieldNames)
            broadcastMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
            perPlayerMode = perPlayerFields.isEmpty ? .all : .dirtyTracking(perPlayerFields)
        } else {
            broadcastMode = .all
            perPlayerMode = .all
        }
        
        // IMPORTANT: We must compute diffs BEFORE returning firstSync because:
        // 1. computeBroadcastDiff and computePerPlayerDiff populate the cache
        // 2. If we return early, cache won't be populated, causing infinite firstSync returns
        // 3. The cache needs to be set up so subsequent calls can generate proper diffs
        
        // Compute broadcast diff (shared across all players)
        // This will populate lastBroadcastSnapshot if it's the first time
        let broadcastDiff = try computeBroadcastDiff(
            from: state,
            onlyPaths: onlyPaths?.filter {
                if let fieldName = $0.split(separator: "/", omittingEmptySubsequences: true).first {
                    return broadcastFieldNames.contains(String(fieldName))
                }
                return false
            },
            mode: broadcastMode
        )
        
        // Compute per-player diff (individual for each player)
        // This will populate lastPerPlayerSnapshots[playerID] if it's the first time
        let perPlayerDiff = try computePerPlayerDiff(
            for: playerID,
            from: state,
            onlyPaths: onlyPaths?.filter {
                if let fieldName = $0.split(separator: "/", omittingEmptySubsequences: true).first {
                    return perPlayerFieldNames.contains(String(fieldName))
                }
                return false
            },
            mode: perPlayerMode
        )
        
        // Merge patches (per-player takes precedence)
        let mergedPatches = mergePatches(broadcastDiff, perPlayerDiff)
        
        // Now that cache is populated, we can safely return firstSync signal
        // Include patches to handle any changes between join and first diff generation
        if isFirstSyncForPlayer {
            hasReceivedFirstSync.insert(playerID)  // Mark as received
            return .firstSync(mergedPatches)
        }
        
        // Return result
        if mergedPatches.isEmpty {
            return .noChange
        } else {
            return .diff(mergedPatches)
        }
    }
    
    // MARK: - Cache Management
    
    /// Warm up broadcast cache with initial state snapshot.
    ///
    /// Call after initial state is fully set up to reduce first player latency.
    /// **Important:** Only warms broadcast cache. Per-player caches are populated automatically on first `generateDiff`.
    ///
    /// - Parameter state: The initial StateNode instance (should be fully initialized).
    /// - Throws: `SyncError` if value conversion fails.
    public mutating func warmupCache<State: StateNodeProtocol>(
        from state: State
    ) throws {
        // Warm up broadcast cache if not already populated
        // Broadcast cache is shared across all players, so it can be pre-warmed at startup
        if lastBroadcastSnapshot == nil {
            lastBroadcastSnapshot = try extractBroadcastSnapshot(from: state, mode: .all)
        }
        // Note: Per-player caches are populated automatically when players first call generateDiff
    }
    
    /// Clear cache for a disconnected player.
    ///
    /// Next `generateDiff` call for this player will return `.firstSync([StatePatch])`.
    /// **Important:** Only call when player has disconnected.
    ///
    /// - Parameter playerID: The player ID whose cache should be cleared.
    public mutating func clearCacheForDisconnectedPlayer(_ playerID: PlayerID) {
        lastPerPlayerSnapshots.removeValue(forKey: playerID)
        hasReceivedFirstSync.remove(playerID)  // Also clear firstSync flag
    }
    
    /// Mark that a player has received initial sync (e.g., via lateJoinSnapshot).
    ///
    /// This prevents the next `generateDiff` call from returning `.firstSync` when there are no changes.
    /// **Important:** Only call after sending initial snapshot to the player.
    ///
    /// - Parameter playerID: The player ID that has received initial sync.
    public mutating func markFirstSyncReceived(for playerID: PlayerID) {
        hasReceivedFirstSync.insert(playerID)
    }
    
    // MARK: - Cache Population Helper
    
    /// Populate cache for a player if not already populated.
    private mutating func populateCacheIfNeeded<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State
    ) throws {
        if lastBroadcastSnapshot == nil {
            lastBroadcastSnapshot = try extractBroadcastSnapshot(from: state, mode: .all)
        }
        
        if lastPerPlayerSnapshots[playerID] == nil {
            lastPerPlayerSnapshots[playerID] = try extractPerPlayerSnapshot(for: playerID, from: state, mode: .all)
        }
    }
    
    // MARK: - Late Join
    
    /// Generate a full snapshot for late join scenarios.
    ///
    /// Populates cache so subsequent `generateDiff` calls can detect changes.
    /// **Difference from `snapshot(for:from:)`:** This also populates cache.
    ///
    /// - Parameters:
    ///   - playerID: The player ID.
    ///   - state: The StateNode instance.
    /// - Returns: A complete `StateSnapshot` containing all visible fields.
    /// - Throws: `SyncError` if value conversion fails.
    public mutating func lateJoinSnapshot<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State
    ) throws -> StateSnapshot {
        let snapshot = try snapshot(for: playerID, from: state)
        try populateCacheIfNeeded(for: playerID, from: state)
        return snapshot
    }
    
    /// Generate a full snapshot for late join and merge into an existing container.
    ///
    /// Allows reusing a `StateSnapshot` container to avoid repeated allocations.
    /// Also populates cache, similar to `lateJoinSnapshot(for:from:)`.
    ///
    /// - Parameters:
    ///   - playerID: The player ID.
    ///   - state: The StateNode instance.
    ///   - into: Container to reuse. Values will be merged (overwriting existing values).
    /// - Returns: The same container with merged values.
    /// - Throws: `SyncError` if value conversion fails.
    public mutating func lateJoinSnapshot<State: StateNodeProtocol>(
        for playerID: PlayerID,
        from state: State,
        into container: inout StateSnapshot
    ) throws -> StateSnapshot {
        let newSnapshot = try state.snapshot(for: playerID, dirtyFields: nil)
        container.merge(newSnapshot, overwrite: true)
        try populateCacheIfNeeded(for: playerID, from: state)
        return container
    }
}

// MARK: - Benchmark/Testing Extensions

extension SyncEngine {
    /// Mirror-based implementation of extractBroadcastSnapshot (for benchmarking comparison).
    ///
    /// Uses runtime reflection (Mirror). The default `extractBroadcastSnapshot` uses macro-generated
    /// code which is much faster. **Only use for performance comparison, not in production code.**
    ///
    /// - Parameter state: The StateNode instance.
    /// - Returns: A `StateSnapshot` containing only broadcast fields.
    public func extractBroadcastSnapshotMirrorVersion<State: StateNodeProtocol>(
        from state: State
    ) throws -> StateSnapshot {
        // Get all sync fields and filter for broadcast policy
        let syncFields = state.getSyncFields()
        let broadcastFields = syncFields.filter { $0.policyType == .broadcast }
        
        // Use reflection to access broadcast field values directly from StateNode
        // For property wrappers, we need to extract wrappedValue
        let mirror = Mirror(reflecting: state)
        var broadcastValues: [String: SnapshotValue] = [:]
        
        for field in broadcastFields {
            // Property wrapper fields may be stored with underscore prefix (_fieldName)
            // or as the field name directly, depending on macro implementation
            let possibleLabels = [field.name, "_\(field.name)"]
            
            for label in possibleLabels {
                if let child = mirror.children.first(where: { $0.label == label }) {
                    var value = child.value
                    
                    // Extract wrappedValue from property wrapper if needed
                    // Sync<T> wraps the actual value, we need to unwrap it
                    let valueMirror = Mirror(reflecting: value)
                    let valueTypeName = String(describing: type(of: value))
                    
                    // Check if this is a Sync property wrapper
                    // Sync struct has: policy (SyncPolicy<Value>) and _wrappedValue (Value)
                    // We must find _wrappedValue, not policy
                    if valueTypeName.contains("Sync<") || valueTypeName.hasPrefix("Sync<") {
                        // This is a Sync property wrapper - find _wrappedValue explicitly
                        if let wrappedChild = valueMirror.children.first(where: { $0.label == "_wrappedValue" }) {
                            value = wrappedChild.value
                        } else {
                            // If _wrappedValue not found, this is an error
                            throw SyncError.unsupportedValue(
                                "Failed to extract _wrappedValue from Sync property wrapper. " +
                                "Type: \(valueTypeName), available children: \(valueMirror.children.map { $0.label ?? "nil" })"
                            )
                        }
                    } else if let wrappedChild = valueMirror.children.first(where: { $0.label == "wrappedValue" }) {
                        // Fallback: try wrappedValue (for other property wrappers)
                        value = wrappedChild.value
                    } else if valueTypeName.contains("SyncPolicy") {
                        // Error: we got the policy instead of the value
                        throw SyncError.unsupportedValue(
                            "Unexpectedly got SyncPolicy instead of wrappedValue from property wrapper. " +
                            "This indicates a bug in property wrapper extraction. Type: \(valueTypeName)"
                        )
                    }
                    // If none of the above, value is already the unwrapped value (not a property wrapper)
                    
                    // Convert value to SnapshotValue
                    // For broadcast fields, we directly use the raw value without player filtering
                    let snapshotValue = try SnapshotValue.make(from: value)
                    broadcastValues[field.name] = snapshotValue
                    break // Found and processed, move to next field
                }
            }
        }
        
        return StateSnapshot(values: broadcastValues)
    }
}
