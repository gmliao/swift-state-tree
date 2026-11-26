// P-903-2 (#903 plan): with `join(playerID:)`'s body replaced by the forwarding in the plan, the
// overload runs CanJoin and the player limit. Ran as a test file on main 4e7c902a (macOS, debug),
// with the forwarding applied (not committed); its output is in the plan's Probes section.
import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct Probe903State: StateNodeProtocol {
    @Sync(.broadcast) var n: Int = 0
    public init() {}
}

@Suite("PROBE 903")
struct Probe903Tests {
    @Test("PROBE 903: join(playerID:) through CanJoin and the cap")
    func probe() async throws {
        let definition = Land("probe-903", using: Probe903State.self) {
            AccessControl { MaxPlayers(1) }
            Rules {
                CanJoin { _, session, _ in
                    if session.playerID == "banned" { return .deny(reason: "banned") }
                    return .allow(playerID: PlayerID(session.playerID))
                }
            }
        }
        let keeper = LandKeeper<Probe903State>(definition: definition, initialState: Probe903State(), autoStartLoops: false)
        do { try await keeper.join(playerID: PlayerID("banned"), clientID: ClientID("c0"), sessionID: SessionID("s0")); print("probe-903 banned: joined") } catch { print("probe-903 banned: \(error)") }
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        do { try await keeper.join(playerID: PlayerID("p2"), clientID: ClientID("c2"), sessionID: SessionID("s2")); print("probe-903 over cap: joined") } catch { print("probe-903 over cap: \(error)") }
        print("probe-903 players: \(await keeper.playerCount())")
        await keeper.forceShutdown()
    }
}
