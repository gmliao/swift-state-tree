// Tests/SwiftStateTreeTests/ReplayJSONAllowanceKeeperTests.swift
//
// The keeper grants the integral-float allowance by `ReevaluationSource.readsJSONRecord`, not by
// the source's type (#824). The source here is a wrapper over the JSON view, so `is
// JSONReevaluationSource` is false for it: only the property can grant the allowance. The record
// holds an integer where the type declares a `Double`, at both keeper sites: a recorded resolver
// output and a recorded server input.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Sources

/// A source that forwards every read to `base`; the conformers choose the `readsJSONRecord` answer.
protocol ForwardingTestSource: ReevaluationSource {
    var base: any ReevaluationSource { get }
}

extension ForwardingTestSource {
    func getMetadata() async throws -> ReevaluationRecordMetadata { try await base.getMetadata() }
    func getActions(for tickId: Int64) async throws -> [ReevaluationRecordedAction] { try await base.getActions(for: tickId) }
    func getClientEvents(for tickId: Int64) async throws -> [ReevaluationRecordedClientEvent] { try await base.getClientEvents(for: tickId) }
    func getLifecycleEvents(for tickId: Int64) async throws -> [ReevaluationRecordedLifecycleEvent] { try await base.getLifecycleEvents(for: tickId) }
    func getStateHash(for tickId: Int64) async throws -> String? { try await base.getStateHash(for: tickId) }
    func getServerEvents(for tickId: Int64) async throws -> [ReevaluationRecordedServerEvent] { try await base.getServerEvents(for: tickId) }
    func getMaxTickId() async throws -> Int64 { try await base.getMaxTickId() }
    func getSequenceWatermarks(for tickId: Int64) async throws -> ReevaluationSequenceWatermarks? { try await base.getSequenceWatermarks(for: tickId) }
    func getPasses(for tickId: Int64) async throws -> [ReevaluationRecordedPass] { try await base.getPasses(for: tickId) }
    func getServerInputs(for tickId: Int64) async throws -> [ReevaluationRecordedServerInput] { try await base.getServerInputs(for: tickId) }
    func getRejected(for tickId: Int64) async throws -> [Int64] { try await base.getRejected(for: tickId) }
    func getSyncStream() async throws -> [ReevaluationSyncStreamEntry] { try await base.getSyncStream() }
    func getLandFailure() async throws -> (tickId: Int64, failure: LandFailure)? { try await base.getLandFailure() }
    func getInitializeRecord() async throws -> ReevaluationRecordedInitialize? { try await base.getInitializeRecord() }
    func getRecordCompleteness() async throws -> ReevaluationRecordCompleteness { try await base.getRecordCompleteness() }
    func getHoldsNonNFCText() async throws -> Bool { try await base.getHoldsNonNFCText() }
}

/// Answers `readsJSONRecord` with `flag`.
struct FlaggedReplaySource: ForwardingTestSource {
    let base: any ReevaluationSource
    let flag: Bool
    var readsJSONRecord: Bool { flag }
}

/// Doesn't declare `readsJSONRecord`: it takes the protocol's default.
struct DefaultFlagReplaySource: ForwardingTestSource {
    let base: any ReevaluationSource
}

enum ReplaySourceFlag: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case flaggedTrue
    case flaggedFalse
    case inheritedDefault

    var testDescription: String { rawValue }

    /// Whether the source's `readsJSONRecord` is true.
    var readsJSON: Bool { self == .flaggedTrue }

    func wrap(_ base: any ReevaluationSource) -> any ReevaluationSource {
        switch self {
        case .flaggedTrue: FlaggedReplaySource(base: base, flag: true)
        case .flaggedFalse: FlaggedReplaySource(base: base, flag: false)
        case .inheritedDefault: DefaultFlagReplaySource(base: base)
        }
    }
}

private func tempPath(_ ext: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("replay-allowance-keeper-\(UUID().uuidString).\(ext)").path
}

/// Writes the saved record at `saved` as its JSON view and opens that file: a source that read
/// JSON, which holds `2` where the live value was `2.0`.
private func openJSONView(ofSavedRecordAt saved: String) throws -> any ReevaluationSource {
    let json = tempPath("json")
    try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: saved)))
        .write(to: URL(fileURLWithPath: json))
    let source = try ReevaluationRecordFile.openSource(filePath: json)
    #expect(source is JSONReevaluationSource, "control: the base is the JSON view")
    return source
}

// MARK: - Resolver output site

