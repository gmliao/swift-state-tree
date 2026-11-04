// Tests/SwiftStateTreeTransportTests/TransportAdapterMergedBroadcastTests.swift
//
// A broadcast field change and a broadcast server event must reach joined sessions on every
// encoding, whether or not change-object metrics are collected (#67). The opcodeMessagePack path
// merges both into one opcode-107 frame; the json / opcodeJsonArray paths send them separately.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test Land

@StateNodeBuilder
struct MergedBroadcastTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var headline: String = ""

    public init() {}
}

@Payload
struct MergedBroadcastSetHeadlineAction: ActionPayload {
    typealias Response = MergedBroadcastAck
    let headline: String
    let announcement: String
}

@Payload
struct MergedBroadcastAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct MergedBroadcastAnnouncementEvent: ServerEventPayload {
    let text: String
}

/// Tickless land: the action runs, and its emitted event is flushed to the adapter, before
/// `handleActionEnvelope` returns.
private func makeMergedBroadcastDefinition() -> LandDefinition<MergedBroadcastTestState> {
    Land("merged-broadcast-test", using: MergedBroadcastTestState.self) {
        ServerEvents {
            Register(MergedBroadcastAnnouncementEvent.self)
        }
        Rules {
            HandleAction(MergedBroadcastSetHeadlineAction.self) {
                (state: inout MergedBroadcastTestState, action: MergedBroadcastSetHeadlineAction, ctx: LandContext) in
                state.headline = action.headline
                ctx.emitEvent(MergedBroadcastAnnouncementEvent(text: action.announcement), to: .all)
                return MergedBroadcastAck(ok: true)
            }
        }
    }
}

// MARK: - Configurations

/// Transport configuration under test.
struct MergedBroadcastCase: Sendable, CustomTestStringConvertible {
    let encodingName: String
    let encoding: TransportEncodingConfig
    let autoDirtyTracking: Bool
    let changeObjectMetrics: Bool

    var testDescription: String {
        "\(encodingName), autoDirtyTracking=\(autoDirtyTracking), changeObjectMetrics=\(changeObjectMetrics)"
    }

    var envConfig: TransportEnvConfig {
        TransportEnvConfig(
            enableDirtyTracking: true,
            useSnapshotForSync: true,
            syncStrategy: .delta,
            enableChangeObjectMetrics: changeObjectMetrics,
            changeObjectMetricsLogEvery: 10,
            changeObjectMetricsEmaAlpha: 0.2,
            enableAutoDirtyTracking: autoDirtyTracking,
            autoDirtyOffThreshold: 0.55,
            autoDirtyOnThreshold: 0.30,
            autoDirtyRequiredConsecutiveSamples: 30,
            profilingConfig: nil
        )
    }
}

private let encodings: [(String, TransportEncodingConfig)] = [
    ("json", .json),
    ("jsonOpcode", .jsonOpcode),
    ("messagepack", .messagepack),
]

/// Test 1 + 2: metrics off (`AUTO_DIRTY_TRACKING=false`, change-object metrics at their default off).
private let metricsOffCases = encodings.map {
    MergedBroadcastCase(encodingName: $0.0, encoding: $0.1, autoDirtyTracking: false, changeObjectMetrics: false)
}

/// Test 3: default configuration (auto dirty tracking on) and metrics on via change-object metrics.
private let metricsOnCases = encodings.flatMap { name, encoding in
    [
        MergedBroadcastCase(encodingName: name, encoding: encoding, autoDirtyTracking: true, changeObjectMetrics: false),
        MergedBroadcastCase(encodingName: name, encoding: encoding, autoDirtyTracking: false, changeObjectMetrics: true),
    ]
}

// MARK: - Helpers

/// Frames sent to each session, whatever their encoding. Waiters are resumed on each `send`,
/// so tests wait for a condition instead of polling with sleeps.
private actor MergedBroadcastRecordingTransport: Transport {
    private struct Waiter {
        let id: UUID
        let isSatisfied: @Sendable ([(target: SwiftStateTreeTransport.EventTarget, data: Data)]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []
    private var waiters: [Waiter] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
        let ready = waiters.filter { $0.isSatisfied(sent) }
        waiters.removeAll { waiter in ready.contains { $0.id == waiter.id } }
        ready.forEach { $0.continuation.resume(returning: true) }
    }

    /// Frames that reach `sessionID`: addressed to it, to its player, or broadcast to everyone.
    /// (Server events go out as `.broadcast` on the json / opcodeJsonArray paths.)
    func frames(for sessionID: SessionID, playerID: PlayerID) -> [Data] {
        Self.frames(in: sent, for: sessionID, playerID: playerID)
    }

    static func frames(
        in sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)],
        for sessionID: SessionID,
        playerID: PlayerID
    ) -> [Data] {
        sent.compactMap { entry in
            switch entry.target {
            case .session(let id) where id == sessionID: return entry.data
            case .player(let id) where id == playerID: return entry.data
            case .broadcast: return entry.data
            case .broadcastExcept(let excluded) where excluded != sessionID: return entry.data
            default: return nil
            }
        }
    }

    /// Resume when the frames reaching the session satisfy `condition`, or return false after
    /// `timeout` (a safety net so a missing send fails instead of hanging).
    func waitUntil(
        session: SessionID,
        player: PlayerID,
        timeout: Duration = .seconds(10),
        _ condition: @escaping @Sendable ([Data]) -> Bool
    ) async -> Bool {
        let isSatisfied: @Sendable ([(target: SwiftStateTreeTransport.EventTarget, data: Data)]) -> Bool = { sent in
            condition(Self.frames(in: sent, for: session, playerID: player))
        }
        if isSatisfied(sent) { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, isSatisfied: isSatisfied, continuation: continuation))
            Task {
                try? await Task.sleep(for: timeout)
                await self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    func clear() { sent.removeAll() }
}

