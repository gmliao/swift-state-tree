// Tests/SwiftStateTreeTransportTests/SyncPlanningTests.swift
//
// The pure sync-plan functions moved out of the adapter (#554 X2), tested without one.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// The fields a mode includes: nil for `.all`, the set for `.dirtyTracking`.
private func fields(_ mode: SnapshotMode) -> Set<String>? {
    switch mode {
    case .all: return nil
    case .dirtyTracking(let fields): return fields
    default:
        Issue.record("unexpected mode \(mode)")
        return []
    }
}

private func set(_ path: String, _ value: Int) -> StatePatch {
    StatePatch(path: path, operation: .set(.int(value)))
}

@Suite("Sync planning's pure functions (#554)")
struct SyncPlanningTests {
    @Test("replacingRows puts each root's rows where its first patch was, drops the root's other patches, and leaves roots without rows")
    func replacingRows() {
        let patches = [set("/a/1", 1), set("/b", 2), set("/a/2", 3), set("/c/x", 4)]
        let rows = ["/a": [set("/a/r1", 10), set("/a/r2", 11)], "/z": [set("/z/r", 12)]]
        #expect(SyncPlanning.replacingRows(of: patches, with: rows)
            == [set("/a/r1", 10), set("/a/r2", 11), set("/b", 2), set("/c/x", 4)])
        #expect(SyncPlanning.replacingRows(of: patches, with: [:]) == patches)
        // A path that is only a root is its own root.
        #expect(SyncPlanning.replacingRows(of: [set("/a", 1)], with: ["/a": [set("/a/r", 2)]]) == [set("/a/r", 2)])
    }

    @Test("keyScopeResetUpdate is always a firstSync, with the update's patches")
    func keyScopeResetUpdate() {
        let patches = [set("/a", 1)]
        #expect(SyncPlanning.keyScopeResetUpdate(.noChange) == .firstSync([]))
        #expect(SyncPlanning.keyScopeResetUpdate(.diff(patches)) == .firstSync(patches))
        #expect(SyncPlanning.keyScopeResetUpdate(.firstSync(patches)) == .firstSync(patches))
    }

    @Test("withoutDroppedFields filters the dropped fields' patches against the empty baseline only")
    func withoutDroppedFields() {
        let patches = [set("/round", 1), set("/title/x", 2), set("/boss", 3)]
        #expect(SyncPlanning.withoutDroppedFields(patches, dropped: ["title"], baseline: .empty)
            == [set("/round", 1), set("/boss", 3)])
        #expect(SyncPlanning.withoutDroppedFields(patches, dropped: ["title"], baseline: .cached) == patches)
        #expect(SyncPlanning.withoutDroppedFields(patches, dropped: [], baseline: .empty) == patches)
    }

    @Test("computeSyncModes: no dirty fields gives all; dirty fields split by policy, server-only in neither")
    func computeSyncModes() {
        let state = DirtyIdentityState()
        let none = SyncPlanning.computeSyncModes(for: state, dirtyFields: nil)
        #expect(fields(none.broadcastMode) == nil && fields(none.perPlayerMode) == nil)

        let both = SyncPlanning.computeSyncModes(for: state, dirtyFields: ["round", "inventories", "secret"])
        #expect(fields(both.broadcastMode) == ["round"])
        #expect(fields(both.perPlayerMode) == ["inventories"])

        // A scope with no dirty field of its own extracts all of it.
        let broadcastOnly = SyncPlanning.computeSyncModes(for: state, dirtyFields: ["title"])
        #expect(fields(broadcastOnly.broadcastMode) == ["title"])
        #expect(fields(broadcastOnly.perPlayerMode) == nil)
    }

    @Test("modesBesideTables: the separate modes without the one-pass extraction; with it, the dirty fields or all for both")
    func modesBesideTables() {
        let separate = SyncPlanning.modesBesideTables(
            useSnapshotForSync: false, dirtyFields: ["round"],
            broadcastMode: .dirtyTracking(["round"]), perPlayerMode: .all
        )
        #expect(fields(separate.broadcast) == ["round"] && fields(separate.perPlayer) == nil)

        let onePass = SyncPlanning.modesBesideTables(
            useSnapshotForSync: true, dirtyFields: ["round", "inventories"],
            broadcastMode: .all, perPlayerMode: .all
        )
        #expect(fields(onePass.broadcast) == ["round", "inventories"] && fields(onePass.perPlayer) == ["round", "inventories"])

        let clean = SyncPlanning.modesBesideTables(
            useSnapshotForSync: true, dirtyFields: nil,
            broadcastMode: .dirtyTracking(["round"]), perPlayerMode: .all
        )
        #expect(fields(clean.broadcast) == nil && fields(clean.perPlayer) == nil)
    }
}
