import Foundation
import SwiftStateTree

/// The pure parts of planning a sync phase (#554 X2): functions of their arguments only, so code
/// outside the adapter's actor can call them as is. The adapter reads its own state (the dirty
/// tracking switches, the carried dirty fields) and passes the result in.
enum SyncPlanning {
    /// `patches` (a view's, from empty) with the patches at or below each root path of `rows`
    /// replaced by that root's row patches, where the first of them was. A root `patches` doesn't
    /// hold stays out.
    static func replacingRows(of patches: [StatePatch], with rows: [String: [StatePatch]]) -> [StatePatch] {
        guard !rows.isEmpty else { return patches }
        func root(of path: String) -> String {
            let utf8 = path.utf8
            guard utf8.count > 1, let end = utf8.dropFirst().firstIndex(of: UInt8(ascii: "/")) else { return path }
            return String(path[..<end])
        }
        var result: [StatePatch] = []
        result.reserveCapacity(patches.count)
        var placed: Set<String> = []
        for patch in patches {
            let path = root(of: patch.path)
            guard let replacement = rows[path] else {
                result.append(patch)
                continue
            }
            if placed.insert(path).inserted {
                result.append(contentsOf: replacement)
            }
        }
        return result
    }

    /// A key scope reset's update: always sent, typed `.firstSync` so the encoder and the client
    /// reset the scope's dynamic key table; its patches are the diff against the cache.
    static func keyScopeResetUpdate(_ update: StateUpdate) -> StateUpdate {
        switch update {
        case .noChange:
            return .firstSync([])
        case .diff(let patches), .firstSync(let patches):
            return .firstSync(patches)
        }
    }

    /// Under the `.empty` baseline (full-snapshot strategy), `patches` without those of the
    /// fields the extraction dropped in their scope (`dropped`). A dropped field holds its cached
    /// value, which keeps the `.empty` diff from deleting it but would otherwise be a real `.set`
    /// of an older value (a client that already has a newer one, e.g. a joiner's firstSync, would
    /// roll back). Against the `.cached` baseline the cached value yields no patch, so nothing is
    /// filtered.
    static func withoutDroppedFields(
        _ patches: [StatePatch],
        dropped: Set<String>,
        baseline: SyncEngine.DiffBaseline
    ) -> [StatePatch] {
        guard case .empty = baseline, !dropped.isEmpty else { return patches }
        return patches.filter { patch in
            let field = patch.path.split(separator: "/").first.map(String.init) ?? ""
            return !dropped.contains(field)
        }
    }

    /// The extraction modes for the broadcast and the per-player snapshots. `dirtyFields` is the
    /// plan's dirty fields when dirty tracking applies, nil otherwise (then both are `.all`).
    static func computeSyncModes<State: StateNodeProtocol>(
        for state: State,
        dirtyFields: Set<String>?
    ) -> (broadcastMode: SnapshotMode, perPlayerMode: SnapshotMode) {
        guard let dirtyFields else { return (.all, .all) }
        let syncFields = state.getSyncFields()
        let broadcastFieldNames = Set(syncFields.filter { $0.policyType == .broadcast }.map { $0.name })
        let perPlayerFieldNames = Set(syncFields.filter { $0.policyType != .broadcast && $0.policyType != .serverOnly }.map { $0.name })

        let broadcastFields = dirtyFields.intersection(broadcastFieldNames)
        let perPlayerFields = dirtyFields.intersection(perPlayerFieldNames)
        let broadcastMode: SnapshotMode = broadcastFields.isEmpty ? .all : .dirtyTracking(broadcastFields)
        let perPlayerMode: SnapshotMode = perPlayerFields.isEmpty ? .all : .dirtyTracking(perPlayerFields)
        return (broadcastMode, perPlayerMode)
    }

    /// The one-pass extraction's single mode (`useSnapshotForSync`), for both the broadcast diff
    /// on the tables and the per-player extraction beside it: the dirty fields, or all. Without
    /// the one-pass extraction the caller keeps its separate modes and doesn't call this.
    /// `dirtyFields` as for `computeSyncModes`.
    static func onePassModes(dirtyFields: Set<String>?) -> (broadcast: SnapshotMode, perPlayer: SnapshotMode) {
        let fullMode: SnapshotMode = dirtyFields.map { .dirtyTracking($0) } ?? .all
        return (fullMode, fullMode)
    }
}

extension SyncPhasePlan {
    /// Moves each resynced session's snapshot (op 3, tagged `isResyncSnapshot`) ahead of its other
    /// frames of the plan, the merged broadcast frame first among them (#332). The client then
    /// applies the whole view before anything else at the resync's sequence: it skips the state
    /// patches of a later frame with that sequence, which the snapshot already holds, and still
    /// reads its key definitions and events. Its ack of the sequence then follows the snapshot.
    ///
    /// With row addressing an unsynced recipient's view (`isFullViewBeforeSharedFrame`) moves the
    /// same way: it holds the committed tables, which the shared frame then brings to live.
    mutating func putResyncSnapshotsFirst() {
        let views = Set(frames.filter(\.isFullViewBeforeSharedFrame).map(\.sessionID))
        for sessionID in Set(syncLag.resyncs.keys).union(views) {
            // No snapshot (it didn't encode whole), or it is already the session's first frame.
            guard let first = frames.firstIndex(where: { $0.sessionID == sessionID }),
                  let snapshot = frames.firstIndex(where: {
                      $0.sessionID == sessionID && ($0.isResyncSnapshot || $0.isFullViewBeforeSharedFrame)
                  }),
                  snapshot > first else { continue }
            frames.insert(frames.remove(at: snapshot), at: first)
        }
    }

    /// The held event frames the plan packed for the targeted events it consumed. Every plan that
    /// consumes targeted events packs them while planning (the full and the broadcast-only plan),
    /// so a pack failure ends the land there; the commit never packs. A plan that consumed none
    /// holds none.
    func heldEventFramesPacked() -> [SessionID: [Data]] {
        guard consumedEvents.targeted > 0 else { return [:] }
        assert(heldEvents != nil && heldEventsEnd == consumedEvents.targeted,
               "a plan that consumes targeted events packs their held frames")
        return heldEvents ?? [:]
    }
}
