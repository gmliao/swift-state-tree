// Tests/SwiftStateTreeTests/ResolverOutputReplayTests.swift
//
// A replayed handler reads a recorded resolver output with the codec that wrote the record (#707),
// as a replayed server event is (#521 PR 1b): `RecordPayloadSource`, strict for a saved record and
// with one integer-to-float allowance for the JSON view. A JSON round trip can't read a `Data`
// field back, so the handler saw `nil` where the live one saw a value. (`Date`, `URL` and
// `Decimal` aren't plain data, so a resolver output can't hold them.)
//

import Foundation
import Logging
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// A resolver output with each plain field a JSON round trip loses or reshapes: `Data`, and
/// `ratio`, an integral Double, which the JSON view writes as an integer.
@PlainData
struct ResolverReplayStamp: ResolverOutput, Equatable {
    let blob: Data
    let ratio: Double
    let n: Int
}

let resolverReplayLive = ResolverReplayStamp(
    blob: Data([0, 1, 254, 255]),
    ratio: 2.0,
    n: 7
)

struct ResolverReplayStampResolver: ContextResolver {
    typealias Output = ResolverReplayStamp
    /// The output the resolver returns; a test sets another for its live run (the keeper's tasks
    /// inherit the binding).
    @TaskLocal static var output = resolverReplayLive
    static func resolve(ctx: ResolverContext) async throws -> ResolverReplayStamp { output }
}

@StateNodeBuilder
struct ResolverReplayState: StateNodeProtocol {
    /// What each handler read: the description of each field, or "nil" when the read failed. One
    /// field per replay site: the action, the join (a lifecycle event) and OnInitialize.
    @Sync(.broadcast)
    var seen: [String] = []
    @Sync(.broadcast)
    var seenAtJoin: [String] = []
    @Sync(.broadcast)
    var seenAtInit: [String] = []
    /// What the action's handler read through the internal `getResolverOutput`.
    @Sync(.broadcast)
    var seenViaGetter: [String] = []
    /// Whether the action's handler, asking for `ResolverReplayMismatch`, got a value.
    @Sync(.broadcast)
    var mismatchRead: String = ""
}

@Payload
struct ResolverReplayAction: ActionPayload {
    typealias Response = ResolverReplayResponse
    let tag: String
}

@Payload
struct ResolverReplayResponse: ResponsePayload {
    let ok: Bool
}

/// Another output type the handler asks for under the same name: the recorded tree doesn't decode
/// into it (no `missing` field).
@PlainData
struct ResolverReplayMismatch: ResolverOutput {
    let missing: String
}

/// Records each log call's level, message and metadata.
final class ResolverReplayLogRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] = []
    func append(_ level: Logger.Level, _ message: String, _ metadata: Logger.Metadata) {
        lock.withLock { records.append((level, message, metadata)) }
    }
    var all: [(level: Logger.Level, message: String, metadata: Logger.Metadata)] { lock.withLock { records } }
}

struct ResolverReplayLogHandler: LogHandler {
    let records: ResolverReplayLogRecords
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        records.append(level, message.description, self.metadata.merging(metadata ?? [:]) { $1 })
    }
}

/// What a handler sees of the output, as strings the state can hold and a test can compare.
func resolverReplaySeen(_ stamp: ResolverReplayStamp?) -> [String] {
    guard let stamp else { return ["nil"] }
    return [
        stamp.blob.base64EncodedString(), "\(stamp.ratio)", "\(stamp.n)",
    ]
}

private let resolverReplayLandID = "resolver-replay:local"

func makeResolverReplayLand() -> LandDefinition<ResolverReplayState> {
    Land("resolver-replay", using: ResolverReplayState.self) {
        Rules {
            HandleAction(ResolverReplayAction.self, resolvers: ResolverReplayStampResolver.self) {
                state, _, ctx in
                state.seen = resolverReplaySeen(ctx.resolverReplayStamp as ResolverReplayStamp?)
                state.seenViaGetter = resolverReplaySeen(ctx.getResolverOutput(ResolverReplayStamp.self, forPropertyName: "resolverReplayStamp"))
                state.mismatchRead = (ctx.resolverReplayStamp as ResolverReplayMismatch?) == nil ? "nil" : "value"
                return ResolverReplayResponse(ok: true)
            }
            OnJoin(resolvers: ResolverReplayStampResolver.self) { state, resolverReplayStamp, ctx in
                state.seenAtJoin = resolverReplaySeen(resolverReplayStamp as ResolverReplayStamp?)
            }
        }
        Lifetime {
            OnInitialize(resolvers: ResolverReplayStampResolver.self) { state, ctx in
                state.seenAtInit = resolverReplaySeen(ctx.resolverReplayStamp as ResolverReplayStamp?)
            }
            Tick(every: .seconds(3600)) { _, _ in }
        }
    }
}

