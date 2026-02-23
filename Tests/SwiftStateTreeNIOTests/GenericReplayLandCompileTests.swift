// GenericReplayLandCompileTests.swift
// Verifies the GenericReplayLand API compiles correctly.
// Actual replay behaviour is verified via E2E (verify-replay-record.ts).

import Foundation
import Testing
import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

// Minimal state type used only in compile tests.
// @StateNodeBuilder generates the runtime methods; StateFromSnapshotDecodable
// conformance is provided manually because the macro declaration currently
// only has @attached(member, ...) and does not emit the extension conformance.
@StateNodeBuilder
private struct CompileTestState: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var label: String = ""
}

extension CompileTestState: StateFromSnapshotDecodable {
    public init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
        self.init()
        if let v = snapshot.values["score"] { self._score.wrappedValue = try _snapshotDecode(v) }
        if let v = snapshot.values["label"] { self._label.wrappedValue = try _snapshotDecode(v) }
    }
}

// LandDefinition used as the base for the compile tests.
private func makeCompileTestBaseLand() -> LandDefinition<CompileTestState> {
    Land("compile-test", using: CompileTestState.self) {
        AccessControl {
            AllowPublic(true)
            MaxPlayers(4)
        }
        Lifetime {
            Tick(every: .milliseconds(50)) { (_: inout CompileTestState, _: LandContext) in }
        }
    }
}

@Suite("GenericReplayLand compile check")
struct GenericReplayLandCompileTests {

    @Test("GenericReplayLand type is accessible with StateFromSnapshotDecodable constraint")
    func genericReplayLandTypeExists() {
        // If this compiles, GenericReplayLand exists with the correct generic constraint.
        let _ = GenericReplayLand<CompileTestState>.self
    }

    @Test("GenericReplayLand.makeLand returns a LandDefinition with the correct id")
    func makeLandPreservesId() {
        let base = makeCompileTestBaseLand()
        let replay = GenericReplayLand<CompileTestState>.makeLand(basedOn: base)
        #expect(replay.id == base.id)
    }

    @Test("GenericReplayLand.makeLand preserves access-control settings from base")
    func makeLandPreservesAccessControl() {
        let base = makeCompileTestBaseLand()
        let replay = GenericReplayLand<CompileTestState>.makeLand(basedOn: base)
        #expect(replay.config.allowPublic == base.config.allowPublic)
        #expect(replay.config.maxPlayers == base.config.maxPlayers)
    }

    @Test("GenericReplayLand.makeLand replay land has a tick handler")
    func makeLandHasTickHandler() {
        let base = makeCompileTestBaseLand()
        let replay = GenericReplayLand<CompileTestState>.makeLand(basedOn: base)
        #expect(replay.lifetimeHandlers.tickHandler != nil)
    }

    @Test("GenericReplayLand.makeLand replay land has a tick interval")
    func makeLandHasTickInterval() {
        let base = makeCompileTestBaseLand()
        let replay = GenericReplayLand<CompileTestState>.makeLand(basedOn: base)
        #expect(replay.lifetimeHandlers.tickInterval != nil)
    }
}
