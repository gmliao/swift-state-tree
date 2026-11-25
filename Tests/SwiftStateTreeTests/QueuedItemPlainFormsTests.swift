// Tests/SwiftStateTreeTests/QueuedItemPlainFormsTests.swift
//
// #700 K1b-1, the tests-first commit: behaviour the plain forms of the keeper's queued items must
// keep. Green on the base before any item changes form.
// - F9: an action's handler is found by its recorded type name, not by a position, and the record
//   holds only that name. Replaying on a land whose handlers are declared in another order finds
//   the same handler.
// - K1-Q7: a recorded resolver output of a scalar type reads back as the live value. Today the
//   replay read takes `payload.base as? T`; after the item holds bytes, the codec reads it.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

@StateNodeBuilder
struct PlainFormsState: StateNodeProtocol {
    @Sync(.broadcast)
    var applied: [String] = []

    public init() {}
}

@Payload
struct PlainFormsAck: ResponsePayload {
    let count: Int
}

@Payload
struct PlainFormsFirst: ActionPayload {
    typealias Response = PlainFormsAck
    let tag: String
}

@Payload
struct PlainFormsSecond: ActionPayload {
    typealias Response = PlainFormsAck
    let tag: String
}

@Payload
struct PlainFormsThird: ActionPayload {
    typealias Response = PlainFormsAck
    let tag: String
}

/// The three action handlers, in `order`: each appends its own name and the tag.
private enum PlainFormsOrder: Sendable {
    /// First, Second, Third: Second at position 1.
    case declared
    /// Third, First, Second: Second at position 2.
    case rotated
}

private func makePlainFormsLand(_ order: PlainFormsOrder = .declared) -> LandDefinition<PlainFormsState> {
    Land("plain-forms", using: PlainFormsState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
        Rules {
            switch order {
            case .declared:
                HandleAction(PlainFormsFirst.self) { state, action, _ in
                    state.applied.append("first:\(action.tag)")
                    return PlainFormsAck(count: state.applied.count)
                }
                HandleAction(PlainFormsSecond.self) { state, action, _ in
                    state.applied.append("second:\(action.tag)")
                    return PlainFormsAck(count: state.applied.count)
                }
                HandleAction(PlainFormsThird.self) { state, action, _ in
                    state.applied.append("third:\(action.tag)")
                    return PlainFormsAck(count: state.applied.count)
                }
            case .rotated:
                HandleAction(PlainFormsThird.self) { state, action, _ in
                    state.applied.append("third:\(action.tag)")
                    return PlainFormsAck(count: state.applied.count)
                }
                HandleAction(PlainFormsFirst.self) { state, action, _ in
                    state.applied.append("first:\(action.tag)")
                    return PlainFormsAck(count: state.applied.count)
                }
                HandleAction(PlainFormsSecond.self) { state, action, _ in
                    state.applied.append("second:\(action.tag)")
                    return PlainFormsAck(count: state.applied.count)
                }
            }
        }
    }
}

private let plainFormsLandID = "plain-forms:local"

private func tempPath(_ ext: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("plain-forms-\(UUID().uuidString).\(ext)").path
}

/// Records one `PlainFormsSecond` action live on the declared land, and returns the keeper, the
/// saved record's path and the live state.
private func recordSecondAction() async throws -> (keeper: LandKeeper<PlainFormsState>, path: String, live: PlainFormsState) {
    let keeper = LandKeeper<PlainFormsState>(
        definition: makePlainFormsLand(),
        initialState: PlainFormsState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: plainFormsLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.awaitInitialization()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: plainFormsLandID,
        landType: "plain-forms",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "plain-forms",
        rngSeed: await keeper.getRngSeed()
    ))
    let player = PlayerID("p"), client = ClientID("c"), session = SessionID("s")
    try await keeper.join(playerID: player, clientID: client, sessionID: session)
    _ = try await keeper.handleActionEnvelope(
        ActionEnvelope(typeIdentifier: String(describing: PlainFormsSecond.self),
                       payload: AnyCodable(PlainFormsSecond(tag: "a"))),
        playerID: player, clientID: client, sessionID: session
    )
    await keeper.stepTickOnce()
    await keeper.waitForRecorderSubmissionsForTesting()
    let live = await keeper.currentState()
    let path = tempPath("sstr")
    try await recorder.save(to: path)
    return (keeper, path, live)
}

// MARK: - K1-Q7 fixtures: a scalar resolver output

/// A retroactive scalar conformer: the one output type today's `payload.base as? T` shortcut
/// takes, because a recorded tree's scalar leaf is an `Int`. No conformer in Sources or Examples
/// is a scalar.
extension Int: ResolverOutput {}

@PlainData
struct PlainFormsCount: Resolver {
    typealias Dependencies = NoServices
    let n: Int
    func resolve(_ deps: NoServices) async throws -> Int { n }
}

