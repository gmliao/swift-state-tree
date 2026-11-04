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

/// Frames sent to each session, whatever their encoding.
private actor MergedBroadcastRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }

    /// Frames that reach `sessionID`: addressed to it, to its player, or broadcast to everyone.
    /// (Server events go out as `.broadcast` on the json / opcodeJsonArray paths.)
    func frames(for sessionID: SessionID, playerID: PlayerID) -> [Data] {
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

    func clear() { sent.removeAll() }
}

/// String values appear as raw UTF-8 bytes in JSON text and in MessagePack `str` payloads,
/// so a unique marker can be found in any encoding without decoding the frame.
private func frames(_ frames: [Data], contain marker: String) -> Bool {
    let needle = Data(marker.utf8)
    return frames.contains { $0.range(of: needle) != nil }
}

/// Adapter sends are dispatched in unstructured tasks; wait (bounded) until both markers arrive.
private func waitForMarkers(
    _ markers: [String],
    session: SessionID,
    player: PlayerID,
    transport: MergedBroadcastRecordingTransport
) async -> [String: Bool] {
    var found: [String: Bool] = [:]
    for _ in 0..<100 {
        let sent = await transport.frames(for: session, playerID: player)
        found = Dictionary(uniqueKeysWithValues: markers.map { ($0, frames(sent, contain: $0)) })
        if found.values.allSatisfy({ $0 }) { break }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return found
}

/// Join one session, change the broadcast field and emit a broadcast event, then run one sync.
/// Returns which markers reached the session.
private func runBroadcastCycle(_ testCase: MergedBroadcastCase) async throws -> [String: Bool] {
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

    let found = await waitForMarkers([headline, announcement], session: session, player: player, transport: transport)
    return ["stateChange": found[headline] ?? false, "event": found[announcement] ?? false]
}

// MARK: - Tests

@Suite("TransportAdapter merged broadcast (#67)")
struct TransportAdapterMergedBroadcastTests {

    // Tests 1 and 2: on opcodeMessagePack this failed before #67 (nothing was sent);
    // json and opcodeJsonArray use the combined path and are covered here as well.
    @Test("Metrics off: broadcast change and broadcast event reach the session", arguments: metricsOffCases)
    func metricsOffDeliversBroadcast(_ testCase: MergedBroadcastCase) async throws {
        let delivered = try await runBroadcastCycle(testCase)
        #expect(delivered["stateChange"] == true, "broadcast field change not sent")
        #expect(delivered["event"] == true, "broadcast event not sent")
    }

    // Test 3: default configuration and metrics-on configurations keep delivering (regression guard).
    @Test("Metrics on: broadcast change and broadcast event reach the session", arguments: metricsOnCases)
    func metricsOnDeliversBroadcast(_ testCase: MergedBroadcastCase) async throws {
        let delivered = try await runBroadcastCycle(testCase)
        #expect(delivered["stateChange"] == true, "broadcast field change not sent")
        #expect(delivered["event"] == true, "broadcast event not sent")
    }
}
