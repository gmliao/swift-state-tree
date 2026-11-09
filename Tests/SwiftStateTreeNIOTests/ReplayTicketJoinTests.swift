// Tests/SwiftStateTreeNIOTests/ReplayTicketJoinTests.swift
//
// A replay land is created only from a ticket the admin replay start signed (#366): a join
// whose instance ID names a record in the records directory without a valid ticket creates no
// land and starts no runner, nor does an expired ticket. A valid ticket creates the land, and
// the land stays joinable with the same ID after the ticket's creation window.

import Crypto
import Foundation
import Testing
import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeReevaluationMonitor
@testable import SwiftStateTreeNIO

@StateNodeBuilder
private struct TicketLiveState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
    init() {}
}

private let liveLandType = "ticket-live"
private let replayLandType = "ticket-live-replay"

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// The runner services the replay land type's services factory created, to check which started.
private final class RunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var services: [ReevaluationRunnerService] = []
    func add(_ service: ReevaluationRunnerService) { lock.withLock { services.append(service) } }
    var started: Int { lock.withLock { services.filter { $0.getStatus().phase != .idle }.count } }
    /// Services built: a refused creation builds none (the keeper mode is asked first).
    var created: Int { lock.withLock { services.count } }
}

private struct NoRunnerFactory: ReevaluationTargetFactory {
    func createRunner(landType _: String, recordFilePath _: String) async throws -> any ReevaluationRunnerProtocol {
        IdleRunner()
    }
}

private actor IdleRunner: ReevaluationRunnerProtocol {
    let maxTickId: Int64 = -1
    func prepare() async throws {}
    func step() async throws -> ReevaluationStepResult? { nil }
}

private func base64URL(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private struct Fixture {
    let server: NIOLandServer<TicketLiveState>
    let signer: ReplayTicketSigner
    let clock: Clock
    let runners: RunnerLog
    let pathToken: String

    init(previous: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil) throws {
        let clock = Clock()
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256), lifetime: .seconds(60), now: { clock.now })
        let runners = RunnerLog()
        let recordsDir = FileManager.default.temporaryDirectory.appendingPathComponent("ticket-records").path
        let definition = Land(liveLandType, using: TicketLiveState.self) { Rules {} }
        var base = NIOLandServerConfiguration(
            allowAutoCreateOnJoin: true,
            servicesFactory: { _, _ in
                var services = LandServices()
                let runner = ReevaluationRunnerService(factory: NoRunnerFactory())
                runners.add(runner)
                services.register(runner, as: ReevaluationRunnerService.self)
                return services
            }
        )
        base.keeperModeResolver = previous
        let configuration = base
            .injectingGenericReplayRunnerBootstrap(
                replayLandType: replayLandType, liveLandType: liveLandType, recordsDir: recordsDir, ticketSigner: signer
            )
            .injectingGenericReplayKeeperModeResolver(
                replayLandType: replayLandType, recordsDir: recordsDir, ticketSigner: signer
            )
        server = try NIOLandServer(
            landType: replayLandType,
            landFactory: { _ in definition },
            initialStateFactory: { _ in TicketLiveState() },
            configuration: configuration,
            transport: WebSocketTransport()
        )
        self.signer = signer
        self.clock = clock
        self.runners = runners
        pathToken = base64URL(URL(fileURLWithPath: recordsDir).appendingPathComponent("match.json").path)
    }

    /// Joins `instanceId` from a new session; returns whether the join was admitted (pending or bound).
    func join(_ instanceId: String, session: String) async throws -> Bool {
        let sessionID = SessionID(session)
        let router = server.landRouter
        await router.onConnect(sessionID: sessionID, clientID: ClientID("c-\(session)"))
        let message = TransportMessage.join(
            requestID: "join-\(session)", landType: replayLandType, landInstanceId: instanceId,
            playerID: "p-\(session)", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
        )
        // The land lookup, and so its creation, runs inside onMessage.
        await router.onMessage(try JSONEncoder().encode(message), from: sessionID)
        let pending = await router.isJoinPending(sessionID)
        let bound = await router.getBoundLandID(for: sessionID)
        return pending || bound != nil
    }

    var landCount: Int {
        get async { await server.landManager.listLands().count }
    }
}

