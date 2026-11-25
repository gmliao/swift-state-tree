// Tests/SwiftStateTreeTransportTests/RecordKeyNormalizationTests.swift
//
// A payload key in another Unicode normalization than its `CodingKey` (NFD "e\u{301}" against
// NFC "\u{E9}") replays as it applied live, on every encoding, for an action and a client event.
//
// Live, the decoders match keys with `String ==` (canonical equivalence). The record keeps the
// client's spelling byte for byte (pinned below). Replay rebuilds a recorded action or client
// event from its tree with `AnyCodablePayloadSource`, a JSON round trip that matches keys with
// `String ==` too. A replay decoder that matched keys by their bytes (as `CanonicalMessagePack`'s
// keyed decoder does) would refuse the NFD key, and the replayed state would differ from live:
// the class #806 described. These tests guard against it, in particular when replay moves to
// decoding recorded bytes (#700 K1a): the decoder it uses must match keys as live does. The NFC
// case is the control.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct KeyNormalizationState: StateNodeProtocol {
    @Sync(.broadcast)
    var applied: [String] = []
}

@Payload
struct KeyNormalizationResponse: ResponsePayload {
    let count: Int
}

/// One field whose `CodingKey` is NFC "café".
@Payload
struct KeyNormalizationAction: ActionPayload {
    typealias Response = KeyNormalizationResponse
    let label: String
    enum CodingKeys: String, CodingKey {
        case label = "caf\u{E9}"
    }
}

@Payload
struct KeyNormalizationEvent: ClientEventPayload {
    let label: String
    enum CodingKeys: String, CodingKey {
        case label = "caf\u{E9}"
    }
}

/// The two spellings a client can send for the field's key.
enum KeySpelling: String, Sendable, CaseIterable, CustomTestStringConvertible {
    /// The `CodingKey`'s own bytes (the control).
    case nfc = "caf\u{E9}"
    /// Canonically equivalent, other bytes: `String ==` matches it, a byte comparison doesn't.
    case nfd = "cafe\u{301}"
    var testDescription: String { self == .nfc ? "NFC key" : "NFD key" }
}

private let keyNormalizationLandID = "key-normalization:1"

private func makeKeyNormalizationLand() -> LandDefinition<KeyNormalizationState> {
    Land("key-normalization", using: KeyNormalizationState.self) {
        ClientEvents { Register(KeyNormalizationEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
        Rules {
            HandleAction(KeyNormalizationAction.self) { state, action, _ in
                state.applied.append("action:\(action.label)")
                return KeyNormalizationResponse(count: state.applied.count)
            }
            HandleEvent(KeyNormalizationEvent.self) { state, event, _ in
                state.applied.append("event:\(event.label)")
            }
        }
    }
}

/// What one live run left: the live state and the saved record's path.
private struct KeyNormalizationRun {
    let liveApplied: [String]
    let recordPath: String
    /// The UTF-8 bytes of each key of the input's payload, as the saved record holds them.
    let recordedKeyBytes: [[UInt8]]
}

/// A live tick land behind a `TransportAdapter` with `encoding`, recording. One client sends an
/// action (or a client event) whose field key is spelled `spelling`, then the tick applies it.
private func recordKeyNormalizationRun(
    encoding: TransportEncoding, spelling: KeySpelling, clientEvent: Bool
) async throws -> KeyNormalizationRun {
    let keeper = LandKeeper<KeyNormalizationState>(
        definition: makeKeyNormalizationLand(),
        initialState: KeyNormalizationState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: keyNormalizationLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let transport = VerifierTransport()
    let config: TransportEncodingConfig = switch encoding {
    case .json: .json
    case .opcodeJsonArray: .opcode
    case .messagepack: .messagepack
    }
    let adapter = TransportAdapter<KeyNormalizationState>(
        keeper: keeper, transport: transport, landID: keyNormalizationLandID, encodingConfig: config
    )
    await transport.setDelegate(adapter)
    await keeper.awaitInitialization()
    await keeper.setTransport(adapter)
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: keyNormalizationLandID,
        landType: "key-normalization",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "key-normalization",
        rngSeed: DeterministicSeed.fromLandID(keyNormalizationLandID),
        recordsSyncStream: await keeper.recordsSyncStream,
        syncConfig: adapter.syncConfigForRecord
    ))

    // A tick land joins through the router's path, as ActionJobReplayOrderTests' does.
    let session = SessionID("s-key")
    let client = ClientID("c-key")
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p-key"))
    await keeper.stepTickOnce()

    let codec = encoding.makeCodec()
    let payload = AnyCodable([spelling.rawValue: "x"] as [String: Any])
    let frame: Data
    if clientEvent {
        let event = AnyClientEvent(type: payloadEventName(for: KeyNormalizationEvent.self), payload: payload)
        frame = try codec.encode(TransportMessage.event(event: .fromClient(event: event)))
    } else {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: KeyNormalizationAction.self), payload: payload)
        frame = try codec.encode(TransportMessage.action(requestID: "a-key", action: envelope))
    }
    await adapter.onMessage(frame, from: session)
    await keeper.stepTickOnce()
    await keeper.stepTickOnce()
    // The frames go to a transport that drops them; the record is what this reads.
    await keeper.waitForRecorderSubmissionsForTesting()

    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("key-normalization-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    let liveApplied = await keeper.currentState().applied
    await keeper.forceShutdown()

    let source = try #require(try ReevaluationRecordFile.openSource(filePath: path) as? ReevaluationRecordLogSource)
    let frames = await source.getAllFrames()
    let recordedPayload: AnyCodable? = clientEvent ? frames.flatMap(\.clientEvents).first?.payload : frames.flatMap(\.actions).first?.payload
    let map = try #require(recordedPayload?.base as? [String: Any], "the input is recorded with a map payload")
    return KeyNormalizationRun(liveApplied: liveApplied, recordPath: path, recordedKeyBytes: map.keys.map { Array($0.utf8) })
}

