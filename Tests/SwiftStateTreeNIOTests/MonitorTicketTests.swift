// Tests/SwiftStateTreeNIOTests/MonitorTicketTests.swift
//
// The reevaluation monitor land is created only from a monitor ticket the admin monitor start
// signed (#366), and verifies the record bound in that ticket: never a path or a land type the
// client sends. A replay ticket and a monitor ticket never open each other's land. Also: the
// generic replay registration's gate, through its public method.

import Crypto
import Foundation
import Logging
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeReevaluationMonitor
@testable import SwiftStateTreeNIO

@StateNodeBuilder
private struct MonitorTestLiveState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast)
    var value: Int = 0
    init() {}
}

private let liveType = "monitor-live"
private let monitorType = "reevaluation-monitor"

private func base64URL(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Records each run the runner services were asked for.
private final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(landType: String, path: String)] = []
    private var services: [ReevaluationRunnerService] = []
    func add(_ landType: String, _ path: String) { lock.withLock { entries.append((landType, path)) } }
    func add(_ service: ReevaluationRunnerService) { lock.withLock { services.append(service) } }
    var runs: [(landType: String, path: String)] { lock.withLock { entries } }
    var runners: [ReevaluationRunnerService] { lock.withLock { services } }
}

/// Holds `step()` until released, so a run stays in `.verifying`.
private final class StepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock { () -> Bool in
                if open { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

private struct LoggingFactory: ReevaluationTargetFactory {
    let log: RunLog
    let gate: StepGate?
    let fail: Bool
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        log.add(landType, recordFilePath)
        if fail { throw TestFailure() }
        return GatedRunner(gate: gate)
    }
}

private struct TestFailure: Error {}

private actor GatedRunner: ReevaluationRunnerProtocol {
    let gate: StepGate?
    nonisolated let maxTickId: Int64 = 0
    init(gate: StepGate?) { self.gate = gate }
    func prepare() async throws {}
    func step() async throws -> ReevaluationStepResult? {
        await gate?.wait()
        return nil
    }
}

@Suite("Monitor tickets")
struct MonitorTicketTests {
    // MARK: Ticket kinds

