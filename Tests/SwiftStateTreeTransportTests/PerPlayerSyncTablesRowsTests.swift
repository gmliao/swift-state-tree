// Tests/SwiftStateTreeTransportTests/PerPlayerSyncTablesRowsTests.swift
//
// The per-player tables (#514) with row addressing in effect. The frame identity harnesses build
// direct adapters, where row addressing never takes effect, so this case joins through the
// in-turn path (a JoinResponse builder, as the router passes) and checks first that row
// addressing is in effect. The per-player boxes have no path cursor, so no per-player patch can
// carry a row tag, which would make it a row entry in the broadcast slot space (plan §7): the
// frames with the per-player tables on must be the frames with them off, and every client must
// decode its frames to the server's view of it.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct PPRowsUnit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var tag: String = ""
    init() {}
}

@StateNodeBuilder
struct PPRowsState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    /// Slot-addressed with row addressing in effect.
    @Sync(.broadcast) var units: [String: PPRowsUnit] = [:]
    /// The visibility land's shape: each player sees the units its id prefixes.
    @Sync(.perPlayer({ (v: [String: PPRowsUnit], player: PlayerID) in v.filter { $0.key.hasPrefix(player.rawValue) } }))
    var seen: [String: PPRowsUnit] = [:]
    @Sync(.perPlayerSlice()) var hands: [PlayerID: [String]] = [:]
    init() {}
}

/// The next step, applied by each tick.
private final class PPRowsScript: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [(inout PPRowsState) -> Void] = []
    func queue(_ step: @escaping (inout PPRowsState) -> Void) { lock.lock(); steps.append(step); lock.unlock() }
    func apply(_ state: inout PPRowsState) {
        lock.lock()
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        step?(&state)
    }
}

private actor PPRowsFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var sent: [(target: String, data: Data)] = []
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { sent.append(("\(target)", message)) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { sent.append(("\(target)", data)) }
    }
}

private func ppRowsLand(_ script: PPRowsScript) -> LandDefinition<PPRowsState> {
    Land("pp-rows", using: PPRowsState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout PPRowsState, ctx: LandContext) in
                script.apply(&state)
                ctx.requestSyncNow()
            }
        }
    }
}

private let ppRowsJoinResponse: @Sendable (PlayerID, Int32) -> Data? = { playerID, slot in
    // Sorted keys: runs compared frame by frame get the same bytes.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(TransportMessage.joinResponse(
        requestID: "r-\(playerID.rawValue)", success: true, playerID: playerID.rawValue, playerSlot: slot, encoding: "json"
    ))
}

private struct PPRowsRun {
    let keeper: LandKeeper<PPRowsState>
    let adapter: TransportAdapter<PPRowsState>
    let frames = PPRowsFrames()
    let script = PPRowsScript()
    let hasher: PathHasher

