import Foundation
import SwiftStateTurns

/// A model of the transport's side of a session: its connections, each with a generation, the
/// player map, and the sessions it was asked to close. Slice 1 repeats these scenarios against
/// the real transport.
final class TransportModel: @unchecked Sendable {
    private let lock = NSLock()
    private let fixture: Fixture
    private var connected: [Int: Int] = [:]
    private var nextGeneration = 0
    private var playerSessions: [Int: Set<Int>] = [:]
    private var heldAfterRegister: Set<Int> = []
    private var closedSessions: [Int] = []

    init(fixture: Fixture) {
        self.fixture = fixture
    }

    /// The transport accepts a connection.
    func connect(_ session: Int) {
        lock.withLock {
            nextGeneration += 1
            connected[session] = nextGeneration
        }
    }

    /// The transport's own disconnect handling: the session goes, and so does its player
    /// mapping.
    func disconnect(_ session: Int) {
        lock.withLock {
            connected.removeValue(forKey: session)
            for player in Array(playerSessions.keys) {
                playerSessions[player]?.remove(session)
                if playerSessions[player]?.isEmpty == true { playerSessions.removeValue(forKey: player) }
            }
        }
    }

    /// Maps the player to the session and returns the connection's generation. A session the
    /// transport doesn't hold is refused: nothing is mapped.
    func register(session: Int, player: Int) -> Int? {
        lock.withLock {
            guard let generation = connected[session] else { return nil }
            playerSessions[player, default: []].insert(session)
            return generation
        }
    }

    func sessions(of player: Int) -> [Int] {
        lock.withLock { (playerSessions[player] ?? []).sorted() }
    }

    /// The registration's worker for `session` stops after the transport answered: it opens
    /// "transport answered <session>" and waits for "post <session>".
    func holdAfterRegister(_ session: Int) {
        lock.withLock { _ = heldAfterRegister.insert(session) }
    }

    func holdsAfterRegister(_ session: Int) -> Bool {
        lock.withLock { heldAfterRegister.contains(session) }
    }

    /// Records the close and opens "closed <session>".
    func close(_ session: Int) {
        lock.withLock { closedSessions.append(session) }
        fixture.open("closed \(session)")
    }

    var closed: [Int] {
        lock.withLock { closedSessions }
    }
}

/// A model of the keeper: the session it names for a player (what a registration reads), and
/// its players (player → the session of its entry), with no entry generation, destroy timer or
/// drain. Slice 1 repeats these scenarios against the real keeper.
final class KeeperModel: @unchecked Sendable {
    private let lock = NSLock()
    private var named: [Int: Int] = [:]
    private var entries: [Int: Int] = [:]
    private var stopped = false
    private var leaveCount = 0

    init() {}

    /// The session the keeper names for `player`.
    func setEntry(player: Int, session: Int) {
        lock.withLock { named[player] = session }
    }

    func entry(player: Int) -> Int? {
        lock.withLock { named[player] }
    }

    /// Ignored once the keeper has stopped (its join throws).
    func insert(player: Int, session: Int) {
        lock.withLock {
            if !stopped { entries[player] = session }
        }
    }

    /// The keeper's forced shutdown: the players still in it are cleared, without OnLeave.
    func stop() {
        lock.withLock {
            stopped = true
            entries.removeAll()
        }
    }

    /// The keeper's leave, counted.
    func leave(player: Int, session: Int) {
        lock.withLock {
            leaveCount += 1
            if entries[player] == session { entries.removeValue(forKey: player) }
        }
    }

    var leaveCalls: Int {
        lock.withLock { leaveCount }
    }

    /// Removes the player's entry only if it is still that session's (a join's rollback).
    func remove(player: Int, session: Int) {
        lock.withLock {
            if entries[player] == session { entries.removeValue(forKey: player) }
        }
    }

    var players: [Int: Int] {
        lock.withLock { entries }
    }
}

struct MembershipSnapshot: Sendable {
    var log: [String] = []
    var players: [Int: Int] = [:]
    var generations: [Int: Int] = [:]
    var flushed: [Int] = []
    var stats = TurnStats()
}