    @Test("A replay ticket never opens a monitor land, and a monitor ticket never opens a replay land")
    func kindsDontCross() {
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256))
        let replay = signer.issue(replayLandType: monitorType, pathToken: "dG9rZW4")
        #expect(signer.inspect(instanceId: replay, kind: .monitor, landType: monitorType).verdict == .invalid)
        let monitor = signer.issueMonitor(monitorLandType: "x-replay", liveLandType: liveType, pathToken: "dG9rZW4")
        #expect(signer.verify(instanceId: monitor, replayLandType: "x-replay") == .invalid)
        // Its own kind and land type verify; another monitor land type doesn't.
        let own = signer.issueMonitor(monitorLandType: monitorType, liveLandType: liveType, pathToken: "dG9rZW4")
        #expect(signer.inspect(instanceId: own, kind: .monitor, landType: monitorType)
            == .valid(.init(liveLandType: liveType, pathToken: "dG9rZW4")))
        #expect(signer.inspect(instanceId: own, kind: .monitor, landType: "other-monitor") == .badMAC)
    }

    @Test("The live land type is signed: a ticket with another one doesn't verify")
    func liveLandTypeSigned() {
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256))
        let ticket = signer.issueMonitor(monitorLandType: monitorType, liveLandType: liveType, pathToken: "dG9rZW4")
        let head = ticket.split(separator: ".")[0].split(separator: "-").map(String.init)
        let other = Data("other-live".utf8).map { String(format: "%02x", $0) }.joined()
        let swapped = "\(head[0])-\(head[1])-\(head[2])-\(other)-\(head[4]).dG9rZW4"
        #expect(signer.inspect(instanceId: swapped, kind: .monitor, landType: monitorType) == .badMAC)
    }

    @Test("An oversized ID is refused before it is parsed")
    func oversizedRefusedFirst() {
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256))
        // Well formed and correctly signed, but one byte past the bound: refused by length.
        let token = String(repeating: "A", count: ReplayTicketSigner.maxInstanceIDLength)
        let ticket = signer.issue(replayLandType: "x-replay", pathToken: token)
        #expect(signer.inspect(instanceId: ticket, kind: .replay, landType: "x-replay") == .tooLong)
        // Malformed and oversized: still the length, so nothing was parsed.
        let junk = String(repeating: "-", count: ReplayTicketSigner.maxInstanceIDLength + 1)
        #expect(signer.inspect(instanceId: junk, kind: .replay, landType: "x-replay") == .tooLong)
    }

    @Test("The monitor land is registered with its own path hashes, not the live land's")
    func monitorPathHashes() throws {
        var live = NIOLandServerConfiguration()
        live.pathHashes = ["score": 1, "monsters.*.position": 2]
        let monitor = try live.monitorLandConfiguration(monitorLandType: monitorType, recordsDir: "./records")
        let land = ReevaluationMonitor.makeLand()
        let expected = try #require(try SchemaExtractor.extract(from: land).lands[land.id]?.pathHashes)
        #expect(monitor.pathHashes == expected)
        #expect(monitor.pathHashes?["status"] != nil)
        // Without path hashes the live land sends string paths, and so does the monitor.
        let plain = try NIOLandServerConfiguration().monitorLandConfiguration(monitorLandType: monitorType, recordsDir: "./records")
        #expect(plain.pathHashes == nil)
    }

    // MARK: The action

    private func monitorContext(run: ReevaluationMonitorRun, runner: ReevaluationRunnerService) -> LandContext {
        var services = LandServices()
        services.register(runner, as: ReevaluationRunnerService.self)
        services.register(run, as: ReevaluationMonitorRun.self)
        return LandContext(
            landID: "\(monitorType):t", playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"),
            services: services, logger: Logger(label: "test"), deviceID: nil, metadata: [:],
            emitEventHandler: { _, _ in }, requestSyncNowHandler: {}, requestSyncBroadcastOnlyHandler: {}
        )
    }

    private func startAction() throws -> AnyActionHandler<ReevaluationMonitorState> {
        try #require(ReevaluationMonitor.makeLand().actionHandlers.first {
            $0.getActionType() == StartVerificationAction.self
        })
    }

    @Test("StartVerification while the run is verifying is a no-op")
    func startWhileVerifying() async throws {
        let log = RunLog()
        let gate = StepGate()
        let runner = ReevaluationRunnerService(factory: LoggingFactory(log: log, gate: gate, fail: false))
        let run = ReevaluationMonitorRun(landType: liveType, recordFilePath: "/records/ticket.json")
        runner.startVerification(landType: run.landType, recordFilePath: run.recordFilePath)
        // The runner is set (phase .verifying) before its first step, which the gate holds.
        while runner.getStatus().phase != .verifying { await Task.yield() }

        var state = ReevaluationMonitorState()
        _ = try startAction().invoke(&state, action: StartVerificationAction(landType: "evil", recordFilePath: "/etc/x"),
                                     ctx: monitorContext(run: run, runner: runner))
        // A second run would show up once its task has run; wait for whichever task the
        // service holds now, then count.
        gate.release()
        await runner.verificationTaskForTesting()?.value
        #expect(log.runs.count == 1, "no second run while verifying")
    }

    @Test("StartVerification after the run finished restarts it on the ticket's record, ignoring the client's", arguments: [false, true])
    func restartAfterTerminal(failFirst: Bool) async throws {
        let log = RunLog()
        let runner = ReevaluationRunnerService(factory: LoggingFactory(log: log, gate: nil, fail: failFirst))
        let run = ReevaluationMonitorRun(landType: liveType, recordFilePath: "/records/ticket.json")
        runner.startVerification(landType: run.landType, recordFilePath: run.recordFilePath)
        await runner.verificationTaskForTesting()?.value
        #expect(runner.getStatus().phase == (failFirst ? .failed : .completed))

        var state = ReevaluationMonitorState()
        _ = try startAction().invoke(&state, action: StartVerificationAction(landType: "evil", recordFilePath: "/etc/x"),
                                     ctx: monitorContext(run: run, runner: runner))
        await runner.verificationTaskForTesting()?.value
        #expect(log.runs.count == 2)
        #expect(log.runs.last?.landType == liveType)
        #expect(log.runs.last?.path == "/records/ticket.json")
    }

    // MARK: Through the public registration

    @Test("registerWithGenericReplay: the monitor land opens only from a monitor ticket and runs its record; the replay land only from a replay ticket")
    func publicRegistration() async throws {
        let log = RunLog()
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, adminAPIKey: "k"))
        try await host.registerWithGenericReplay(
            landType: liveType,
            liveLand: Land(liveType, using: MonitorTestLiveState.self) { Rules {} },
            liveInitialState: MonitorTestLiveState(),
            liveWebSocketPath: "/game/\(liveType)",
            configuration: NIOLandServerConfiguration(allowAutoCreateOnJoin: true),
            reevaluation: ReevaluationFeatureConfiguration(
                enabled: true,
                runnerServiceFactory: {
                    let service = ReevaluationRunnerService(factory: LoggingFactory(log: log, gate: nil, fail: false))
                    log.add(service)
                    return service
                }
            )
        )
        let recordsDir = NIOEnvConfig.fromEnvironment().reevaluationRecordsDir
        // Spelled as the containment check standardizes it (see #366 item 1 on spellings).
        let recordPath = URL(fileURLWithPath: recordsDir, isDirectory: true).standardizedFileURL.path + "/ticket.json"
        let token = base64URL(recordPath)
        let signer = ReplayTicketSigner.process

        func join(_ path: String, _ landType: String, _ instanceId: String?, _ session: String) async throws {
            let transport = try #require(await host.transportForTesting(webSocketPath: path))
            let router = try #require(await transport.delegate)
            let sessionID = SessionID(session)
            await router.onConnect(sessionID: sessionID, clientID: ClientID("c-\(session)"), authInfo: nil)
            let message = TransportMessage.join(
                requestID: "j-\(session)", landType: landType, landInstanceId: instanceId,
                playerID: "p-\(session)", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
            )
            await router.onMessage(try JSONEncoder().encode(message), from: sessionID)
        }
        func lands(_ landType: String) async -> Int {
            await host.realm.listAllLands().filter { $0.landType == landType }.count
        }

        // The monitor land: no instance ID, an old random ID, a replay ticket: no land, no run.
        try await join("/reevaluation-monitor", monitorType, nil, "m-none")
        try await join("/reevaluation-monitor", monitorType, UUID().uuidString, "m-uuid")
        try await join("/reevaluation-monitor", monitorType, signer.issue(replayLandType: monitorType, pathToken: token), "m-replay")
        #expect(await lands(monitorType) == 0)
        #expect(log.runs.isEmpty)
        // A monitor ticket: the land, and its run on the ticket's record and live land type.
        try await join("/reevaluation-monitor", monitorType,
                       signer.issueMonitor(monitorLandType: monitorType, liveLandType: liveType, pathToken: token), "m-ok")
        #expect(await lands(monitorType) == 1)
        for runner in log.runners { await runner.verificationTaskForTesting()?.value }
        #expect(log.runs.count == 1)
        #expect(log.runs.first?.landType == liveType)
        #expect(log.runs.first?.path == recordPath)

        // The replay land (the generic registration's gate, through its public method): a
        // forged ID and a monitor ticket create nothing; a replay ticket creates the land.
        let replayType = "\(liveType)-replay"
        let replayToken = token
        try await join("/game/\(replayType)", replayType, "\(UUID().uuidString.lowercased()).\(replayToken)", "r-forged")
        try await join("/game/\(replayType)", replayType,
                       signer.issueMonitor(monitorLandType: replayType, liveLandType: liveType, pathToken: replayToken), "r-monitor")
        #expect(await lands(replayType) == 0)
        try await join("/game/\(replayType)", replayType, signer.issue(replayLandType: replayType, pathToken: replayToken), "r-ok")
        #expect(await lands(replayType) == 1)
    }
}
