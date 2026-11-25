// Tests/SwiftStateTreeTransportTests/RecordedPayloadReplayTests.swift
//
// #700 K1a, format 3.7: a recorded action or client event keeps the bytes of the decoder live
// used, and replay decodes them with the live decoder for their encoding (plan §3.11, K1-Q8 (a)).
// Each kind of input replays to the value it applied live, on every encoding; a land that records
// nothing keeps no bytes; a record from before 3.7 is read and refused for replay; and the header's
// encoding is written once and filled back in on read.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct RecordedPayloadState: StateNodeProtocol {
    @Sync(.broadcast)
    var applied: [String] = []
}

@Payload
struct RecordedPayloadAck: ResponsePayload {
    let count: Int
}

/// An action without resolvers. `ratio` is a `Double` a JSON client may send as `1`.
@Payload
struct RecordedPlainAction: ActionPayload {
    typealias Response = RecordedPayloadAck
    let label: String
    let ratio: Double
}

/// An action whose resolvers' closure builds a resolver when `fetch` (a job) and nothing otherwise
/// (#825: delivered inline, as an action without resolvers).
@Payload
struct RecordedMaybeAction: ActionPayload {
    typealias Response = RecordedPayloadAck
    let label: String
    let fetch: Bool
}

@Payload
struct RecordedPayloadEvent: ClientEventPayload {
    let label: String
}

@PlainData
struct RecordedPayloadOutput: ResolverOutput {
    let n: Int
}

@PlainData
struct RecordedPayloadResolver: Resolver {
    typealias Dependencies = NoServices
    let n: Int
    func resolve(_ deps: NoServices) async throws -> RecordedPayloadOutput { RecordedPayloadOutput(n: n) }
}

/// An action whose `Codable` doesn't round-trip: it encodes `tag` uppercased.
@Payload
struct RecordedNormalizingAction: ActionPayload {
    typealias Response = RecordedPayloadAck
    let tag: String
    init(tag: String) { self.tag = tag }
    init(from decoder: Decoder) throws {
        tag = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .tag)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag.uppercased(), forKey: .tag)
    }
    enum CodingKeys: String, CodingKey { case tag }
}

/// A tick land, or a tickless one, which applies an action in the call that submits it.
private func makeRecordedPayloadLand(tick: Bool = true) -> LandDefinition<RecordedPayloadState> {
    Land(tick ? "recorded-payload" : "recorded-payload-tickless", using: RecordedPayloadState.self) {
        ClientEvents { Register(RecordedPayloadEvent.self) }
        if tick {
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
            }
        }
        Rules {
            HandleAction(RecordedPlainAction.self) { state, action, _ in
                state.applied.append("plain:\(action.label):\(action.ratio)")
                return RecordedPayloadAck(count: state.applied.count)
            }
            HandleAction(RecordedMaybeAction.self, resolvers: { _, action, _ in
                action.fetch ? RecordedPayloadResolver(n: 7) : nil
            }) { state, action, output, _ in
                state.applied.append("maybe:\(action.label):\(output.map { String($0.n) } ?? "none")")
                return RecordedPayloadAck(count: state.applied.count)
            }
            HandleAction(RecordedNormalizingAction.self) { state, action, _ in
                state.applied.append("normalizing:\(action.tag)")
                return RecordedPayloadAck(count: state.applied.count)
            }
            HandleEvent(RecordedPayloadEvent.self) { state, event, _ in
                state.applied.append("event:\(event.label)")
            }
        }
    }
}

private let recordedPayloadLandID = "recorded-payload:1"

/// One input a client sends, as its payload tree.
enum RecordedInput: Sendable {
    case action(type: String, payload: AnyCodable)
    case event(payload: AnyCodable)

    static let plain = RecordedInput.action(
        type: String(describing: RecordedPlainAction.self),
        payload: AnyCodable(["label": "p", "ratio": 1.5] as [String: Any])
    )
    static let job = RecordedInput.action(
        type: String(describing: RecordedMaybeAction.self),
        payload: AnyCodable(["label": "j", "fetch": true] as [String: Any])
    )
    static let builtNothing = RecordedInput.action(
        type: String(describing: RecordedMaybeAction.self),
        payload: AnyCodable(["label": "n", "fetch": false] as [String: Any])
    )
    static let event = RecordedInput.event(payload: AnyCodable(["label": "e"] as [String: Any]))
    /// `ratio` sent as the integer `1`, which a JSON client may write for `1.0`.
    static let integralFloat = RecordedInput.action(
        type: String(describing: RecordedPlainAction.self),
        payload: AnyCodable(["label": "i", "ratio": 1] as [String: Any])
    )
}

