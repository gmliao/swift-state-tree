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

    var records: [LandLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored.map { try! JSONDecoder().decode(LandLifecycleRecord.self, from: Data($0.utf8)) }
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
