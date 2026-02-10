import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct MembershipTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var tick: Int = 0
}

@Payload
private struct MembershipMessageEvent: ServerEventPayload {
    let message: String
    init(message: String) { self.message = message }
}

private actor MembershipRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    func start() async throws { }
    func stop() async throws { }

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((message, target))
    }

    func recordedMessages() async -> [Data] {
        sent.map(\.data)
    }

    func recordedFrames() async -> [(data: Data, target: SwiftStateTreeTransport.EventTarget)] {
        sent
    }

    func clear() async {
        sent.removeAll()
    }
}

private func messagePackContainsString(_ value: MessagePackValue, _ needle: String) -> Bool {
    switch value {
    case .string(let text):
        return text == needle
    case .array(let values):
        return values.contains { messagePackContainsString($0, needle) }
    case .map(let pairs):
        return pairs.contains { messagePackContainsString($0.key, needle) || messagePackContainsString($0.value, needle) }
    default:
        return false
    }
}

private func frameContainsString(_ data: Data, _ needle: String) -> Bool {
    if let unpacked = try? unpack(data), messagePackContainsString(unpacked, needle) {
        return true
    }
    if let text = String(data: data, encoding: .utf8), text.contains(needle) {
        return true
    }
    return false
}

@Test("Queued targeted event is dropped after leave + rejoin")
func testQueuedTargetedEventDroppedAfterRejoin() async throws {
    let definition = Land("membership-test", using: MembershipTestState.self) {
        ServerEvents {
            Register(MembershipMessageEvent.self)
        }
        Rules { }
    }
    let transport = MembershipRecordingTransport()
    let keeper = LandKeeper<MembershipTestState>(definition: definition, initialState: MembershipTestState())
    let encodingConfig = TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
    let adapter = TransportAdapter<MembershipTestState>(
        keeper: keeper,
        transport: transport,
        landID: "membership-test",
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)

    let session1 = SessionID("sess-1")
    let client1 = ClientID("cli-1")
    let player = PlayerID("p1")

    await adapter.onConnect(sessionID: session1, clientID: client1)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: session1,
        clientID: client1,
        playerID: player
    )
    await transport.clear()

    await adapter.sendEvent(AnyServerEvent(MembershipMessageEvent(message: "old")), to: .player(player))
    await adapter.onDisconnect(sessionID: session1, clientID: client1)

    let session2 = SessionID("sess-2")
    let client2 = ClientID("cli-2")
    await adapter.onConnect(sessionID: session2, clientID: client2)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: session2,
        clientID: client2,
        playerID: player
    )

    await adapter.syncNow()

    let messages = await transport.recordedMessages()
    var opcode103Count = 0
    for data in messages {
        let unpacked = try unpack(data)
        guard case .array(let array) = unpacked,
              case .int(let opcode) = array.first else { continue }
        if opcode == 103 { opcode103Count += 1 }
    }

    #expect(opcode103Count == 0, "Stale targeted event should not be delivered after rejoin")
}

@Test("Queued targeted event is dropped after duplicate login kicks stale session")
func testQueuedTargetedEventDroppedAfterDuplicateLoginKick() async throws {
    let definition = Land("membership-test", using: MembershipTestState.self) {
        ServerEvents {
            Register(MembershipMessageEvent.self)
        }
        Rules { }
    }
    let transport = MembershipRecordingTransport()
    let keeper = LandKeeper<MembershipTestState>(definition: definition, initialState: MembershipTestState())
    let encodingConfig = TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack)
    let adapter = TransportAdapter<MembershipTestState>(
        keeper: keeper,
        transport: transport,
        landID: "membership-test",
        enableLegacyJoin: true,
        encodingConfig: encodingConfig
    )
    await transport.setDelegate(adapter)

    let sessionA = SessionID("sess-a")
    let clientA = ClientID("cli-a")
    let player = PlayerID("p1")
    let messageEncoder = MessagePackTransportMessageEncoder()

    await adapter.onConnect(sessionID: sessionA, clientID: clientA)
    let joinA = TransportMessage.join(
        requestID: "join-a",
        landType: "membership-test",
        landInstanceId: nil,
        playerID: player.rawValue,
        deviceID: nil,
        metadata: nil
    )
    await adapter.onMessage(try messageEncoder.encode(joinA), from: sessionA)
    try await Task.sleep(for: .milliseconds(50))
    await transport.clear()

    await adapter.sendEvent(
        AnyServerEvent(MembershipMessageEvent(message: "stale-before-kick")),
        to: SwiftStateTree.EventTarget.player(player)
    )

    let sessionB = SessionID("sess-b")
    let clientB = ClientID("cli-b")
    await adapter.onConnect(sessionID: sessionB, clientID: clientB)
    let joinB = TransportMessage.join(
        requestID: "join-b",
        landType: "membership-test",
        landInstanceId: nil,
        playerID: player.rawValue,
        deviceID: nil,
        metadata: nil
    )
    await adapter.onMessage(try messageEncoder.encode(joinB), from: sessionB)
    try await Task.sleep(for: .milliseconds(50))

    // Verify lifecycle state
    let isJoinedB = await adapter.isJoined(sessionID: sessionB)
    #expect(isJoinedB, "Session B should be joined")

    let playerIDB = await adapter.getPlayerID(for: sessionB)
    #expect(playerIDB == player, "Session B should be mapped to player")

    let sessionsForPlayer = await adapter.getSessions(for: player)
    #expect(sessionsForPlayer.contains(sessionB), "Player sessions should contain session B")
    #expect(sessionsForPlayer.count == 1, "Player should have exactly one session (session A kicked)")

    let isConnectedA = await adapter.isConnected(sessionID: sessionA)
    #expect(!isConnectedA, "Session A should be disconnected")

    // Verify stale payload does not appear after duplicate-login kick path.
    let postJoinFrames = await transport.recordedFrames()
    var staleSeen = false
    for frame in postJoinFrames {
        if frameContainsString(frame.data, "stale-before-kick") {
            staleSeen = true
        }
    }
    #expect(!staleSeen, "Stale targeted event should not be delivered after duplicate login kick")

    await transport.clear()
    await adapter.sendEvent(
        AnyServerEvent(MembershipMessageEvent(message: "fresh-after-kick")),
        to: SwiftStateTree.EventTarget.player(player)
    )

    await adapter.syncNow()

    let frames = await transport.recordedFrames()
    #expect(!frames.isEmpty, "Expected outbound messages after sync")

    var containsFreshForActiveTarget = false
    var containsStale = false
    for frame in frames {
        if frameContainsString(frame.data, "stale-before-kick") { containsStale = true }
        if frameContainsString(frame.data, "fresh-after-kick") {
            switch frame.target {
            case .player(let pid) where pid == player:
                containsFreshForActiveTarget = true
            case .session(let sid) where sid == sessionB:
                containsFreshForActiveTarget = true
            default:
                break
            }
        }
    }

    #expect(!containsStale, "Stale targeted event should not be delivered after duplicate login kick")
    #expect(containsFreshForActiveTarget, "Fresh targeted event should be delivered to active target")
}
