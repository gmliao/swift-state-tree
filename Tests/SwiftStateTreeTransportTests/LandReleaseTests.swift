// Tests/SwiftStateTreeTransportTests/LandReleaseTests.swift
//
// A land that LandManager destroys must be released: its keeper, its adapter, and the state,
// transport and recorder they hold (#346). The keeper and its adapter form a reference cycle
// (`keeper.setTransport(adapter)`, `adapter.keeper`), and a land's own transport another one
// (its delegate is the adapter); each instance breaks its links at the end of its own teardown.
// Every destroy path is created through the hosting path (`getOrCreateLand`), destroyed through
// the manager's own teardown, and checked with weak references, with in-turn sync on and off
// (the `IN_TURN_SYNC` CI legs).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct LandReleaseTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

@Payload
struct LandReleaseSetAction: ActionPayload {
    typealias Response = LandReleaseAck
    let value: Int
}

@Payload
struct LandReleaseAck: ResponsePayload {
    let ok: Bool
}

private func releaseTestLand(_ landID: LandID) -> LandDefinition<LandReleaseTestState> {
    Land(landID.landType, using: LandReleaseTestState.self) {
        Rules {
            HandleAction(LandReleaseSetAction.self) { (state: inout LandReleaseTestState, action: LandReleaseSetAction, _: LandContext) in
                state.value = action.value
                return LandReleaseAck(ok: true)
            }
        }
        Lifetime {
            DestroyWhenEmpty(after: .milliseconds(10)) { (_: inout LandReleaseTestState, _: LandContext) in }
        }
    }
}

struct LandReleaseInitOutput: ResolverOutput {
    let value: Int
}

/// Never returns, and ignores cancellation, until the test's gate opens: the land's
/// initialization times out and fails.
struct LandReleaseStuckResolver: ContextResolver {
    typealias Output = LandReleaseInitOutput
    static let gate = TestGate()
    static func resolve(ctx: ResolverContext) async throws -> LandReleaseInitOutput {
        await gate.arrive()
        return LandReleaseInitOutput(value: 0)
    }
}

private func failingInitLand(_ landID: LandID) -> LandDefinition<LandReleaseTestState> {
    Land(landID.landType, using: LandReleaseTestState.self) {
        Rules {}
        Lifetime {
            OnInitialize(resolvers: LandReleaseStuckResolver.self) { (_: inout LandReleaseTestState, _: LandContext) in }
        }
    }
}

/// Weak references to one land instance's parts.
private struct WeakLand {
    weak var keeper: LandKeeper<LandReleaseTestState>?
    weak var adapter: TransportAdapter<LandReleaseTestState>?
    weak var transport: WebSocketTransport?

    var released: Bool { keeper == nil && adapter == nil && transport == nil }
    var description: String {
        func state(_ alive: Bool) -> String { alive ? "alive" : "released" }
        return "keeper \(state(keeper != nil)), adapter \(state(adapter != nil)), transport \(state(transport != nil))"
    }

    init(_ container: LandContainer<LandReleaseTestState>, ownsTransport: Bool) {
        keeper = container.keeper
        adapter = container.transportAdapter
        if ownsTransport { transport = container.transport }
    }

    init(keeper: LandKeeper<LandReleaseTestState>?) {
        self.keeper = keeper
    }
}

/// Waits for the weak references to clear, polling with a 2 s bound. That is a release check,
/// not an interleaving: the destruction's last tasks may hold the instance for a few turns
/// after it has left the manager, and nothing else signals the moment it is freed.
private func waitUntilReleased(_ land: WeakLand) async -> Bool {
    for _ in 0..<2_000 {
        if land.released { return true }
        try? await safeTaskSleep(for: .milliseconds(1))
    }
    return land.released
}

/// The empty-room path: one player joins and leaves, and the land's timer destroys it.
private func emptyAndDestroy(_ keeper: LandKeeper<LandReleaseTestState>, player: String = "p1") async throws {
    _ = try await keeper.join(playerID: PlayerID(player), clientID: ClientID("c-\(player)"), sessionID: SessionID("s-\(player)"))
    try await keeper.leave(playerID: PlayerID(player), clientID: ClientID("c-\(player)"))
    while !keeper.isDraining { await Task.yield() }
    await keeper.waitUntilDrained()
}

