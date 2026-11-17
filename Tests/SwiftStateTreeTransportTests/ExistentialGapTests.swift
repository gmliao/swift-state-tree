// The registration check's documented gap (#535 §4): an existential behind a typealias isn't
// refused, by the macros or at registration. Its backstop is the sync conversion: the first
// value it can't convert ends the land, and every session closes with 4016.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

private protocol GapPayload: Sendable {}
extension Int: GapPayload {}
/// A class: registration sees only the default value, an `Int`.
private final class GapObject: GapPayload, @unchecked Sendable {}
private typealias AnyGapPayload = any GapPayload

@StateNodeBuilder
private struct ExistentialGapState: StateNodeProtocol {
    @Sync(.broadcast) var payload: AnyGapPayload = 0
    @Sync(.broadcast) var round: Int = 0
    init() {}
}

private actor ExistentialGapTransport: Transport {
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

@Suite("An existential behind a typealias: registration passes, the first throw ends the land (#535 §4)")
struct ExistentialGapTests {
    @Test("Registration passes the alias; a class it later holds ends the land with syncConversion and 4016, torn down as failed")
    func gapEndsTheLand() async throws {
        let definition = Land("existential-gap-test", using: ExistentialGapState.self) {
            Rules {
                OnJoin { (state: inout ExistentialGapState, _: LandContext) in
                    state.round += 1
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout ExistentialGapState, ctx: LandContext) in
                    if state.round > 1 { state.payload = GapObject() }
                    state.round += 1
                    ctx.requestSyncNow()
                }
            }
        }
        try definition.validateForRegistration(context: .encodingIndependent)
        let transport = ExistentialGapTransport()
        let keeper = LandKeeper<ExistentialGapState>(definition: definition, initialState: ExistentialGapState())
        let adapter = TransportAdapter<ExistentialGapState>(keeper: keeper, transport: transport, landID: "existential-gap-test")
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let session = SessionID("s1"), client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"))
        // The first tick's sync sends the player its full view: the payload is an Int.
        await keeper.stepTickOnce()
        #expect(keeper.failure == nil, "an Int converts")
        await adapter.waitForOutboundIdleForTesting()
        await keeper.stepTickOnce()  // the payload becomes a class
        if !InTurnSync.isEnabled() {
            // Legacy sync submits the failure; the keeper applies it at its next turn, the next tick.
            await keeper.stepTickOnce()
        }
        try #require(await keeper.waitForFailureForTesting(), "the land failed")
        await keeper.waitUntilDrained()
        #expect(keeper.failure?.kind == .syncConversion)
        #expect(keeper.failure?.field == "payload")
        #expect(keeper.destructionCause == .failed)
        #expect(await transport.closes == [SessionClose.Code.landFailed])
    }
}
