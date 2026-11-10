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

/// Waits until `count` calls joined the creation in flight, so every call is known to share it
/// before the test releases it.
private func waitForCreationJoins(
    _ count: Int,
    manager: LandManager<SingleFlightTestState>
) async -> Bool {
    await pollUntil { await manager.creationJoinCount() >= count }
}

/// Whether `error` is `JoinError.landShuttingDown`.
private func isLandShuttingDown(_ error: Error) -> Bool {
    if case .landShuttingDown? = error as? JoinError { return true }
    return false
}

/// A gate that is open from the start: it only counts arrivals (a "this point was reached"
/// signal for hooks that must not block).
private func signal() -> TestGate {
    let gate = TestGate()
    gate.open()
    return gate
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
            version: ReevaluationRecordVersion.current
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
        await manager.installHolds(HoldRegistry.at(.creation) { await gate.arrive() })
        let landID = LandID(landType: "sf-game", instanceId: "room-0-0")

        let calls = concurrentCreations(8, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        // The other seven calls joined the held creation.
        #expect(await waitForCreationJoins(7, manager: manager))
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
        await manager.installHolds(HoldRegistry.at(.creation) { await gate.arrive() })
        let landID = LandID(landType: "sf-game-replay", instanceId: "viewer-room")

        let calls = concurrentCreations(2, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        #expect(await waitForCreationJoins(1, manager: manager))
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
        await manager.installHolds(HoldRegistry.at(.creation) { await gate.arrive() })
        let landID = LandID(landType: "sf-game", instanceId: "fails-once")

        let calls = concurrentCreations(3, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        // All three callers wait on the held creation before it fails.
        #expect(await waitForCreationJoins(2, manager: manager))
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
        await manager.installHolds(HoldRegistry.at(.creation) { await gate.arrive() })
        let landID = LandID(landType: "sf-game", instanceId: "impatient")

        let calls = concurrentCreations(2, manager: manager, landID: landID)
        #expect(await gate.waitForArrivals(1))
        #expect(await waitForCreationJoins(1, manager: manager))
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
        let reachedWait = signal()
        await manager.installHolds(HoldRegistry.at(.drainWait) { await reachedWait.arrive() })
        let old = try await manager.getOrCreateLand(
            landID: landID,
            definition: oldInstanceLand(landID, log: log, afterFinalizeGate: nil),
            initialState: SingleFlightTestState(),
            metadata: [:]
        )
        // Hold the destruction after it started (isDraining) and before any finalize handler.
        await old.keeper.installHolds(HoldRegistry.at(.drainStart) { await drainGate.arrive() })

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
        // The recreate reached the drain wait while the drain is held, so the ordering below
        // proves it waited.
        #expect(await reachedWait.waitForArrivals(1))
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

    @Test("A recreate during a drain held in AfterFinalize gets a new instance, published after the old one's removal")
    func destroyAndRecreateKeepTheNewInstance() async throws {
        let log = LifecycleLog()
        let afterFinalizeGate = TestGate()
        let landID = LandID(landType: "sf-game", instanceId: "reused-b")
        let manager = makeManager()
        let reachedWait = signal()
        await manager.installHolds(HoldRegistry.at(.drainWait) { await reachedWait.arrive() })
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
        #expect(await reachedWait.waitForArrivals(1))
        afterFinalizeGate.open()
        await destruction.value
        let fresh = try await recreate.value

        #expect(ObjectIdentifier(fresh.keeper) != ObjectIdentifier(old.keeper))
        #expect(fresh.epoch != old.epoch)
        // The drain, the old instance's removal included, finished before the new one was
        // published: the new one stays stored.
        let stored = try #require(await manager.getLand(landID: landID), "the new instance was removed")
        #expect(ObjectIdentifier(stored.keeper) == ObjectIdentifier(fresh.keeper))
    }

    @Test("A destroyed instance's own removal still removes it")
    func destroyedInstanceRemovesItself() async throws {
        let manager = makeManager()
        let landID = LandID(landType: "sf-game", instanceId: "alone")
        let container = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        await container.keeper.forceShutdown()
        let removed = await pollUntil { await manager.getLand(landID: landID) == nil }
        #expect(removed)
    }

    @Test("Removal by an older epoch leaves the newer instance stored")
    func olderEpochRemovalKeepsTheNewerInstance() async throws {
        let manager = makeManager()
        let landID = LandID(landType: "sf-game", instanceId: "epochs")
        let old = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        await manager.removeLand(landID: landID)
        let fresh = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        #expect(fresh.epoch != old.epoch)

        await manager.removeLand(landID: landID, epoch: old.epoch)
        let stored = try #require(await manager.getLand(landID: landID), "the older epoch removed the newer instance")
        #expect(ObjectIdentifier(stored.keeper) == ObjectIdentifier(fresh.keeper))

        await manager.removeLand(landID: landID, epoch: fresh.epoch)
        #expect(await manager.getLand(landID: landID) == nil)
    }

    @Test("An instance removed by ID while live keeps the newer instance stored when it is destroyed later")
    func adminRemovedLiveInstanceKeepsTheNewerOne() async throws {
        let manager = makeManager()
        let landID = LandID(landType: "sf-game", instanceId: "admin-live")
        let old = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        try await old.keeper.join(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        await manager.removeLand(landID: landID)

        // The old instance still has a player, so the recreate does not wait for it.
        let fresh = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        // Its destruction runs now, and its callback meets the newer instance.
        await old.keeper.forceShutdown()

        let stored = try #require(await manager.getLand(landID: landID), "the old instance's callback removed the newer one")
        #expect(ObjectIdentifier(stored.keeper) == ObjectIdentifier(fresh.keeper))
    }

    @Test("A recreate after an admin removal of a draining instance still waits for its drain")
    func recreateWaitsForAdminRemovedDrain() async throws {
        let log = LifecycleLog()
        let drainGate = TestGate()
        let landID = LandID(landType: "sf-game", instanceId: "admin-draining")
        let manager = makeManager()
        let reachedWait = signal()
        await manager.installHolds(HoldRegistry.at(.drainWait) { await reachedWait.arrive() })
        let old = try await manager.getOrCreateLand(
            landID: landID,
            definition: oldInstanceLand(landID, log: log, afterFinalizeGate: nil),
            initialState: SingleFlightTestState(),
            metadata: [:]
        )
        await old.keeper.installHolds(HoldRegistry.at(.drainStart) { await drainGate.arrive() })
        let destruction = Task { await old.keeper.forceShutdown() }
        #expect(await drainGate.waitForArrivals(1))

        // The admin removes it by ID mid-drain: the manager no longer stores it.
        await manager.removeLand(landID: landID)
        #expect(await manager.getLand(landID: landID) == nil)

        let recreate = Task {
            try await manager.getOrCreateLand(
                landID: landID,
                definition: newInstanceLand(landID, log: log),
                initialState: SingleFlightTestState(),
                metadata: [:]
            )
        }
        #expect(await reachedWait.waitForArrivals(1), "the recreate did not wait for the detached drain")
        #expect(!log.events.contains("new-initialize"))

        drainGate.open()
        await destruction.value
        let fresh = try await recreate.value
        #expect(await pollUntil { log.events.contains("new-initialize") })
        #expect(log.isOrdered("old-finalize", before: "new-initialize"), "events: \(log.events)")
        let stored = try #require(await manager.getLand(landID: landID))
        #expect(ObjectIdentifier(stored.keeper) == ObjectIdentifier(fresh.keeper))
    }

    @Test("A drain held past the bound fails the recreate with landShuttingDown, and a later join succeeds")
    func boundedDrainWait() async throws {
        let drainGate = TestGate()
        let landID = LandID(landType: "sf-game", instanceId: "hung-finalize")
        let manager = makeManager()
        await manager.setDrainWaitTimeout(.milliseconds(200))
        let old = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        await old.keeper.installHolds(HoldRegistry.at(.drainStart) { await drainGate.arrive() })
        let destruction = Task { await old.keeper.forceShutdown() }
        #expect(await drainGate.waitForArrivals(1))

        do {
            _ = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
            Issue.record("the recreate did not time out")
        } catch {
            #expect(isLandShuttingDown(error), "unexpected error: \(error)")
        }
        // The failure is not cached.
        #expect(await manager.creationsInFlight() == 0)

        drainGate.open()
        await destruction.value
        let fresh = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        #expect(ObjectIdentifier(fresh.keeper) != ObjectIdentifier(old.keeper))
    }

    @Test("shutdownAllLands rejects creations during its awaits and shuts down what its flights published")
    func shutdownRejectsNewCreations() async throws {
        let manager = makeManager()
        let gate = TestGate()
        await manager.installHolds(HoldRegistry.at(.creation) { await gate.arrive() })
        let held = LandID(landType: "sf-game", instanceId: "held")
        let late = LandID(landType: "sf-game", instanceId: "late")

        let heldCall = concurrentCreations(1, manager: manager, landID: held)[0]
        #expect(await gate.waitForArrivals(1))
        let shutdown = Task { await manager.shutdownAllLands() }
        #expect(await pollUntil { await manager.isShutdownStarted() })
        // The shutdown is awaiting the held creation: a new creation is rejected.
        do {
            _ = try await concurrentCreations(1, manager: manager, landID: late)[0].value
            Issue.record("a creation started during the shutdown")
        } catch {
            #expect(isLandShuttingDown(error), "unexpected error: \(error)")
        }
        #expect(gate.arrivalCount == 1, "a creation started during the shutdown")

        gate.open()
        let heldResult = await heldCall.result
        await shutdown.value
        #expect(await manager.creationsInFlight() == 0)
        #expect(await manager.getLand(landID: late) == nil)
        switch heldResult {
        case .success(let container):
            #expect(container.keeper.isDraining, "the held creation's land was published but not shut down")
        case .failure:
            #expect(await manager.getLand(landID: held) == nil)
        }
    }

    @Test("A second destruction caller waits for the one in progress; the destruction runs once")
    func secondShutdownWaitsForTheFirst() async throws {
        let log = LifecycleLog()
        let drainGate = TestGate()
        let landID = LandID(landType: "sf-game", instanceId: "twice")
        let manager = makeManager()
        let old = try await manager.getOrCreateLand(
            landID: landID,
            definition: oldInstanceLand(landID, log: log, afterFinalizeGate: nil),
            initialState: SingleFlightTestState(),
            metadata: [:]
        )
        await old.keeper.installHolds(HoldRegistry.at(.drainStart) { await drainGate.arrive() })
        let first = Task { await old.keeper.forceShutdown() }
        #expect(await drainGate.waitForArrivals(1))
        let second = Task {
            await old.keeper.forceShutdown()
            log.record("second-returned")
        }

        drainGate.open()
        await first.value
        await second.value
        #expect(drainGate.arrivalCount == 1, "the destruction ran \(drainGate.arrivalCount) times")
        #expect(log.events.filter { $0 == "old-finalize" }.count == 1, "events: \(log.events)")
        #expect(log.isOrdered("old-afterFinalize-end", before: "second-returned"), "events: \(log.events)")
    }

    @Test("A join suspended before its insert when the destruction starts is rejected")
    func joinSuspendedBeforeInsertIsRejected() async throws {
        let manager = makeManager()
        let landID = LandID(landType: "sf-game", instanceId: "join-vs-drain")
        let container = try await concurrentCreations(1, manager: manager, landID: landID)[0].value
        let joinGate = TestGate()
        await container.keeper.installHolds(HoldRegistry.at(.join) { await joinGate.arrive() })

        let join = Task {
            try await container.keeper.join(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        }
        #expect(await joinGate.waitForArrivals(1))
        // The land is still empty: the destruction starts and finishes while the join waits.
        await container.keeper.forceShutdown()
        #expect(container.keeper.isDraining)

        joinGate.open()
        do {
            try await join.value
            Issue.record("the join reached a destroyed keeper")
        } catch {
            #expect(isLandShuttingDown(error), "unexpected error: \(error)")
        }
        #expect(await container.keeper.playerCount() == 0)
    }

    @Test("landShuttingDown is answered with a retryable JOIN_DENIED")
    func landShuttingDownMapsToJoinDenied() {
        let (code, message) = LandRouter<SingleFlightTestState>.joinErrorResponse(.landShuttingDown)
        #expect(code == .joinDenied)
        #expect(message.contains("retry"))
    }

    @Test("A router join whose land creation throws landShuttingDown gets JOIN_DENIED")
    func routerJoinDuringShutdownIsJoinDenied() async throws {
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry<SingleFlightTestState>(
            landFactory: { _, landID in plainLand(landID) },
            initialStateFactory: { _, _ in SingleFlightTestState() }
        )
        let manager = LandManager<SingleFlightTestState>(
            landFactory: { registry.getLandDefinition(landType: $0.landType, landID: $0) },
            initialStateFactory: { registry.initialStateFactory($0.landType, $0) },
            transport: transport
        )
        let router = LandRouter<SingleFlightTestState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)
        // From now on every creation throws `JoinError.landShuttingDown`.
        await manager.shutdownAllLands()

        let sessionID = SessionID("router-shutdown")
        let connection = JoinReplyConnection()
        await transport.handleConnection(sessionID: sessionID, connection: connection)
        let join = TransportMessage.join(
            requestID: "req-shutdown",
            landType: "sf-game",
            landInstanceId: "after-shutdown",
            playerID: "p",
            deviceID: nil,
            metadata: StateUpdateFeature.joinMetadata
        )
        await transport.handleIncomingMessage(sessionID: sessionID, data: try JSONEncoder().encode(join))

        #expect(await pollUntil { await !connection.messages.isEmpty })
        let reply = try JSONDecoder().decode(TransportMessage.self, from: try #require(await connection.messages.first))
        guard case .error(let payload) = reply.payload else {
            Issue.record("expected an error reply, got \(reply)")
            return
        }
        #expect(payload.code == ErrorCode.joinDenied.rawValue, "code: \(payload.code), message: \(payload.message)")
        #expect(await router.getBoundLandID(for: sessionID) == nil)
    }
}

/// Records what the transport sends to one session.
private actor JoinReplyConnection: WebSocketConnection {
    private(set) var messages: [Data] = []

    func send(_ data: Data) async throws {
        messages.append(data)
    }

    func close() async throws {}
}