    init(encoding: RowAddressingEncoding, perPlayerTables: Bool) async throws {
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(ppRowsLand(PPRowsScript()))])
        let pathHashes = try #require(schema.lands["pp-rows"]?.pathHashes)
        hasher = PathHasher(pathHashes: pathHashes)
        keeper = LandKeeper(definition: ppRowsLand(script), initialState: PPRowsState(), autoStartLoops: false)
        var config = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: true, syncStrategy: .delta, profilingConfig: nil)
        // Off: row addressing turns the broadcast tables on regardless.
        config.useSyncTables = false
        config.perPlayerSyncTables = perPlayerTables
        adapter = TransportAdapter<PPRowsState>(
            keeper: keeper,
            transport: frames,
            landID: "pp-rows",
            transportEnvConfig: config,
            encodingConfig: encoding.config.withSyncSequence(true).withRowAddressing(true),
            pathHashes: pathHashes,
            suppressMissingPathHashesWarning: true,
            inTurnSync: true,
            joinsThroughRouter: true
        )
        await frames.setDelegate(adapter)
        await keeper.setTransport(adapter)
    }

    func join(_ name: String) async throws {
        let session = SessionID("s-\(name)"), client = ClientID("c-\(name)")
        await adapter.onConnect(sessionID: session, clientID: client)
        let result = try await adapter.performJoin(
            playerSession: PlayerSession(playerID: name, deviceID: "dev", metadata: [:]),
            clientID: client, sessionID: session, authInfo: nil, joinResponse: ppRowsJoinResponse
        )
        _ = try #require(result)
        #expect(await adapter.waitForOutboundDrain())
    }

    func leave(_ name: String) async {
        await adapter.onDisconnect(sessionID: SessionID("s-\(name)"), clientID: ClientID("c-\(name)"))
        await keeper.waitForInFlightWorkForTesting()
        #expect(await adapter.waitForOutboundDrain())
    }

    func tick(_ step: @escaping (inout PPRowsState) -> Void) async {
        script.queue(step)
        await keeper.stepTickOnce()
        #expect(await adapter.waitForOutboundDrain())
    }

    /// `name`'s view, decoded from every state frame its session received.
    func clientView(_ name: String, encoding: RowAddressingEncoding) async throws -> [String: SnapshotValue] {
        let decoder = OpcodeJSONStateUpdateDecoder(
            pathHasher: hasher, atomicLayout: AtomicLayoutTable.forState(PPRowsState.self), pathIndex: true, syncSequence: true
        )
        var view = SnapshotClientView()
        for frame in await frames.sent where frame.target == "session(s-\(name))" {
            if (try? JSONDecoder().decode(TransportMessage.self, from: frame.data)) != nil { continue }
            guard let decoded = try decoder.decodeFrame(frame.data, format: encoding.format) else { continue }
            if decoded.resync { view = SnapshotClientView() }
            switch decoded.update {
            case .noChange: break
            case .diff(let p), .firstSync(let p): try view.apply(p)
            }
        }
        return view.fields
    }
}

@Suite("The per-player tables with row addressing in effect (#514)", .timeLimit(.minutes(1)))
struct PerPlayerSyncTablesRowsTests {
    @Test("Per-player frames are the same with the per-player tables on and off, and every client reaches its view", arguments: RowAddressingEncoding.allCases)
    func rowsInEffect(encoding: RowAddressingEncoding) async throws {
        var sent: [[(target: String, data: Data)]] = []
        for perPlayerTables in [true, false] {
            let run = try await PPRowsRun(encoding: encoding, perPlayerTables: perPlayerTables)
            #expect(run.adapter.rowAddressing, "row addressing is in effect")
            #expect(run.adapter.stateUpdateFeatures.contains(StateUpdateFeature.rowAddressing))
            #expect(await run.adapter.perPlayerSyncTablesInEffect() == perPlayerTables)
            try await run.join("p1")
            try await run.join("p2")
            for round in 0..<12 {
                await run.tick { state in
                    state.round = round
                    let key = "p\(1 + round % 2).u\(round % 3)"
                    if round % 4 == 3 {
                        state.units.removeValue(forKey: key)
                    } else {
                        state.units[key, default: PPRowsUnit()].hp += 1
                        state.units[key]!.tag = "t\(round)"
                    }
                    state.seen = state.units
                    state.hands[PlayerID("p\(1 + round % 2)"), default: []].append("c\(round)")
                    if round == 6 { state.hands.removeValue(forKey: PlayerID("p1")) }
                }
                // A join mid-run (its full view) and a leave.
                if round == 4 { try await run.join("p3") }
                if round == 8 { await run.leave("p2") }
            }
            let state = await run.keeper.currentState()
            for name in ["p1", "p3"] {
                let server = try state.snapshot(for: PlayerID(name), dirtyFields: nil).values
                let client = try await run.clientView(name, encoding: encoding)
                #expect(client == server, "\(encoding), per-player tables \(perPlayerTables): \(name)'s view")
            }
            #expect(await run.adapter.syncFailedPlans == 0)
            sent.append(await run.frames.sent)
        }
        // Bytes per recipient, in order. (`expectSameFrames`' slot check reads the per-path key
        // tables, not row entries; the client views above check the decoding.)
        #expect(sent[0].count == sent[1].count, "\(encoding): frame count")
        let on = Dictionary(grouping: sent[0], by: \.target).mapValues { $0.map(\.data) }
        let off = Dictionary(grouping: sent[1], by: \.target).mapValues { $0.map(\.data) }
        #expect(on == off, "\(encoding): the same frames per recipient")
        #expect(on.keys.count == 3)
    }
}
