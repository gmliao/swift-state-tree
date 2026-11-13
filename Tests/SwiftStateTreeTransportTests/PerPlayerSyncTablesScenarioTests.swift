// Tests/SwiftStateTreeTransportTests/PerPlayerSyncTablesScenarioTests.swift
//
// The per-player tables (#514) through the adapter's failure and membership paths: one script
// runs with both tables on, with the broadcast tables alone (per-player fields on today's
// per-player snapshot diff) and with neither, and each recipient must get the same frames, byte
// for byte and in order, on every encoding, with the one-pass extraction on and off. The scripts
// fail a plan (a key reset follows), fail one player's frames to encode, fail the opcode 107
// merged broadcast frame, run broadcast-only syncs, throw in a per-player conversion with a late
// join right after, disconnect and reconnect, and supersede a session.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// MARK: - Lands

/// A value whose conversion throws for a negative `n`.
struct PPScenarioRisky: Equatable, Sendable, SnapshotValueConvertible {
    var n: Int = 0
    func toSnapshotValue() throws -> SnapshotValue {
        if n < 0 { throw SyncError.unsupportedValue("negative n \(n)") }
        return .object(["n": .int(n)])
    }
}

@StateNodeBuilder
struct PPScenarioState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var board: [String: Int] = [:]
    @Sync(.perPlayerSlice()) var hands: [PlayerID: [String]] = [:]
    /// Each player sees the marks keyed with its own id as prefix.
    @Sync(.perPlayer({ (v: [String: Int], player: PlayerID) in v.filter { $0.key.hasPrefix(player.rawValue) } }))
    var marks: [String: Int] = [:]
    @Sync(.perPlayer({ (v: PPScenarioRisky, _: PlayerID) in v })) var risky: PPScenarioRisky = PPScenarioRisky()
    @Sync(.serverOnly) var steps: Int = 0
    init() {}
}

/// No per-player fields: the per-player tables have no field to diff (B1: no entry; B2: an
/// empty entry per player).
@StateNodeBuilder
struct PPScenarioBroadcastState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var board: [String: Int] = [:]
    @Sync(.broadcast) var flaky: PPScenarioRisky = PPScenarioRisky()
    init() {}
}

/// One script step. `@Payload` rejects optionals: "" and `PPScenarioStep.none` mean "none".
@Payload
struct PPScenarioStep: ClientEventPayload {
    let hand: String
    let clearHand: Bool
    let mark: Int
    let risky: Int
    let board: Int
}

extension PPScenarioStep {
    static let none = Int.min
}

private func makePPScenarioLand(landID: String) -> LandDefinition<PPScenarioState> {
    Land(landID, using: PPScenarioState.self) {
        ClientEvents { Register(PPScenarioStep.self) }
        Rules {
            OnJoin { (state: inout PPScenarioState, ctx: LandContext) in
                state.hands[ctx.playerID] = []
            }
            OnLeave { (state: inout PPScenarioState, ctx: LandContext) in
                state.hands.removeValue(forKey: ctx.playerID)
                for key in state.marks.keys.sorted() where key.hasPrefix(ctx.playerID.rawValue) {
                    state.marks.removeValue(forKey: key)
                }
            }
            HandleEvent(PPScenarioStep.self) { (state: inout PPScenarioState, step: PPScenarioStep, ctx: LandContext) in
                state.steps += 1
                if !step.hand.isEmpty { state.hands[ctx.playerID, default: []].append(step.hand) }
                if step.clearHand { state.hands.removeValue(forKey: ctx.playerID) }
                if step.mark != PPScenarioStep.none { state.marks["\(ctx.playerID.rawValue).\(step.mark % 3)"] = step.mark }
                if step.risky != PPScenarioStep.none { state.risky.n = step.risky }
                if step.board != PPScenarioStep.none {
                    state.round += 1
                    state.board["b\(step.board % 4)"] = step.board
                }
            }
        }
    }
}

private func makePPScenarioBroadcastLand(landID: String) -> LandDefinition<PPScenarioBroadcastState> {
    Land(landID, using: PPScenarioBroadcastState.self) {
        ClientEvents { Register(PPScenarioStep.self) }
        Rules {
            HandleEvent(PPScenarioStep.self) { (state: inout PPScenarioBroadcastState, step: PPScenarioStep, _: LandContext) in
                if step.risky != PPScenarioStep.none { state.flaky.n = step.risky }
                if step.board != PPScenarioStep.none {
                    state.round += 1
                    state.board["b\(step.board % 4)"] = step.board
                }
            }
        }
    }
}

// MARK: - Harness