/// The actor that runs `MembershipModel`. Its effects reach the keeper and transport models,
/// and wait at the fixture's gates: an effect with a non-empty gate opens "at <gate>" when its
/// worker starts. The keeper's join worker calls back into this actor (`ask`) in the middle of
/// its run, as the keeper shares the adapter's executor.
actor MembershipActor: TurnActor {
    let core: TurnCore<MembershipModel>
    nonisolated let fixture: Fixture
    nonisolated let keeper: KeeperModel
    nonisolated let transport: TransportModel
    private var flushed: [Int] = []

    init(fixture: Fixture = Fixture(), parkedLimit: Int = 1024, segmentBudget: Int = 64) {
        let core = TurnCore(
            MembershipModel(),
            parkedLimit: parkedLimit,
            segmentBudget: segmentBudget,
            clock: TestClock(fixture: fixture)
        )
        core.onDiagnostic = { event in fixture.observe(event) }
        self.fixture = fixture
        self.keeper = KeeperModel()
        self.transport = TransportModel(fixture: fixture)
        self.core = core
    }

    @concurrent nonisolated func perform(_ effect: MembershipModel.Effect) async -> MembershipModel.Input? {
        switch effect {
        case .txnWork(let name, let gate):
            if !gate.isEmpty { fixture.open("at " + gate) }
            await fixture.wait(gate)
            return .txnFinished(name)
        case .keeperEntry(let session, let player, let gate):
            if !gate.isEmpty { fixture.open("at " + gate) }
            await fixture.wait(gate)
            return .keeperEntryRead(session: session, player: player, entry: keeper.entry(player: player))
        case .transportRegister(let session, let player, let gate):
            if !gate.isEmpty { fixture.open("at " + gate) }
            await fixture.wait(gate)
            let generation = transport.register(session: session, player: player)
            if transport.holdsAfterRegister(session) {
                fixture.open("transport answered \(session)")
                await fixture.wait("post \(session)")
            }
            return .transportRegistered(session: session, generation: generation)
        case .firstSync(let session, let gate):
            await fixture.wait(gate)
            return .firstSyncDone(session)
        case .keeperJoin(let session, let player, let gate, let shape):
            // The keeper's join as a worker: the gates are its awaits, and the segments
            // between them run on this actor.
            var joined = true
            var admitted = false
            switch shape {
            case .admitAtInsert:
                if !gate.isEmpty { fixture.open("at " + gate) }
                await fixture.wait(gate)
                admitted = await keeperAdmitThenInsert(session: session, player: player)
                joined = admitted
            case .insertThenAdmit:
                keeper.insert(player: player, session: session)
                if !gate.isEmpty { fixture.open("at " + gate) }
                await fixture.wait(gate)
                admitted = await keeperAdmitOrRollBack(session: session, player: player)
                joined = admitted
            case .callerAdmits:
                if !gate.isEmpty { fixture.open("at " + gate) }
                await fixture.wait(gate)
                keeper.insert(player: player, session: session)
            }
            if admitted, !gate.isEmpty {
                // The rest of the keeper's join (its OnJoin turn).
                fixture.open("admitted " + gate)
                await fixture.wait("after " + gate)
            }
            return .keeperJoined(session: session, player: player, joined: joined, admitted: admitted)
        case .keeperLeave(let session, let player):
            keeper.leave(player: player, session: session)
            return .keeperLeft(session: session, player: player)
        case .close(let session):
            transport.close(session)
            return nil
        }
    }

    func flush(_ outputs: consuming [Int]) {
        let batch: [Int] = outputs
        flushed.append(contentsOf: batch)
    }

    func snapshot() -> MembershipSnapshot {
        var snapshot = core.read { machine in
            MembershipSnapshot(log: machine.log, players: machine.sessionToPlayer, generations: machine.connectionGenerations)
        }
        snapshot.flushed = flushed
        snapshot.stats = core.stats
        return snapshot
    }

    /// Returns once the machine's log has `count` lines (a control call).
    func waitForLog(_ count: Int) async {
        _ = try? await call(.awaitLog(count), cancellation: .ignored)
    }

    /// The keeper's segment at its insert when the join has no OnJoin input: it asks the
    /// adapter first and inserts only an admitted player.
    func keeperAdmitThenInsert(session: Int, player: Int) -> Bool {
        guard ask(.admit(session: session, player: player)) == 1 else { return false }
        keeper.insert(player: player, session: session)
        return true
    }

    /// The keeper's segment after its resolvers: the player went in before them, and a
    /// refused admission takes it out again, if it is still this join's entry.
    func keeperAdmitOrRollBack(session: Int, player: Int) -> Bool {
        if ask(.admit(session: session, player: player)) == 1 { return true }
        keeper.remove(player: player, session: session)
        return false
    }
}