/// String values appear as raw UTF-8 bytes in JSON text and in MessagePack `str` payloads,
/// so a unique marker can be found in any encoding without decoding the frame.
private func frameCount(_ frames: [Data], containing marker: String) -> Int {
    let needle = Data(marker.utf8)
    return frames.filter { $0.range(of: needle) != nil }.count
}

/// Result of one broadcast cycle as seen by the session.
private struct BroadcastDelivery {
    let stateChangeDelivered: Bool
    let eventDelivered: Bool
    /// Frames containing the event after a later idle sync (1 when there is no duplicate send).
    let eventFrameCount: Int
}

/// Join one session, change the broadcast field and emit a broadcast event, then run one sync,
/// followed by an idle sync so a duplicate event send would show up.
private func runBroadcastCycle(_ testCase: MergedBroadcastCase) async throws -> BroadcastDelivery {
    let transport = MergedBroadcastRecordingTransport()
    let keeper = LandKeeper<MergedBroadcastTestState>(
        definition: makeMergedBroadcastDefinition(),
        initialState: MergedBroadcastTestState()
    )
    let adapter = TransportAdapter<MergedBroadcastTestState>(
        keeper: keeper,
        transport: transport,
        landID: "merged-broadcast-test",
        transportEnvConfig: testCase.envConfig,
        encodingConfig: testCase.encoding
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)

    let session = SessionID("s1")
    let client = ClientID("c1")
    let player = PlayerID("p1")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: player)
    await adapter.syncNow()
    await adapter.waitForOutboundDrain()
    await transport.clear()

    let headline = "headline-marker-6c1f"
    let announcement = "announcement-marker-93ab"
    _ = try await keeper.handleActionEnvelope(
        ActionEnvelope(
            typeIdentifier: String(describing: MergedBroadcastSetHeadlineAction.self),
            payload: AnyCodable(MergedBroadcastSetHeadlineAction(headline: headline, announcement: announcement))
        ),
        playerID: player,
        clientID: client,
        sessionID: session
    )
    await adapter.syncNow()
    await adapter.waitForOutboundDrain()

    let stateChangeDelivered = await transport.waitUntil(session: session, player: player) {
        frameCount($0, containing: headline) > 0
    }
    let eventDelivered = await transport.waitUntil(session: session, player: player) {
        frameCount($0, containing: announcement) > 0
    }

    // Nothing is dirty and no event is pending now; this sync must not resend the event.
    // Its sends (if any) are dispatched in tasks, so give them a few turns to land.
    await adapter.syncNow()
    await adapter.waitForOutboundDrain()
    for _ in 0..<20 { await Task.yield() }
    let eventFrameCount = frameCount(await transport.frames(for: session, playerID: player), containing: announcement)

    return BroadcastDelivery(
        stateChangeDelivered: stateChangeDelivered,
        eventDelivered: eventDelivered,
        eventFrameCount: eventFrameCount
    )
}

// MARK: - Tests

@Suite("TransportAdapter merged broadcast (#67)")
struct TransportAdapterMergedBroadcastTests {

    // Tests 1 and 2: on opcodeMessagePack this failed before #67 (nothing was sent);
    // json and opcodeJsonArray use the combined path and are covered here as well.
    @Test("Metrics off: broadcast change and broadcast event reach the session", arguments: metricsOffCases)
    func metricsOffDeliversBroadcast(_ testCase: MergedBroadcastCase) async throws {
        let delivered = try await runBroadcastCycle(testCase)
        #expect(delivered.stateChangeDelivered, "broadcast field change not sent")
        #expect(delivered.eventDelivered, "broadcast event not sent")
        #expect(delivered.eventFrameCount == 1, "broadcast event sent \(delivered.eventFrameCount) times")
    }

    // Test 3: default configuration and metrics-on configurations keep delivering (regression guard).
    @Test("Metrics on: broadcast change and broadcast event reach the session", arguments: metricsOnCases)
    func metricsOnDeliversBroadcast(_ testCase: MergedBroadcastCase) async throws {
        let delivered = try await runBroadcastCycle(testCase)
        #expect(delivered.stateChangeDelivered, "broadcast field change not sent")
        #expect(delivered.eventDelivered, "broadcast event not sent")
        #expect(delivered.eventFrameCount == 1, "broadcast event sent \(delivered.eventFrameCount) times")
    }
}