/// A test switch read from the adapter's fault hooks.
private final class PPScenarioFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var failingPlayer: PlayerID?
    private var mergedFrameFails = false
    private var planFails = false

    func player() -> PlayerID? { lock.lock(); defer { lock.unlock() }; return failingPlayer }
    func setPlayer(_ value: PlayerID?) { lock.lock(); failingPlayer = value; lock.unlock() }
    func mergedFrame() -> Bool { lock.lock(); defer { lock.unlock() }; return mergedFrameFails }
    func setMergedFrame(_ value: Bool) { lock.lock(); mergedFrameFails = value; lock.unlock() }
    /// True once, after `armPlan`.
    func takePlan() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let fails = planFails
        planFails = false
        return fails
    }
    func armPlan() { lock.lock(); planFails = true; lock.unlock() }
}

private struct PPScenarioPlanFault: Error {}

/// The three configurations: both tables, the broadcast tables alone, neither.
private let ppScenarioConfigs: [(tables: Bool, perPlayerTables: Bool)] = [(true, true), (true, false), (false, false)]

private struct PPScenarioRun<State: StateNodeProtocol> {
    let keeper: LandKeeper<State>
    let adapter: TransportAdapter<State>
    let transport: DirtyIdentityRecordingTransport
    let faults = PPScenarioFaults()

    init(
        definition: LandDefinition<State>,
        tables: Bool,
        perPlayerTables: Bool,
        onePass: Bool,
        encoding: TransportEncodingConfig
    ) async {
        var config = TransportEnvConfig(enableDirtyTracking: true, useSnapshotForSync: onePass, syncStrategy: .delta, profilingConfig: nil)
        config.useSyncTables = tables
        config.perPlayerSyncTables = perPlayerTables
        transport = DirtyIdentityRecordingTransport()
        keeper = LandKeeper<State>(definition: definition, initialState: State(), autoStartLoops: false)
        adapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: definition.id,
            transportEnvConfig: config,
            encodingConfig: encoding,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let faults = self.faults
        await adapter.setSyncEncodeFaultForTesting { $0 == faults.player() }
        await adapter.setMergedBroadcastFrameFaultForTesting { faults.mergedFrame() }
        await adapter.setSyncPlanFaultForTesting { if faults.takePlan() { throw PPScenarioPlanFault() } }
    }

    /// Joins `name` on session `s-<name><suffix>`: a second join of a player supersedes its session.
    func join(_ name: String, suffix: String = "") async throws {
        let session = SessionID("s-\(name)\(suffix)"), client = ClientID("c-\(name)\(suffix)")
        await adapter.onConnect(sessionID: session, clientID: client)
        _ = try await adapter.performJoin(playerSession: PlayerSession(playerID: name), clientID: client, sessionID: session, authInfo: nil)
        await adapter.syncStateForNewPlayer(playerID: PlayerID(name), sessionID: session)
        await settle()
    }

    func leave(_ name: String, suffix: String = "") async {
        await adapter.onDisconnect(sessionID: SessionID("s-\(name)\(suffix)"), clientID: ClientID("c-\(name)\(suffix)"))
        await settle()
    }

