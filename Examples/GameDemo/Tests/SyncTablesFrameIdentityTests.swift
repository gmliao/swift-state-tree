// Examples/GameDemo/Tests/SyncTablesFrameIdentityTests.swift
//
// The broadcast diff on the typed sync tables (`USE_SYNC_TABLES`) must send the frames today's
// snapshot diff sends. Hero Defense and the visibility test land (its per-player state and its
// broadcast twin) run one script on an adapter with the switch on and on one with it off, and
// each recipient must get the same frames, byte for byte and in order, in every encoding, with
// string paths, path hashes and the path index. The scripts tick the land, send client input,
// and have players join mid-run, leave and come back.
//
// The diff and the sends iterate dictionaries, whose order Swift seeds per process: run the
// suite in several processes to cover more orders.
//
// By default the suite is a short check: three cells per land, short scripts, one cell at a
// time, so it doesn't take the CPU from the wall-clock tests that run beside it. Set
// `FRAME_IDENTITY_FULL=1` for the whole matrix (18 cells per land) with the long scripts.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import GameContent

/// Every frame sent, in order, with its target.
private actor FrameRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var sent: [(target: String, data: Data)] = []
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append(("\(target)", message))
    }
}

private func frameIdentityConfig(tables: Bool, perPlayerTables: Bool, dirtyTracking: Bool) -> TransportEnvConfig {
    var config = TransportEnvConfig(
        enableDirtyTracking: dirtyTracking,
        useSnapshotForSync: true,
        syncStrategy: .delta,
        profilingConfig: nil
    )
    config.syncTablesEnabled = tables
    config.perPlayerSyncTablesEnabled = perPlayerTables
    return config
}

/// A land and its adapter, ticked and synced by the script.
private struct FrameIdentityRun<State: StateNodeProtocol> {
    let keeper: LandKeeper<State>
    let adapter: TransportAdapter<State>
    let transport: FrameRecordingTransport

    init(
        definition: LandDefinition<State>,
        landID: String,
        services: LandServices,
        tables: Bool,
        perPlayerTables: Bool,
        dirtyTracking: Bool,
        encoding: TransportEncodingConfig,
        pathHashes: [String: UInt32]?
    ) async {
        transport = FrameRecordingTransport()
        // No loops: the script ticks and syncs, so two runs are comparable.
        keeper = LandKeeper<State>(definition: definition, initialState: State(), services: services, autoStartLoops: false)
        // The same land ID in both runs: it seeds the land's random numbers and is in the frames.
        await keeper.setLandID(landID)
        adapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: landID,
            transportEnvConfig: frameIdentityConfig(tables: tables, perPlayerTables: perPlayerTables, dirtyTracking: dirtyTracking),
            encodingConfig: encoding,
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
    }

    func join(_ name: String) async throws {
        let session = SessionID("s-\(name)"), client = ClientID("c-\(name)")
        await adapter.onConnect(sessionID: session, clientID: client)
        _ = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: name),
            clientID: client,
            sessionID: session,
            authInfo: nil
        )
        await adapter.syncStateForNewPlayer(playerID: PlayerID(name), sessionID: session)
        await settle()
    }

    func leave(_ name: String) async {
        await adapter.onDisconnect(sessionID: SessionID("s-\(name)"), clientID: ClientID("c-\(name)"))
        await settle()
    }

    /// Every step is applied and its frames are out before the next one, so two runs take the
    /// same steps in the same order.
    func settle() async {
        await keeper.waitForInFlightWorkForTesting()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    func event(_ payload: some ClientEventPayload, as name: String) async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(payload),
            playerID: PlayerID(name), clientID: ClientID("c-\(name)"), sessionID: SessionID("s-\(name)")
        )
        await settle()
    }

    func action(_ payload: some ActionPayload, as name: String) async throws {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: type(of: payload)), payload: AnyCodable(payload))
        _ = try await keeper.handleActionEnvelope(
            envelope, playerID: PlayerID(name), clientID: ClientID("c-\(name)"), sessionID: SessionID("s-\(name)")
        )
        await settle()
    }

    func tick(_ count: Int = 1) async {
        for _ in 0..<count {
            await keeper.stepTickOnce()
            await settle()
        }
    }

    func sync() async {
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }
}

