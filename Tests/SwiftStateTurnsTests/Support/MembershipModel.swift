import SwiftStateTurns

/// Where the keeper's join admits the session, as its worker sees it.
enum JoinShape: Sendable {
    /// The keeper asks the adapter in the segment of its insert (no OnJoin input).
    case admitAtInsert
    /// The keeper inserts, awaits (its resolvers), then asks in the segment of its append.
    case insertThenAdmit
    /// The keeper doesn't ask (in-turn sync off): the join's caller admits when it returns.
    case callerAdmits
}

/// A model of the transport adapter's membership path on the turn core: connection, member and
/// land keys, registrations that read the keeper and register with the transport while holding
/// `.membership`, library joins whose keeper worker calls back into the machine, and
/// disconnects that leave the keeper. It is a model, not the adapter: it keeps only what the
/// scenarios need. Slice 1 repeats each scenario against the real adapter and keeper.
struct MembershipModel: TurnMachine {
    enum Input: Sendable {
        /// Other membership work in flight: holds `.membership` until its gate opens.
        case txn(Int, gate: String)
        case txnFinished(Int)
        case register(session: Int, player: Int, gate: String, token: EndToken?, generation: Int? = nil)
        case keeperEntryRead(session: Int, player: Int, entry: Int?)
        case transportRegistered(session: Int, generation: Int?)
        /// A control input: nothing refuses it. As a call it is answered when the session's
        /// keeper leave has run: 1; none was due: 0; the core ended first and the leave was
        /// dropped: 2.
        case disconnect(Int)
        /// The keeper's join as one request.
        case libraryJoin(session: Int, player: Int, gate: String, shape: JoinShape, token: EndToken?)
        case keeperJoined(session: Int, player: Int, joined: Bool, admitted: Bool)
        /// Queued behind `.membership` by a disconnect.
        case leave(session: Int, player: Int)
        case keeperLeft(session: Int, player: Int)
        case startFirstSync(Int, gate: String)
        case firstSyncDone(Int)
        case shutdown
        case teardown
        case awaitLog(Int)
    }

    enum Effect: Sendable {
        case txnWork(Int, gate: String)
        case keeperEntry(session: Int, player: Int, gate: String)
        case firstSync(Int, gate: String)
        case transportRegister(session: Int, player: Int, gate: String)
        case keeperJoin(session: Int, player: Int, gate: String, shape: JoinShape)
        case keeperLeave(session: Int, player: Int)
        case close(session: Int)
    }

    enum Key: Hashable, Sendable {
        case txn(Int)
        case membership
        case connection(Int)
        case member(Int)
        /// Lives with the adapter: cleanup that outlives a session.
        case land
    }

    enum Query: Sendable {
        /// The keeper's admission of a joining session, asked inside its join.
        case admit(session: Int, player: Int)
        /// The router's join budget ran out. 1: the join hadn't started and is ended. 0: it
        /// started, and is left alone.
        case endJoinBeforeAdmission(session: Int, token: EndToken)
    }

    typealias Output = Int
    typealias Reply = Int
    typealias Answer = Int

    struct Registration: Sendable {
        var session: Int
        var player: Int
        var caller: InputID?
        var gate: String
        var generation: Int? = nil
    }

    struct CountWaiter: Sendable {
        var count: Int
        var caller: InputID
    }

    /// The holding deadline of every request here: the scenarios never let one pass.
    static let unbounded: Duration = .seconds(3600)

    var log: [String] = []
    var logWaiters: [CountWaiter] = []
    var txnCaller: [Int: InputID] = [:]
    var txnRequest: [RequestID: Int] = [:]
    var sessionToPlayer: [Int: Int] = [:]
    var connectionGenerations: [Int: Int] = [:]
    var registrations: [RequestID: Registration] = [:]
    var firstSyncs: [RequestID: Int] = [:]
    var joins: [RequestID: Registration] = [:]
    var leaves: [RequestID: Int] = [:]
    /// Sessions whose keeper player came from a library join (the ones a disconnect leaves).
    var libraryMembers: Set<Int> = []
    /// Sessions whose keeper leave is still due, with the disconnect callers waiting for it.
    var leaveWaiters: [Int: [InputID]] = [:]

