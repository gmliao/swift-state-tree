// Tests/SwiftStateTreeTransportTests/LandLifecycleLogTests.swift
//
// The land lifecycle log (opt-in, `LAND_LIFECYCLE_LOG_PATH`): one JSON line per land instance
// created, removed by ID, and destroyed, with a process-monotonic instance number, so a
// measurement can tell a recreated land from a surviving one.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct LifecycleLogTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

/// Collects the log's lines in memory.
private final class LineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }

    var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored.count
    }

    var records: [LandLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
            .filter { !$0.contains("\"event\":\"session") }
            .map { try! JSONDecoder().decode(LandLifecycleRecord.self, from: Data($0.utf8)) }
    }

    var sessionRecords: [SessionLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
            .filter { $0.contains("\"event\":\"session") }
            .map { try! JSONDecoder().decode(SessionLifecycleRecord.self, from: Data($0.utf8)) }
    }
}

struct LifecycleLogInitOutput: ResolverOutput {
    let value: Int
}

/// Never returns until the test's gate opens: the land's initialization times out.
struct LifecycleLogStuckResolver: ContextResolver {
    typealias Output = LifecycleLogInitOutput
    static let gate = TestGate()
    static func resolve(ctx: ResolverContext) async throws -> LifecycleLogInitOutput {
        await gate.arrive()
        return LifecycleLogInitOutput(value: 0)
    }
}

private func stuckInitLand(_ landID: LandID) -> LandDefinition<LifecycleLogTestState> {
    Land(landID.landType, using: LifecycleLogTestState.self) {
        Rules {}
        Lifetime {
            OnInitialize(resolvers: LifecycleLogStuckResolver.self) { (_: inout LifecycleLogTestState, _: LandContext) in }
        }
    }
}

private func emptyTimeoutLand(_ landID: LandID) -> LandDefinition<LifecycleLogTestState> {
    Land(landID.landType, using: LifecycleLogTestState.self) {
        Lifetime {
            DestroyWhenEmpty(after: .milliseconds(10)) { (_: inout LifecycleLogTestState, _: LandContext) in }
        }
        Rules {}
    }
}

private func makeManager(_ sink: LineSink) async -> LandManager<LifecycleLogTestState> {
    let manager = LandManager<LifecycleLogTestState>(
        landFactory: { emptyTimeoutLand($0) },
        initialStateFactory: { _ in LifecycleLogTestState() }
    )
    await manager.installLifecycleLog(LandLifecycleLog(write: { sink.append($0) }))
    return manager
}

private func create(
    _ manager: LandManager<LifecycleLogTestState>,
    _ landID: LandID
) async throws -> LandContainer<LifecycleLogTestState> {
    try await manager.getOrCreateLand(
        landID: landID,
        definition: emptyTimeoutLand(landID),
        initialState: LifecycleLogTestState(),
        metadata: [:]
    )
}

/// Joins and leaves one player, so the empty-room timer starts; returns once the destruction,
/// the manager's `onLandDestroyed` included, is over.
private func emptyAndDestroy(_ container: LandContainer<LifecycleLogTestState>) async throws {
    let player = PlayerID("p1")
    let client = ClientID("c1")
    _ = try await container.keeper.join(playerID: player, clientID: client, sessionID: SessionID("s1"))
    try await container.keeper.leave(playerID: player, clientID: client)
    while !container.keeper.isDraining { await Task.yield() }
    await container.keeper.waitUntilDrained()
}

@Suite("Land lifecycle log", .timeLimit(.minutes(1)))
struct LandLifecycleLogTests {
    @Test("Off unless LAND_LIFECYCLE_LOG_PATH is set")
    func offByDefault() {
        #expect(LandLifecycleLog.fromEnvironment([:]) == nil)
        #expect(LandLifecycleLog.fromEnvironment(["LAND_LIFECYCLE_LOG_PATH": ""]) == nil)
    }

    @Test("A land emptied and destroyed by its timer logs created, then destroyed with cause emptyTimeout")
    func emptyTimeout() async throws {
        let sink = LineSink()
        let manager = await makeManager(sink)
        let landID = LandID(landType: "lifecycle", instanceId: "room-1")
        try await emptyAndDestroy(try await create(manager, landID))

        let records = sink.records
        #expect(records.map(\.event) == [.created, .destroyed])
        try #require(records.count == 2)
        #expect(records.allSatisfy { $0.landID == "lifecycle:room-1" && $0.landType == "lifecycle" })
        #expect(records[1].cause == .emptyTimeout)
        #expect(records[0].cause == nil)
        #expect(records[0].instance == records[1].instance, "the destroyed line names the created instance")
        #expect(records[0].epoch == records[1].epoch)
        #expect(records[0].wallMs <= records[1].wallMs)
        #expect(records[0].uptimeNs <= records[1].uptimeNs)
    }