/// The instance a hold saw, weakly.
private final class BuiltLandBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storedKeeper: LandKeeper<LandReleaseTestState>?
    private weak var storedAdapter: TransportAdapter<LandReleaseTestState>?
    private var set = false

    func set(keeper: LandKeeper<LandReleaseTestState>, adapter: TransportAdapter<LandReleaseTestState>?) {
        lock.withLock { storedKeeper = keeper; storedAdapter = adapter; set = adapter != nil }
    }

    var keeper: LandKeeper<LandReleaseTestState>? { lock.withLock { storedKeeper } }
    var adapter: TransportAdapter<LandReleaseTestState>? { lock.withLock { storedAdapter } }
    var wasSet: Bool { lock.withLock { set } }
}

/// A delegate of a shared transport (the router's role in hosting).
private actor SharedTransportDelegate: TransportDelegate {
    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {}
    func onMessage(_ message: Data, from sessionID: SessionID) async {}
}

@Suite("A destroyed land is released (#346)", .timeLimit(.minutes(1)))
struct LandReleaseTests {
    private func makeManager(
        transport: WebSocketTransport? = nil,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<LandReleaseTestState> = { releaseTestLand($0) },
        keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil
    ) -> LandManager<LandReleaseTestState> {
        LandManager<LandReleaseTestState>(
            landFactory: landFactory,
            initialStateFactory: { _ in LandReleaseTestState() },
            transport: transport,
            keeperModeResolver: keeperModeResolver
        )
    }

    private func create(
        _ manager: LandManager<LandReleaseTestState>,
        _ landID: LandID,
        ownsTransport: Bool = true
    ) async throws -> WeakLand {
        let container = try await manager.getOrCreateLand(
            landID: landID,
            definition: releaseTestLand(landID),
            initialState: LandReleaseTestState(),
            metadata: [:]
        )
        return WeakLand(container, ownsTransport: ownsTransport)
    }