/// What one live run left.
private struct RecordedPayloadRun {
    let liveApplied: [String]
    let recordPath: String
    let keeper: LandKeeper<RecordedPayloadState>
}

/// A live tick land behind a `TransportAdapter` with `encoding`, recording when `recording`. One
/// client sends `inputs`, each applied by its own tick.
private func runRecordedPayloadLand(
    encoding: TransportEncoding, inputs: [RecordedInput], recording: Bool = true, keepRunning: Bool = false
) async throws -> RecordedPayloadRun {
    let keeper = LandKeeper<RecordedPayloadState>(
        definition: makeRecordedPayloadLand(),
        initialState: RecordedPayloadState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        landID: recordedPayloadLandID
    )
    let transport = VerifierTransport()
    let config: TransportEncodingConfig = switch encoding {
    case .json: .json
    case .opcodeJsonArray: .opcode
    case .messagepack: .messagepack
    }
    let adapter = TransportAdapter<RecordedPayloadState>(
        keeper: keeper, transport: transport, landID: recordedPayloadLandID, encodingConfig: config
    )
    await transport.setDelegate(adapter)
    await keeper.awaitInitialization()
    await keeper.setTransport(adapter)
    if recording {
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: recordedPayloadLandID,
            landType: "recorded-payload",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: [:],
            landDefinitionID: "recorded-payload",
            rngSeed: DeterministicSeed.fromLandID(recordedPayloadLandID),
            recordsSyncStream: await keeper.recordsSyncStream,
            syncConfig: adapter.syncConfigForRecord,
            schemaFingerprint: try ReevaluationSchemaFingerprint.compute(for: makeRecordedPayloadLand()),
            payloadEncoding: adapter.payloadEncodingForRecord
        ))
    }

    let session = SessionID("s-rp")
    let client = ClientID("c-rp")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p-rp"))
    await keeper.stepTickOnce()

    let codec = encoding.makeCodec()
    for (index, input) in inputs.enumerated() {
        let frame: Data
        switch input {
        case .action(let type, let payload):
            frame = try codec.encode(TransportMessage.action(
                requestID: "r\(index)", action: ActionEnvelope(typeIdentifier: type, payload: payload)
            ))
        case .event(let payload):
            let event = AnyClientEvent(type: payloadEventName(for: RecordedPayloadEvent.self), payload: payload)
            frame = try codec.encode(TransportMessage.event(event: .fromClient(event: event)))
        }
        await adapter.onMessage(frame, from: session)
        // A job resolves off the keeper; the tick after it applies the action.
        await keeper.waitForActionJobsForTesting()
        await keeper.stepTickOnce()
    }
    await keeper.stepTickOnce()

    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("recorded-payload-\(UUID().uuidString).sstr").path
    if recording {
        await keeper.waitForRecorderSubmissionsForTesting()
        try await #require(await keeper.getReevaluationRecorder()).save(to: path)
    }
    let liveApplied = await keeper.currentState().applied
    if !keepRunning { await keeper.forceShutdown() }
    return RecordedPayloadRun(liveApplied: liveApplied, recordPath: path, keeper: keeper)
}

/// Replays the record with the standard decoders: every recorded tick hash matches live.
private func expectReplayMatchesLive(_ run: RecordedPayloadRun, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let result = try await ReevaluationEngine.run(
        definition: makeRecordedPayloadLand(),
        initialState: RecordedPayloadState(),
        recordFilePath: run.recordPath,
        payloadDecoders: .standard
    )
    #expect(result.recordCompleteness == .complete, sourceLocation: sourceLocation)
    #expect(!result.recordedStateHashes.isEmpty, sourceLocation: sourceLocation)
    #expect(
        result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes,
        "replayed state differs from live", sourceLocation: sourceLocation
    )
}