    func step(
        _ name: String, suffix: String = "", hand: String = "", clearHand: Bool = false,
        mark: Int = PPScenarioStep.none, risky: Int = PPScenarioStep.none, board: Int = PPScenarioStep.none
    ) async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(PPScenarioStep(hand: hand, clearHand: clearHand, mark: mark, risky: risky, board: board)),
            playerID: PlayerID(name), clientID: ClientID("c-\(name)\(suffix)"), sessionID: SessionID("s-\(name)\(suffix)")
        )
        await settle()
    }

    func settle() async {
        await keeper.waitForInFlightWorkForTesting()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    func sync() async {
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    func syncBroadcastOnly() async {
        await adapter.syncBroadcastOnly()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }
}

/// Runs `script` in the three configurations and compares each recipient's frames with neither
/// table's.
private func comparePPScenario<State: StateNodeProtocol>(
    _ label: String,
    definition: @escaping () -> LandDefinition<State>,
    onePass: Bool,
    encoding: TransportEncodingConfig,
    sourceLocation: SourceLocation = #_sourceLocation,
    script: (PPScenarioRun<State>) async throws -> Void
) async throws {
    var frames: [[(target: String, data: Data)]] = []
    for config in ppScenarioConfigs {
        let run = await PPScenarioRun<State>(
            definition: definition(), tables: config.tables, perPlayerTables: config.perPlayerTables,
            onePass: onePass, encoding: encoding
        )
        #expect(await run.adapter.usesSyncTablesForTesting() == config.tables, sourceLocation: sourceLocation)
        #expect(await run.adapter.usesPerPlayerTablesForTesting() == config.perPlayerTables, sourceLocation: sourceLocation)
        try await script(run)
        frames.append(await run.transport.sent)
    }
    #expect(frames[2].count > 10, "\(label): the script sends frames", sourceLocation: sourceLocation)
    expectSameFrames(frames[0], frames[2], "\(label), both tables", sourceLocation: sourceLocation)
    expectSameFrames(frames[1], frames[2], "\(label), broadcast tables alone", sourceLocation: sourceLocation)
}

private let ppScenarioCells: [String] = dirtyIdentityEncodings.flatMap { encoding in
    [true, false].map { onePass in "\(encoding.0)|\(onePass)" }
}

private func ppScenarioCell(_ cell: String) throws -> (encoding: TransportEncodingConfig, onePass: Bool) {
    let parts = cell.split(separator: "|").map(String.init)
    return (try #require(dirtyIdentityEncodings.first { $0.0 == parts[0] }?.1), parts[1] == "true")
}

// MARK: - Tests

@Suite("The per-player tables send today's frames through failures and membership changes (#514)", .timeLimit(.minutes(1)))
struct PerPlayerSyncTablesScenarioTests {
    @Test("Failed plans, encode failures, broadcast-only syncs, throws, leaves and supersedes", arguments: ppScenarioCells)
    func failuresAndMembership(cell: String) async throws {
        let (encoding, onePass) = try ppScenarioCell(cell)
        try await comparePPScenario(cell, definition: { makePPScenarioLand(landID: "pp-scenario") }, onePass: onePass, encoding: encoding) { run in
            try await run.join("p1")
            try await run.join("p2")
            await run.sync()
            try await run.step("p1", hand: "a", mark: 1)
            try await run.step("p2", hand: "b", board: 1)
            await run.sync()

            // A failed plan: nothing commits, and the next plan resets the key scopes.
            try await run.step("p1", hand: "c", mark: 2)
            run.faults.armPlan()
            await run.sync()
            try await run.step("p2", mark: 3)
            await run.sync()

            if !onePass {
                // One player's frames fail to encode entirely (a combined frame with json and
                // opcodeJsonArray; the per-player frame with opcode 107), then encode again. With
                // the one-pass extraction the lag that follows differs by design (M7, D5):
                // `encodeFailureLagOnePass` pins it.
                try await run.step("p2", hand: "d", mark: 4, board: 2)
                run.faults.setPlayer(PlayerID("p2"))
                await run.sync()
                run.faults.setPlayer(nil)
                try await run.step("p1", mark: 5)
                await run.sync()
            }

            // The opcode 107 merged broadcast frame fails while the per-player frames go out.
            try await run.step("p1", hand: "e", board: 3)
            run.faults.setMergedFrame(true)
            await run.sync()
            run.faults.setMergedFrame(false)
            try await run.step("p2", mark: 6)
            await run.sync()

            // Broadcast-only syncs: per-player changes wait for the next full sync.
            try await run.step("p1", hand: "f", board: 4)
            await run.syncBroadcastOnly()
            try await run.step("p2", board: 5)
            await run.syncBroadcastOnly()
            await run.sync()

            if !onePass {
                // A per-player conversion throws, a player joins right after, then it converts.
                // With the one-pass extraction today's fallback is all-or-nothing (M8), which the
                // typed diff doesn't copy (T1), so the identity is checked without it.
                try await run.step("p1", mark: 7, risky: -1)
                await run.sync()
                try await run.join("p3")
                try await run.step("p3", hand: "g")
                await run.sync()
                try await run.step("p1", risky: 2)
                await run.sync()
            }

            // A leave and a reconnect: the player's view again from empty.
            await run.leave("p2")
            await run.sync()
            try await run.join("p2")
            try await run.step("p2", hand: "h", mark: 8)
            await run.sync()

            // A second join supersedes the player's session.
            try await run.join("p1", suffix: "-b")
            #expect(await run.adapter.supersededSessionCount == 1)
            try await run.step("p1", suffix: "-b", hand: "i", mark: 9)
            await run.sync()

            // A player's slice leaves its view and comes back.
            try await run.step("p1", suffix: "-b", clearHand: true)
            await run.sync()
            try await run.step("p1", suffix: "-b", hand: "j")
            await run.sync()
            await run.sync()
            #expect(await run.adapter.syncFailedPlans == 1, "\(cell): only the armed plan failed")
        }
    }

    /// M6, M7 (D5): after a total per-player encode failure with the one-pass extraction, a clean
    /// per-player field lags. Its box stays at what the client has, so the field's next write
    /// sends the missed change too; today's cache was advanced silently, so the client stays
    /// behind until that value changes again. Known bug #532; interim until #535 closes the land
    /// on the failure.
    @Test("One-pass, after an encode failure: the next write of the lagging field sends the missed change (#532, #535)", arguments: dirtyIdentityEncodings.map(\.0))
    func encodeFailureLagOnePass(encodingName: String) async throws {
        let encoding = try #require(dirtyIdentityEncodings.first { $0.0 == encodingName }?.1)
        let p2Session = "session(s-p2)"
        for config in ppScenarioConfigs {
            let run = await PPScenarioRun<PPScenarioState>(
                definition: makePPScenarioLand(landID: "pp-scenario-lag"), tables: config.tables,
                perPlayerTables: config.perPlayerTables, onePass: true, encoding: encoding
            )
            try await run.join("p1")
            try await run.join("p2")
            await run.sync()
            try await run.step("p2", hand: "b")
            await run.sync()
            // p2's frames fail entirely while its hand changes.
            try await run.step("p2", hand: "d")
            run.faults.setPlayer(PlayerID("p2"))
            await run.sync()
            run.faults.setPlayer(nil)
            // A broadcast-only mutation: `hands` is clean, so no mode compares it.
            try await run.step("p1", board: 1)
            await run.sync()
            // A write to `hands` (p1's entry): p2's own entry is unchanged since the failure.
            try await run.step("p1", hand: "e")
            let before = await run.transport.sent.filter { $0.target == p2Session }.count
            await run.sync()
            let sent = await run.transport.sent.filter { $0.target == p2Session }.count - before
            let label = "\(encodingName), tables \(config.tables), per-player tables \(config.perPlayerTables)"
            // The per-player tables send p2 its missed hand; today's path sends nothing.
            #expect(sent == (config.perPlayerTables ? 1 : 0), "\(label): frames to p2 on the write")
            let hand = await run.adapter.lastSentPerPlayerSnapshotForTesting(PlayerID("p2"))?.values["hands"]
            #expect(hand == .object(["p2": .array([.string("b"), .string("d")])]), "\(label): last-sent")
        }
    }

    @Test("A state without per-player fields: key resets after a failed plan and after a broadcast throw", arguments: ppScenarioCells)
    func noPerPlayerFields(cell: String) async throws {
        let (encoding, onePass) = try ppScenarioCell(cell)
        try await comparePPScenario(cell, definition: { makePPScenarioBroadcastLand(landID: "pp-scenario-broadcast") }, onePass: onePass, encoding: encoding) { run in
            try await run.join("p1")
            try await run.join("p2")
            await run.sync()
            try await run.step("p1", board: 1)
            await run.sync()
            // A key reset: with B2 (one-pass off) a `.firstSync([])` per-player frame per player;
            // with B1 none.
            try await run.step("p1", board: 2)
            run.faults.armPlan()
            await run.sync()
            await run.sync()
            // A broadcast conversion throws (B2 for this plan whatever the one-pass switch), then
            // a key reset.
            try await run.step("p2", risky: -1, board: 3)
            await run.sync()
            run.faults.armPlan()
            try await run.step("p2", board: 4)
            await run.sync()
            await run.sync()
            try await run.step("p2", risky: 1)
            await run.sync()
        }
    }

    /// #531: a player's later sessions get no per-player change. Two sessions of one player
    /// coexist only through a direct `registerSession`; the router supersedes the older one.
    /// Which of the two sessions is the player's first recipient follows the recipient order,
    /// which isn't the same across adapters, so the configurations are compared by count.
    @Test("A player's second session: one session gets the per-player patches, the other none (known bug, #531)", arguments: dirtyIdentityEncodings.map(\.0))
    func secondSessionPin(encodingName: String) async throws {
        let encoding = try #require(dirtyIdentityEncodings.first { $0.0 == encodingName }?.1)
        let second = SessionID("s-p1-second")
        for config in ppScenarioConfigs {
            let run = await PPScenarioRun<PPScenarioState>(
                definition: makePPScenarioLand(landID: "pp-scenario-sessions"), tables: config.tables,
                perPlayerTables: config.perPlayerTables, onePass: true, encoding: encoding
            )
            let label = "\(encodingName), tables \(config.tables), per-player tables \(config.perPlayerTables)"
            try await run.join("p1")
            try await run.join("p2")
            await run.adapter.onConnect(sessionID: second, clientID: ClientID("c-p1-second"))
            await run.adapter.registerSession(sessionID: second, clientID: ClientID("c-p1-second"), playerID: PlayerID("p1"), authInfo: nil)
            await run.settle()
            await run.sync()
            let before = await run.transport.sent.count
            // A per-player-only change of p1.
            try await run.step("p1", mark: 1)
            await run.sync()
            let after = await run.transport.sent.dropFirst(before)
            let toFirst = after.filter { $0.target == "session(s-p1)" }.count
            let toSecond = after.filter { $0.target == "session(\(second.rawValue))" }.count
            #expect(toFirst + toSecond == 1 && min(toFirst, toSecond) == 0, "\(label): #531, one session gets p1's change: \(toFirst), \(toSecond)")
            #expect(!after.contains { $0.target == "session(s-p2)" }, "\(label): p2 gets nothing")
        }
    }
}
