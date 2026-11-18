import Foundation
import SwiftStateTree

/// The sync stream recorder's pure helpers (#554 X3): canonical forms and hashes of what a sync
/// phase sends, and the clear marker's draft. `recordSyncStream` and `recordSyncStreamClear`
/// stay in the adapter, since they read its recording state and the keeper.
enum SyncStreamCanonical {
    /// The canonical form of an in-turn event: its keeper sequence, type and payload. Nil when it
    /// has no sequence or its payload does not convert (the events scope is then unverifiable).
    static func canonicalEvent(_ item: InTurnServerEvent) -> CanonicalSyncEvent? {
        guard let sequence = item.sequence,
              let payload = try? SnapshotValue.make(from: item.event.payload.base) else { return nil }
        return CanonicalSyncEvent(sequence: sequence, type: item.event.type, payload: payload)
    }

    /// A clear marker's draft; where the keeper would read the state at numbering is its
    /// position (its sequence and, tickless, its `afterPass`).
    static func clearDraft(_ playerID: PlayerID) -> SyncStreamDraft {
        SyncStreamDraft(.marker { streamIndex, position in
            ReevaluationRecordedSyncMarker(
                kind: .clear, playerID: playerID.rawValue, streamIndex: streamIndex,
                sequence: position.sequence, afterPass: position.afterPass
            )
        })
    }

    /// The canonical hash of one scope's patches. The diff never puts a path and one of its
    /// descendants in one scope; debug builds check it.
    static func scopeHash(_ patches: [StatePatch], scope: String) -> UInt64 {
        let list = CanonicalPatchList(patches)
        assert(!list.hasPrefixPairs, "sync scope \(scope) has a path and one of its descendants")
        return list.hash
    }

    static func sortedIDs(_ players: [PlayerID]) -> [String] {
        players.map(\.rawValue).sorted { SnapshotValue.utf8Less($0, $1) }
    }
}