/// Replays the record and checks it against live: every recorded tick hash matches.
private func replayMatchesLive(_ run: KeyNormalizationRun) async throws {
    let result = try await ReevaluationEngine.run(
        definition: makeKeyNormalizationLand(),
        initialState: KeyNormalizationState(),
        recordFilePath: run.recordPath
    )
    #expect(result.recordCompleteness == .complete)
    #expect(!result.recordedStateHashes.isEmpty)
    #expect(
        result.tickHashes.filter { result.recordedStateHashes[$0.key] != nil } == result.recordedStateHashes,
        "replayed state differs from live"
    )
}

@Suite("A payload key in another Unicode normalization replays as it applied live (guards #806's class)", .timeLimit(.minutes(1)))
struct RecordKeyNormalizationTests {
    static let encodings: [TransportEncoding] = [.json, .opcodeJsonArray, .messagepack]

    @Test("Live matches the key in either spelling, on every encoding", arguments: encodings, KeySpelling.allCases)
    func liveMatchesEitherSpelling(encoding: TransportEncoding, spelling: KeySpelling) async throws {
        for clientEvent in [false, true] {
            let run = try await recordKeyNormalizationRun(encoding: encoding, spelling: spelling, clientEvent: clientEvent)
            defer { try? FileManager.default.removeItem(atPath: run.recordPath) }
            #expect(run.liveApplied == [clientEvent ? "event:x" : "action:x"])
            // The record keeps the client's spelling, byte for byte: the replay tests below read
            // that spelling, not a normalized one.
            #expect(run.recordedKeyBytes == [Array(spelling.rawValue.utf8)], "clientEvent=\(clientEvent)")
        }
    }

    @Test("An NFC key replays as live (the control)", arguments: encodings)
    func nfcKeyReplays(encoding: TransportEncoding) async throws {
        for clientEvent in [false, true] {
            let run = try await recordKeyNormalizationRun(encoding: encoding, spelling: .nfc, clientEvent: clientEvent)
            defer { try? FileManager.default.removeItem(atPath: run.recordPath) }
            try await replayMatchesLive(run)
        }
    }

    @Test("An NFD key replays as live (guards #806's class)", arguments: encodings)
    func nfdKeyReplays(encoding: TransportEncoding) async throws {
        for clientEvent in [false, true] {
            let run = try await recordKeyNormalizationRun(encoding: encoding, spelling: .nfd, clientEvent: clientEvent)
            defer { try? FileManager.default.removeItem(atPath: run.recordPath) }
            try await replayMatchesLive(run)
        }
    }
}
