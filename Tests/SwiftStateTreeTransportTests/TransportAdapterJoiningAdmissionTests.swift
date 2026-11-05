// Tests/SwiftStateTreeTransportTests/TransportAdapterJoiningAdmissionTests.swift
//
// A join admits the session as `.joining` (#69): from the admission until its initial sync, the
// session is not a sync recipient and is not reached by `.player` or `.broadcast` frames, so it
// can't get a diff or an event before its JoinResponse and firstSync. On the in-turn path the
// keeper admits inside its join (same synchronous segment as its state change); otherwise the
// adapter admits right after the join returns. Either way exactly once.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct JoiningAdmissionTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0
}

@Payload
struct JoiningAdmissionTestEvent: ServerEventPayload {
    let note: String
}

/// Frames the transport was asked to send, with their targets.
private actor SentFrames {
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []
    func append(_ data: Data, _ target: SwiftStateTreeTransport.EventTarget) { frames.append((data, target)) }

    /// What `sessionID` received, in order: "joinResponse", "firstSync", "diff", "noChange",
    /// "event" or "other".
    func kinds(for sessionID: SessionID) -> [String] {
        frames.compactMap { frame -> String? in
            guard case .session(let s) = frame.target, s == sessionID else { return nil }
            let decoder = JSONDecoder()
            if let message = try? decoder.decode(TransportMessage.self, from: frame.data) {
                switch message.kind {
                case .joinResponse: return "joinResponse"
                case .event: return "event"
                default: return "other"
                }
            }
            if let update = try? decoder.decode(StateUpdate.self, from: frame.data) {
                switch update {
                case .noChange: return "noChange"
                case .firstSync: return "firstSync"
                case .diff: return "diff"
                }
            }
            return "other"
        }
    }
}

private struct Fixture {
    let keeper: LandKeeper<JoiningAdmissionTestState>
    let adapter: TransportAdapter<JoiningAdmissionTestState>
    let sent: SentFrames
}

private enum OnJoinMode { case ok, throwing }

private struct OnJoinFailure: Error {}

private func makeFixture(
    inTurn: Bool,
    tick: Bool = false,
    onJoin: OnJoinMode = .ok,
    mode: LandMode = .live,
    attachTransport: Bool = true
) async -> Fixture {
    let throwing = onJoin == .throwing
    let definition = tick
        ? Land("joining-admission", using: JoiningAdmissionTestState.self) {
            ServerEvents { Register(JoiningAdmissionTestEvent.self) }
            Rules {
                OnJoin { (state: inout JoiningAdmissionTestState, _: LandContext) in
                    if throwing { throw OnJoinFailure() }
                    state.joins += 1
                }
            }
            Lifetime {
                Tick(every: .milliseconds(50)) { (_: inout JoiningAdmissionTestState, _: LandContext) in }
            }
        }
        : Land("joining-admission", using: JoiningAdmissionTestState.self) {
            ServerEvents { Register(JoiningAdmissionTestEvent.self) }
            Rules {
                OnJoin { (state: inout JoiningAdmissionTestState, _: LandContext) in
                    if throwing { throw OnJoinFailure() }
                    state.joins += 1
                }
            }
        }
    let transport = RecordingTransport()
    let sent = SentFrames()
    await transport.setOnSend { data, target in await sent.append(data, target) }
    let keeper = LandKeeper(
        definition: definition,
        initialState: JoiningAdmissionTestState(),
        mode: mode,
        autoStartLoops: false
    )
    let adapter = TransportAdapter<JoiningAdmissionTestState>(
        keeper: keeper,
        transport: transport,
        landID: "joining-admission",
        inTurnSync: inTurn
    )
    await transport.setDelegate(adapter)
    if attachTransport {
        await keeper.setTransport(adapter)
    }
    return Fixture(keeper: keeper, adapter: adapter, sent: sent)
}

private func join(
    _ fixture: Fixture,
    session: SessionID,
    client: ClientID,
    player: PlayerID
) async throws -> TransportAdapter<JoiningAdmissionTestState>.JoinResult {
    await fixture.adapter.onConnect(sessionID: session, clientID: client)
    let result = try await fixture.adapter.performJoin(
        playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev-\(client.rawValue)", metadata: [:]),
        clientID: client,
        sessionID: session,
        authInfo: nil
    )
    return try #require(result)
}