/// Each recipient got the same frames, in order.
private func expectSameFrames(
    _ on: [(target: String, data: Data)],
    _ off: [(target: String, data: Data)],
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    func text(_ data: Data) -> String {
        if let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return String(decoding: data.prefix(600), as: UTF8.self)
        }
        return data.prefix(300).map { String(format: "%02x", $0) }.joined()
    }
    let left = Dictionary(grouping: on, by: \.target).mapValues { $0.map(\.data) }
    let right = Dictionary(grouping: off, by: \.target).mapValues { $0.map(\.data) }
    #expect(Set(left.keys) == Set(right.keys), "\(label): recipients", sourceLocation: sourceLocation)
    for target in left.keys.sorted() {
        let mine = left[target] ?? [], theirs = right[target] ?? []
        let first = zip(mine, theirs).enumerated().first { $0.element.0 != $0.element.1 }
        if mine.count != theirs.count || first != nil {
            let detail = first.map { "; first difference at frame \($0.offset): \(text($0.element.0)) vs \(text($0.element.1))" } ?? ""
            Issue.record("\(label): \(target) got \(mine.count) vs \(theirs.count) frames\(detail)", sourceLocation: sourceLocation)
        }
    }
}

private let frameIdentityEncodings: [(String, TransportEncodingConfig)] = [
    ("json", .json),
    ("jsonOpcode", .jsonOpcode),
    ("messagepack", .messagepack),
]

/// The whole matrix and the long scripts (`FRAME_IDENTITY_FULL=1`), or the short check.
private let frameIdentityFull = ProcessInfo.processInfo.environment["FRAME_IDENTITY_FULL"] == "1"

/// Full: every encoding with dirty tracking on and off, with string paths, path hashes and the
/// path index. Short: each encoding once, each of those three once, dirty tracking both ways.
private let frameIdentityCells: [String] = frameIdentityFull
    ? frameIdentityEncodings.flatMap { encoding in
        [true, false].flatMap { dirty in
            ["paths", "hashes", "index"].map { schema in "\(encoding.0)|\(dirty)|\(schema)" }
        }
    }
    : ["messagepack|true|index", "jsonOpcode|false|hashes", "json|true|paths"]

/// The benchmark's capped workload (`--monster-cap`): a spawn every tick up to `cap`, so about
/// `cap` monsters are alive and moving on every tick, with rows created as others are removed.
private struct CappedMonsterTestConfigProvider: GameConfigProvider {
    let base = DefaultGameConfigProvider()
    let cap: Int

    var monsterMaxCount: Int { cap }
    var monsterSpawnIntervalMinTicks: Int { 1 }
    var monsterSpawnIntervalMaxTicks: Int { 1 }
    var monsterSpawnCountMin: Int { cap }
    var monsterSpawnCountMax: Int { cap }

    var worldWidth: Float { base.worldWidth }
    var worldHeight: Float { base.worldHeight }
    var baseCenterX: Float { base.baseCenterX }
    var baseCenterY: Float { base.baseCenterY }
    var baseRadius: Float { base.baseRadius }
    var baseMaxHealth: Int { base.baseMaxHealth }
    var tickIntervalMs: Int { base.tickIntervalMs }
    var monsterSpawnAccelerationTicks: Int64 { base.monsterSpawnAccelerationTicks }
    var monsterMoveSpeed: Float { base.monsterMoveSpeed }
    var monsterBaseHealth: Int { base.monsterBaseHealth }
    var monsterBaseReward: Int { base.monsterBaseReward }
    var weaponBaseDamage: Int { base.weaponBaseDamage }
    var weaponBaseRange: Float { base.weaponBaseRange }
    var weaponFireRateTicks: Int { base.weaponFireRateTicks }
    var turretBaseDamage: Int { base.turretBaseDamage }
    var turretBaseRange: Float { base.turretBaseRange }
    var turretFireRateTicks: Int { base.turretFireRateTicks }
    var turretPlacementDistance: Float { base.turretPlacementDistance }
    var weaponUpgradeCost: Int { base.weaponUpgradeCost }
    var turretUpgradeCost: Int { base.turretUpgradeCost }
    var turretPlacementCost: Int { base.turretPlacementCost }
}

private func heroDefenseServices(monsterCap: Int?) -> LandServices {
    var services = LandServices()
    let provider: any GameConfigProvider = monsterCap.map { CappedMonsterTestConfigProvider(cap: $0) } ?? DefaultGameConfigProvider()
    services.register(GameConfigProviderService(provider: provider), as: GameConfigProviderService.self)
    return services
}

