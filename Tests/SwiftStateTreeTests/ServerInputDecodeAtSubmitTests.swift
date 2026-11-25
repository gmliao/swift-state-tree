// Tests/SwiftStateTreeTests/ServerInputDecodeAtSubmitTests.swift
//
// A server input is decoded once, from its record form: at submit live, when the item is built
// in replay. Live applies that value, and the record keeps the tree it was decoded from, never a
// re-encode of the value. An input whose record form doesn't decode back to its type is refused
// at submit, after the in-flight cap and before its sequence is taken.

import Foundation
import Testing
@testable import SwiftStateTree

/// Writes its field under one key and reads it from another: its record form doesn't decode back.
@Payload
struct SIOneWay: ServerInputPayload {
    let tag: String

    init(tag: String) { self.tag = tag }

    private enum Keys: String, CodingKey {
        case written, read
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(tag, forKey: .written)
    }

    init(from decoder: Decoder) throws {
        tag = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .read)
    }
}

/// Counts the decodes of `SICounted` in this task.
enum SIDecodeCount {
    final class Box: @unchecked Sendable { var count = 0 }
    @TaskLocal static var box: Box?
}

/// Counts each decode, so a test can tell how often an input was decoded.
@Payload
struct SICounted: ServerInputPayload {
    let tag: String

    init(tag: String) { self.tag = tag }

    private enum CodingKeys: String, CodingKey {
        case tag
    }

    init(from decoder: Decoder) throws {
        SIDecodeCount.box?.count += 1
        tag = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .tag)
    }
}

/// An `Int??` holding `.some(nil)`: the tree holds an explicit nil, the decoded value is `.none`,
/// and its re-encode leaves the key out. `@Payload` refuses optional fields and the record schema
/// fingerprint can't list this type's fields, so it is declared only on a land that is recorded,
/// never replayed.
@PlainData
struct SIMaybe: ServerInputPayload {
    let value: Int??
}