    @Test("A land recreated under the same ID gets a new, larger instance number")
    func recreatedLandIsANewInstance() async throws {
        let sink = LineSink()
        let manager = await makeManager(sink)
        let landID = LandID(landType: "lifecycle", instanceId: "room-1")
        try await emptyAndDestroy(try await create(manager, landID))
        _ = try await create(manager, landID)

        let created = sink.records.filter { $0.event == .created }
        try #require(created.count == 2)
        #expect(created[1].instance > created[0].instance)
    }

    @Test("Instance numbers are unique across managers in one process")
    func instanceNumbersAreProcessWide() async throws {
        let sink = LineSink()
        let log = LandLifecycleLog(write: { sink.append($0) })
        var managers: [LandManager<LifecycleLogTestState>] = []
        for _ in 0..<2 {
            let manager = LandManager<LifecycleLogTestState>(
                landFactory: { emptyTimeoutLand($0) },
                initialStateFactory: { _ in LifecycleLogTestState() }
            )
            await manager.installLifecycleLog(log)
            managers.append(manager)
        }
        // The same land ID in each manager: their per-manager epochs are equal.
        let landID = LandID(landType: "lifecycle", instanceId: "room-1")
        for manager in managers { _ = try await create(manager, landID) }

        let created = sink.records.filter { $0.event == .created }
        try #require(created.count == 2)
        #expect(created[0].epoch == created[1].epoch)
        #expect(created[0].instance != created[1].instance)
    }

    @Test("forceShutdown logs destroyed with cause forceShutdown")
    func forceShutdown() async throws {
        let sink = LineSink()
        let manager = await makeManager(sink)
        let container = try await create(manager, LandID(landType: "lifecycle", instanceId: "room-2"))
        await container.keeper.forceShutdown()

        #expect(sink.records.map(\.event) == [.created, .destroyed])
        #expect(sink.records.last?.cause == .forceShutdown)
    }

    @Test("Removal by ID logs removed; the detached instance logs destroyed when it ends")
    func removedThenDestroyed() async throws {
        let sink = LineSink()
        let manager = await makeManager(sink)
        let landID = LandID(landType: "lifecycle", instanceId: "room-3")
        let container = try await create(manager, landID)
        await manager.removeLand(landID: landID)
        #expect(sink.records.map(\.event) == [.created, .removed])
        try await emptyAndDestroy(container)

        let records = sink.records
        #expect(records.map(\.event) == [.created, .removed, .destroyed])
        try #require(records.count == 3)
        #expect(Set(records.map(\.instance)).count == 1, "all three lines name one instance")
        #expect(records[2].cause == .emptyTimeout)
    }

    @Test("An old instance destroyed after its replacement was created logs its own instance and epoch")
    func destroyedAfterReplacement() async throws {
        let sink = LineSink()
        let manager = await makeManager(sink)
        let landID = LandID(landType: "lifecycle", instanceId: "room-5")
        // Removed by ID, the old instance isn't draining: the new creation doesn't wait for it,
        // so its `onLandDestroyed` reaches the manager after the replacement is stored.
        let old = try await create(manager, landID)
        await manager.removeLand(landID: landID)
        let replacement = try await create(manager, landID)
        try await emptyAndDestroy(old)

        let records = sink.records
        #expect(records.map(\.event) == [.created, .removed, .created, .destroyed])
        try #require(records.count == 4)
        #expect(records[3].instance == records[0].instance)
        #expect(records[3].epoch == old.epoch.rawValue)
        #expect(records[2].epoch == replacement.epoch.rawValue)
        #expect(records[2].instance != records[0].instance)
        #expect(await manager.getLand(landID: landID)?.epoch == replacement.epoch, "the replacement stays stored")
    }

    @Test("A published instance whose initialization fails logs destroyed with cause initializationFailed")
    func initializationFailed() async throws {
        let sink = LineSink()
        let manager = LandManager<LifecycleLogTestState>(
            landFactory: { stuckInitLand($0) },
            initialStateFactory: { _ in LifecycleLogTestState() }
        )
        await manager.installLifecycleLog(LandLifecycleLog(write: { sink.append($0) }))
        defer { LifecycleLogStuckResolver.gate.open() }
        let landID = LandID(landType: "lifecycle-init", instanceId: "room-6")
        let container = try await ResolverDeadline.$initOverrideForTesting.withValue(.milliseconds(20)) {
            try await manager.getOrCreateLand(
                landID: landID,
                definition: stuckInitLand(landID),
                initialState: LifecycleLogTestState(),
                metadata: [:]
            )
        }
        while !container.keeper.isDraining { await Task.yield() }
        await container.keeper.waitUntilDrained()

        #expect(sink.records.map(\.event) == [.created, .destroyed])
        #expect(sink.records.last?.cause == .initializationFailed)
    }

    @Test("A failed write disables the log once; the manager keeps serving")
    func failedWriteDisablesTheLog() async throws {
        struct DiskFull: Error {}
        let attempts = LineSink()
        let closes = LineSink()
        let log = LandLifecycleLog(
            write: { line in
                attempts.append(line)
                throw DiskFull()
            },
            close: { closes.append("{}") }
        )
        let manager = LandManager<LifecycleLogTestState>(
            landFactory: { emptyTimeoutLand($0) },
            initialStateFactory: { _ in LifecycleLogTestState() }
        )
        await manager.installLifecycleLog(log)
        let first = try await create(manager, LandID(landType: "lifecycle", instanceId: "room-7"))
        #expect(log.isDisabled)
        try await emptyAndDestroy(first)
        let second = try await create(manager, LandID(landType: "lifecycle", instanceId: "room-8"))
        #expect(await manager.getLand(landID: second.landID) != nil, "creations still succeed")
        #expect(attempts.records.count == 1, "no write after the first failure")
        #expect(closes.lineCount == 1, "closed once")
    }

