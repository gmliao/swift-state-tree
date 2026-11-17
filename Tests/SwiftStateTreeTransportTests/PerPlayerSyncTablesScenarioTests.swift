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
    /// NaN converts but JSON can't encode it: the player's update is re-encoded without it.
    @Sync(.perPlayer({ (v: Double, _: PlayerID) in v })) var speed: Double = 0
    /// Each player sees its own entries: a negative one throws for that player only (T1).
    @Sync(.perPlayer({ (v: [String: PPScenarioRisky], player: PlayerID) in v.filter { $0.key.hasPrefix(player.rawValue) } }))
    var secrets: [String: PPScenarioRisky] = [:]
    /// A second root of the same kind, for two failing roots of one player.
    @Sync(.perPlayer({ (v: [String: PPScenarioRisky], player: PlayerID) in v.filter { $0.key.hasPrefix(player.rawValue) } }))
    var vault: [String: PPScenarioRisky] = [:]
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
    let speed: Int
    let secret: Int
    let vault: Int
}

extension PPScenarioStep {
    static let none = Int.min
    /// As `speed`: sets NaN.
    static let nan = Int.max
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
                if step.speed != PPScenarioStep.none { state.speed = step.speed == PPScenarioStep.nan ? .nan : Double(step.speed) }
                if step.secret != PPScenarioStep.none { state.secrets["\(ctx.playerID.rawValue).s"] = PPScenarioRisky(n: step.secret) }
                if step.vault != PPScenarioStep.none { state.vault["\(ctx.playerID.rawValue).v"] = PPScenarioRisky(n: step.vault) }
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
    /// The sync-lag clock, moved by hand (with the sync sequence on).
    let clock = SyncLagManualClock()
    /// Holds each failed plan's delayed follow-up cycle (`startDelayedFollowUpSync`), so the
    /// frames follow from the script's own syncs, not from whether a 100 ms timer fired first
    /// in one configuration and not in another. Opened when the script is done (`finish`).
    let followUps = TestGate()

    init(
        definition: LandDefinition<State>,
        tables: Bool,
        perPlayerTables: Bool,
        onePass: Bool,
        dirtyTracking: Bool = true,
        encoding: TransportEncodingConfig
    ) async {
        var config = TransportEnvConfig(enableDirtyTracking: dirtyTracking, useSnapshotForSync: onePass, syncStrategy: .delta, profilingConfig: nil)
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
        let clock = self.clock
        await adapter.setSyncLagClockForTesting { clock.now }
        await adapter.setSyncLagTimerIntervalForTesting(.seconds(3600))
        let followUps = self.followUps
        await adapter.installHolds(HoldRegistry.at(.failedPlanFollowUp) { await followUps.arrive() })
    }

    /// Lets the held follow-up cycles run once the frames are read.
    func finish() { followUps.open() }

    /// The sequence of the last state frame `name`'s session got (opcode JSON array frames).
    func lastSeq(_ name: String) async throws -> UInt64 {
        let frames = await transport.sent.filter { $0.target == "session(s-\(name))" }
        for frame in frames.reversed() {
            guard let array = try JSONSerialization.jsonObject(with: frame.data) as? [Any],
                  let op = array.first as? Int, (1...3).contains(op), array.count > 1,
                  let seq = SyncAckFrame.syncSequence(array[1]) else { continue }
            return seq
        }
        throw PPScenarioPlanFault()
    }

    func ack(_ name: String, _ seq: UInt64) async {
        await adapter.onMessage(SyncAckFrame.encode(seq: seq, binary: false), from: SessionID("s-\(name)"))
    }

    /// Joins `name` on session `s-<name><suffix>`: a second join of a player supersedes its session.
    func join(_ name: String, suffix: String = "") async throws {
        let session = SessionID("s-\(name)\(suffix)"), client = ClientID("c-\(name)\(suffix)")
        await adapter.onConnect(sessionID: session, clientID: client)
        _ = try await adapter.performJoin(playerSession: PlayerSession(playerID: name), clientID: client, sessionID: session, authInfo: nil)
        await adapter.syncStateForNewPlayer(playerID: PlayerID(name), sessionID: session)
        await awaitIdle()
    }