    init() {}

    func admission(of input: Input) -> Admission<Key> {
        switch input {
        case .txn:
            return .external(hold: .membership, scope: nil)
        case .register(let session, _, _, let token, _):
            return .external(hold: .membership, scope: .connection(session), unless: token)
        case .libraryJoin(let session, _, _, _, let token):
            return .external(hold: .membership, scope: .connection(session), unless: token)
        default:
            return .control
        }
    }

    mutating func note(_ line: String) {
        log.append(line)
    }

    mutating func ensureLand(_ turn: inout Turn<MembershipModel>) {
        if !turn.isLive(.land) { turn.issue(.land) }
    }

    /// The admission of a library join's session: membership and its member key, in one step.
    mutating func admitMember(session: Int, player: Int, _ turn: inout Turn<MembershipModel>) {
        turn.issue(.member(session))
        sessionToPlayer[session] = player
        libraryMembers.insert(session)
        note("admitted \(session) as \(player)")
    }

    /// The keeper's leave for a session that is gone. Under the land's key, so the ended
    /// session can't abandon it; it holds `.membership` until its worker has returned.
    /// False: no request was made (the core has ended).
    @discardableResult
    mutating func requestLeave(session: Int, player: Int, _ turn: inout Turn<MembershipModel>) -> Bool {
        ensureLand(&turn)
        guard let request = turn.request(
            .keeperLeave(session: session, player: player),
            for: .land,
            holding: .untilWorkerRetires(.membership, deadline: Self.unbounded)
        ) else { return false }
        leaves[request] = session
        note("leave \(session) requested")
        return true
    }

    /// Answers the disconnect callers waiting for `session`'s leave.
    mutating func answerLeave(_ session: Int, _ value: Int, _ turn: inout Turn<MembershipModel>) {
        for caller in leaveWaiters.removeValue(forKey: session) ?? [] {
            turn.reply(to: caller, .success(value))
        }
    }

    mutating func settleLogWaiters(_ turn: inout Turn<MembershipModel>) {
        if logWaiters.isEmpty { return }
        let count = log.count
        for waiter in logWaiters where waiter.count <= count {
            turn.reply(to: waiter.caller, .success(count))
        }
        logWaiters.removeAll { $0.count <= count }
    }

    mutating func handle(_ input: Input, _ turn: inout Turn<MembershipModel>) {
        apply(input, &turn)
        settleLogWaiters(&turn)
    }