@Suite("Joining at admission (#69)")
struct TransportAdapterJoiningAdmissionTests {
    @Test("A joining session gets no sync frame and no group event before its initial sync", arguments: [true, false])
    func joiningSessionGetsNothingBeforeInitialSync(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1")

        _ = try await join(fixture, session: s1, client: c1, player: p1)
        #expect(await adapter.isJoining(s1))

        // Held between the admission and the initial sync: a sync and group events run.
        await adapter.syncNow()
        await adapter.sendEvent(AnyServerEvent(JoiningAdmissionTestEvent(note: "all")), to: .all)
        await adapter.sendEvent(AnyServerEvent(JoiningAdmissionTestEvent(note: "p1")), to: .player(p1))
        #expect(await adapter.waitForOutboundDrain())
        let beforeInitialSync = await fixture.sent.kinds(for: s1)
        #expect(beforeInitialSync == [], "frames before the initial sync: \(beforeInitialSync)")

        // The initial sync hands `.joining` over and sends the firstSync first.
        await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1)
        #expect(await adapter.isJoining(s1) == false)
        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1).first == "firstSync")

        // Afterwards the session is a recipient again.
        await adapter.sendEvent(AnyServerEvent(JoiningAdmissionTestEvent(note: "after")), to: .all)
        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1).last == "event")
    }

    @Test("A joining session still gets frames addressed to it (its JoinResponse)")
    func joiningSessionGetsSessionFrames() async throws {
        let fixture = await makeFixture(inTurn: true, tick: true)
        let s1 = SessionID("s1")
        _ = try await join(fixture, session: s1, client: ClientID("c1"), player: PlayerID("p1"))
        #expect(await fixture.adapter.sessionIDs(for: .session(s1)) == [s1])
        #expect(await fixture.adapter.sessionIDs(for: .player(PlayerID("p1"))) == [])
        #expect(await fixture.adapter.sessionIDs(for: .broadcast) == [])
    }

    @Test("The in-turn keeper admits inside its join; otherwise the adapter does; exactly once", arguments: [true, false])
    func admissionPointAndExactlyOnce(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true)
        let adapter = fixture.adapter
        let s1 = SessionID("s1")
        let result = try await join(fixture, session: s1, client: ClientID("c1"), player: PlayerID("p1"))
        let keeperAdmits = adapter.runsSyncPhaseInTurn(of: fixture.keeper)
        #expect(await adapter.inTurnAdmissionCountForTesting == (keeperAdmits ? 1 : 0))
        #expect(await adapter.isJoining(s1))
        #expect(await adapter.getPlayerSlot(for: PlayerID("p1")) == result.playerSlot)
        #expect(await adapter.membershipSessionIDs(for: PlayerID("p1")) == [s1])
    }

    @Test("A tickless in-turn land: the OnJoin turn inside the join sends the joiner nothing")
    func ticklessOnJoinTurnSendsJoinerNothing() async throws {
        let fixture = await makeFixture(inTurn: true)
        let adapter = fixture.adapter
        // A player already joined, so a sync has a recipient and commits.
        let s0 = SessionID("s0"), p0 = PlayerID("p0")
        _ = try await join(fixture, session: s0, client: ClientID("c0"), player: p0)
        await adapter.syncStateForNewPlayer(playerID: p0, sessionID: s0)

        let s1 = SessionID("s1"), p1 = PlayerID("p1")
        _ = try await join(fixture, session: s1, client: ClientID("c1"), player: p1)
        #expect(await adapter.inTurnAdmissionCountForTesting == (adapter.runsSyncPhaseInTurn(of: fixture.keeper) ? 2 : 0))
        // An input turn syncs only on request; a sync while the joiner is joining reaches the
        // earlier player (the OnJoin's change) and not the joiner.
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await fixture.sent.kinds(for: s0).contains("diff"))

        await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1)
        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1).first == "firstSync")
    }

    @Test("A replay viewer's join on a reevaluation keeper doesn't trap and is admitted by the adapter", arguments: [true, false])
    func reevaluationKeeperJoin(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true, mode: .reevaluation)
        let s1 = SessionID("viewer")
        _ = try await join(fixture, session: s1, client: ClientID("cv"), player: PlayerID("viewer"))
        #expect(await fixture.adapter.inTurnAdmissionCountForTesting == 0)
        #expect(await fixture.adapter.isJoining(s1))
        await fixture.adapter.syncStateForNewPlayer(playerID: PlayerID("viewer"), sessionID: s1)
        #expect(await fixture.adapter.isJoining(s1) == false)
    }

    @Test("A join before the keeper has its transport is admitted by the adapter")
    func joinBeforeSetTransport() async throws {
        let fixture = await makeFixture(inTurn: true, tick: true, attachTransport: false)
        let s1 = SessionID("s1")
        _ = try await join(fixture, session: s1, client: ClientID("c1"), player: PlayerID("p1"))
        #expect(await fixture.adapter.inTurnAdmissionCountForTesting == 0)
        #expect(await fixture.adapter.isJoining(s1))
        #expect(await fixture.adapter.membershipSessionIDs(for: PlayerID("p1")) == [s1])
    }

    @Test("A join that fails after the in-turn admission leaves no membership, slot or joining mark")
    func failedJoinAfterAdmissionIsUndone() async throws {
        let fixture = await makeFixture(inTurn: true, onJoin: .throwing)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1")
        await adapter.onConnect(sessionID: s1, clientID: c1)
        await #expect(throws: (any Error).self) {
            _ = try await adapter.performJoin(
                playerSession: PlayerSession(playerID: p1.rawValue, deviceID: "dev", metadata: [:]),
                clientID: c1,
                sessionID: s1,
                authInfo: nil
            )
        }
        #expect(await adapter.isJoining(s1) == false)
        #expect(await adapter.membershipSessionIDs(for: p1).isEmpty)
        #expect(await adapter.getPlayerSlot(for: p1) == nil)
    }

    @Test("A disconnect while joining clears the joining mark")
    func disconnectWhileJoining() async throws {
        let fixture = await makeFixture(inTurn: true, tick: true)
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1")
        _ = try await join(fixture, session: s1, client: c1, player: p1)
        await fixture.adapter.onDisconnect(sessionID: s1, clientID: c1)
        #expect(await fixture.adapter.isJoining(s1) == false)
        #expect(await fixture.adapter.getPlayerSlot(for: p1) == nil)
    }
}