@Suite("Replay tickets gate replay land creation")
struct ReplayTicketJoinTests {
    @Test("A record path without a valid ticket creates no land and starts no runner", arguments: [
        "plain",          // the pre-ticket form: any prefix, then the path token
        "missing-mac",    // ticket fields without a MAC
        "bad-mac",        // a well-formed ticket whose MAC doesn't verify
        "other-key",      // signed by another process's key
    ])
    func forgedTicket(kind: String) async throws {
        let f = try Fixture()
        let issued = f.signer.issue(replayLandType: replayLandType, pathToken: f.pathToken)
        let instanceId: String
        switch kind {
        case "plain":
            instanceId = "\(UUID().uuidString.lowercased()).\(f.pathToken)"
        case "missing-mac":
            let fields = issued.split(separator: ".")[0].split(separator: "-")
            instanceId = "\(fields[0])-\(fields[1])-\(fields[2]).\(f.pathToken)"
        case "bad-mac":
            var chars = Array(issued)
            let macEnd = issued.firstIndex(of: ".")!.utf16Offset(in: issued) - 1
            chars[macEnd] = chars[macEnd] == "0" ? "1" : "0"
            instanceId = String(chars)
        default:
            instanceId = ReplayTicketSigner(key: SymmetricKey(size: .bits256), now: { f.clock.now })
                .issue(replayLandType: replayLandType, pathToken: f.pathToken)
        }
        #expect(try await !f.join(instanceId, session: "s1"))
        #expect(await f.landCount == 0)
        #expect(f.runners.started == 0, "no runner started on the record")
        #expect(f.runners.created == 0, "refused before any service was built")
    }

    @Test("A ticket for another replay land type doesn't verify")
    func ticketForAnotherLandType() async throws {
        let f = try Fixture()
        let instanceId = f.signer.issue(replayLandType: "other-replay", pathToken: f.pathToken)
        #expect(try await !f.join(instanceId, session: "s1"))
        #expect(await f.landCount == 0)
        #expect(f.runners.started == 0)
    }

    @Test("An expired ticket creates no land, and the refusal is counted")
    func expiredTicket() async throws {
        let f = try Fixture()
        let instanceId = f.signer.issue(replayLandType: replayLandType, pathToken: f.pathToken)
        f.clock.advance(61)
        let before = ReplayTicketRejections.shared.expired
        #expect(try await !f.join(instanceId, session: "s1"))
        #expect(await f.landCount == 0)
        #expect(f.runners.created == 0, "refused before any service was built")
        #expect(ReplayTicketRejections.shared.expired > before)
    }

    @Test("After its land is removed, an expired ticket doesn't create it again")
    func expiredTicketAfterLandDestroyed() async throws {
        let f = try Fixture()
        let instanceId = f.signer.issue(replayLandType: replayLandType, pathToken: f.pathToken)
        #expect(try await f.join(instanceId, session: "s1"))
        #expect(f.runners.started == 1)
        f.clock.advance(61)
        await f.server.landManager.removeLand(landID: LandID(landType: replayLandType, instanceId: instanceId))
        #expect(await f.landCount == 0)
        #expect(try await !f.join(instanceId, session: "s2"))
        #expect(await f.landCount == 0)
        #expect(f.runners.created == 1, "no second land's services, so no second runner")
    }

    @Test("A valid ticket creates the land; the same ID joins it again after the creation window")
    func validTicketThenRejoin() async throws {
        let f = try Fixture()
        let instanceId = f.signer.issue(replayLandType: replayLandType, pathToken: f.pathToken)
        #expect(try await f.join(instanceId, session: "s1"))
        #expect(await f.landCount == 1)
        #expect(f.runners.started == 1, "the bootstrap started the runner on the record")
        f.clock.advance(3_600)
        #expect(try await f.join(instanceId, session: "s2"), "a reconnect or second viewer joins the existing land")
        #expect(await f.landCount == 1)
        #expect(f.runners.started == 1)
    }

    @Test("A host resolver that answers for the replay land type doesn't let a forged or expired ticket through", arguments: [
        "live", "reevaluation",
    ])
    func previousResolverAnswersFirst(mode: String) async throws {
        let f = try Fixture(previous: { landID, _ in
            guard landID.landType == replayLandType else { return nil }
            return mode == "live" ? .live : .reevaluation(recordFilePath: "/anything.json")
        })
        let forged = "\(UUID().uuidString.lowercased()).\(f.pathToken)"
        #expect(try await !f.join(forged, session: "s1"))
        let expired = f.signer.issue(replayLandType: replayLandType, pathToken: f.pathToken)
        f.clock.advance(61)
        #expect(try await !f.join(expired, session: "s2"))
        #expect(await f.landCount == 0)
        #expect(f.runners.created == 0, "refused before any service was built, so no runner")
    }