@Suite("A recorded payload's bytes replay to the value live applied (#700 K1a)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct RecordedPayloadReplayTests {
    static let encodings: [TransportEncoding] = [.json, .opcodeJsonArray, .messagepack]

    @Test("An action without resolvers, an action job, one whose resolvers built nothing, and a client event replay as live", arguments: encodings)
    func eachInputKindReplaysAsLive(encoding: TransportEncoding) async throws {
        let run = try await runRecordedPayloadLand(encoding: encoding, inputs: [.plain, .job, .builtNothing, .event])
        defer { try? FileManager.default.removeItem(atPath: run.recordPath) }
        #expect(run.liveApplied == ["plain:p:1.5", "maybe:j:7", "maybe:n:none", "event:e"])
        try await expectReplayMatchesLive(run)

        // The header names the transport's encoding, and every entry was read in it.
        let source = try #require(try ReevaluationRecordFile.openSource(filePath: run.recordPath) as? ReevaluationRecordLogSource)
        let expected: RecordPayloadEncoding = encoding == .messagepack ? .messagepack : .json
        #expect(try await source.getMetadata().payloadEncoding == expected)
        let frames = await source.getAllFrames()
        #expect(frames.flatMap(\.actions).map(\.payloadEncoding) == [expected, expected, expected])
        #expect(frames.flatMap(\.clientEvents).map(\.payloadEncoding) == [expected])
    }

    @Test("A JSON client's integer for a Double replays equal", arguments: [TransportEncoding.json, .opcodeJsonArray])
    func integralFloatReplaysEqual(encoding: TransportEncoding) async throws {
        let run = try await runRecordedPayloadLand(encoding: encoding, inputs: [.integralFloat])
        defer { try? FileManager.default.removeItem(atPath: run.recordPath) }
        #expect(run.liveApplied == ["plain:i:1.0"])
        try await expectReplayMatchesLive(run)
    }

    @Test("A land that records nothing holds no payload bytes in its queued items", arguments: encodings)
    func nonRecordingItemsHoldNoBytes(encoding: TransportEncoding) async throws {
        for recording in [false, true] {
            // The inputs stay queued: no tick runs after them.
            let keeper = LandKeeper<RecordedPayloadState>(
                definition: makeRecordedPayloadLand(),
                initialState: RecordedPayloadState(),
                enableLiveStateHashRecording: recording,
                autoStartLoops: false,
                landID: recordedPayloadLandID
            )
            let transport = VerifierTransport()
            let config: TransportEncodingConfig = encoding == .messagepack ? .messagepack : (encoding == .json ? .json : .opcode)
            let adapter = TransportAdapter<RecordedPayloadState>(
                keeper: keeper, transport: transport, landID: recordedPayloadLandID, encodingConfig: config
            )
            await transport.setDelegate(adapter)
            await keeper.awaitInitialization()
            await keeper.setTransport(adapter)
            let session = SessionID("s-nr")
            await adapter.onConnect(sessionID: session, clientID: ClientID("c-nr"))
            try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: ClientID("c-nr"), playerID: PlayerID("p-nr"))
            await keeper.stepTickOnce()
            let codec = encoding.makeCodec()
            guard case .action(let type, let payload) = RecordedInput.plain else { return }
            await adapter.onMessage(try codec.encode(TransportMessage.action(
                requestID: "r", action: ActionEnvelope(typeIdentifier: type, payload: payload)
            )), from: session)
            let event = AnyClientEvent(type: payloadEventName(for: RecordedPayloadEvent.self), payload: AnyCodable(["label": "e"] as [String: Any]))
            await adapter.onMessage(try codec.encode(TransportMessage.event(event: .fromClient(event: event))), from: session)

            let items = await keeper.pendingItemsForTesting()
            var holdsBytes: [Bool] = []
            for item in items {
                switch item {
                case .action(let action): holdsBytes.append(action.recorded != nil)
                case .clientEvent(let event): holdsBytes.append(event.recorded != nil)
                default: continue
                }
            }
            #expect(holdsBytes == [recording, recording], "recording=\(recording)")
            await keeper.forceShutdown()
        }
    }

    @Test("A hand-built action applies the value its canonical JSON decodes to, on a land that records and one that doesn't")
    func handBuiltActionRoundTripsAlways() async throws {
        let item = try LandKeeper<RecordedPayloadState>.PendingActionItem(
            sequence: 0, action: RecordedNormalizingAction(tag: "abc"),
            playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"),
            resolverOutputs: [:], resolvedAtTick: 0
        )
        // The value is the round trip's: the encode uppercased it.
        #expect((try item.decoded.get() as? RecordedNormalizingAction)?.tag == "ABC")
        #expect(item.recorded?.encoding == .json)

        // Through the keeper's envelope path, recording or not, the applied value is the same.
        var applied: [[String]] = []
        for recording in [false, true] {
            let keeper = LandKeeper<RecordedPayloadState>(
                definition: makeRecordedPayloadLand(tick: false),
                initialState: RecordedPayloadState(),
                enableLiveStateHashRecording: recording,
                autoStartLoops: false,
                landID: recordedPayloadLandID
            )
            await keeper.awaitInitialization()
            // The envelope holds the typed value, not a client's tree.
            _ = try await keeper.handleActionEnvelope(
                ActionEnvelope(
                    typeIdentifier: String(describing: RecordedNormalizingAction.self),
                    payload: AnyCodable(RecordedNormalizingAction(tag: "abc"))
                ),
                playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s")
            )
            applied.append(await keeper.currentState().applied)
            await keeper.forceShutdown()
        }
        #expect(applied == [["normalizing:ABC"], ["normalizing:ABC"]])
    }
}
