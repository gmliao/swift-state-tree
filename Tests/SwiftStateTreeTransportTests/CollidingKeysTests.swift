// Two map keys that convert to the same string end the land (#535 D8): the sync conversion
// throws `SyncError.collidingKeys` instead of letting one key overwrite the other.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// A key whose string form is constant: any two distinct keys collide.
private struct CollidingCode: Hashable, Sendable, CustomStringConvertible {
    let id: Int
    var description: String { "same" }
}

/// A key whose string form follows its value: distinct keys don't collide.
private struct DistinctCode: Hashable, Sendable, CustomStringConvertible {
    let id: Int
    var description: String { "c\(id)" }
}

@StateNodeBuilder
private struct CollidingKeysState: StateNodeProtocol {
    @Sync(.broadcast) var byCode: [CollidingCode: Int] = [:]
    @Sync(.broadcast) var round: Int = 0
    init() {}
}

private actor CollidingKeysTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var closes: [UInt16] = []
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        closes.append(close.code)
    }
}

/// The message of the `collidingKeys` that `body` throws; nil when it throws nothing or another
/// error.
private func collidingKeysMessage(_ body: () throws -> SnapshotValue) -> String? {
    do {
        _ = try body()
        return nil
    } catch SyncError.collidingKeys(let message) {
        return message
    } catch {
        return nil
    }
}

/// The message for a `[CollidingCode: Int]` whose keys convert to "same". The type name isn't
/// compared whole: in a release build the test's `type(of:)` spells the `private` key type with
/// its file discriminator (`(CollidingCode in _F7DF…)`) and the library's doesn't (#609).
private func namesCollidingCodesOnSame(_ message: String) -> Bool {
    message.hasPrefix("Two keys of Dictionary<") && message.contains("CollidingCode")
        && message.hasSuffix(", Int> convert to \"same\"")
}

@Suite("Colliding map keys end the land (#535 D8)")
struct CollidingKeysTests {
    @Test("The sync conversion of a map whose keys collide as strings throws collidingKeys; one key or distinct keys don't")
    func conversionThrows() throws {
        let colliding: [CollidingCode: Int] = [CollidingCode(id: 1): 1, CollidingCode(id: 2): 2]
        for message in [collidingKeysMessage { try SnapshotValue.make(from: colliding) },
                        collidingKeysMessage { try SnapshotValue.makeFull(from: colliding) }] {
            #expect(message.map(namesCollidingCodesOnSame) == true, "\(message ?? "no collidingKeys thrown")")
        }
        #expect(try SnapshotValue.make(from: [CollidingCode(id: 1): 1]) == .object(["same": .int(1)]))
        let distinct: [DistinctCode: Int] = [DistinctCode(id: 1): 1, DistinctCode(id: 2): 2]
        #expect(try SnapshotValue.make(from: distinct) == .object(["c1": .int(1), "c2": .int(2)]))
    }

    @Test("A synced map whose keys collide ends the land with syncConversion, naming the field; its session closes with 4016", arguments: [false, true])
    func collidingFieldEndsTheLand(atJoin: Bool) async throws {
        let definition = Land("colliding-keys-test", using: CollidingKeysState.self) {
            Rules {
                OnJoin { (state: inout CollidingKeysState, _: LandContext) in
                    state.round += 1
                    if atJoin { state.byCode = [CollidingCode(id: 1): 1, CollidingCode(id: 2): 2] }
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout CollidingKeysState, ctx: LandContext) in
                    if !atJoin {
                        state.byCode[CollidingCode(id: state.byCode.count + 1)] = state.round
                    }
                    ctx.requestSyncNow()
                }
            }
        }
        let transport = CollidingKeysTransport()
        let keeper = LandKeeper<CollidingKeysState>(definition: definition, initialState: CollidingKeysState())
        let adapter = TransportAdapter<CollidingKeysState>(keeper: keeper, transport: transport, landID: "colliding-keys-test")
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let session = SessionID("s1"), client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
        // The first tick's sync sends the unsynced player its full view.
        await keeper.stepTickOnce()
        if !atJoin {
            #expect(keeper.failure == nil, "one key converts")
            // The first view left the writer: the next tick's sync isn't deferred behind it.
            await adapter.waitForOutboundIdleForTesting()
            await keeper.stepTickOnce()  // a second key with the same string
        }
        try #require(await keeper.waitForFailureForTesting(), "the land failed")
        await keeper.waitUntilDrained()
        #expect(keeper.failure?.kind == .syncConversion)
        #expect(keeper.failure?.field == "byCode")
        #expect(keeper.failure?.detail.contains("collidingKeys") == true, "\(String(describing: keeper.failure))")
        #expect(await transport.closes == [SessionClose.Code.landFailed])
    }
}