    @Test("An oversized ID or MAC field is refused before it is decoded")
    func oversizedFields() {
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256))
        let issued = signer.issue(replayLandType: replayLandType, pathToken: "dG9rZW4")
        let fields = issued.split(separator: ".")[0].split(separator: "-").map(String.init)
        let longMAC = "\(fields[0])-\(fields[1])-\(fields[2])-\(fields[3])\(String(repeating: "0", count: 1_000_000)).dG9rZW4"
        #expect(signer.verify(instanceId: longMAC, replayLandType: replayLandType) == .invalid)
        let longToken = signer.issue(replayLandType: replayLandType, pathToken: String(repeating: "A", count: ReplayTicketSigner.maxInstanceIDLength))
        #expect(signer.verify(instanceId: longToken, replayLandType: replayLandType) == .invalid)
    }

    @Test("registerWithReevaluation's resolver: only a valid, unexpired ticket gives a reevaluation keeper")
    func reevaluationResolver() throws {
        let clock = Clock()
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256), lifetime: .seconds(60), now: { clock.now })
        let recordsDir = FileManager.default.temporaryDirectory.appendingPathComponent("ticket-records").path
        let recordPath = URL(fileURLWithPath: recordsDir).appendingPathComponent("match.json").path
        let token = base64URL(recordPath)
        let resolver = try #require(NIOLandServerConfiguration()
            .injectingReevaluationKeeperModeResolver(replayLandType: replayLandType, recordsDir: recordsDir, ticketSigner: signer)
            .keeperModeResolver)
        func mode(_ instanceId: String) -> LandKeeperModeConfig? {
            resolver(LandID(landType: replayLandType, instanceId: instanceId), [:])
        }
        let issued = signer.issue(replayLandType: replayLandType, pathToken: token)
        guard case .reevaluation(let path)? = mode(issued) else {
            Issue.record("a valid ticket: \(String(describing: mode(issued)))")
            return
        }
        #expect(path == recordPath)
        guard case .invalidReplaySession? = mode("\(UUID().uuidString.lowercased()).\(token)") else {
            Issue.record("no ticket must be refused")
            return
        }
        clock.advance(61)
        guard case .invalidReplaySession? = mode(issued) else {
            Issue.record("an expired ticket must be refused")
            return
        }
    }

    @Test("A ticket has one spelling: a changed field doesn't verify")
    func oneSpelling() {
        let signer = ReplayTicketSigner(key: SymmetricKey(size: .bits256))
        let issued = signer.issue(replayLandType: replayLandType, pathToken: "dG9rZW4")
        #expect(signer.verify(instanceId: issued, replayLandType: replayLandType) == .valid)
        let head = issued.split(separator: ".")[0]
        let fields = head.split(separator: "-").map(String.init)
        let variants = [
            "\(fields[0])-\(fields[1])-+\(fields[2])-\(fields[3]).dG9rZW4",
            "\(fields[0])-\(fields[1].uppercased())-\(fields[2])-\(fields[3]).dG9rZW4",
            "\(fields[0])-\(fields[1])-\(fields[2])-\(fields[3].uppercased()).dG9rZW4",
            "\(fields[0])-\(fields[1])-0\(fields[2])-\(fields[3]).dG9rZW4",
            "\(head).dG9rZW5",
            "\(head)",
        ]
        for variant in variants {
            #expect(signer.verify(instanceId: variant, replayLandType: replayLandType) == .invalid, "\(variant)")
        }
    }
}

@StateNodeBuilder
private struct TicketReplayState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
    init() {}
}

@Suite("registerWithReevaluation gates its replay land on a replay ticket")
struct RegisterWithReevaluationTicketTests {
    @Test("Through the public registration: a forged ID creates no replay land, a ticket from the admin start's signer does")
    func gate() async throws {
        let host = NIOLandHost(configuration: NIOLandHostConfiguration(host: "localhost", port: 8080, adminAPIKey: "k"))
        try await host.registerWithReevaluation(
            landType: liveLandType,
            liveLand: Land(liveLandType, using: TicketLiveState.self) { Rules {} },
            liveInitialState: TicketLiveState(),
            liveWebSocketPath: "/game/\(liveLandType)",
            replayLand: Land(replayLandType, using: TicketReplayState.self) { Rules {} },
            replayInitialState: TicketReplayState(),
            configuration: NIOLandServerConfiguration(allowAutoCreateOnJoin: true),
            reevaluation: ReevaluationFeatureConfiguration(
                enabled: true,
                runnerServiceFactory: { ReevaluationRunnerService(factory: NoRunnerFactory()) }
            )
        )
        let transport = try #require(await host.transportForTesting(webSocketPath: "/game/\(replayLandType)"))
        let router = try #require(await transport.delegate)
        let recordsDir = NIOEnvConfig.fromEnvironment().reevaluationRecordsDir
        // Spelled as the containment check spells the records directory (the default is relative).
        let pathToken = base64URL(URL(fileURLWithPath: recordsDir, isDirectory: true).standardizedFileURL.path + "/match.json")
        func join(_ instanceId: String, _ session: String) async throws {
            let sessionID = SessionID(session)
            await router.onConnect(sessionID: sessionID, clientID: ClientID("c-\(session)"), authInfo: nil)
            let message = TransportMessage.join(
                requestID: "j-\(session)", landType: replayLandType, landInstanceId: instanceId,
                playerID: "p-\(session)", deviceID: nil, metadata: StateUpdateFeature.joinMetadata
            )
            await router.onMessage(try JSONEncoder().encode(message), from: sessionID)
        }
        func replayLands() async -> Int {
            await host.realm.listAllLands().filter { $0.landType == replayLandType }.count
        }
        try await join("\(UUID().uuidString.lowercased()).\(pathToken)", "forged")
        #expect(await replayLands() == 0)
        try await join(ReplayTicketSigner.process.issue(replayLandType: replayLandType, pathToken: pathToken), "valid")
        #expect(await replayLands() == 1)
    }
}
