// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncDirtyWindowTests.swift
//
// Regression tests for #68: a sync cycle must not clear dirty flags of mutations that happen
// after it took its state copy; otherwise the next dirty-tracking cycle skips them and clients
// keep the stale value. The window #68 found (a cycle that took its copy, then awaited while
// the keeper mutated) no longer exists: every sync phase runs inside a keeper turn and clears
// the dirty flags in that turn (#546 L2d), so no mutation lands inside a cycle. What this file
// checks is what that in-turn clear decides, through the adapter: a committed cycle leaves the
// keeper's state clean, and a mutation after it is carried by the next cycle's own update (not
// only by the final view, which a cycle that sends more would also make converge). The keeper
// side of the clear is pinned by the dirty-flag spy tests in `LandKeeperSyncLockTests`.
//
// Every scenario dirties one more field before the checked cycle, so it is not an `.all` cycle:
// a cycle with nothing dirty falls back to `.all`, which would repair the lost update and hide it.
// With `useSnapshotForSync` off the fallback is per policy category, so those runs dirty one more
// field of each category under test (`a` for broadcast `b`, `bonus` for per-player `score`).

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// MARK: - Test state and action

@StateNodeBuilder
struct DirtyWindowTestState: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.broadcast) var b: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var bonuses: [PlayerID: Int] = [:]
    init() {}
}

@Payload
struct DirtyWindowSetAction: ActionPayload {
    typealias Response = DirtyWindowSetResponse
    /// "a", "b", "score" or "bonus" (the calling player's `scores` / `bonuses` entry).
    let field: String
    let value: Int
}

@Payload
struct DirtyWindowSetResponse: ResponsePayload {
    let ok: Bool
}

private func makeDirtyWindowLand() -> LandDefinition<DirtyWindowTestState> {
    Land("dirty-window-test", using: DirtyWindowTestState.self) {
        Rules {
            OnJoin { (state: inout DirtyWindowTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
                state.bonuses[ctx.playerID] = 0
            }
            HandleAction(DirtyWindowSetAction.self) { (state: inout DirtyWindowTestState, action: DirtyWindowSetAction, ctx: LandContext) in
                switch action.field {
                case "a": state.a = action.value
                case "b": state.b = action.value
                case "bonus": state.bonuses[ctx.playerID] = action.value
                default: state.scores[ctx.playerID] = action.value
                }
                return DirtyWindowSetResponse(ok: true)
            }
        }
    }
}

// MARK: - Recording transport

/// Records every send.
private actor DirtyWindowTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates {
            sent.append((target, data))
        }
    }

    /// How many frames were sent so far; pass it to `messages(for:after:)` to read only later ones.
    var sentCount: Int { sent.count }

    func messages(for sessionID: SessionID, after mark: Int = 0) -> [Data] {
        sent.dropFirst(mark).compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return entry.data }
            return nil
        }
    }
}

// MARK: - Client-side model

/// The client's view of `DirtyWindowTestState` for one player, rebuilt from received patches.
private struct DirtyWindowClientView: Equatable, CustomStringConvertible {
    var a: Int
    var b: Int
    var score: Int?
    var bonus: Int?

    init(a: Int, b: Int, score: Int?, bonus: Int?) {
        self.a = a
        self.b = b
        self.score = score
        self.bonus = bonus
    }

    /// The projection the server state implies for `player`.
    init(server state: DirtyWindowTestState, player: PlayerID) {
        self.init(a: state.a, b: state.b, score: state.scores[player], bonus: state.bonuses[player])
    }

    var description: String {
        "a=\(a) b=\(b) score=\(score.map { String($0) } ?? "nil") bonus=\(bonus.map { String($0) } ?? "nil")"
    }

    mutating func apply(_ updates: [StateUpdate], player: PlayerID) {
        for update in updates {
            switch update {
            case .noChange:
                continue
            case .firstSync(let patches), .diff(let patches):
                for patch in patches {
                    apply(patch, player: player)
                }
            }
        }
    }

    private mutating func apply(_ patch: StatePatch, player: PlayerID) {
        let value: SnapshotValue?
        switch patch.operation {
        case .set(let v), .add(let v): value = v
        case .delete: value = nil
        }
        switch patch.path {
        case "/a": a = value.flatMap(Self.int) ?? 0
        case "/b": b = value.flatMap(Self.int) ?? 0
        case "/scores/\(player.rawValue)": score = value.flatMap(Self.int)
        case "/scores": score = value?.objectValue?[player.rawValue].flatMap(Self.int)
        case "/bonuses/\(player.rawValue)": bonus = value.flatMap(Self.int)
        case "/bonuses": bonus = value?.objectValue?[player.rawValue].flatMap(Self.int)
        default: break
        }
    }