    mutating func apply(_ input: Input, _ turn: inout Turn<MembershipModel>) {
        switch input {
        case .txn(let name, let gate):
            note("begin \(name)")
            if let caller = turn.input { txnCaller[name] = caller }
            turn.issue(.txn(name))
            if let request = turn.request(
                .txnWork(name, gate: gate),
                for: .txn(name),
                holding: .untilRequestCloses(.membership, deadline: Self.unbounded)
            ) {
                txnRequest[request] = name
            }
        case .txnFinished(let name):
            note("end \(name)")
            txnRequest = txnRequest.filter { $0.value != name }
            turn.end(.txn(name))
            if let caller = txnCaller.removeValue(forKey: name) { turn.reply(to: caller, .success(name)) }

        case .register(let session, let player, let gate, _, let generation):
            note("register \(session)")
            // The first registration of a session issues its connection key. One that was
            // parked when the session disconnected never gets here: the disconnect's `end`
            // withdrew it.
            if !turn.isLive(.connection(session)) { turn.issue(.connection(session)) }
            if let request = turn.request(
                .keeperEntry(session: session, player: player, gate: gate),
                for: .connection(session),
                holding: .untilRequestCloses(.membership, deadline: Self.unbounded)
            ) {
                registrations[request] = Registration(
                    session: session, player: player, caller: turn.input, gate: gate, generation: generation
                )
            }
        case .keeperEntryRead(let session, let player, let entry):
            guard let request = registrations.first(where: { $0.value.session == session })?.key,
                  let registration = registrations.removeValue(forKey: request) else { return }
            if let entry, entry != session {
                // The keeper names a newer session of the player: refused, and the connection
                // is closed. Other parked registrations of this connection are withdrawn. The
                // session's membership, if it has one, ends when its disconnect arrives.
                note("refuse \(session)")
                turn.end(.connection(session))
                turn.run(.close(session: session))
                if let caller = registration.caller { turn.reply(to: caller, .failure(DemoError.refused)) }
            } else {
                // The member key moves only when the binding changes, and it moves now, when
                // the decision is applied.
                if sessionToPlayer[session] != player {
                    turn.issue(.member(session))
                    note("member \(session) issued")
                }
                sessionToPlayer[session] = player
                note("registered \(session) as \(player)")
                // Every accepted registration registers with the transport. The new request
                // takes over the hold in the step that closed the read's.
                if let next = turn.request(
                    .transportRegister(
                        session: session, player: player,
                        gate: registration.gate.isEmpty ? "" : "t" + registration.gate
                    ),
                    for: .connection(session),
                    holding: .untilRequestCloses(.membership, deadline: Self.unbounded)
                ) {
                    registrations[next] = registration
                }
            }
        case .transportRegistered(let session, let generation):
            guard let request = registrations.first(where: { $0.value.session == session })?.key,
                  let registration = registrations.removeValue(forKey: request) else { return }
            // The generation passed in, else the one the transport returned.
            if let accepted = registration.generation ?? generation {
                connectionGenerations[session] = accepted
                note("transport \(session) generation \(accepted)")
            } else {
                // The transport has no live queue for the session. Nothing ends here: the
                // registration stands, without a generation, until the disconnect arrives.
                note("transport \(session) not connected")
            }
            if let caller = registration.caller { turn.reply(to: caller, .success(session)) }
        case .disconnect(let session):
            note("disconnect \(session)")
            let joining = joins.values.contains { $0.session == session }
            turn.end(.connection(session))
            turn.end(.member(session))
            let player = sessionToPlayer.removeValue(forKey: session)
            connectionGenerations.removeValue(forKey: session)
            let wasMember = libraryMembers.remove(session) != nil
            // A leave is still due if the session's keeper join is running (what the keeper
            // has to undo is known when that worker returns, in `handleStale`), or if an
            // earlier disconnect of this session is still waiting for one.
            var leaveDue = joining || leaveWaiters[session] != nil
            if !joining, wasMember, let player {
                // The keeper's leave keeps its place behind the membership work in flight.
                leaveDue = turn.queue(.leave(session: session, player: player), behind: .membership)
            }
            if leaveDue {
                leaveWaiters[session, default: []].append(contentsOf: turn.input.map { [$0] } ?? [])
            } else if let caller = turn.input {
                turn.reply(to: caller, .success(wasMember ? 2 : 0))
            }

        case .libraryJoin(let session, let player, let gate, let shape, _):
            note("join \(session)")
            if !turn.isLive(.connection(session)) { turn.issue(.connection(session)) }
            // Nothing else of the membership path runs in the keeper until this worker returns.
            if let request = turn.request(
                .keeperJoin(session: session, player: player, gate: gate, shape: shape),
                for: .connection(session),
                holding: .untilWorkerRetires(.membership, deadline: Self.unbounded)
            ) {
                joins[request] = Registration(session: session, player: player, caller: turn.input, gate: gate)
            }
        case .keeperJoined(let session, let player, let joined, let admitted):
            guard let request = joins.first(where: { $0.value.session == session })?.key,
                  let join = joins.removeValue(forKey: request) else { return }
            if joined {
                // The keeper didn't ask: admitted here, in the completion's step, which runs
                // only while the connection's key is live.
                if !admitted { admitMember(session: session, player: player, &turn) }
                note("joined \(session)")
                if let caller = join.caller { turn.reply(to: caller, .success(session)) }
            } else {
                note("join \(session) refused")
                if let caller = join.caller { turn.reply(to: caller, .failure(DemoError.refused)) }
            }
        case .leave(let session, let player):
            if !requestLeave(session: session, player: player, &turn) { answerLeave(session, 2, &turn) }
        case .keeperLeft(let session, _):
            leaves = leaves.filter { $0.value != session }
            note("left \(session)")
            answerLeave(session, 1, &turn)
        case .startFirstSync(let session, let gate):
            if let request = turn.request(.firstSync(session, gate: gate), for: .member(session)) {
                firstSyncs[request] = session
            } else {
                note("no member \(session)")
            }
        case .firstSyncDone(let session):
            firstSyncs = firstSyncs.filter { $0.value != session }
            note("first sync \(session) done")

        case .shutdown:
            note("shutdown")
            turn.close()
        case .teardown:
            note("teardown")
            turn.endAll()
            // The queued leaves are dropped: every disconnect caller still waiting for one is
            // answered here, in the ending step.
            for session in leaveWaiters.keys.sorted() { answerLeave(session, 2, &turn) }
        case .awaitLog(let count):
            if let caller = turn.input { logWaiters.append(CountWaiter(count: count, caller: caller)) }
        }
    }

