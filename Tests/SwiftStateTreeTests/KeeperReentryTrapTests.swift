// Tests/SwiftStateTreeTests/KeeperReentryTrapTests.swift
//
// The re-entry contract (#700 K1b-4): a handler runs on `&model.state`, an access to the keeper's
// whole model, so a handler that calls back into its keeper synchronously and reads the model
// stops the process with Swift's exclusivity error. This test shows that trap; it kills its test
// process, so it runs only when asked, one case per process:
//
//     KEEPER_REENTRY_TRAP=1 swift test --filter KeeperReentryTrapTests
//
// Expected: the process ends with "Simultaneous accesses" and "Fatal access conflict detected".
// A run that passes means the handler's access no longer covers the model: the contract's docs
// (docs/core/runtime.md, `LandContext`) then need revisiting.

import Foundation
import Synchronization
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct ReentryTrapState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: Int = 0

    init() {}
}

enum KeeperReentryTrapEnvKeys {
    /// Set to `1` to run the trap (it ends the test process).
    static let run = "KEEPER_REENTRY_TRAP"
}

/// The keeper the handler reaches back into, set after the keeper exists.
private final class ReentryTrapKeeperBox: Sendable {
    let keeper = Mutex<LandKeeper<ReentryTrapState>?>(nil)
}

@Suite("A handler that calls back into its keeper traps (#700 K1b-4)")
struct KeeperReentryTrapTests {
    @Test(
        "A handler that reads its keeper synchronously stops the process",
        .enabled(if: isDebugBuild && EnvHelpers.getEnvBool(key: KeeperReentryTrapEnvKeys.run, defaultValue: false))
    )
    func reentryTraps() async throws {
        let box = ReentryTrapKeeperBox()
        let land = Land("reentry-trap", using: ReentryTrapState.self) {
            Rules {
                OnJoin { state, _ in
                    guard let keeper = box.keeper.withLock({ $0 }) else { return }
                    // On the keeper's executor, while `&model.state` is held: the read of
                    // `model.players` overlaps the handler's access.
                    state.players = keeper.assumeIsolated { $0.playerCount() } // lint-allow: turns-isolated: the re-entry the contract refuses, shown trapping
                }
            }
        }
        let keeper = LandKeeper(definition: land, initialState: ReentryTrapState(), autoStartLoops: false)
        box.keeper.withLock { $0 = keeper }
        await keeper.awaitInitialization()
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        await keeper.stepTickOnce()
        Issue.record("the handler's re-entry didn't trap")
    }
}
