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
    /// Holds the run in `.loading` (inside `createRunner`) until released.
    var createGate: StepGate? = nil
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        log.add(landType, recordFilePath)
        await createGate?.wait()
        if fail { throw TestFailure() }
        return GatedRunner(gate: gate)
    }
}

private struct TestFailure: Error {}

/// The run for `/old` waits on `gate`, then fails; any other run completes at once.
private struct StaleRunFactory: ReevaluationTargetFactory {
    let gate: StepGate
    func createRunner(landType _: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        if recordFilePath == "/old" {
            await gate.wait()
            throw TestFailure()
        }
        return GatedRunner(gate: nil)
    }
}

/// `/old` and `/new` each return one result (`stateHash` is the path's name) after their
/// gate opens, then finish.
private struct ResultRunFactory: ReevaluationTargetFactory {
    let oldGate: StepGate
    let newGate: StepGate
    func createRunner(landType _: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        recordFilePath == "/old" ? OneResultRunner(gate: oldGate, hash: "old") : OneResultRunner(gate: newGate, hash: "new")
    }
}

private actor OneResultRunner: ReevaluationRunnerProtocol {
    let gate: StepGate
    let hash: String
    var stepped = false
    nonisolated let maxTickId: Int64 = 0
    init(gate: StepGate, hash: String) { self.gate = gate; self.hash = hash }
    func prepare() async throws {}
    func step() async throws -> ReevaluationStepResult? {
        if stepped { return nil }
        stepped = true
        await gate.wait()
        return ReevaluationStepResult(tickId: hash == "old" ? 7 : 1, stateHash: hash, recordedHash: hash, isMatch: true)
    }
}

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