    mutating func handleAbandoned(_ request: RequestID, _ why: Abandonment, _ turn: inout Turn<MembershipModel>) {
        if let name = txnRequest.removeValue(forKey: request) {
            note("abandoned \(name) \(why)")
            if let caller = txnCaller.removeValue(forKey: name) { turn.reply(to: caller, .failure(DemoError.abandoned)) }
        } else if let registration = registrations.removeValue(forKey: request) {
            note("registration \(registration.session) abandoned \(why)")
            if let caller = registration.caller { turn.reply(to: caller, .failure(DemoError.abandoned)) }
        } else if let session = firstSyncs.removeValue(forKey: request) {
            note("first sync \(session) abandoned \(why)")
        } else if let join = joins.removeValue(forKey: request) {
            note("join \(join.session) abandoned \(why)")
            if let caller = join.caller { turn.reply(to: caller, .failure(DemoError.abandoned)) }
        } else if let session = leaves.removeValue(forKey: request) {
            note("leave \(session) abandoned \(why)")
        }
        settleLogWaiters(&turn)
    }

    mutating func handleStale(_ input: Input, _ turn: inout Turn<MembershipModel>) {
        switch input {
        case .txnFinished(let name): note("stale \(name)")
        case .keeperEntryRead(let session, _, _): note("stale read \(session)")
        case .transportRegistered(let session, _): note("stale transport \(session)")
        case .firstSyncDone(let session): note("stale first sync \(session)")
        case .keeperJoined(let session, let player, let joined, _):
            // The join's worker has returned after its request closed. If the keeper has the
            // player and this machine doesn't have the member, the keeper's player is undone.
            note("stale join \(session)")
            var leaveRequested = false
            if joined, sessionToPlayer[session] != player {
                leaveRequested = requestLeave(session: session, player: player, &turn)
            }
            // Nothing to undo (or the core has ended): a disconnect waiting on this join is
            // answered now.
            if !leaveRequested { answerLeave(session, 0, &turn) }
        case .keeperLeft(let session, _): note("stale left \(session)")
        default: break
        }
        settleLogWaiters(&turn)
    }

    mutating func answer(_ query: Query, _ turn: inout Turn<MembershipModel>) -> Int {
        switch query {
        case .admit(let session, let player):
            // Asked by the keeper in the segment of its insert. Admitted only while the join's
            // request is open: a disconnect that stepped first ended the key and closed it.
            guard turn.isLive(.connection(session)), joins.values.contains(where: { $0.session == session }) else {
                note("admission \(session) refused")
                settleLogWaiters(&turn)
                return 0
            }
            admitMember(session: session, player: player, &turn)
            settleLogWaiters(&turn)
            return 1
        case .endJoinBeforeAdmission(let session, let token):
            // Whether the admission started is this machine's to say, in one step. Not
            // started: its token ends here, and the final frame and the close leave this
            // step. Started: it goes on to its outcome.
            let started = sessionToPlayer[session] != nil
                || registrations.values.contains { $0.session == session }
                || joins.values.contains { $0.session == session }
            if started {
                note("join \(session) already started")
                settleLogWaiters(&turn)
                return 0
            }
            turn.revoke(token)
            note("join \(session) ended before admission")
            ensureLand(&turn)
            turn.emit(1000 + session, for: .land)
            turn.run(.close(session: session))
            settleLogWaiters(&turn)
            return 1
        }
    }
}
