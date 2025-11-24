// Sources/SwiftStateTree/Sync/StateUpdate.swift

import Foundation

/// Represents a state update, either no changes, first sync signal, or a set of patches.
///
/// The `firstSync` case is used to signal to the client that the sync engine has started
/// and will begin sending diff updates. This prevents race conditions between snapshot
/// initialization and diff updates.
///
/// The `firstSync` case includes patches to handle any changes that occurred between
/// join (snapshot) and the first diff generation. This ensures no changes are lost.
///
/// See [DESIGN_SYNC_FIRSTSYNC.md](../../../DESIGN_SYNC_FIRSTSYNC.md) for detailed design documentation.
public enum StateUpdate: Equatable, Sendable {
    /// No changes detected
    case noChange
    /// First sync signal - indicates sync engine has started and will begin sending diffs
    /// This is sent once per player when their cache is first populated.
    /// Includes patches to handle any changes between join and first diff generation.
    case firstSync([StatePatch])
    /// Changes represented as patches
    case diff([StatePatch])
}