@Suite("Monitor tickets", .timeLimit(.minutes(1)))
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
        while runner.getStatus().phase != .verifying { try Task.checkCancellation(); await Task.yield() }

        let ticket = runner.generationForTesting()
        var state = ReevaluationMonitorState()
        _ = try startAction().invoke(&state, action: StartVerificationAction(landType: "evil", recordFilePath: "/etc/x"),
                                     ctx: monitorContext(run: run, runner: runner))
        // A request would have taken a new ticket synchronously, in the turn.
        #expect(runner.generationForTesting() == ticket, "no run requested while verifying")
        #expect(runner.getStatus().phase == .verifying)
        gate.release()
        await runner.verificationTaskForTesting()?.value
        #expect(log.runs.count == 1)
    }

    @Test("StartVerification while the run is loading or paused is a no-op", arguments: ["loading", "paused"])
    func startWhileLoadingOrPaused(phase: String) async throws {
        let log = RunLog()
        let stepGate = StepGate()
        let createGate = StepGate()
        let runner = ReevaluationRunnerService(factory: LoggingFactory(
            log: log, gate: stepGate, fail: false, createGate: phase == "loading" ? createGate : nil
        ))
        let run = ReevaluationMonitorRun(landType: liveType, recordFilePath: "/records/ticket.json")
        runner.startVerification(landType: run.landType, recordFilePath: run.recordFilePath)
        if phase == "loading" {
            // `createRunner` holds on the gate, so the run stays in `.loading`.
            while log.runs.isEmpty { try Task.checkCancellation(); await Task.yield() }
            #expect(runner.getStatus().phase == .loading)
        } else {
            while runner.getStatus().phase != .verifying { try Task.checkCancellation(); await Task.yield() }
            runner.pause()
            #expect(runner.getStatus().phase == .paused)
        }

        let ticket = runner.generationForTesting()
        let before = runner.getStatus().phase
        var state = ReevaluationMonitorState()
        _ = try startAction().invoke(&state, action: StartVerificationAction(landType: "evil", recordFilePath: "/etc/x"),
                                     ctx: monitorContext(run: run, runner: runner))
        #expect(runner.generationForTesting() == ticket, "no run requested while \(phase)")
        #expect(runner.getStatus().phase == before)
        createGate.release()
        runner.resume()
        stepGate.release()
        await runner.verificationTaskForTesting()?.value
        #expect(log.runs.count == 1)
    }

    @Test("A replaced run can't write: its late failure doesn't touch the current run's status")
    func replacedRunCantWrite() async throws {
        let gate = StepGate()
        let runner = ReevaluationRunnerService(factory: StaleRunFactory(gate: gate))
        runner.startDriver()
        runner.startVerification(landType: liveType, recordFilePath: "/old")
        let old = try #require(runner.verificationTaskForTesting())
        // A turn requests a new run while the old one is still loading.
        runner.requestVerification(landType: liveType, recordFilePath: "/new")
        await runner.waitForRunsStartedForTesting(2)
        await runner.verificationTaskForTesting()?.value
        #expect(runner.getStatus().phase == .completed)
        // The old run now fails; its ticket is stale, so the status stays the new run's.
        gate.release()
        await old.value
        #expect(runner.getStatus().phase == .completed)
        #expect(runner.getStatus().recordFilePath == "/new")
    }

    @Test("A run replaced mid-run can't write: its late result is dropped, and the current run is undisturbed")
    func replacedRunLateResult() async throws {
        let oldGate = StepGate()
        let newGate = StepGate()
        let runner = ReevaluationRunnerService(factory: ResultRunFactory(oldGate: oldGate, newGate: newGate))
        runner.startVerification(landType: liveType, recordFilePath: "/old")
        while runner.getStatus().phase != .verifying { try Task.checkCancellation(); await Task.yield() }
        let old = try #require(runner.verificationTaskForTesting())
        // A direct start while the old run is in its step: the old run's step will still return.
        runner.startVerification(landType: liveType, recordFilePath: "/new")
        while runner.getStatus().phase != .verifying { try Task.checkCancellation(); await Task.yield() }
        let current = try #require(runner.verificationTaskForTesting())

        oldGate.release()
        await old.value
        #expect(runner.consumeResults().isEmpty, "the old run's late result is dropped")
        #expect(runner.getStatus().phase == .verifying)
        #expect(runner.getStatus().recordFilePath == "/new")
        #expect(runner.getStatus().currentTick == 0)

        newGate.release()
        await current.value
        #expect(runner.getStatus().phase == .completed)
        #expect(runner.consumeResults().map(\.stateHash) == ["new"], "the current run stepped its own runner once")
    }

    @Test("A stopped run can't write: its late result is dropped and the phase stays idle")
    func stoppedRunCantWrite() async throws {
        let gate = StepGate()
        let runner = ReevaluationRunnerService(factory: ResultRunFactory(oldGate: gate, newGate: StepGate()))
        runner.startVerification(landType: liveType, recordFilePath: "/old")
        while runner.getStatus().phase != .verifying { try Task.checkCancellation(); await Task.yield() }
        let run = try #require(runner.verificationTaskForTesting())
        runner.stop()
        gate.release()
        await run.value
        #expect(runner.consumeResults().isEmpty, "the stopped run's late result is dropped")
        #expect(runner.getStatus().phase == .idle)
    }

    @Test("The run starts in the first join's turn, not before; a rejoin mid-run or after completion doesn't restart it")
    func runStartsOnFirstJoin() async throws {
        let log = RunLog()
        let gate = StepGate()
        let runner = ReevaluationRunnerService(factory: LoggingFactory(log: log, gate: gate, fail: false))
        runner.startDriver()
        var services = LandServices()
        services.register(runner, as: ReevaluationRunnerService.self)
        services.register(ReevaluationMonitorRun(landType: liveType, recordFilePath: "/records/ticket.json"),
                          as: ReevaluationMonitorRun.self)
        let keeper = LandKeeper<ReevaluationMonitorState>(
            definition: ReevaluationMonitor.makeLand(),
            initialState: ReevaluationMonitorState(),
            services: services,
            autoStartLoops: false
        )
        // Ticks before anyone joined: no run, so no result is emitted to nobody.
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(runner.generationForTesting() == 0)
        #expect(runner.getStatus().phase == .idle)

        // A ticking land applies OnJoin in its next turn.
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        #expect(runner.generationForTesting() == 0, "the join is a turn input, not yet applied")
        await keeper.stepTickOnce()
        #expect(runner.generationForTesting() == 1, "the join's turn requested the run")
        await runner.waitForRunsStartedForTesting(1)
        while runner.getStatus().phase != .verifying { try Task.checkCancellation(); await Task.yield() }

        // The land admits one player. A rejoin mid-run keeps the same run.
        try await keeper.leave(playerID: PlayerID("p1"), clientID: ClientID("c1"))
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s2"))
        await keeper.stepTickOnce()
        #expect(runner.generationForTesting() == 1, "a rejoin mid-run requests nothing")
        #expect(runner.getStatus().phase == .verifying)

        gate.release()
        await runner.verificationTaskForTesting()?.value
        #expect(runner.getStatus().phase == .completed)
        #expect(log.runs.count == 1)
        #expect(log.runs.first?.path == "/records/ticket.json")

        // A rejoin after completion doesn't restart it either; that is the action's job.
        try await keeper.leave(playerID: PlayerID("p1"), clientID: ClientID("c1"))
        try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s3"))
        await keeper.stepTickOnce()
        #expect(runner.generationForTesting() == 1, "a rejoin after completion requests nothing")
        #expect(log.runs.count == 1)
    }

    @Test("StartVerification after the run finished restarts it on the ticket's record, ignoring the client's", arguments: [false, true])
    func restartAfterTerminal(failFirst: Bool) async throws {
        let log = RunLog()
        let runner = ReevaluationRunnerService(factory: LoggingFactory(log: log, gate: nil, fail: failFirst))
        runner.startDriver()
        let run = ReevaluationMonitorRun(landType: liveType, recordFilePath: "/records/ticket.json")
        runner.startVerification(landType: run.landType, recordFilePath: run.recordFilePath)
        await runner.verificationTaskForTesting()?.value
        #expect(runner.getStatus().phase == (failFirst ? .failed : .completed))

        let before = runner.generationForTesting()
        var state = ReevaluationMonitorState()
        _ = try startAction().invoke(&state, action: StartVerificationAction(landType: "evil", recordFilePath: "/etc/x"),
                                     ctx: monitorContext(run: run, runner: runner))
        // The turn only requested the run (one new ticket, taken in the turn); the driver starts it.
        #expect(runner.generationForTesting() == before + 1)
        await runner.waitForRunsStartedForTesting(2)
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
        // The join's turn requests the run; the driver the creation started runs it.
        for runner in log.runners {
            await runner.waitForRunsStartedForTesting(1)
            await runner.verificationTaskForTesting()?.value
        }
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// A monitor land server gated by `monitorLandConfiguration` with a test signer and clock; its
/// services factory records each runner service it builds.
private struct MonitorFixture {
    let server: NIOLandServer<ReevaluationMonitorState>
    let signer: ReplayTicketSigner
    let clock: TestClock
    let log: RunLog
    let pathToken: String

    init(previous: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil, recordLive: Bool = false) throws {
        let clock = TestClock()
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256), lifetime: .seconds(60), now: { clock.now })
        let log = RunLog()
        let recordsDir = FileManager.default.temporaryDirectory.appendingPathComponent("monitor-records").path
        var base = NIOLandServerConfiguration(
            allowAutoCreateOnJoin: true,
            servicesFactory: { _, _ in
                var services = LandServices()
                let runner = ReevaluationRunnerService(factory: LoggingFactory(log: log, gate: nil, fail: false))
                log.add(runner)
                services.register(runner, as: ReevaluationRunnerService.self)
                return services
            }
        )
        base.keeperModeResolver = previous
        base.enableLiveStateHashRecording = recordLive
        server = try NIOLandServer(
            landType: monitorType,
            landFactory: { _ in ReevaluationMonitor.makeLand() },
            initialStateFactory: { _ in ReevaluationMonitorState() },
            configuration: try base.monitorLandConfiguration(
                monitorLandType: monitorType, recordsDir: recordsDir, ticketSigner: signer
            ),
            transport: WebSocketTransport()
        )
        self.signer = signer
        self.clock = clock
        self.log = log
        pathToken = base64URL(URL(fileURLWithPath: recordsDir).appendingPathComponent("match.json").path)
    }

    func ticket() -> String {
        signer.issueMonitor(monitorLandType: monitorType, liveLandType: liveType, pathToken: pathToken)
    }

    /// Joins `instanceId` from a new session; returns whether the join was admitted.
    func join(_ instanceId: String, session: String) async throws -> Bool {
        let sessionID = SessionID(session)
        let router = server.landRouter
        await router.onConnect(sessionID: sessionID, clientID: ClientID("c-\(session)"))
        let message = TransportMessage.join(
            requestID: "join-\(session)", landType: monitorType, landInstanceId: instanceId,
            playerID: "p-\(session)", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        )
        await router.onMessage(try JSONEncoder().encode(message), from: sessionID)
        let pending = await router.isJoinPending(sessionID)
        let bound = await router.getBoundLandID(for: sessionID)
        return pending || bound != nil
    }

    var landCount: Int {
        get async { await server.landManager.listLands().count }
    }
}