    func leave(_ name: String, suffix: String = "") async {
        await adapter.onDisconnect(sessionID: SessionID("s-\(name)\(suffix)"), clientID: ClientID("c-\(name)\(suffix)"))
        await awaitIdle()
    }

    func step(
        _ name: String, suffix: String = "", hand: String = "", clearHand: Bool = false,
        mark: Int = PPScenarioStep.none, risky: Int = PPScenarioStep.none, board: Int = PPScenarioStep.none,
        speed: Int = PPScenarioStep.none, secret: Int = PPScenarioStep.none, vault: Int = PPScenarioStep.none
    ) async throws {
        try await keeper.handleClientEvent(
            AnyClientEvent(PPScenarioStep(
                hand: hand, clearHand: clearHand, mark: mark, risky: risky, board: board, speed: speed, secret: secret, vault: vault
            )),
            playerID: PlayerID(name), clientID: ClientID("c-\(name)\(suffix)"), sessionID: SessionID("s-\(name)\(suffix)")
        )
        await awaitIdle()
    }

    /// Waits on events only: the keeper's in-flight work, then the writer handing every queued
    /// frame to the transport. Background sync work is held (`followUps`).
    func awaitIdle() async {
        await keeper.waitForInFlightWorkForTesting()
        await adapter.waitForOutboundIdleForTesting()
    }

    func sync() async {
        await adapter.syncNow()
        await adapter.waitForOutboundIdleForTesting()
    }

    func syncBroadcastOnly() async {
        await adapter.syncBroadcastOnly()
        await adapter.waitForOutboundIdleForTesting()
    }
}

/// Runs `script` in the three configurations and compares each recipient's frames with neither
/// table's.
private func comparePPScenario<State: StateNodeProtocol>(
    _ label: String,
    definition: @escaping () -> LandDefinition<State>,
    onePass: Bool,
    dirtyTracking: Bool = true,
    encoding: TransportEncodingConfig,
    sourceLocation: SourceLocation = #_sourceLocation,
    script: (PPScenarioRun<State>) async throws -> Void
) async throws {
    var frames: [[(target: String, data: Data)]] = []
    for config in ppScenarioConfigs {
        let run = await PPScenarioRun<State>(
            definition: definition(), tables: config.tables, perPlayerTables: config.perPlayerTables,
            onePass: onePass, dirtyTracking: dirtyTracking, encoding: encoding
        )
        #expect(await run.adapter.usesSyncTablesForTesting() == config.tables, sourceLocation: sourceLocation)
        #expect(await run.adapter.usesPerPlayerTablesForTesting() == config.perPlayerTables, sourceLocation: sourceLocation)
        // Held follow-ups resume even when the script throws.
        defer { run.finish() }
        try await script(run)
        frames.append(await run.transport.sent)
    }
    #expect(frames[2].count > 10, "\(label): the script sends frames", sourceLocation: sourceLocation)
    expectSameFrames(frames[0], frames[2], "\(label), both tables", sourceLocation: sourceLocation)
    expectSameFrames(frames[1], frames[2], "\(label), broadcast tables alone", sourceLocation: sourceLocation)
}

/// Encoding × one-pass × dirty tracking. Without dirty tracking every plan's mode is `.all`.
private let ppScenarioCells: [String] = dirtyIdentityEncodings.flatMap { encoding in
    [true, false].flatMap { onePass in [true, false].map { dirty in "\(encoding.0)|\(onePass)|dirty-\(dirty)" } }
}

