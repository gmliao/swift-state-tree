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
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct JoiningAdmissionTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0
}

@Payload
struct JoiningAdmissionTestEvent: ServerEventPayload {
    let note: String
}

/// The test transport: records every frame with its target in `send`, in send order. (Recording
/// through a callback in an unstructured Task can reorder frames or miss the latest one.)
private actor SentFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        frames.append((message, target))
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

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
    attachTransport: Bool = true,
    encoding: InTurnEncoding = .json
) async -> Fixture {
    // OnJoin throws only for this player, so a later join of another player shows whether the
    // failed join's input ran again.
    let throwingPlayer = onJoin == .throwing ? "bad" : nil
    let definition = tick
        ? Land("joining-admission", using: JoiningAdmissionTestState.self) {
            ServerEvents { Register(JoiningAdmissionTestEvent.self) }
            Rules {
                OnJoin { (state: inout JoiningAdmissionTestState, ctx: LandContext) in
                    if ctx.playerID.rawValue == throwingPlayer { throw OnJoinFailure() }
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
                OnJoin { (state: inout JoiningAdmissionTestState, ctx: LandContext) in
                    if ctx.playerID.rawValue == throwingPlayer { throw OnJoinFailure() }
                    state.joins += 1
                }
            }
        }
    let sent = SentFrames()
    let transport = sent
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
        encodingConfig: encoding.config,
        pathHashes: encoding == .json ? nil : ["joins": DeterministicHash.fnv1a32("joins")],
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
    @Test(
        "A joining session gets no sync frame and no group event before its initial sync",
        arguments: [true, false], InTurnEncoding.allCases
    )
    func joiningSessionGetsNothingBeforeInitialSync(inTurn: Bool, encoding: InTurnEncoding) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true, encoding: encoding)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1")

        _ = try await join(fixture, session: s1, client: c1, player: p1)
        #expect(await adapter.isJoining(s1))

        // Held between the admission and the initial sync: group events, then a sync (which
        // also delivers queued opcode 107 events).
        await adapter.sendEvent(AnyServerEvent(JoiningAdmissionTestEvent(note: "all")), to: .all)
        await adapter.sendEvent(AnyServerEvent(JoiningAdmissionTestEvent(note: "p1")), to: .player(p1))
        await adapter.sendEvent(AnyServerEvent(JoiningAdmissionTestEvent(note: "ps")), to: .players([p1]))
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain())
        let beforeInitialSync = await fixture.sent.kinds(for: s1)
        #expect(beforeInitialSync == [], "frames before the initial sync: \(beforeInitialSync)")

        // The initial sync hands `.joining` over and sends the firstSync first.
        await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1)
        #expect(await adapter.isJoining(s1) == false)
        #expect(await adapter.waitForOutboundDrain())
        guard encoding == .json else { return }  // frame kinds below are decoded as JSON
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

    @Test("A join whose tickless OnJoin throws leaves nothing behind, in the adapter or the keeper", arguments: [true, false])
    func failedJoinAfterAdmissionIsUndone(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, onJoin: .throwing)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("bad")
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
        // The keeper removed the player (no capacity held, nothing keeps the land alive) and
        // the failed join's input: the next join doesn't run that OnJoin again.
        #expect(await fixture.keeper.playerCount() == 0)
        // The connection itself stays registered: the client can join again on it.
        #expect(await adapter.isConnected(sessionID: s1))
        let retry = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: "retry", deviceID: "dev", metadata: [:]),
            clientID: c1,
            sessionID: s1,
            authInfo: nil
        )
        #expect(retry?.playerID == PlayerID("retry"))
        #expect(await fixture.keeper.playerCount() == 1)
        _ = try await join(fixture, session: SessionID("s2"), client: ClientID("c2"), player: PlayerID("good"))
        #expect(await fixture.keeper.playerCount() == 2)
        #expect(await fixture.keeper.currentState().joins == 2)
    }

    @Test("A disconnect after performJoin returned and before the handover: no firstSync, no per-player state", arguments: [true, false])
    func disconnectBeforeHandover(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1")
        _ = try await join(fixture, session: s1, client: c1, player: p1)
        // The router's next step is held; the queued disconnect runs first.
        await adapter.onDisconnect(sessionID: s1, clientID: c1)
        let started = TestGate()
        started.open()
        await adapter.setInitialSyncHoldForTesting { await started.arrive() }
        await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1)
        // The handover refused: the initial sync never started (no state read).
        #expect(started.arrivalCount == 0)
        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(p1) == false)
        #expect(await adapter.getPlayerSlot(for: p1) == nil)
    }

    @Test("A disconnect while the initial sync reads the state: no firstSync commit", arguments: [true, false])
    func disconnectDuringStateRead(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1")
        _ = try await join(fixture, session: s1, client: c1, player: p1)

        let readGate = TestGate()
        await adapter.setInitialSyncHoldForTesting { await readGate.arrive() }
        let initialSync = Task { await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1) }
        #expect(await readGate.waitForArrivals(1))
        await adapter.onDisconnect(sessionID: s1, clientID: c1)
        readGate.open()
        await initialSync.value

        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(p1) == false)
        #expect(await adapter.getPlayerSlot(for: p1) == nil)
    }

    @Test("A re-join on the same SessionID while the old initial sync reads the state: only the new one commits", arguments: [true, false])
    func rejoinSameSessionDuringStateRead(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1")
        _ = try await join(fixture, session: s1, client: c1, player: p1)

        // The old initial sync is held at its state read.
        let readGate = TestGate()
        await adapter.setInitialSyncHoldForTesting { await readGate.arrive() }
        let oldInitialSync = Task { await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1) }
        #expect(await readGate.waitForArrivals(1))
        await adapter.setInitialSyncHoldForTesting(nil)

        // The session ends and a new connection with the same SessionID joins as the same
        // player: the membership matches again, but the admission is a new generation.
        await adapter.onDisconnect(sessionID: s1, clientID: c1)
        _ = try await join(fixture, session: s1, client: c1, player: p1)
        await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1)

        readGate.open()
        await oldInitialSync.value

        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["firstSync"])
        #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(p1) == true)
    }

    @Test("A direct register that rebinds the session during the initial sync's state read: the old sync commits nothing", arguments: [true, false])
    func rebindDuringStateRead(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1"), p2 = PlayerID("p2")
        _ = try await join(fixture, session: s1, client: c1, player: p1)

        let readGate = TestGate()
        await adapter.setInitialSyncHoldForTesting { await readGate.arrive() }
        let initialSync = Task { await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1) }
        #expect(await readGate.waitForArrivals(1))

        // Rebound to p2 and back to p1: the membership matches p1 again, but the binding the
        // initial sync started for has ended.
        await adapter.registerSession(sessionID: s1, clientID: c1, playerID: p2, authInfo: nil)
        await adapter.registerSession(sessionID: s1, clientID: c1, playerID: p1, authInfo: nil)
        readGate.open()
        await initialSync.value

        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(p1) == false)
    }

    @Test("An old join's initial sync after the SessionID was admitted again for another player: it takes nothing", arguments: [true, false])
    func oldInitialSyncAfterReadmissionAsAnotherPlayer(inTurn: Bool) async throws {
        let fixture = await makeFixture(inTurn: inTurn, tick: true)
        let adapter = fixture.adapter
        let s1 = SessionID("s1"), c1 = ClientID("c1"), p1 = PlayerID("p1"), p2 = PlayerID("p2")
        _ = try await join(fixture, session: s1, client: c1, player: p1)
        // The router's next step for p1's join is held; s1 ends and is admitted as p2.
        await adapter.onDisconnect(sessionID: s1, clientID: c1)
        _ = try await join(fixture, session: s1, client: c1, player: p2)
        #expect(await adapter.isJoining(s1))

        await adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1)
        // p2's admission is untouched: still joining, so not yet a sync recipient.
        #expect(await adapter.isJoining(s1))
        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(p1) == false)

        await adapter.syncStateForNewPlayer(playerID: p2, sessionID: s1)
        #expect(await adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["firstSync"])
        #expect(await adapter.syncEngineForTesting().hasReceivedFirstSyncForTesting(p2) == true)
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

