// Examples/Demo/Tests/DemoContentTests/SyncTablesFrameIdentityTests.swift
//
// The broadcast diff on the typed sync tables (the default) must send the frames the snapshot
// diff sends. The cookie game and the counter run one script on an adapter with the tables on
// and on one with them off, and each recipient must get the same frames, byte for byte and in
// order, in every encoding, with dirty tracking on and off. The scripts tick the land, send
// client input, and have players join mid-run, leave and come back.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
@testable import DemoContent

private actor FrameRecordingTransport: Transport {
    var delegate: TransportDelegate?
    var sent: [(target: String, data: Data)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append(("\(target)", message))
    }
}

/// A land and its adapter, ticked and synced by the script.
private struct FrameIdentityRun<State: StateNodeProtocol> {
    let keeper: LandKeeper<State>
    let adapter: TransportAdapter<State>
    let transport: FrameRecordingTransport

    init(
        definition: LandDefinition<State>,
        landID: String,
        tables: Bool,
        dirtyTracking: Bool,
        encoding: TransportEncodingConfig,
        pathHashes: [String: UInt32]
    ) async {
        transport = FrameRecordingTransport()
        // No loops: the script ticks and syncs, so two runs are comparable.
        keeper = LandKeeper<State>(definition: definition, initialState: State(), autoStartLoops: false)
        await keeper.setLandID(landID)
        var config = TransportEnvConfig(
            enableDirtyTracking: dirtyTracking,
            useSnapshotForSync: true,
            syncStrategy: .delta,
            profilingConfig: nil
        )
        config.syncTablesEnabled = tables
        adapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: landID,
            transportEnvConfig: config,
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

    func tick() async {
        await keeper.stepTickOnce()
        await settle()
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
    let left = Dictionary(grouping: on, by: \.target).mapValues { $0.map(\.data) }
    let right = Dictionary(grouping: off, by: \.target).mapValues { $0.map(\.data) }
    #expect(Set(left.keys) == Set(right.keys), "\(label): recipients", sourceLocation: sourceLocation)
    for target in left.keys.sorted() {
        let mine = left[target] ?? [], theirs = right[target] ?? []
        if let first = zip(mine, theirs).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
            Issue.record("\(label): \(target) differs first at frame \(first.offset)", sourceLocation: sourceLocation)
        } else if mine.count != theirs.count {
            Issue.record("\(label): \(target) got \(mine.count) vs \(theirs.count) frames", sourceLocation: sourceLocation)
        }
    }
}

private let frameIdentityEncodings: [(String, TransportEncodingConfig)] = [
    ("json", .json),
    ("jsonOpcode", .jsonOpcode),
    ("messagepack", .messagepack),
]

/// Every encoding with dirty tracking on and off.
private let frameIdentityCells: [String] = frameIdentityEncodings.flatMap { encoding in
    [true, false].map { "\(encoding.0)|\($0)" }
}

@Suite("The typed tables on and off send the same frames: Demo lands", .serialized, .timeLimit(.minutes(2)))
struct SyncTablesFrameIdentityTests {
    private func compare<State: StateNodeProtocol>(
        cell: String,
        landType: String,
        definition: @escaping () -> LandDefinition<State>,
        kinds: [String: SyncTableFieldKind],
        script: (FrameIdentityRun<State>) async throws -> Void
    ) async throws {
        let parts = cell.split(separator: "|").map(String.init)
        let encoding = try #require(frameIdentityEncodings.first { $0.0 == parts[0] }?.1)
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(definition())])
        let pathHashes = try #require(schema.lands[landType]?.pathHashes)
        var frames: [[(target: String, data: Data)]] = []
        for tables in [true, false] {
            let run = await FrameIdentityRun<State>(
                definition: definition(), landID: "\(landType):frame-identity", tables: tables,
                dirtyTracking: parts[1] == "true", encoding: encoding, pathHashes: pathHashes
            )
            // A field on the fallback is the snapshot diff on both sides: pin which are typed.
            #expect(await run.adapter.syncTableFieldKinds() == (tables ? kinds : nil), "\(cell): kinds")
            try await script(run)
            frames.append(await run.transport.sent)
            #expect(await run.adapter.syncFailedPlans == 0, "\(cell): no plan failed")
        }
        #expect(frames[0].count > 20, "\(cell): the script sends frames")
        expectSameFrames(frames[0], frames[1], cell)
    }

    @Test("The cookie game", arguments: frameIdentityCells)
    func cookie(cell: String) async throws {
        try await compare(
            cell: cell, landType: "cookie", definition: { CookieGame.makeLand() },
            // `privateStates` is a per-player slice, so it isn't on the tables.
            kinds: ["players": .nodeMap, "totalCookies": .value, "ticks": .value]
        ) { run in
            try await run.join("alice")
            try await run.join("bob")
            await run.sync()
            for step in 0..<48 {
                try await run.event(ClickCookieEvent(amount: 1 + step % 5), as: step % 3 == 0 ? "bob" : "alice")
                if step % 9 == 4 { try await run.action(BuyUpgradeAction(upgradeID: "cursor"), as: "alice") }
                if step == 12 { try await run.join("carol") }
                if step == 20 { await run.leave("bob") }
                if step == 30 { try await run.join("bob") }
                if step > 12, step % 5 == 0 { try await run.event(ClickCookieEvent(amount: 3), as: "carol") }
                if step % 4 == 3 { await run.tick() }
                if step % 2 == 1 { await run.sync() }
            }
            await run.sync()
        }
    }

    @Test("The counter", arguments: frameIdentityCells)
    func counter(cell: String) async throws {
        try await compare(
            cell: cell, landType: "counter", definition: { CounterDemo.makeLand() },
            kinds: ["count": .value]
        ) { run in
            try await run.join("alice")
            try await run.join("bob")
            await run.sync()
            for step in 0..<40 {
                try await run.action(IncrementAction(), as: step % 2 == 0 ? "alice" : "bob")
                if step == 10 { try await run.join("carol") }
                if step == 18 { await run.leave("bob") }
                if step == 26 { try await run.join("bob") }
                if step % 5 == 4 { await run.tick() }
                if step % 3 != 1 { await run.sync() }
            }
            await run.sync()
        }
    }
}
