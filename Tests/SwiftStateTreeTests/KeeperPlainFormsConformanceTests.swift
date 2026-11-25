// Tests/SwiftStateTreeTests/KeeperPlainFormsConformanceTests.swift
//
// #700 K1b-1: the keeper's queued items, and every type they hold, are PlainData, so K1b-4's
// `KeeperModel` can be. This file compiles only while each one conforms. Each commit of K1b-1
// adds the types it marks; the nested ones (inside the generic `LandKeeper<State>`) pin that the
// macro expands there.

import SwiftStateTurns
import Testing
@testable import SwiftStateTree

/// Compiles only when `T` is `PlainData`.
private func requirePlain<T: PlainData>(_: T.Type) {}

@StateNodeBuilder
struct KeeperPlainFormsPinState: StateNodeProtocol {
    @Sync(.broadcast)
    var n: Int = 0

    public init() {}
}

@Suite("The keeper's queued item types are PlainData (#700 K1b-1)")
struct KeeperPlainFormsConformanceTests {
    @Test("Each type a queued item holds conforms")
    func conforms() {
        // Commit 2: the public enums and LandFailure.
        requirePlain(LandFailure.self)
        requirePlain(LandFailure.Kind.self)
        requirePlain(LandFailurePosition.self)
        requirePlain(LandFailurePosition.Stage.self)
        requirePlain(RecordPayloadEncoding.self)
        requirePlain(RecordedPayloadBytes.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.LifecycleKind.self)
        // Commit 3: the decoded payloads.
        requirePlain(DecodedAction.self)
        requirePlain(DecodedServerInput.self)
        // Commit 4: the handler index.
        requirePlain(ActionHandlerIndex.self)
        // Commit 6: the held resolver outputs.
        requirePlain(HeldResolverOutput.self)
        requirePlain(RecordedResolverOutput.self)
        // Commit 7: the tuples made structs.
        requirePlain(SyncOutputIndexCursor.self)
        requirePlain(ReplayFailureEnd.self)
        // Commit 8: the items and PendingItem.
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingItem.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingActionItem.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingClientEventItem.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingClientEventPayload.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingLifecycleItem.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingServerInputItem.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingShutdownItem.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.PendingLandFailureItem.self)
        // K1b-2: the failure IDs and what holds them.
        requirePlain(Epoch.self)
        requirePlain(EpochCounter.self)
        requirePlain(FailureID.self)
        requirePlain(InputResult.self)
        requirePlain(LandKeeper<KeeperPlainFormsPinState>.ActionTicket.self)
    }
}