/// Runs the action live with recording on and returns its JSON view as a source, with the live state.
private func recordResolverOutput() async throws -> (source: any ReevaluationSource, live: ResolverReplayState) {
    let landID = "resolver-replay:local"
    let keeper = LandKeeper<ResolverReplayState>(
        definition: makeResolverReplayLand(),
        initialState: ResolverReplayState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: landID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.awaitInitialization()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID,
        landType: "resolver-replay",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "resolver-replay",
        rngSeed: await keeper.getRngSeed()
    ))
    let player = PlayerID("p"), client = ClientID("c"), session = SessionID("s")
    try await keeper.join(playerID: player, clientID: client, sessionID: session)
    _ = try await keeper.handleActionEnvelope(
        ActionEnvelope(typeIdentifier: String(describing: ResolverReplayAction.self),
                       payload: AnyCodable(ResolverReplayAction(tag: "a"))),
        playerID: player, clientID: client, sessionID: session
    )
    await keeper.stepTickOnce()
    await keeper.waitForRecorderSubmissionsForTesting()
    let live = await keeper.currentState()
    let saved = tempPath("sstr")
    try await recorder.save(to: saved)
    return (try openJSONView(ofSavedRecordAt: saved), live)
}

// MARK: - Server input site

@StateNodeBuilder
struct FlagInputState: StateNodeProtocol {
    @Sync(.broadcast)
    var seen: [String] = []

    public init() {}
}

@Payload
struct FlagInputRatio: ServerInputPayload {
    let ratio: Double
    let n: Int
}

struct FlagInputNotAccepted: Error {}

private func makeFlagInputLand() -> LandDefinition<FlagInputState> {
    Land("flag-input", using: FlagInputState.self) {
        Rules {
            HandleServerInput(FlagInputRatio.self) { (state: inout FlagInputState, input: FlagInputRatio, _: LandContext) in
                state.seen.append("\(input.ratio)/\(input.n)")
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout FlagInputState, _: LandContext) in }
        }
    }
}

/// Submits `ratio: 2.0` live with recording on and returns the record's JSON view as a source,
/// with the live state.
private func recordServerInput() async throws -> (source: any ReevaluationSource, live: FlagInputState) {
    let landID = "flag-input:local"
    let keeper = LandKeeper<FlagInputState>(
        definition: makeFlagInputLand(),
        initialState: FlagInputState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: landID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.awaitInitialization()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID,
        landType: "flag-input",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        metadata: [:],
        landDefinitionID: "flag-input",
        rngSeed: await keeper.getRngSeed()
    ))
    guard case .accepted = await keeper.submitServerInput(FlagInputRatio(ratio: 2.0, n: 3)) else {
        throw FlagInputNotAccepted()
    }
    await keeper.stepTickOnce()
    await keeper.waitForRecorderSubmissionsForTesting()
    let live = await keeper.currentState()
    let saved = tempPath("sstr")
    try await recorder.save(to: saved)
    return (try openJSONView(ofSavedRecordAt: saved), live)
}

// MARK: - Tests

@Suite("The keeper grants the integral-float allowance by readsJSONRecord, not by the source's type (#824)")
struct ReplayJSONAllowanceKeeperTests {
    @Test("A recorded resolver output holding an integer where the type declares Double: read when the source reads JSON, nil when it doesn't",
          arguments: ReplaySourceFlag.allCases)
    func resolverOutputFollowsTheFlag(flag: ReplaySourceFlag) async throws {
        let (base, live) = try await recordResolverOutput()
        #expect(live.seen == resolverReplaySeen(resolverReplayLive), "control: live read every field")
        let source = flag.wrap(base)
        #expect(!(source is JSONReevaluationSource), "control: the type test can't grant it")
        #expect(source.readsJSONRecord == flag.readsJSON)
        let keeper = LandKeeper<ResolverReplayState>(
            definition: makeResolverReplayLand(),
            initialState: ResolverReplayState(),
            mode: .reevaluation,
            reevaluationSource: source,
            autoStartLoops: false
        )
        await keeper.stepTickOnce()
        let replayed = await keeper.currentState()
        if flag.readsJSON {
            #expect(replayed.seen == live.seen, "\(flag): the integer reads as the live Double")
        } else {
            #expect(replayed.seen == ["nil"], "\(flag): the integer isn't a Double, the output doesn't decode")
        }
    }

    @Test("A recorded server input whose type declares Double replays live's value whatever the flag says: its bytes keep the Double (#700 K1a)",
          arguments: ReplaySourceFlag.allCases)
    func serverInputFollowsTheFlag(flag: ReplaySourceFlag) async throws {
        let (base, live) = try await recordServerInput()
        #expect(live.seen == ["2.0/3"], "control: live applied the input")
        let source = flag.wrap(base)
        #expect(!(source is JSONReevaluationSource), "control: the type test can't grant it")
        #expect(source.readsJSONRecord == flag.readsJSON)
        let keeper = LandKeeper<FlagInputState>(
            definition: makeFlagInputLand(),
            initialState: FlagInputState(),
            mode: .reevaluation,
            reevaluationSource: source,
            autoStartLoops: false
        )
        await keeper.stepTickOnce()
        let replayed = await keeper.currentState()
        // From 3.7 a server input's payload is its MessagePack bytes, base64 in the JSON view, so
        // the view holds the Double live applied and no allowance is needed.
        #expect(replayed.seen == live.seen, "\(flag): applied with the live value")
    }
}
