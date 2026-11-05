// Tests/SwiftStateTreeTransportTests/LandManagerSingleFlightTests.swift
//
// Land creation and destruction across awaits (#96): concurrent first joins share one creation,
// a destroyed instance never removes its replacement, and a draining land is never joined.
// Each race is forced with a `TestGate` held at the await where it happens.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct SingleFlightTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

private func plainLand(_ landID: LandID) -> LandDefinition<SingleFlightTestState> {
    Land(landID.landType, using: SingleFlightTestState.self) {
        Rules {}
    }
}

/// Lifecycle events from the instances under test, in the order they happened.
private final class LifecycleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ event: String) {
        lock.lock()
        entries.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func isOrdered(_ first: String, before second: String) -> Bool {
        let all = events
        guard let a = all.firstIndex(of: first), let b = all.firstIndex(of: second) else { return false }
        return a < b
    }
}

/// The instance being destroyed: records its finalize; `afterFinalizeGate` holds AfterFinalize.
private func oldInstanceLand(
    _ landID: LandID,
    log: LifecycleLog,
    afterFinalizeGate: TestGate?
) -> LandDefinition<SingleFlightTestState> {
    Land(landID.landType, using: SingleFlightTestState.self) {
        Rules {}
        Lifetime {
            OnFinalize { (_: inout SingleFlightTestState, _: LandContext) in
                log.record("old-finalize")
            }
            AfterFinalize { (_: SingleFlightTestState, _: LandContext) in
                log.record("old-afterFinalize-start")
                if let afterFinalizeGate { await afterFinalizeGate.arrive() }
                log.record("old-afterFinalize-end")
            }
        }
    }
}

/// The replacement instance: records its initialize.
private func newInstanceLand(_ landID: LandID, log: LifecycleLog) -> LandDefinition<SingleFlightTestState> {
    Land(landID.landType, using: SingleFlightTestState.self) {
        Rules {}
        Lifetime {
            OnInitialize { (_: inout SingleFlightTestState, _: LandContext) in
                log.record("new-initialize")
            }
        }
    }
}

private func makeManager(
    keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil
) -> LandManager<SingleFlightTestState> {
    LandManager<SingleFlightTestState>(
        landFactory: { plainLand($0) },
        initialStateFactory: { _ in SingleFlightTestState() },
        keeperModeResolver: keeperModeResolver
    )
}

/// Starts `count` concurrent `getOrCreateLand` calls for `landID`.
private func concurrentCreations(
    _ count: Int,
    manager: LandManager<SingleFlightTestState>,
    landID: LandID
) -> [Task<LandContainer<SingleFlightTestState>, Error>] {
    (0..<count).map { _ in
        Task {
            try await manager.getOrCreateLand(
                landID: landID,
                definition: plainLand(landID),
                initialState: SingleFlightTestState(),
                metadata: [:]
            )
        }
    }
}

/// The record file layout `JSONReevaluationSource` reads.
private struct SingleFlightRecordFile: Codable {
    let recordMetadata: ReevaluationRecordMetadata
    let tickFrames: [ReevaluationTickFrame]
}

private func writeReplayRecord() throws -> URL {
    let recordFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("single-flight-replay-\(UUID().uuidString).json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(SingleFlightRecordFile(
        recordMetadata: ReevaluationRecordMetadata(
            landID: "sf-game:recorded",
            landType: "sf-game",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "sf-game",
            version: "1.0"
        ),
        tickFrames: [ReevaluationTickFrame(tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [])]
    ))
    try data.write(to: recordFile)
    return recordFile
}

/// The distinct keepers among `containers`.
private func keeperIdentities(_ containers: [LandContainer<SingleFlightTestState>]) -> Set<ObjectIdentifier> {
    Set(containers.map { ObjectIdentifier($0.keeper) })
}

/// Counts the calls a resolver gets; the first `failures` calls reject the land.
private final class FailingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let failures: Int

    init(failures: Int) {
        self.failures = failures
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func resolve(_: LandID, _: [String: String]) -> LandKeeperModeConfig? {
        lock.lock()
        calls += 1
        let fail = calls <= failures
        lock.unlock()
        return fail ? .invalidReplaySession(message: "rejected for the test") : nil
    }
}