@Suite("The typed tables on and off send the same frames: game lands", .serialized, .timeLimit(.minutes(5)))
struct SyncTablesFrameIdentityTests {
    /// Runs `script` with the switch on and off and compares what each recipient was sent.
    private func compare<State: StateNodeProtocol>(
        cell: String,
        landID: String,
        landType: String,
        definition: @escaping () -> LandDefinition<State>,
        services: @escaping () -> LandServices = { LandServices() },
        kinds: [String: SyncTableFieldKind],
        perPlayerKinds: [String: SyncTableFieldKind],
        script: (FrameIdentityRun<State>) async throws -> Void
    ) async throws {
        let parts = cell.split(separator: "|").map(String.init)
        let encoding = try #require(frameIdentityEncodings.first { $0.0 == parts[0] }?.1).withPathIndex(parts[2] == "index")
        let dirtyTracking = parts[1] == "true"
        var pathHashes: [String: UInt32]?
        if parts[2] != "paths" {
            let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(definition())])
            pathHashes = try #require(schema.lands[landType]?.pathHashes)
        }
        // Both tables on, the broadcast tables alone (per-player fields on today's path, #514),
        // and neither: each against neither.
        var frames: [[(target: String, data: Data)]] = []
        for (tables, perPlayerTables) in [(true, true), (true, false), (false, false)] {
            let run = await FrameIdentityRun<State>(
                definition: definition(), landID: landID, services: services(), tables: tables,
                perPlayerTables: perPlayerTables, dirtyTracking: dirtyTracking, encoding: encoding, pathHashes: pathHashes
            )
            // Which broadcast fields the typed diff walks: a field on the fallback is the
            // snapshot diff on both sides, so the cell says nothing about the tables for it.
            #expect(await run.adapter.syncTableFieldKinds() == (tables ? kinds : nil), "\(cell): kinds")
            #expect(await run.adapter.perPlayerSyncTablesInEffect() == perPlayerTables, "\(cell): per-player tables in effect")
            // Which per-player fields the per-player tables type: a nil description would put
            // them all on `.fallback`, and the identity would hold with the saving gone.
            #expect(await run.adapter.perPlayerSyncTableFieldKinds() == (perPlayerTables ? perPlayerKinds : nil), "\(cell): per-player kinds")
            try await script(run)
            frames.append(await run.transport.sent)
            #expect(await run.adapter.syncFailedPlans == 0, "\(cell): no plan failed")
        }
        #expect(frames[0].count > 20, "\(cell): the script sends frames")
        expectSameFrames(frames[0], frames[2], cell + " (both tables)")
        expectSameFrames(frames[1], frames[2], cell + " (broadcast tables)")
    }

    @Test("Hero Defense", arguments: frameIdentityCells)
    func heroDefense(cell: String) async throws {
        try await heroDefenseCell(cell, monsterCap: nil)
    }

    /// The workload the sync cost is measured on: about 100 monsters alive from the first ticks.
    @Test("Hero Defense with 100 monsters alive", arguments: frameIdentityCells)
    func heroDefenseCap100(cell: String) async throws {
        try await heroDefenseCell(cell, monsterCap: 100)
    }

    private func heroDefenseCell(_ cell: String, monsterCap: Int?) async throws {
        try await compare(
            cell: cell, landID: "hero-defense:frame-identity", landType: "hero-defense",
            definition: { HeroDefense.makeLand() }, services: { heroDefenseServices(monsterCap: monsterCap) },
            // Every broadcast field is typed.
            kinds: ["players": .nodeMap, "monsters": .nodeMap, "turrets": .nodeMap, "base": .node, "score": .value],
            perPlayerKinds: [:]
        ) { run in
            var capReachedAt: Int?
            try await run.join("alice")
            try await run.join("bob")
            await run.sync()
            // Monsters spawn and move, players move, shoot, turn and build.
            let ticks = frameIdentityFull ? 240 : (monsterCap == nil ? 72 : 24)
            for tick in 0..<ticks {
                if tick % 7 == 0 {
                    try await run.event(MoveToEvent(x: Float(20 + tick % 60), y: Float(10 + tick % 40)), as: "alice")
                }
                if tick % 11 == 3 {
                    try await run.event(UpdateRotationEvent(radians: Float(tick % 6)), as: "alice")
                    try await run.event(ShootEvent(), as: "alice")
                }
                if tick == ticks / 6 { try await run.join("carol") }
                if tick > ticks / 6, tick % 13 == 5 {
                    try await run.event(MoveToEvent(x: Float(70 - tick % 50), y: Float(30 + tick % 20)), as: "carol")
                    try await run.event(ShootEvent(), as: "carol")
                }
                if tick == ticks / 4 { try await run.event(PlaceTurretEvent(x: 40, y: 30), as: "alice") }
                if tick == ticks * 5 / 12 { await run.leave("bob") }
                if tick == ticks * 5 / 8 { try await run.join("bob") }
                if tick > ticks * 5 / 8, tick % 9 == 2 { try await run.event(ShootEvent(), as: "bob") }
                await run.tick()
                if let monsterCap, capReachedAt == nil, await run.keeper.currentState().monsters.count >= monsterCap {
                    capReachedAt = tick
                }
                if tick % 2 == 1 { await run.sync() }
            }
            await run.sync()
            await run.sync()
            if let monsterCap {
                // Most of the run is at the cap, with rows created as others are removed.
                let reached = try #require(capReachedAt, "\(monsterCap) monsters were never alive at once")
                #expect(reached < 30, "the cap is reached at tick \(reached)")
                // Under the cap the count dips as monsters die; it must not stay far below.
                let alive = await run.keeper.currentState().monsters.count
                #expect(alive * 2 >= monsterCap, "\(alive) monsters alive at the end")
                if cell == frameIdentityCells[0] { print("monster cap \(monsterCap): first reached at tick \(reached), \(alive) alive at the end") }
            }
        }
    }

    /// Entities move in and out of each viewer's radius; one is placed by an action.
    private func visibilityScript<State: VisibilityTestStateShape>(_ run: FrameIdentityRun<State>) async throws {
        try await run.join("p0")
        try await run.join("p1")
        await run.sync()
        let ticks = frameIdentityFull ? 120 : 48
        for tick in 0..<ticks {
            if tick % 10 == 4 {
                try await run.event(MoveViewerEvent(position: Position2(x: Float(10 + tick % 50), y: Float(15 + tick % 30))), as: "p0")
            }
            if tick == ticks / 4 { try await run.join("p2") }
            if tick == ticks * 3 / 8 {
                try await run.action(
                    PlaceEntityAction(id: "e7", positions: [Position2(x: 20, y: 20), Position2(x: 50, y: 50)]), as: "p0"
                )
            }
            if tick == ticks / 2 { await run.leave("p1") }
            if tick == ticks * 2 / 3 { try await run.join("p1") }
            if tick == ticks * 3 / 4 { try await run.action(SetMotionAction(enabled: false), as: "p0") }
            if tick == ticks * 5 / 6 { try await run.action(SetMotionAction(enabled: true), as: "p0") }
            await run.tick()
            if tick % 2 == 1 { await run.sync() }
        }
        await run.sync()
        await run.sync()
    }

    /// The per-player policy with each filter: `.radius` (what each player sees changes as
    /// entities move) and `.all` (every entity to every player).
    @Test("The visibility test land, per-player entities", arguments: frameIdentityCells, [VisibilityFilter.radius, .all])
    func visibilityPerPlayer(cell: String, filter: VisibilityFilter) async throws {
        let settings = VisibilityTestSettings(entityCount: 40, viewRadius: 15, filter: filter)
        try await compare(
            cell: cell, landID: "visibility-test:frame-identity", landType: VisibilityTestConfig.landType,
            definition: { VisibilityTest.makeLand(VisibilityTestState.self, settings: settings) },
            // `entities` is per-player here, so it isn't on the broadcast tables. Every broadcast
            // field is typed, and `entities` takes the per-player tables' node map slot.
            kinds: ["motion": .value, "tickCount": .value, "viewEntries": .value, "viewExits": .value, "viewers": .value],
            perPlayerKinds: ["entities": .nodeMap],
            script: visibilityScript
        )
    }

    @Test("The visibility test land, broadcast twin", arguments: frameIdentityCells)
    func visibilityBroadcast(cell: String) async throws {
        let settings = VisibilityTestSettings(entityCount: 40, viewRadius: 15, filter: .broadcast)
        try await compare(
            cell: cell, landID: "visibility-test:frame-identity", landType: VisibilityTestConfig.landType,
            definition: { VisibilityTest.makeLand(VisibilityTestBroadcastState.self, settings: settings) },
            // The twin's `entities` is a broadcast node map. Every broadcast field is typed.
            kinds: [
                "entities": .nodeMap, "motion": .value, "tickCount": .value, "viewEntries": .value, "viewExits": .value,
                "viewers": .value,
            ],
            perPlayerKinds: [:],
            script: visibilityScript
        )
    }

    @Test("The card game", arguments: frameIdentityCells)
    func cardGame(cell: String) async throws {
        try await compare(
            cell: cell, landID: "card-game:frame-identity", landType: "card-game",
            definition: { CardGame.makeLand() },
            // `hands` is a per-player slice, so it isn't on the tables. Every broadcast field is typed.
            kinds: [
                "players": .value, "publicCards": .value, "currentRound": .value, "gamePhase": .value,
                "deckSize": .value, "turnOrder": .value, "currentPlayerIndex": .value,
            ],
            perPlayerKinds: ["hands": .value]
        ) { run in
            // Players draw on ticks, overflow their hands to the public pile, join, leave and come back.
            try await run.join("alice")
            try await run.join("bob")
            await run.sync()
            let ticks = frameIdentityFull ? 400 : 160
            for tick in 0..<ticks {
                if tick == ticks / 8 { try await run.join("carol") }
                if tick == ticks / 3 { await run.leave("bob") }
                if tick == ticks / 2 { try await run.join("bob") }
                if tick == ticks * 3 / 4 { try await run.join("dave") }
                await run.tick()
                if tick % 2 == 1 { await run.sync() }
            }
            await run.sync()
        }
    }
}