private func makeDecodeDefinition() -> LandDefinition<ServerInputTestState> {
    Land("server-input-decode", using: ServerInputTestState.self) {
        Rules {
            HandleServerInput(SIProgress.self) { state, input, _ in
                state.log.append("progress:\(input.tag)")
            }
            HandleServerInput(SIOneWay.self) { state, input, _ in
                state.log.append("one-way:\(input.tag)")
            }
            HandleServerInput(SICounted.self) { state, input, _ in
                state.log.append("counted:\(input.tag)")
            }
            HandleServerInput(SIDated.self) { state, input, _ in
                state.log.append("dated:\(input.label.text)")
            }
            HandleServerInput(SIMaybe.self) { state, input, _ in
                state.log.append("maybe:\(String(describing: input.value))")
            }
        }
        Lifetime {
            // Hourly and stepped by hand: no real tick runs during a test.
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

private func makeDecodeKeeper() async throws -> LandKeeper<ServerInputTestState> {
    let definition = makeDecodeDefinition()
    let landID = "\(definition.id):\(UUID().uuidString)"
    let keeper = LandKeeper<ServerInputTestState>(
        definition: definition,
        initialState: ServerInputTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: landID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID,
        landType: definition.id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: definition.id,
        rngSeed: DeterministicSeed.fromLandID(landID),
        version: ReevaluationRecordVersion.current
    ))
    return keeper
}

private func recordedServerInputs(_ keeper: LandKeeper<ServerInputTestState>) async throws -> [ReevaluationRecordedServerInput] {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    return await recorder.getAllFrames().flatMap(\.serverInputs)
}

private func sequence(_ outcome: ServerInputOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int64 {
    guard case let .accepted(sequence) = outcome else {
        Issue.record("expected accepted, got \(outcome)", sourceLocation: sourceLocation)
        throw SIError()
    }
    return sequence
}

@Suite("Server inputs are decoded once, at submit, from their record form", .timeLimit(.minutes(1)))
struct ServerInputDecodeAtSubmitTests {
    @Test("An input whose record form doesn't decode back is refused at submit: nothing queued or recorded, no sequence taken")
    func undecodableIsRefusedAtSubmit() async throws {
        let keeper = try await makeDecodeKeeper()
        // It has a record form: only the decode back refuses it.
        _ = try ServerInputCodec.recordedForm(of: SIOneWay(tag: "x"))
        let first = try sequence(await keeper.submitServerInput(SIProgress(tag: "1")))
        #expect(await keeper.submitServerInput(SIOneWay(tag: "x")) == .refused(.unencodable))
        let second = try sequence(await keeper.submitServerInput(SIProgress(tag: "2")))
        #expect(second == first + 1, "the refused input took no sequence")
        #expect(await keeper.serverInputsInFlightForTesting() == 2)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == ["progress:1", "progress:2"])
        #expect(try await recordedServerInputs(keeper).map(\.sequence) == [first, second])
    }

    @Test("At the in-flight cap, an input that wouldn't decode back is refused for the cap: the cap is checked first")
    func capComesBeforeTheDecode() async throws {
        let keeper = try await makeDecodeKeeper()
        await keeper.setServerInputMaxInFlightForTesting(1)
        _ = try sequence(await keeper.submitServerInput(SIProgress(tag: "1")))
        #expect(await keeper.submitServerInput(SIOneWay(tag: "x")) == .refused(.overCap))
        // An input refused for the cap costs no decode.
        let decodes = SIDecodeCount.Box()
        await SIDecodeCount.$box.withValue(decodes) {
            #expect(await keeper.submitServerInput(SICounted(tag: "over")) == .refused(.overCap))
        }
        #expect(decodes.count == 0)
        #expect(await keeper.serverInputCapRejections == 2)
    }

    @Test("Under a freeze the decode happens at submit: a failing input is refused, a held one is decoded once across freeze, resume and apply")
    func freezeDecodesAtSubmitOnce() async throws {
        let keeper = try await makeDecodeKeeper()
        await keeper.stepTickOnce()
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        #expect(await keeper.submitServerInput(SIOneWay(tag: "x")) == .refused(.unencodable))
        let decodes = SIDecodeCount.Box()
        try await SIDecodeCount.$box.withValue(decodes) {
            _ = try sequence(await keeper.submitServerInput(SICounted(tag: "held")))
            #expect(decodes.count == 1, "decoded at submit, before it is held")
            await keeper.debugResume(generation: 1)
            await keeper.stepTickOnce()
            await keeper.stepTickOnce()
        }
        #expect(await keeper.currentState().log == ["counted:held"])
        #expect(decodes.count == 1, "the resume and the apply don't decode it again")
    }

    @Test("Replay decodes a recorded input once, when it reads the record, and applies that value")
    func replayDecodesOnce() async throws {
        let keeper = try await makeDecodeKeeper()
        _ = try sequence(await keeper.submitServerInput(SICounted(tag: "r")))
        await keeper.stepTickOnce()
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        let tickId = try #require(frames.first { !$0.serverInputs.isEmpty }?.tickId)
        let metadata = try #require(await recorder.getMetadata())
        let replay = LandKeeper<ServerInputTestState>(
            definition: makeDecodeDefinition(),
            initialState: ServerInputTestState(),
            mode: .reevaluation,
            reevaluationSource: JSONReevaluationSource(metadata: metadata, frames: frames),
            autoStartLoops: false
        )
        let decodes = SIDecodeCount.Box()
        await SIDecodeCount.$box.withValue(decodes) {
            for _ in 0...tickId { await replay.stepTickOnce() }
        }
        #expect(await replay.currentState().log == ["counted:r"])
        #expect(decodes.count == 1, "decoded when the item is built, not again at apply")
    }

    @Test("The record holds the canonical bytes of the tree the input was decoded from, even where the decoded value re-encodes differently")
    func serverInputRecordFormUnchanged() async throws {
        let keeper = try await makeDecodeKeeper()
        let inputs: [(name: String, input: any ServerInputPayload, reencodeDiffers: Bool)] = [
            ("plain", SIProgress(tag: "p"), false),
            ("normalizing Codable", SIDated(label: SILowered("ABC"), ratio: 2.0, count: 3), true),
            ("Int?? holding .some(nil)", SIMaybe(value: .some(nil)), true),
        ]
        var expected: [[UInt8]] = []
        for (name, input, reencodeDiffers) in inputs {
            let tree = try CanonicalMessagePack.decode(AnyCodable.self, from: CanonicalMessagePack.encode(AnyCodable(input)))
            let treeBytes = try CanonicalMessagePack.encode(tree)
            #expect(Array(try ServerInputCodec.recordedForm(of: input)) == treeBytes, "\(name)")
            if reencodeDiffers {
                // The fixture can tell a record of the tree from a record of the re-encoded value.
                let handler = try #require(makeDecodeDefinition().serverInputHandlers[String(describing: type(of: input))])
                let reencoded = try CanonicalMessagePack.encode(AnyCodable(try handler.decode(Data(treeBytes))))
                #expect(reencoded != treeBytes, "\(name): the re-encode equals the tree")
            }
            expected.append(treeBytes)
            _ = try sequence(await keeper.submitServerInput(input))
        }
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == ["progress:p", "dated:abc", "maybe:nil"])
        // A keeper without a transport has a `json` header: the bytes are MessagePack anyway
        // (K1-Q4 (a)).
        let recorded = try await recordedServerInputs(keeper).map { Array($0.payload) }
        #expect(recorded == expected)
    }

    @Test("A normalizing Codable replays from a saved record to the value live applied")
    func normalizingInputReplaysLiveValue() async throws {
        let keeper = try await makeDecodeKeeper()
        _ = try sequence(await keeper.submitServerInput(SIDated(label: SILowered("ABC"), ratio: 2.0, count: 3)))
        await keeper.stepTickOnce()
        let live = await keeper.currentState().log
        #expect(live == ["dated:abc"])
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("si-normalizing-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await recorder.save(to: path)
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let replay = LandKeeper<ServerInputTestState>(
            definition: makeDecodeDefinition(),
            initialState: ServerInputTestState(),
            mode: .reevaluation,
            reevaluationSource: source,
            autoStartLoops: false
        )
        let maxTickId = try await source.getMaxTickId()
        for _ in 0...max(maxTickId, 0) { await replay.stepTickOnce() }
        #expect(await replay.currentState().log == live)
    }

    @Test("A failed decode is kept with its error and rebuilt when the input is applied")
    func decodeFailureRebuildsItsError() throws {
        // A field of the wrong type: the record codec's own error, kept by its text.
        let wrongType = AnyCodable(["tag": "bad", "n": "five"] as [String: Any])
        var thrown: (any Error)?
        do {
            _ = try ServerInputCodec.decode(ReplaySIDecodeInput.self, from: Data(try CanonicalMessagePack.encode(wrongType)))
        } catch {
            thrown = error
        }
        let original = try #require(thrown)
        #expect(original is CanonicalMessagePackError)
        let undecodable = RecordedPayloadDecodeFailure(original)
        #expect(undecodable == .undecodable(String(describing: original)))
        #expect(undecodable.error is RecordedPayloadDecodeError)
        #expect(String(describing: undecodable.error) == String(describing: original))

        // The depth refusals keep their types.
        let recordTooDeep = RecordedPayloadDecodeFailure(CanonicalMessagePackError.nestingTooDeep)
        #expect(recordTooDeep == .recordTooDeep)
        #expect(recordTooDeep.error as? CanonicalMessagePackError == .nestingTooDeep)
        let tooDeep = RecordedPayloadDecodeFailure(PayloadNesting.TooDeep(limit: 5))
        #expect(tooDeep == .tooDeep(limit: 5))
        #expect((tooDeep.error as? PayloadNesting.TooDeep)?.limit == 5)
        #expect(String(describing: tooDeep.error) == String(describing: PayloadNesting.TooDeep(limit: 5)))
    }
}