@Suite("Monitor tickets gate monitor land creation", .timeLimit(.minutes(1)))
struct MonitorTicketGateTests {
    @Test("A forged ID creates no monitor land and builds no services", arguments: ["uuid", "replay-ticket", "bad-mac", "other-key"])
    func forged(kind: String) async throws {
        let f = try MonitorFixture()
        let issued = f.ticket()
        let instanceId: String
        switch kind {
        case "uuid": instanceId = UUID().uuidString
        case "replay-ticket": instanceId = f.signer.issue(replayLandType: monitorType, pathToken: f.pathToken)
        case "bad-mac":
            var chars = Array(issued)
            let macEnd = issued.firstIndex(of: ".").map { issued.distance(from: issued.startIndex, to: $0) } ?? 1
            chars[macEnd - 1] = chars[macEnd - 1] == "0" ? "1" : "0"
            instanceId = String(chars)
        default:
            instanceId = ReplayTicketSigner(key: SymmetricKey(size: .bits256))
                .issueMonitor(monitorLandType: monitorType, liveLandType: liveType, pathToken: f.pathToken)
        }
        #expect(try await !f.join(instanceId, session: "s1"))
        #expect(await f.landCount == 0)
        #expect(f.log.runners.isEmpty)
    }

    @Test("An expired ticket creates no monitor land, and the refusal is counted")
    func expired() async throws {
        let f = try MonitorFixture()
        let issued = f.ticket()
        let before = ReplayTicketRejections.shared.expired
        f.clock.advance(61)
        #expect(try await !f.join(issued, session: "s1"))
        #expect(await f.landCount == 0)
        #expect(ReplayTicketRejections.shared.expired > before)
    }