private func ppScenarioCell(_ cell: String) throws -> (encoding: TransportEncodingConfig, onePass: Bool, dirtyTracking: Bool) {
    let parts = cell.split(separator: "|").map(String.init)
    return (try #require(dirtyIdentityEncodings.first { $0.0 == parts[0] }?.1), parts[1] == "true", parts[2] == "dirty-true")
}

// MARK: - Tests

@Suite("The per-player tables send today's frames through failures and membership changes (#514)", .timeLimit(.minutes(1)))
struct PerPlayerSyncTablesScenarioTests {
    @Test("Failed plans, encode failures, broadcast-only syncs, throws, leaves and supersedes", arguments: ppScenarioCells)
    func failuresAndMembership(cell: String) async throws {
        let (encoding, onePass, dirtyTracking) = try ppScenarioCell(cell)
        try await comparePPScenario(cell, definition: { makePPScenarioLand(landID: "pp-scenario") }, onePass: onePass, dirtyTracking: dirtyTracking, encoding: encoding) { run in
            try await run.join("p1")
            try await run.join("p2")
            await run.sync()
            try await run.step("p1", hand: "a", mark: 1)
            try await run.step("p2", hand: "b", board: 1)
            await run.sync()

            // A failed plan, a frame that doesn't encode at all and a failed merged broadcast
            // frame end the land (#535 rows 9, 10, 12, 15): `totalFailureEndsTheLand` covers them.
            try await run.step("p1", hand: "c", mark: 2)
            await run.sync()
            try await run.step("p2", mark: 3)
            await run.sync()

            // Broadcast-only syncs: per-player changes wait for the next full sync.
            try await run.step("p1", hand: "f", board: 4)
            await run.syncBroadcastOnly()
            try await run.step("p2", board: 5)
            await run.syncBroadcastOnly()
            await run.sync()

            // A per-player conversion throws (for every player), a player joins right after,
            // then it converts. With one-pass on, today falls back to the separate extraction
            // for every player (T1) and the typed diff stays per pair; their frames agree here
            // because every recipient already has boxes (see `oneTimeThrowOnePass`).
            try await run.step("p1", mark: 7, risky: -1)
            await run.sync()
            try await run.join("p3")
            try await run.step("p3", hand: "g")
            await run.sync()
            try await run.step("p1", risky: 2)
            await run.sync()

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
            #expect(await run.adapter.syncFailedPlans == 0, "\(cell): no plan failed")
        }
    }

    /// T1 and the failure scenarios with a per-player throw for one player, one-pass on and off
    /// (interim, #535; D5's expected outputs). The throwing pair sends none of its field, its
    /// box keeps what its client has, and one drop is counted per failing (player, root) that the
    /// cycle converts; the other players and the player's other fields flow. Two failing roots
    /// count two. A key reset while the throw lasts keeps the boxes. With one-pass on, today's
    /// all-or-nothing fallback to the separate extraction (T1) changes only how a player
    /// without boxes is seeded, and a recipient always has boxes here: a player's firstSync
    /// commits its seed with its firstSync mark, and a clear removes both. So the frames are
    /// also today's, and are compared with them.
    @Test("A per-player throw for one player: its field is dropped, its box kept, the rest flows (T1)", arguments: ppScenarioCells)
    func oneTimeThrowOnePass(cell: String) async throws {
        let (encoding, onePass, dirtyTracking) = try ppScenarioCell(cell)
        let textual = !cell.hasPrefix("messagepack")
        try await comparePPScenario(cell, definition: { makePPScenarioLand(landID: "pp-scenario-t1") }, onePass: onePass, dirtyTracking: dirtyTracking, encoding: encoding) { run in
            /// Runs a sync; returns the drops it counted and the frames each player got.
            func cycle(_ body: () async throws -> Void = {}) async throws -> (drops: Int, frames: [String: [String]]) {
                let before = await run.adapter.syncDroppedUpdates
                let sentBefore = await run.transport.sent.count
                try await body()
                await run.sync()
                let sent = await run.transport.sent.dropFirst(sentBefore)
                var frames: [String: [String]] = [:]
                for frame in sent { frames[frame.target, default: []].append(String(decoding: frame.data, as: UTF8.self)) }
                return (await run.adapter.syncDroppedUpdates - before, frames)
            }
            func lastSent(_ name: String, _ field: String) async -> SnapshotValue? {
                await run.adapter.lastSentPerPlayerSnapshotForTesting(PlayerID(name))?.values[field]
            }
            func mentions(_ frames: [String]?, _ field: String) -> Bool {
                (frames ?? []).contains { $0.contains("\\/\(field)") || $0.contains("\"\(field)\"") }
            }
            let p1 = "session(s-p1)", p2 = "session(s-p2)"
            try await run.join("p1")
            try await run.join("p2")
            try await run.join("p3")
            try await run.step("p1", secret: 1, vault: 1)
            try await run.step("p2", secret: 1)
            await run.sync()
            let committed = await lastSent("p1", "secrets")
            #expect(committed == .object(["p1.s": .object(["n": .int(1)])]))

            // p1's entry throws for p1 only, while p1's hand and p2's own entry change.
            let one = try await cycle {
                try await run.step("p1", hand: "a", secret: -1)
                try await run.step("p2", secret: 2)
            }
            #expect(one.drops == 1, "one failing (player, root)")
            #expect(await lastSent("p1", "secrets") == committed, "p1's box keeps what its client has")
            #expect(await lastSent("p2", "secrets") == .object(["p2.s": .object(["n": .int(2)])]))
            if textual {
                #expect(mentions(one.frames[p1], "hands") && !mentions(one.frames[p1], "secrets"))
                #expect(mentions(one.frames[p2], "secrets"))
            }

            // Two failing roots for p1; p3's hand flows.
            let two = try await cycle {
                try await run.step("p1", secret: -2, vault: -1)
                try await run.step("p3", hand: "b")
            }
            #expect(two.drops == 2, "two failing roots")
            #expect(await lastSent("p1", "vault") == .object(["p1.v": .object(["n": .int(1)])]))

            // A cycle while both still throw: the boxes stay. (A failed plan's key reset is gone:
            // a failed plan ends the land, #535 row 19.)
            let still = try await cycle { try await run.step("p2", board: 1) }
            #expect(still.drops == (onePass && dirtyTracking ? 0 : 2), "the throwing roots are converted only under `.all`")
            #expect(await lastSent("p1", "secrets") == committed)
            if textual {
                #expect(!mentions(still.frames[p1], "secrets") && !mentions(still.frames[p1], "vault"))
            }

            // Both convert again: the missed values go out.
            let back = try await cycle { try await run.step("p1", secret: 3, vault: 4) }
            #expect(back.drops == 0)
            #expect(await lastSent("p1", "secrets") == .object(["p1.s": .object(["n": .int(3)])]))
            if textual {
                #expect(mentions(back.frames[p1], "secrets") && mentions(back.frames[p1], "vault"))
            }
        }
    }

    /// A per-player update that fails to encode is re-encoded without the patches that can't be
    /// (NaN in JSON): what was sent commits, so the boxes advance as today's cache does and the
    /// next plan doesn't send the kept patches again.
    @Test("A per-player update re-encoded without an unencodable patch commits the rest", arguments: [true, false])
    func droppingReencode(onePass: Bool) async throws {
        let encoding = TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray)
        try await comparePPScenario("dropping re-encode, one-pass \(onePass)", definition: { makePPScenarioLand(landID: "pp-scenario-nan") }, onePass: onePass, encoding: encoding) { run in
            try await run.join("p1")
            try await run.join("p2")
            await run.sync()
            for round in 0..<3 {
                try await run.step("p1", hand: "h\(round)", mark: round, board: round)
                await run.sync()
            }
            // One plan: p1's hand and mark change with its speed set to NaN.
            try await run.step("p1", hand: "n", mark: 4, speed: PPScenarioStep.nan)
            await run.sync()
            #expect(await run.adapter.syncDroppedUpdates > 0, "the NaN patch was dropped")
            try await run.step("p1", board: 7)
            await run.sync()
            try await run.step("p2", mark: 5)
            await run.sync()
            try await run.step("p1", speed: 3)
            await run.sync()
            try await run.step("p1", hand: "m", board: 8)
            await run.sync()
        }
    }

    /// A lagging reader is resynced in place (#332): its full view re-seeds its per-player boxes
    /// from the plan's state, so its per-player changes made in the resync plan aren't sent again.
    @Test("A resync re-seeds the reader's per-player boxes", arguments: [true, false])
    func resync(onePass: Bool) async throws {
        let encoding = TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray, syncSequence: true)
        try await comparePPScenario("resync, one-pass \(onePass)", definition: { makePPScenarioLand(landID: "pp-scenario-resync") }, onePass: onePass, encoding: encoding) { run in
            try await run.join("p1")
            try await run.join("p2")
            await run.sync()
            let stale = try await run.lastSeq("p2")
            await run.ack("p2", stale)
            // p2 keeps acking its first view while p1 keeps up: past 3 s p2 is resynced.
            for round in 0..<3 {
                try await run.step("p2", hand: "x\(round)", mark: round)
                try await run.step("p1", mark: round, board: round)
                await run.sync()
                await run.ack("p1", try await run.lastSeq("p1"))
                run.clock.advance(1.5)
                await run.ack("p2", stale)
            }
            run.clock.advance(0.6)
            await run.ack("p2", stale)
            // The resync plan: p2's own per-player fields change in it too.
            try await run.step("p2", hand: "y", mark: 7)
            await run.sync()
            #expect(await run.adapter.syncLagResyncs == 1, "p2 was resynced")
            await run.ack("p2", try await run.lastSeq("p2"))
            await run.ack("p1", try await run.lastSeq("p1"))
            try await run.step("p1", board: 9)
            await run.sync()
            try await run.step("p2", mark: 8)
            await run.sync()
        }
    }

    /// A frame that doesn't encode at all ends the land in every configuration (#535 rows 9, 10
    /// total, 12, 15), so no later frame can lag behind it (#532 is gone with the land): a failed
    /// plan, one player's frames, and the opcode 107 merged broadcast frame.
    @Test("A total failure ends the land in every configuration (#535)", arguments: dirtyIdentityEncodings.map(\.0))
    func totalFailureEndsTheLand(encodingName: String) async throws {
        let encoding = try #require(dirtyIdentityEncodings.first { $0.0 == encodingName }?.1)
        enum Fault: CaseIterable { case plan, player, mergedFrame }
        for fault in Fault.allCases {
            for onePass in [true, false] {
                for config in ppScenarioConfigs {
                    let run = await PPScenarioRun<PPScenarioState>(
                        definition: makePPScenarioLand(landID: "pp-scenario-total"), tables: config.tables,
                        perPlayerTables: config.perPlayerTables, onePass: onePass, encoding: encoding
                    )
                    let label = "\(encodingName), \(fault), one-pass \(onePass), tables \(config.tables), per-player tables \(config.perPlayerTables)"
                    try await run.join("p1")
                    try await run.join("p2")
                    await run.sync()
                    try await run.step("p2", hand: "d", board: 1)
                    switch fault {
                    case .plan: run.faults.armPlan()
                    case .player: run.faults.setPlayer(PlayerID("p2"))
                    case .mergedFrame: run.faults.setMergedFrame(true)
                    }
                    // The merged broadcast frame exists with opcode 107 (messagepack) only.
                    guard fault != .mergedFrame || encodingName == "messagepack" else {
                        run.faults.setMergedFrame(false)
                        run.finish()
                        continue
                    }
                    let before = await run.transport.sent.count
                    await run.sync()
                    try #require(await run.keeper.waitForFailureForTesting(), "the land failed")
                    #expect(run.keeper.failure?.position.stage == .syncPhase, "\(label): the land failed in the sync phase")
                    #expect(await run.transport.sent.count == before, "\(label): the failing cycle sent nothing")
                    run.finish()
                }
            }
        }
    }

    @Test("A state without per-player fields: a broadcast throw and the cycles after it", arguments: ppScenarioCells)
    func noPerPlayerFields(cell: String) async throws {
        let (encoding, onePass, dirtyTracking) = try ppScenarioCell(cell)
        try await comparePPScenario(cell, definition: { makePPScenarioBroadcastLand(landID: "pp-scenario-broadcast") }, onePass: onePass, dirtyTracking: dirtyTracking, encoding: encoding) { run in
            try await run.join("p1")
            try await run.join("p2")
            await run.sync()
            try await run.step("p1", board: 1)
            await run.sync()
            // A broadcast conversion throws (B2 for this plan whatever the one-pass switch). A
            // failed plan's key reset is gone: a failed plan ends the land (#535 row 19).
            try await run.step("p2", risky: -1, board: 3)
            await run.sync()
            try await run.step("p2", board: 4)
            await run.sync()
            try await run.step("p1", board: 5)
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
            await run.awaitIdle()
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
            run.finish()
        }
    }
}