// MARK: - A failed OnJoin removes only its own entry

/// Holds the first OnJoin resolver call at `gate`; later calls pass. Each output carries its
/// call index, so OnJoin can fail only the first join.
private final class HeldJoinResolverControl: @unchecked Sendable {
    static let shared = HeldJoinResolverControl()
    let gate = TestGate()
    private let lock = NSLock()
    private var calls = 0
    func nextCall() -> Int {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls - 1
    }
}

struct HeldJoinResolver: ContextResolver {
    typealias Output = HeldJoinResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> HeldJoinResolverOutput {
        let call = HeldJoinResolverControl.shared.nextCall()
        if call == 0 {
            await HeldJoinResolverControl.shared.gate.arrive()
        }
        return HeldJoinResolverOutput(call: call)
    }
}

struct HeldJoinResolverOutput: ResolverOutput {
    let call: Int
}

@Test("A failed OnJoin doesn't remove a later join's entry with the same player, client and session")
func failedOnJoinKeepsLaterJoinsEntry() async throws {
    let definition = Land("failed-join-entry", using: JoiningAdmissionTestState.self) {
        Rules {
            OnJoin(resolvers: HeldJoinResolver.self) { (state: inout JoiningAdmissionTestState, ctx: LandContext) in
                // The first join (held, then released) fails; the later one succeeds.
                if (ctx.heldJoin as HeldJoinResolverOutput?)?.call == 0 { throw OnJoinFailure() }
                state.joins += 1
            }
        }
    }
    let keeper = LandKeeper(definition: definition, initialState: JoiningAdmissionTestState(), autoStartLoops: false)
    let session = PlayerSession(playerID: "p1", deviceID: "dev", metadata: [:])
    let client = ClientID("c1"), sessionID = SessionID("s1")

    // Join A inserts the player, then is held in its OnJoin resolver.
    let joinA = Task {
        try await keeper.join(session: session, clientID: client, sessionID: sessionID, services: LandServices())
    }
    #expect(await HeldJoinResolverControl.shared.gate.waitForArrivals(1))

    // Join B of the same player, client and session (a reconnect) replaces the entry and completes.
    _ = try await keeper.join(session: session, clientID: client, sessionID: sessionID, services: LandServices())
    #expect(await keeper.playerCount() == 1)
    #expect(await keeper.currentState().joins == 1)

    // A is released and its OnJoin throws: B's entry stays.
    HeldJoinResolverControl.shared.gate.open()
    await #expect(throws: (any Error).self) { _ = try await joinA.value }
    #expect(await keeper.playerCount() == 1)
}