    @Test("A monitor land is never recorded, even when the live land is")
    func monitorNotRecorded() async throws {
        var live = NIOLandServerConfiguration(allowAutoCreateOnJoin: true)
        live.enableLiveStateHashRecording = true
        #expect(try live.monitorLandConfiguration(monitorLandType: monitorType, recordsDir: "./records")
            .enableLiveStateHashRecording == false)
        let f = try MonitorFixture(recordLive: true)
        let issued = f.ticket()
        #expect(try await f.join(issued, session: "s1"))
        let container = try #require(await f.server.landManager.getLand(landID: LandID(landType: monitorType, instanceId: issued)))
        #expect(await container.keeper.getReevaluationRecorder() == nil)
    }

    @Test("After its land is removed, an expired ticket doesn't create it again")
    func expiredAfterLandRemoved() async throws {
        let f = try MonitorFixture()
        let issued = f.ticket()
        #expect(try await f.join(issued, session: "s1"))
        #expect(await f.landCount == 1)
        f.clock.advance(61)
        await f.server.landManager.removeLand(landID: LandID(landType: monitorType, instanceId: issued))
        #expect(await f.landCount == 0)
        #expect(try await !f.join(issued, session: "s2"))
        #expect(await f.landCount == 0)
    }

    @Test("A host resolver that answers for the monitor land type doesn't let a forged or expired ticket through", arguments: [
        "live", "reevaluation",
    ])
    func previousResolverAnswersFirst(mode: String) async throws {
        let f = try MonitorFixture(previous: { landID, _ in
            guard landID.landType == monitorType else { return nil }
            return mode == "live" ? .live : .reevaluation(recordFilePath: "/anything.json")
        })
        #expect(try await !f.join(UUID().uuidString, session: "s1"))
        let expired = f.ticket()
        f.clock.advance(61)
        #expect(try await !f.join(expired, session: "s2"))
        #expect(await f.landCount == 0)
        #expect(f.log.runners.isEmpty, "refused before any service was built")
    }
}