    private static func int(_ value: SnapshotValue) -> Int? {
        switch value {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
}

// MARK: - Fixture

private struct DirtyWindowFixture {
    let keeper: LandKeeper<DirtyWindowTestState>
    let adapter: TransportAdapter<DirtyWindowTestState>
    let transport: DirtyWindowTransport
    let session = SessionID("dw-session")
    let client = ClientID("dw-client")
    let player = PlayerID("dw-player")

    static func make(envConfig: TransportEnvConfig) async throws -> DirtyWindowFixture {
        let transport = DirtyWindowTransport()
        let keeper = LandKeeper<DirtyWindowTestState>(
            definition: makeDirtyWindowLand(),
            initialState: DirtyWindowTestState()
        )
        let adapter = TransportAdapter<DirtyWindowTestState>(
            keeper: keeper,
            transport: transport,
            landID: "dirty-window-test",
            transportEnvConfig: envConfig
        )
        await transport.setDelegate(adapter)
        let fixture = DirtyWindowFixture(keeper: keeper, adapter: adapter, transport: transport)
        await adapter.onConnect(sessionID: fixture.session, clientID: fixture.client)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: fixture.session,
            clientID: fixture.client,
            playerID: fixture.player
        )
        // simulateRouterJoin awaits the initial sync, so the player is already syncable here.
        return fixture
    }

    func set(_ field: String, _ value: Int) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: DirtyWindowSetAction.self),
            payload: AnyCodable(DirtyWindowSetAction(field: field, value: value))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: player,
            clientID: client,
            sessionID: session
        )
    }

    /// The client view right after the join: initial state plus the OnJoin per-player entries.
    var initialView: DirtyWindowClientView {
        DirtyWindowClientView(a: 0, b: 0, score: 0, bonus: 0)
    }

    /// Client view rebuilt from every state update this session received after the join.
    func clientView(from start: DirtyWindowClientView) async -> DirtyWindowClientView {
        var view = start
        view.apply(decodeStateUpdates(await transport.messages(for: session)), player: player)
        return view
    }

    func serverView() async -> DirtyWindowClientView {
        DirtyWindowClientView(server: await keeper.currentState(), player: player)
    }
}

private func makeDirtyWindowEnvConfig(
    useSnapshotForSync: Bool,
    enableDirtyTracking: Bool = true
) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: enableDirtyTracking,
        useSnapshotForSync: useSnapshotForSync,
        syncStrategy: .delta,
        profilingConfig: nil
    )
}

// MARK: - Tests

@Suite("TransportAdapter sync dirty-flag window (#68)", .timeLimit(.minutes(1)))
struct TransportAdapterSyncDirtyWindowTests {

    @Test(
        "a committed sync leaves the state clean, and the next cycle's own update carries a later mutation",
        arguments: [true, false]
    )
    func mutationAfterCommittedSyncIsSentByNextCycle(useSnapshotForSync: Bool) async throws {
        let f = try await DirtyWindowFixture.make(envConfig: makeDirtyWindowEnvConfig(useSnapshotForSync: useSnapshotForSync))

        // First cycle: a dirty-tracking cycle (`b` dirty), which clears the dirty flags in its turn.
        try await f.set("b", 1)
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        let dirtyAfterFirst = await f.keeper.currentState().getDirtyFields()
        #expect(dirtyAfterFirst.isEmpty, "a committed cycle must clear the dirty flags in its turn, left \(dirtyAfterFirst)")

        // The keeper mutates `a` after the committed cycle; `b` (same broadcast category) is dirty
        // too, so the next cycle is not an `.all` cycle that would resend `a` regardless.
        try await f.set("a", 1)
        try await f.set("b", 2)
        let mark = await f.transport.sentCount
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForSyncQuiescenceForTesting(), "sync did not settle")

        // Only the second cycle's frames: `a` starts at a value no update sets, so it must change.
        var second = DirtyWindowClientView(a: -1, b: -1, score: nil, bonus: nil)
        second.apply(decodeStateUpdates(await f.transport.messages(for: f.session, after: mark)), player: f.player)
        #expect(second.a == 1, "the second cycle's update must carry a=1, got \(second)")
        #expect(second.b == 2, "the second cycle's update must carry b=2, got \(second)")

        let client = await f.clientView(from: f.initialView)
        let server = await f.serverView()
        #expect(client == server, "client \(client) must equal server \(server)")
    }
}