    @Test("The empty-room timer: the destroyed land is released")
    func emptyRoomTimer() async throws {
        let manager = makeManager()
        let landID = LandID("land-release:empty")
        let land = try await create(manager, landID)
        try await emptyAndDestroy(try #require(land.keeper))
        #expect(await manager.getLand(landID: landID) == nil)
        let released = await waitUntilReleased(land)
        #expect(released, "after the empty-room destruction: \(land.description)")
    }

    @Test("shutdownAllLands: every land is released")
    func shutdownAllLands() async throws {
        let manager = makeManager()
        let first = try await create(manager, LandID("land-release:shutdown-1"))
        let second = try await create(manager, LandID("land-release:shutdown-2"))
        await manager.shutdownAllLands()
        let firstReleased = await waitUntilReleased(first)
        let secondReleased = await waitUntilReleased(second)
        #expect(firstReleased, "first land after shutdownAllLands: \(first.description)")
        #expect(secondReleased, "second land after shutdownAllLands: \(second.description)")
    }

    @Test("Removal by ID (the admin route's removeLand): the detached land is released when it is destroyed")
    func removalByID() async throws {
        let manager = makeManager()
        let landID = LandID("land-release:removed")
        let land = try await create(manager, landID)
        await manager.removeLand(landID: landID)
        #expect(await manager.getLand(landID: landID) == nil)
        try await emptyAndDestroy(try #require(land.keeper))
        let released = await waitUntilReleased(land)
        #expect(released, "after removal by ID and destruction: \(land.description)")
    }

    @Test("A failed creation: the half-wired instance torn down by its failed initialization is released")
    func failedCreation() async throws {
        let manager = makeManager(landFactory: { failingInitLand($0) })
        let landID = LandID(landType: "land-release-failed", instanceId: "room-1")
        // The container is used inside this scope only, so the test holds nothing afterwards.
        var land: WeakLand
        do {
            let created: Result<LandContainer<LandReleaseTestState>, any Error> = await ResolverDeadline.$initOverrideForTesting.withValue(.milliseconds(20)) {
                do {
                    return .success(try await manager.getOrCreateLand(
                        landID: landID,
                        definition: failingInitLand(landID),
                        initialState: LandReleaseTestState(),
                        metadata: [:]
                    ))
                } catch {
                    return .failure(error)
                }
            }
            switch created {
            case .success(let container):
                // Published, then torn down by its failed initialization.
                land = WeakLand(container, ownsTransport: true)
            case .failure:
                // Torn down before its publication (half-wired).
                land = WeakLand(keeper: await manager.lastBuiltKeeperForTesting)
            }
        }
        do {
            let keeper = try #require(land.keeper)
            while !keeper.isDraining { await Task.yield() }
            await keeper.waitUntilDrained()
        }
        // The stuck resolver ignores cancellation; once it returns, nothing holds the instance.
        LandReleaseStuckResolver.gate.open()
        let released = await waitUntilReleased(land)
        #expect(released, "after the failed initialization's teardown: \(land.description)")
    }

    @Test("A creation whose teardown finished before it was wired (the half-wired instance) is released")
    func tornDownBeforeWiring() async throws {
        let manager = makeManager(landFactory: { failingInitLand($0) })
        // Held before the adapter is attached until the keeper's failed initialization has
        // finished its whole teardown: the adapter and the transport's delegate are then wired
        // to a keeper that has already made its last call to a transport.
        let built = BuiltLandBox()
        await manager.installHolds(HoldRegistry.at(.wiring) {
            guard let keeper = await manager.lastBuiltKeeperForTesting else { return }
            built.set(keeper: keeper, adapter: await manager.lastBuiltAdapterForTesting)
            while !keeper.isDraining { await Task.yield() }
            await keeper.waitUntilDrained()
        })
        let landID = LandID(landType: "land-release-failed", instanceId: "room-2")
        let error: (any Error)? = await ResolverDeadline.$initOverrideForTesting.withValue(.milliseconds(20)) {
            do {
                _ = try await manager.getOrCreateLand(
                    landID: landID,
                    definition: failingInitLand(landID),
                    initialState: LandReleaseTestState(),
                    metadata: [:]
                )
                return nil
            } catch {
                return error
            }
        }
        if case .landShuttingDown? = error as? JoinError {} else {
            Issue.record("the creation fails before publication, got \(String(describing: error))")
        }
        #expect(built.wasSet, "the hold saw the built instance")
        var land = WeakLand(keeper: built.keeper)
        land.adapter = built.adapter
        LandReleaseStuckResolver.gate.open()
        let released = await waitUntilReleased(land)
        #expect(released, "after a teardown that finished before the wiring: \(land.description)")
    }

    @Test("A replay land (re-evaluation keeper): released after shutdownAllLands")
    func replayLand() async throws {
        let recordFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("land-release-replay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: recordFile) }
        try ReevaluationRecordFile.jsonViewData(
            metadata: ReevaluationRecordMetadata(
                landID: "land-release:local",
                landType: "land-release",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: [:],
                landDefinitionID: "land-release-replay",
                version: ReevaluationRecordVersion.current
            ),
            frames: [ReevaluationTickFrame(tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [])]
        ).write(to: recordFile)
        let manager = makeManager(keeperModeResolver: { landID, _ in
            landID.landType.hasSuffix("-replay") ? .reevaluation(recordFilePath: recordFile.path) : nil
        })
        let landID = LandID(landType: "land-release-replay", instanceId: "replay-1")
        let land = try await create(manager, landID)
        #expect(await land.keeper?.getMode() == .reevaluation)
        await manager.shutdownAllLands()
        let released = await waitUntilReleased(land)
        #expect(released, "replay land after shutdownAllLands: \(land.description)")
    }

    @Test("A shared transport: one land destroyed is released, the other keeps working, the transport and its delegate stay")
    func sharedTransportTwoLands() async throws {
        let shared = WebSocketTransport()
        let delegate = SharedTransportDelegate()
        await shared.setDelegate(delegate)
        let manager = makeManager(transport: shared)
        let gone = try await create(manager, LandID("land-release:shared-1"), ownsTransport: false)
        let kept = try await create(manager, LandID("land-release:shared-2"), ownsTransport: false)

        try await emptyAndDestroy(try #require(gone.keeper))
        let released = await waitUntilReleased(gone)
        #expect(released, "destroyed land on a shared transport: \(gone.description)")

        // The other land and the shared transport are untouched.
        let keeper = try #require(kept.keeper)
        #expect(kept.adapter != nil)
        #expect(await shared.delegate as AnyObject? === delegate, "the shared transport's delegate stays")
        _ = try await keeper.join(playerID: PlayerID("p2"), clientID: ClientID("c2"), sessionID: SessionID("s2"))
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(typeIdentifier: String(describing: LandReleaseSetAction.self), payload: AnyCodable(LandReleaseSetAction(value: 7))),
            playerID: PlayerID("p2"), clientID: ClientID("c2"), sessionID: SessionID("s2")
        )
        #expect(await keeper.currentState().value == 7, "the remaining land still applies inputs")
        await manager.shutdownAllLands()
    }
}
