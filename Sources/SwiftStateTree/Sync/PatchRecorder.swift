// Sources/SwiftStateTree/Sync/PatchRecorder.swift

import Foundation

/// Protocol for accumulating state patches during mutations.
///
/// Implementations should be reference types to enable patch recording
/// across struct copies (Swift COW semantics).
public protocol PatchRecorder: AnyObject, Sendable {
    /// Record a single patch.
    func record(_ patch: StatePatch)
    
    /// Take all accumulated patches and clear the internal buffer.
    /// - Returns: All patches recorded since last take.
    func takePatches() -> [StatePatch]
    
    /// Check if there are any patches accumulated.
    var hasPatches: Bool { get }
}

/// Land-scoped patch recorder.
///
/// Thread-safety: Not required because all mutations happen synchronously
/// within the `LandKeeper` actor. Only one action handler executes at a time.
public final class LandPatchRecorder: PatchRecorder, @unchecked Sendable {
    private var patches: [StatePatch] = []
    
    public init() {}
    
    public func record(_ patch: StatePatch) {
        patches.append(patch)
    }
    
    public func takePatches() -> [StatePatch] {
        let result = patches
        patches.removeAll(keepingCapacity: true)
        return result
    }
    
    public var hasPatches: Bool {
        !patches.isEmpty
    }
}
