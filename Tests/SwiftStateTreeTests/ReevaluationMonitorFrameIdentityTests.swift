// Tests/SwiftStateTreeTests/ReevaluationMonitorFrameIdentityTests.swift
//
// The reevaluation monitor land on the typed sync tables (the default) must send the frames the
// snapshot diff sends. One script runs on an adapter with the tables on and on one with them off,
// and the recipient must get the same frames, byte for byte and in order, in every encoding, with
// dirty tracking on and off.
//
// The monitor's tick copies the runner service's status and results into the state. Each cycle
// runs a scripted verification to its end, outside any turn, before the tick reads it, so both
// runs read the same results at the same ticks.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

private actor MonitorFrameTransport: Transport {
    var delegate: TransportDelegate?
    var sent: [(target: String, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append(("\(target)", message))
    }
}

/// One run per verification, each with its own fixed results.
private final class MonitorScriptFactory: ReevaluationTargetFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [[ReevaluationStepResult]]

    init(runs: [[ReevaluationStepResult]]) {
        self.runs = runs
    }

    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol {
        let results = lock.withLock { runs.isEmpty ? [] : runs.removeFirst() }
        return MonitorScriptRunner(results: results)
    }
}

private actor MonitorScriptRunner: ReevaluationRunnerProtocol {
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

/// The verification runs of the script: different lengths, some ticks mismatched.
private func monitorScriptRuns() throws -> [[ReevaluationStepResult]] {
    try (0..<8).map { run in
        try (1...Int64(2 + run % 4)).map { tick in
            let state = try JSONSerialization.data(withJSONObject: ["score": Int(tick) * (run + 1)], options: [.sortedKeys])
            let isMatch = (tick + Int64(run)) % 3 != 0
            return ReevaluationStepResult(
                tickId: tick,
                stateHash: "hash-\(run)-\(tick)",
                recordedHash: isMatch ? "hash-\(run)-\(tick)" : "recorded-\(run)-\(tick)",
                isMatch: isMatch,
                actualState: AnyCodable(String(decoding: state, as: UTF8.self))
            )
        }
    }
}

private let monitorEncodings: [(String, TransportEncodingConfig)] = [
    ("json", .json),
    ("jsonOpcode", .jsonOpcode),
    ("messagepack", .messagepack),
]

private let monitorCells: [String] = monitorEncodings.flatMap { encoding in
    [true, false].map { "\(encoding.0)|\($0)" }
}

@Suite("The typed tables on and off send the same frames: the reevaluation monitor", .serialized, .timeLimit(.minutes(2)))
struct ReevaluationMonitorFrameIdentityTests {
    @Test("The reevaluation monitor", arguments: monitorCells)
    func monitor(cell: String) async throws {
        let parts = cell.split(separator: "|").map(String.init)
        let encoding = try #require(monitorEncodings.first { $0.0 == parts[0] }?.1)
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(ReevaluationMonitor.makeLand())])
        let pathHashes = try #require(schema.lands["reevaluation-monitor"]?.pathHashes)
        let runs = try monitorScriptRuns()
        var frames: [[(target: String, data: Data)]] = []
        for tables in [true, false] {
            let service = ReevaluationRunnerService(
                factory: MonitorScriptFactory(runs: runs),
                projectorResolver: { _ in HeroDefenseReplayProjector() }
            )
            var services = LandServices()
            services.register(service, as: ReevaluationRunnerService.self)
            let keeper = LandKeeper<ReevaluationMonitorState>(
                definition: ReevaluationMonitor.makeLand(),
                initialState: ReevaluationMonitorState(),
                services: services,
                autoStartLoops: false
            )
            await keeper.setLandID("reevaluation-monitor:frame-identity")
            var config = TransportEnvConfig(
                enableDirtyTracking: parts[1] == "true",
                useSnapshotForSync: true,
                syncStrategy: .delta,
                profilingConfig: nil
            )
            config.syncTablesEnabled = tables
            let transport = MonitorFrameTransport()
            let adapter = TransportAdapter<ReevaluationMonitorState>(
                keeper: keeper,
                transport: transport,
                landID: "reevaluation-monitor:frame-identity",
                transportEnvConfig: config,
                encodingConfig: encoding,
                pathHashes: pathHashes,
                suppressMissingPathHashesWarning: true
            )
            await transport.setDelegate(adapter)
            await keeper.setTransport(adapter)
            // Every broadcast field is a value on the tables.
            #expect(await adapter.syncTableFieldKinds()?.values.allSatisfy { $0 == .value } == (tables ? true : nil), "\(cell): kinds")

            func settle() async {
                await keeper.waitForInFlightWorkForTesting()
                #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
            }
            func join() async throws {
                await adapter.onConnect(sessionID: SessionID("s-alice"), clientID: ClientID("c-alice"))
                _ = try await adapter.performJoin(
                    playerSession: PlayerSession(playerID: "alice"),
                    clientID: ClientID("c-alice"),
                    sessionID: SessionID("s-alice"),
                    authInfo: nil
                )
                await adapter.syncStateForNewPlayer(playerID: PlayerID("alice"), sessionID: SessionID("s-alice"))
                await settle()
            }
            func action(_ payload: some ActionPayload) async throws {
                let envelope = ActionEnvelope(typeIdentifier: String(describing: type(of: payload)), payload: AnyCodable(payload))
                _ = try await keeper.handleActionEnvelope(
                    envelope, playerID: PlayerID("alice"), clientID: ClientID("c-alice"), sessionID: SessionID("s-alice")
                )
                await settle()
            }
            func sync() async {
                await adapter.syncNow()
                #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
            }

            try await join()
            await sync()
            for run in 0..<runs.count {
                service.startVerification(landType: "frame-identity", recordFilePath: "/dev/null")
                let task = try #require(service.verificationTaskForTesting())
                await task.value
                await keeper.stepTickOnce()
                await settle()
                await sync()
                if run % 3 == 1 {
                    try await action(PauseVerificationAction())
                    await sync()
                    try await action(ResumeVerificationAction())
                }
                if run == 4 {
                    await adapter.onDisconnect(sessionID: SessionID("s-alice"), clientID: ClientID("c-alice"))
                    await settle()
                    try await join()
                }
                await sync()
            }
            frames.append(await transport.sent)
            #expect(await adapter.syncFailedPlans == 0, "\(cell): no plan failed")
        }
        // messagepack merges events into the state frames, so it sends the fewest.
        #expect(frames[0].count > 10, "\(cell): the script sends frames (\(frames[0].count))")
        #expect(frames[0].map(\.target) == frames[1].map(\.target), "\(cell): targets")
        let first = zip(frames[0], frames[1]).enumerated().first { $0.element.0.data != $0.element.1.data }
        #expect(first == nil && frames[0].count == frames[1].count, "\(cell): frames differ first at \(first?.offset ?? -1) of \(frames[0].count) vs \(frames[1].count)")
    }
}
