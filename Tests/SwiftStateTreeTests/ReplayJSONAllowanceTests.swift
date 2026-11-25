// Tests/SwiftStateTreeTests/ReplayJSONAllowanceTests.swift
//
// Pins that the integral-float allowance tracks whether the source parsed JSON bytes, not whether
// its type is JSONReevaluationSource (#824). `init(metadata:frames:)` holds canonical frames built
// in memory and must be strict; only `init(data:)` and `init(filePath:)` grant the allowance.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

// MARK: - Keeper-level fixtures

@StateNodeBuilder
private struct JSONAllowanceKeeperState: StateNodeProtocol {
    @Sync(.broadcast)
    var actionApplied: Bool = false
    @Sync(.broadcast)
    var resolverRatioWasNil: Bool = false
    public init() {}
}

@Payload
private struct JSONAllowanceAction: ActionPayload {
    typealias Response = JSONAllowanceResponse
}

@Payload
private struct JSONAllowanceResponse: ResponsePayload {}

@PlainData
private struct JSONAllowanceOutput: ResolverOutput {
    let ratio: Double
}

/// Named so its output key is "jSONAllowance", the key the recorded frame carries.
@PlainData
private struct JSONAllowance: Resolver {
    typealias Dependencies = NoServices
    func resolve(_ deps: NoServices) async throws -> JSONAllowanceOutput { JSONAllowanceOutput(ratio: 2.0) }
}

private func makeJSONAllowanceLand() -> LandDefinition<JSONAllowanceKeeperState> {
    Land("json-allowance-keeper", using: JSONAllowanceKeeperState.self) {
        Rules {
            HandleAction(JSONAllowanceAction.self, resolvers: { _, _, _ in JSONAllowance() }) {
                (state: inout JSONAllowanceKeeperState, _: JSONAllowanceAction, output: JSONAllowanceOutput?, _: LandContext) in
                state.actionApplied = true
                state.resolverRatioWasNil = output == nil
                return JSONAllowanceResponse()
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout JSONAllowanceKeeperState, _: LandContext) in }
        }
    }
}

@StateNodeBuilder
private struct JSONAllowanceSIState: StateNodeProtocol {
    @Sync(.broadcast)
    var seen: [String] = []
    public init() {}
}

@Payload
private struct JSONAllowanceSIInput: ServerInputPayload {
    let ratio: Double
}

private func makeJSONAllowanceSILand() -> LandDefinition<JSONAllowanceSIState> {
    Land("json-allowance-si", using: JSONAllowanceSIState.self) {
        Rules {
            HandleServerInput(JSONAllowanceSIInput.self) {
                (state: inout JSONAllowanceSIState, input: JSONAllowanceSIInput, _: LandContext) in
                state.seen.append("\(input.ratio)")
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout JSONAllowanceSIState, _: LandContext) in }
        }
    }
}

// MARK: - Tests

@Suite("Replay JSON allowance is granted by whether the source read JSON bytes (#824)")
struct ReplayJSONAllowanceTests {
    static let minimalRecord = Data(
        #"{"recordMetadata":{"landID":"l","landType":"t","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"2.6"},"tickFrames":[]}"#.utf8
    )

    static func metadata() -> ReevaluationRecordMetadata {
        ReevaluationRecordMetadata(landID: "l", landType: "t", createdAt: Date(timeIntervalSince1970: 0), metadata: [:], version: "2.6")
    }

    @Test("JSONReevaluationSource(data:) sets readsJSONRecord = true")
    func dataInitSetsReadsJSONRecord() throws {
        let source = try JSONReevaluationSource(data: Self.minimalRecord)
        #expect(source.readsJSONRecord == true)
    }

    @Test("JSONReevaluationSource(metadata:frames:) sets readsJSONRecord = false")
    func metadataFramesInitDoesNotSetReadsJSONRecord() {
        let source = JSONReevaluationSource(metadata: Self.metadata(), frames: [])
        #expect(source.readsJSONRecord == false)
    }

    @Test("integralFloats(for:) is false for a source built with init(metadata:frames:)")
    func integralFloatsIsFalseForInMemorySource() {
        let source = JSONReevaluationSource(metadata: Self.metadata(), frames: [])
        #expect(ReevaluationReplayFrame.integralFloats(for: source) == false)
    }