    @Test("A path that can't be opened gives no log")
    func unusablePath() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)/lifecycle.jsonl").path
        #expect(LandLifecycleLog.fromEnvironment(["LAND_LIFECYCLE_LOG_PATH": path]) == nil)
    }

    @Test("Two logs on one path both append: neither overwrites the other's lines")
    func sharedPathAppends() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("land-lifecycle-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let env = ["LAND_LIFECYCLE_LOG_PATH": path]
        let logs = [try #require(LandLifecycleLog.fromEnvironment(env)), try #require(LandLifecycleLog.fromEnvironment(env))]
        for (i, log) in logs.enumerated() {
            let manager = LandManager<LifecycleLogTestState>(
                landFactory: { emptyTimeoutLand($0) },
                initialStateFactory: { _ in LifecycleLogTestState() }
            )
            await manager.installLifecycleLog(log)
            _ = try await create(manager, LandID(landType: "lifecycle", instanceId: "shared-\(i)"))
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        let ids = try lines.map { try JSONDecoder().decode(LandLifecycleRecord.self, from: Data($0.utf8)).landID }
        #expect(ids == ["lifecycle:shared-0", "lifecycle:shared-1"])
    }

    @Test("A completed join writes sessionJoined with the player, the land and the published instance")
    func sessionJoinedLegacyPath() async throws {
        let sink = LineSink()
        let manager = await makeManager(sink)
        let container = try await create(manager, LandID(landType: "lifecycle", instanceId: "room-9"))
        let adapter = container.transportAdapter
        let session = SessionID("s-legacy")
        let client = ClientID("c-legacy")
        await adapter.onConnect(sessionID: session, clientID: client)
        let result = try #require(try await adapter.performJoin(
            playerSession: PlayerSession(playerID: "p-legacy", deviceID: "d", metadata: [:]),
            clientID: client,
            sessionID: session,
            authInfo: nil
        ))
        #expect(sink.sessionRecords.isEmpty, "admitted, not joined yet: the join completes with its initial sync")
        await adapter.syncStateForNewPlayer(playerID: result.playerID, sessionID: session)

        let joined = try #require(sink.sessionRecords.first)
        #expect(sink.sessionRecords.count == 1)
        #expect(joined.event == .sessionJoined)
        #expect(joined.sessionID == "s-legacy")
        #expect(joined.playerID == "p-legacy")
        #expect(joined.landID == "lifecycle:room-9")
        #expect(joined.instance == sink.records.first?.instance, "the instance its created line names")
        #expect(joined.instance != nil)
    }

    @Test(
        "A join that completes in a turn writes sessionJoined at its flip",
        .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: no in-turn joins")
    )
    func sessionJoinedInTurn() async throws {
        let sink = LineSink()
        let manager = await makeManager(sink)
        let container = try await create(manager, LandID(landType: "lifecycle", instanceId: "room-10"))
        let adapter = container.transportAdapter
        let session = SessionID("s-turn")
        let client = ClientID("c-turn")
        await adapter.onConnect(sessionID: session, clientID: client)
        let result = try #require(try await adapter.performJoin(
            playerSession: PlayerSession(playerID: "p-turn", deviceID: "d", metadata: [:]),
            clientID: client,
            sessionID: session,
            authInfo: nil,
            joinResponse: { playerID, slot in
                try? JSONEncoder().encode(TransportMessage.joinResponse(
                    requestID: "r", success: true, playerID: playerID.rawValue, playerSlot: slot, encoding: "json"
                ))
            }
        ))
        #expect(result.completedInTurn)
        #expect(sink.sessionRecords.map(\.sessionID) == ["s-turn"])
        #expect(sink.sessionRecords.first?.playerID == "p-turn")
        #expect(sink.sessionRecords.first?.instance == sink.records.first?.instance)
    }

    @Test("The file sink appends one JSON line per event")
    func fileSink() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("land-lifecycle-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = try #require(LandLifecycleLog.fromEnvironment(["LAND_LIFECYCLE_LOG_PATH": path]))
        let manager = LandManager<LifecycleLogTestState>(
            landFactory: { emptyTimeoutLand($0) },
            initialStateFactory: { _ in LifecycleLogTestState() }
        )
        await manager.installLifecycleLog(log)
        let container = try await create(manager, LandID(landType: "lifecycle", instanceId: "room-4"))
        await container.keeper.forceShutdown()

        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let events = try lines.map { try JSONDecoder().decode(LandLifecycleRecord.self, from: Data($0.utf8)).event }
        #expect(events == [.created, .destroyed])
    }
}
