// Tests/SwiftStateTreeTests/ReevaluationMonitorStateTextTests.swift
//
// The monitor's TickProcessedEvent carries a step's state as JSON text. The built-in runner
// already puts JSON text in `ReevaluationStepResult.actualState`; a runner that puts an object
// tree there gets the same text, with sorted keys, on the wire.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

private actor StateTextTransport: Transport {
    var delegate: TransportDelegate?
    var sent: [Data] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to _: SwiftStateTreeTransport.EventTarget) {
        sent.append(message)
    }
}

private final class StateTextFactory: ReevaluationTargetFactory, @unchecked Sendable {
    let results: [ReevaluationStepResult]
    init(results: [ReevaluationStepResult]) { self.results = results }

    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol {
        StateTextRunner(results: results)
    }
}

private actor StateTextRunner: ReevaluationRunnerProtocol {
    func initializeVerification() async -> ReevaluationEngine.InitializeVerification { .notRecorded }

    nonisolated let maxTickId: Int64
    private var results: [ReevaluationStepResult]

    init(results: [ReevaluationStepResult]) {
        self.results = results
        self.maxTickId = results.last?.tickId ?? 0
    }

    func prepare() async throws {}

    func step() async throws -> ReevaluationStepResult? {
        results.isEmpty ? nil : results.removeFirst()
    }
}

@Suite("The monitor sends a step's state as JSON text", .serialized, .timeLimit(.minutes(1)))
struct ReevaluationMonitorStateTextTests {
    @Test("A step result whose state is an object tree reaches TickProcessedEvent as JSON text with sorted keys; a String passes through")
    func objectTreeBecomesJSONText() async throws {
        let results = [
            ReevaluationStepResult(
                tickId: 1, stateHash: "h1", recordedHash: "h1", isMatch: true,
                actualState: AnyCodable(["h": AnyCodable(0), "c": AnyCodable(1), "a": AnyCodable(2), "f": AnyCodable(3), "b": AnyCodable(4), "g": AnyCodable(5), "d": AnyCodable(6), "e": AnyCodable(7)])
            ),
            ReevaluationStepResult(
                tickId: 2, stateHash: "h2", recordedHash: "h2", isMatch: true,
                actualState: AnyCodable(#"{"z":2}"#)
            ),
        ]
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(ReevaluationMonitor.makeLand())])
        let pathHashes = try #require(schema.lands["reevaluation-monitor"]?.pathHashes)
        let service = ReevaluationRunnerService(
            factory: StateTextFactory(results: results),
            projectorResolver: { _ in HeroDefenseReplayProjector() }
        )
        var services = LandServices()
        services.register(service, as: ReevaluationRunnerService.self)
        let keeper = LandKeeper<ReevaluationMonitorState>(
            definition: ReevaluationMonitor.makeLand(),
            initialState: ReevaluationMonitorState(),
            services: services,
            autoStartLoops: false,
            landID: "reevaluation-monitor:state-text"
        )
        let transport = StateTextTransport()
        let adapter = TransportAdapter<ReevaluationMonitorState>(
            keeper: keeper,
            transport: transport,
            landID: "reevaluation-monitor:state-text",
            encodingConfig: .json,
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)

        await adapter.onConnect(sessionID: SessionID("s-alice"), clientID: ClientID("c-alice"))
        _ = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: "alice"),
            clientID: ClientID("c-alice"),
            sessionID: SessionID("s-alice"),
            authInfo: nil
        )
        await adapter.syncStateForNewPlayer(playerID: PlayerID("alice"), sessionID: SessionID("s-alice"))
        await keeper.waitForInFlightWorkForTesting()
        await adapter.waitForOutboundIdleForTesting()
        service.startVerification(landType: "state-text", recordFilePath: "/dev/null")
        let task = try #require(service.verificationTaskForTesting())
        await task.value
        await keeper.stepTickOnce()
        await keeper.waitForInFlightWorkForTesting()
        await adapter.waitForOutboundIdleForTesting()
        await adapter.syncNow()
        await adapter.waitForOutboundIdleForTesting()

        let sent = await transport.sent
        let text = sent.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        // The JSON encoder writes each state as a JSON string: its quotes are escaped. Eight keys,
        // so an unsorted encoding can't pass by chance.
        #expect(text.contains(#""actualState":"{\"a\":2,\"b\":4,\"c\":1,\"d\":6,\"e\":7,\"f\":3,\"g\":5,\"h\":0}""#), "\(sent.count) frames: \(text)")
        #expect(text.contains(#""actualState":"{\"z\":2}""#), "\(text)")
    }
}