@Payload
struct PlainFormsCounted: ActionPayload {
    typealias Response = PlainFormsAck
    let n: Int
}

private func makeScalarOutputLand() -> LandDefinition<PlainFormsState> {
    Land("plain-forms-scalar", using: PlainFormsState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
        Rules {
            HandleAction(PlainFormsCounted.self, resolvers: { _, action, _ in PlainFormsCount(n: action.n) }) {
                state, _, output, _ in
                state.applied.append(output.map { "count:\($0)" } ?? "nil")
                return PlainFormsAck(count: state.applied.count)
            }
        }
    }
}

// MARK: - Tests

@Suite("The keeper's queued items keep their behaviour as they become plain (#700 K1b-1)", .timeLimit(.minutes(1)))
struct QueuedItemPlainFormsTests {
    @Test("An action's record entry holds its type's name and today's keys, and no handler position (F9)")
    func recordHoldsOnlyTheActionTypeName() async throws {
        let (keeper, _, live) = try await recordSecondAction()
        #expect(live.applied == ["second:a"], "control: live applied the second handler")
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let data = try await recorder.encodeJSONViewForTesting()
        let view = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let frames = try #require(view["tickFrames"] as? [[String: Any]])
        let actions = frames.flatMap { ($0["actions"] as? [[String: Any]]) ?? [] }
        let action = try #require(actions.only, "one action recorded")
        #expect(action["typeIdentifier"] as? String == String(describing: PlainFormsSecond.self))
        // Today's key set. `payloadEncoding` is left out when it equals the header's.
        let todaysKeys: Set<String> = [
            "kind", "sequence", "typeIdentifier", "payload", "playerID", "clientID", "sessionID",
            "resolverOutputs", "resolvedAtTick",
        ]
        #expect(Set(action.keys).subtracting(["payloadEncoding"]) == todaysKeys)
        await keeper.forceShutdown()
    }

    @Test("A replay on a land whose action handlers are declared in another order runs the recorded type's handler (F9)")
    func replayFindsTheHandlerAfterTheHandlersAreReordered() async throws {
        let (keeper, path, live) = try await recordSecondAction()
        await keeper.forceShutdown()
        // Pinned here, not only by the record test: a first-handler mutant runs First live and in
        // replay alike, and its type check rejects both, so comparing the two alone would pass.
        #expect(live.applied == ["second:a"], "live applied the second handler")
        // Recorded with the target at position 1; replayed with it at position 2. Taking the
        // recorded position runs Third, and taking the first handler runs First or Third.
        let rotated = makePlainFormsLand(.rotated)
        #expect(rotated.actionHandlers.firstIndex { $0.canHandle(PlainFormsSecond.self) } == 2, "control: the target moved")
        let replay = LandKeeper<PlainFormsState>(
            definition: rotated,
            initialState: PlainFormsState(),
            mode: .reevaluation,
            reevaluationSource: try ReevaluationRecordFile.openSource(filePath: path),
            autoStartLoops: false
        )
        let ticks = try await ReevaluationRecordFile.openSource(filePath: path).getMaxTickId()
        for _ in 0...ticks { await replay.stepTickOnce() }
        #expect(await replay.currentState().applied == ["second:a"])
    }

    @Test("A recorded resolver output of a scalar type reads back as the live value (K1-Q7)")
    func recordedScalarResolverOutputReadsAsBefore() async throws {
        let landID = "plain-forms-scalar:local"
        let keeper = LandKeeper<PlainFormsState>(
            definition: makeScalarOutputLand(),
            initialState: PlainFormsState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false,
            landID: landID
        )
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await keeper.awaitInitialization()
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "plain-forms-scalar",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: [:],
            landDefinitionID: "plain-forms-scalar",
            rngSeed: await keeper.getRngSeed()
        ))
        let player = PlayerID("p"), client = ClientID("c"), session = SessionID("s")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(typeIdentifier: String(describing: PlainFormsCounted.self),
                           payload: AnyCodable(PlainFormsCounted(n: 42))),
            playerID: player, clientID: client, sessionID: session
        )
        await keeper.waitForActionJobsForTesting()
        await keeper.stepTickOnce()
        await keeper.waitForRecorderSubmissionsForTesting()
        let live = await keeper.currentState()
        #expect(live.applied == ["count:42"], "control: live read the output")
        let path = tempPath("sstr")
        try await recorder.save(to: path)
        await keeper.forceShutdown()

        let replay = LandKeeper<PlainFormsState>(
            definition: makeScalarOutputLand(),
            initialState: PlainFormsState(),
            mode: .reevaluation,
            reevaluationSource: try ReevaluationRecordFile.openSource(filePath: path),
            autoStartLoops: false
        )
        let ticks = try await ReevaluationRecordFile.openSource(filePath: path).getMaxTickId()
        for _ in 0...ticks { await replay.stepTickOnce() }
        #expect(await replay.currentState().applied == live.applied)
    }
}

private extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