/// The record formats a replay reads (as ReplayTypedEventDecodeTests).
enum ResolverReplayForm: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case saved
    case jsonView
    var testDescription: String { rawValue }
}

private func tempPath(_ ext: String) -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("resolver-replay-\(UUID().uuidString).\(ext)").path
}

/// Runs the action live with recording on, steps one tick, saves the record and returns its path
/// in `form`, with the live state.
private func recordAction(form: ResolverReplayForm) async throws -> (path: String, live: ResolverReplayState) {
    let keeper = LandKeeper<ResolverReplayState>(
        definition: makeResolverReplayLand(),
        initialState: ResolverReplayState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        landID: resolverReplayLandID
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.awaitInitialization()
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: resolverReplayLandID,
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
    guard form == .jsonView else { return (saved, live) }
    let json = tempPath("json")
    try ReevaluationRecordFile.jsonView(ofRecordData: Data(contentsOf: URL(fileURLWithPath: saved)))
        .write(to: URL(fileURLWithPath: json))
    return (json, live)
}

/// Replays the record at `path` in a reevaluation keeper until the action has applied, and
/// returns the replayed state.
private func replayState(path: String, logs: ResolverReplayLogRecords? = nil) async throws -> ResolverReplayState {
    let source = try ReevaluationRecordFile.openSource(filePath: path)
    let keeper = LandKeeper<ResolverReplayState>(
        definition: makeResolverReplayLand(),
        initialState: ResolverReplayState(),
        mode: .reevaluation,
        reevaluationSource: source,
        autoStartLoops: false,
        logger: logs.map { records in Logger(label: "resolver-replay") { _ in ResolverReplayLogHandler(records: records) } }
    )
    await keeper.stepTickOnce()
    return await keeper.currentState()
}

// MARK: - Tests

@Suite("A replayed handler reads a recorded resolver output with the record's codec (#707)")
struct ResolverOutputReplayTests {
    @Test("Live, each handler sees every field: the action's, the join's and OnInitialize's")
    func liveSeesEveryField() async throws {
        let (_, live) = try await recordAction(form: .saved)
        let expected = resolverReplaySeen(resolverReplayLive)
        #expect(live.seen == expected)
        #expect(live.seenAtJoin == expected)
        #expect(live.seenAtInit == expected)
    }

    @Test("Replayed from each record form, each handler sees what the live one saw: Data, an integral Double",
          arguments: ResolverReplayForm.allCases)
    func replaySeesTheLiveOutput(form: ResolverReplayForm) async throws {
        let (path, live) = try await recordAction(form: form)
        let replayed = try await replayState(path: path)
        #expect(replayed.seen == live.seen, "\(form): the action")
        #expect(replayed.seenViaGetter == live.seen, "\(form): the action, through getResolverOutput")
        #expect(replayed.seenAtJoin == live.seenAtJoin, "\(form): the join")
        #expect(replayed.seenAtInit == live.seenAtInit, "\(form): OnInitialize")
        #expect(![replayed.seen, replayed.seenAtJoin, replayed.seenAtInit].contains { $0.contains("nil") }, "\(form)")
    }

    @Test("An output that doesn't decode into the type the handler asks for reads nil in replay, with a warning naming it",
          arguments: ResolverReplayForm.allCases)
    func undecodableOutputWarns(form: ResolverReplayForm) async throws {
        let (path, live) = try await recordAction(form: form)
        #expect(live.mismatchRead == "nil", "live, the cast fails")
        let logs = ResolverReplayLogRecords()
        let replayed = try await replayState(path: path, logs: logs)
        #expect(replayed.mismatchRead == "nil", "\(form)")
        let warnings = logs.all.filter { $0.level == .warning && $0.message.contains("doesn't decode in replay") }
        #expect(warnings.count == 1, "\(form): \(logs.all.map(\.message))")
        #expect(warnings.first?.metadata["output"] == "resolverReplayStamp", "\(form)")
        #expect(warnings.first?.metadata["requestedType"].map { "\($0)".hasSuffix("ResolverReplayMismatch") } == true, "\(form)")
        // The outputs that do decode log nothing.
        #expect(replayed.seen == live.seen, "\(form)")
    }
}