    @Test("FaultingReevaluationSource forwards readsJSONRecord: a wrapped JSON read reports true")
    func faultingSourceForwardsTrue() throws {
        let wrapped = FaultingReevaluationSource(base: try JSONReevaluationSource(data: Self.minimalRecord), faults: ReplayRunnerFaults())
        #expect(wrapped.readsJSONRecord == true)
        #expect(ReevaluationReplayFrame.integralFloats(for: wrapped) == true)
    }

    @Test("FaultingReevaluationSource forwards readsJSONRecord: a wrapped in-memory source reports false")
    func faultingSourceForwardsFalse() {
        let wrapped = FaultingReevaluationSource(base: JSONReevaluationSource(metadata: Self.metadata(), frames: []), faults: ReplayRunnerFaults())
        #expect(wrapped.readsJSONRecord == false)
        #expect(ReevaluationReplayFrame.integralFloats(for: wrapped) == false)
    }

    // MARK: Keeper-level: resolver output

    @Test("Resolver output with an integer where Double is declared reads nil from an in-memory source (no JSON allowance)")
    func resolverOutputIntegerRefusedFromInMemorySource() async throws {
        let metadata = ReevaluationRecordMetadata(
            landID: "json-allowance-keeper:local",
            landType: "json-allowance-keeper",
            createdAt: Date(timeIntervalSince1970: 0),
            metadata: [:]
        )
        let resolverOutput = ReevaluationRecordedResolverOutput(
            typeIdentifier: "JSONAllowanceOutput",
            value: AnyCodable(["ratio": AnyCodable(2)] as [String: AnyCodable])
        )
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [
                ReevaluationRecordedAction(
                    kind: "action",
                    sequence: 0,
                    typeIdentifier: String(describing: JSONAllowanceAction.self),
                    payload: AnyCodable([:] as [String: AnyCodable]),
                    playerID: "p",
                    clientID: "c",
                    sessionID: "s",
                    resolverOutputs: ["jSONAllowance": resolverOutput],
                    resolvedAtTick: 0
                )
            ],
            clientEvents: [],
            lifecycleEvents: []
        )
        let source = JSONReevaluationSource(metadata: metadata, frames: [frame])
        let keeper = LandKeeper<JSONAllowanceKeeperState>(
            definition: makeJSONAllowanceLand(),
            initialState: JSONAllowanceKeeperState(),
            mode: .reevaluation,
            reevaluationSource: source,
            autoStartLoops: false
        )
        await keeper.stepTickOnce()
        let state = await keeper.currentState()
        #expect(state.actionApplied == true)
        #expect(state.resolverRatioWasNil == true, "integer is refused where the type declares Double without the JSON allowance")
    }

    // MARK: Keeper-level: server input

    @Test("Server input with an integer where Double is declared is refused from an in-memory source (no JSON allowance)")
    func serverInputIntegerRefusedFromInMemorySource() async throws {
        let metadata = ReevaluationRecordMetadata(
            landID: "json-allowance-si:local",
            landType: "json-allowance-si",
            createdAt: Date(timeIntervalSince1970: 0),
            metadata: [:]
        )
        let frame = ReevaluationTickFrame(
            tickId: 0,
            actions: [],
            clientEvents: [],
            lifecycleEvents: [],
            serverInputs: [
                ReevaluationRecordedServerInput(
                    sequence: 0,
                    typeIdentifier: String(describing: JSONAllowanceSIInput.self),
                    payload: AnyCodable(["ratio": AnyCodable(2)] as [String: AnyCodable]),
                    resolvedAtTick: 0
                )
            ]
        )
        let source = JSONReevaluationSource(metadata: metadata, frames: [frame])
        let keeper = LandKeeper<JSONAllowanceSIState>(
            definition: makeJSONAllowanceSILand(),
            initialState: JSONAllowanceSIState(),
            mode: .reevaluation,
            reevaluationSource: source,
            autoStartLoops: false
        )
        await keeper.setReplayRecordsRejected(true)
        await keeper.stepTickOnce()
        let state = await keeper.currentState()
        #expect(state.seen == [], "integer 2 is refused where the type declares Double without the JSON allowance")
    }
}