@Suite("LandManager single-flight creation and epoch removal")
struct LandManagerSingleFlightTests {
    @Test("Concurrent getOrCreateLand calls for a new ID create one keeper and share its container")
    func concurrentFirstJoinsShareOneCreation() async throws {
        let manager = makeManager()
        let gate = TestGate()
        await manager.setCreationHook { _ in await gate.arrive() }
        let landID = LandID(landType: "sf-game", instanceId: "room-0-0")

        let calls = concurrentCreations(8, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        // Give the other seven calls time to reach the manager while the first creation is held.
        try await Task.sleep(for: .milliseconds(100))
        let creationsStarted = gate.arrivalCount
        gate.open()
        var containers: [LandContainer<SingleFlightTestState>] = []
        for call in calls {
            containers.append(try await call.value)
        }

        #expect(creationsStarted == 1, "\(creationsStarted) creations started for one LandID")
        #expect(keeperIdentities(containers).count == 1)
        #expect(await manager.listLands() == [landID])
        let stored = try #require(await manager.getLand(landID: landID))
        #expect(ObjectIdentifier(stored.keeper) == ObjectIdentifier(containers[0].keeper))
    }

    @Test("Opening one replay ID twice at once creates one replay keeper")
    func concurrentReplayOpensShareOneCreation() async throws {
        let recordFile = try writeReplayRecord()
        defer { try? FileManager.default.removeItem(at: recordFile) }
        let manager = makeManager(keeperModeResolver: { landID, _ in
            landID.landType.hasSuffix("-replay") ? .reevaluation(recordFilePath: recordFile.path) : nil
        })
        let gate = TestGate()
        await manager.setCreationHook { _ in await gate.arrive() }
        let landID = LandID(landType: "sf-game-replay", instanceId: "viewer-room")

        let calls = concurrentCreations(2, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        try await Task.sleep(for: .milliseconds(100))
        let creationsStarted = gate.arrivalCount
        gate.open()
        let first = try await calls[0].value
        let second = try await calls[1].value

        #expect(creationsStarted == 1, "\(creationsStarted) creations started for one replay ID")
        #expect(ObjectIdentifier(first.keeper) == ObjectIdentifier(second.keeper))
        #expect(await first.keeper.getMode() == .reevaluation)
    }

    @Test("A failed creation reaches every waiter and is not cached")
    func failedCreationIsRetried() async throws {
        let resolver = FailingResolver(failures: 1)
        let manager = makeManager(keeperModeResolver: { resolver.resolve($0, $1) })
        let gate = TestGate()
        await manager.setCreationHook { _ in await gate.arrive() }
        let landID = LandID(landType: "sf-game", instanceId: "fails-once")

        let calls = concurrentCreations(3, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        for call in calls {
            await #expect(throws: ReevaluationReplayError.self) { _ = try await call.value }
        }
        #expect(resolver.callCount == 1)
        #expect(await manager.creationsInFlight() == 0)
        #expect(await manager.listLands().isEmpty)

        let retried = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        #expect(retried.landID == landID)
        #expect(resolver.callCount == 2)
    }

    @Test("A cancelled caller stops waiting; the creation goes on for the others")
    func cancelledWaiterDoesNotCancelCreation() async throws {
        let manager = makeManager()
        let gate = TestGate()
        await manager.setCreationHook { _ in await gate.arrive() }
        let landID = LandID(landType: "sf-game", instanceId: "impatient")

        let calls = concurrentCreations(2, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        try await Task.sleep(for: .milliseconds(50))
        calls[0].cancel()
        await #expect(throws: CancellationError.self) { _ = try await calls[0].value }

        gate.open()
        let survivor = try await calls[1].value
        #expect(survivor.landID == landID)
        #expect(await manager.getLand(landID: landID) != nil)
    }

    @Test("A recreate waits for the drain held before finalize; the draining keeper is not joined")
    func recreateWaitsForDrainHeldBeforeFinalize() async throws {
        let log = LifecycleLog()
        let drainGate = TestGate()
        let landID = LandID(landType: "sf-game", instanceId: "reused-a")
        let manager = makeManager()
        let old = try await manager.getOrCreateLand(
            landID: landID,
            definition: oldInstanceLand(landID, log: log, afterFinalizeGate: nil),
            initialState: SingleFlightTestState(),
            metadata: [:]
        )
        // Hold the destruction after it started (isDraining) and before any finalize handler.
        await old.keeper.setDrainHook { await drainGate.arrive() }

        let destruction = Task { await old.keeper.forceShutdown() }
        #expect(await drainGate.waitForArrivals(1))
        #expect(old.keeper.isDraining)
        await #expect(throws: JoinError.self) {
            try await old.keeper.join(playerID: PlayerID("late"), clientID: ClientID("c"), sessionID: SessionID("s"))
        }

        let recreate = Task {
            try await manager.getOrCreateLand(
                landID: landID,
                definition: newInstanceLand(landID, log: log),
                initialState: SingleFlightTestState(),
                metadata: [:]
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!log.events.contains("new-initialize"), "the new instance initialized during the old one's drain")

        drainGate.open()
        await destruction.value
        let fresh = try await recreate.value
        // Live keepers initialize eagerly after creation.
        #expect(await pollUntil { log.events.contains("new-initialize") })

        #expect(ObjectIdentifier(fresh.keeper) != ObjectIdentifier(old.keeper))
        #expect(fresh.epoch != old.epoch)
        #expect(log.isOrdered("old-finalize", before: "new-initialize"), "events: \(log.events)")
        #expect(log.isOrdered("old-afterFinalize-end", before: "new-initialize"), "events: \(log.events)")
        let stored = try #require(await manager.getLand(landID: landID), "the new instance was removed")
        #expect(ObjectIdentifier(stored.keeper) == ObjectIdentifier(fresh.keeper))
    }

    @Test("A recreate during a drain held in AfterFinalize gets a new instance that the old one's removal keeps")
    func destroyAndRecreateKeepTheNewInstance() async throws {
        let log = LifecycleLog()
        let afterFinalizeGate = TestGate()
        let landID = LandID(landType: "sf-game", instanceId: "reused-b")
        let manager = makeManager()
        let old = try await manager.getOrCreateLand(
            landID: landID,
            definition: oldInstanceLand(landID, log: log, afterFinalizeGate: afterFinalizeGate),
            initialState: SingleFlightTestState(),
            metadata: [:]
        )

        // The old instance is empty and starts its destruction; hold it in AfterFinalize.
        let destruction = Task { await old.keeper.forceShutdown() }
        #expect(await afterFinalizeGate.waitForArrivals(1))
        #expect(old.keeper.isDraining)
        await #expect(throws: JoinError.self) {
            try await old.keeper.join(playerID: PlayerID("late"), clientID: ClientID("c"), sessionID: SessionID("s"))
        }

        // A join meanwhile must not get the draining instance.
        let recreate = Task {
            try await manager.getOrCreateLand(
                landID: landID,
                definition: newInstanceLand(landID, log: log),
                initialState: SingleFlightTestState(),
                metadata: [:]
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        afterFinalizeGate.open()
        await destruction.value
        let fresh = try await recreate.value

        #expect(ObjectIdentifier(fresh.keeper) != ObjectIdentifier(old.keeper))
        #expect(fresh.epoch != old.epoch)
        // The old instance's removal ran: the new one stays stored.
        try await Task.sleep(for: .milliseconds(50))
        let stored = try #require(await manager.getLand(landID: landID), "the new instance was removed")
        #expect(ObjectIdentifier(stored.keeper) == ObjectIdentifier(fresh.keeper))
    }

    @Test("A destroyed instance's own removal still removes it")
    func destroyedInstanceRemovesItself() async throws {
        let manager = makeManager()
        let landID = LandID(landType: "sf-game", instanceId: "alone")
        let container = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        await container.keeper.forceShutdown()
        let removed = await pollUntilAsync { await manager.getLand(landID: landID) == nil }
        #expect(removed)
    }
}

/// `pollUntil` for an async condition.
private func pollUntilAsync(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
