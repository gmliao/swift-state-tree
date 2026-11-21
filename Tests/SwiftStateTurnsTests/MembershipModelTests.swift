import SwiftStateTurns
import Testing

/// The membership scenarios the core's design closed on, on models of the adapter's membership
/// path, the keeper and the transport: a hold handed over, `queue(behind:)` on a held key,
/// `revoke` while queued, `reply(after:)` behind a worker, and `query` inside an admission. A core
/// bug that only shows in these combinations surfaces here. Slice 1 repeats each scenario
/// against the real adapter and keeper.
@Suite("Turn core: membership model", .timeLimit(.minutes(1)))
struct MembershipModelTests {
    @Test("M1: a registration queued behind the hold, then a disconnect: withdrawn by scope")
    func parkedRegistrationThenDisconnect() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        await a.send(.txn(1, gate: "s1"))
        let registration = Task {
            try await a.sendAndWait(.register(session: 5, player: 50, gate: "", token: nil), cancellation: .ignoresCancel)
        }
        await f.reach("park #1")
        await a.send(.disconnect(5))
        let result = outcome(await boundedResult(registration))
        f.open("s1")
        await a.waitForLog(3)
        let s = await a.snapshot()
        #expect(result == "withdrawn")
        #expect(s.log == ["begin 1", "disconnect 5", "end 1"])
        #expect(s.players[5] == nil)
        #expect(s.stats.queued == 0)
    }

    @Test("M2: a refused registration withdraws a second one queued behind it")
    func refusedRegistrationWithdrawsSecond() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        let first = Task {
            try await a.sendAndWait(.register(session: 6, player: 60, gate: "k6", token: nil), cancellation: .ignoresCancel)
        }
        await f.reach("at k6")
        let second = Task {
            try await a.sendAndWait(.register(session: 6, player: 60, gate: "", token: nil), cancellation: .ignoresCancel)
        }
        await f.reach("park #1")
        a.keeper.setEntry(player: 60, session: 7)
        f.open("k6")
        let firstResult = outcome(await boundedResult(first))
        let secondResult = outcome(await boundedResult(second))
        await f.reach("closed 6")
        let s = await a.snapshot()
        #expect(firstResult == "refused")
        #expect(secondResult == "withdrawn")
        #expect(s.log == ["register 6", "refuse 6"])
        #expect(s.players[6] == nil)
        #expect(s.stats.queued == 0)
        #expect(s.stats.heldKeys == 0)
    }

    @Test("M3: a disconnect during the keeper read: the request is abandoned, the hold released, the late read stale")
    func disconnectDuringKeeperRead() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        let registration = Task {
            try await a.sendAndWait(.register(session: 8, player: 80, gate: "k8", token: nil), cancellation: .ignoresCancel)
        }
        await f.reach("at k8")
        let next = Task { try await a.sendAndWait(.txn(9, gate: ""), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        await a.send(.disconnect(8))
        let result = outcome(await boundedResult(registration))
        let nextResult = outcome(await boundedResult(next))
        f.open("k8")
        await a.waitForLog(6)
        let s = await a.snapshot()
        #expect(result == "abandoned")
        #expect(nextResult == "success 9")
        #expect(s.log == [
            "register 8", "disconnect 8", "registration 8 abandoned keyEnded", "begin 9", "end 9", "stale read 8",
        ])
        #expect(s.players[8] == nil)
    }

    @Test("M4: a refusal leaves the member's first sync running; the same binding doesn't move the member key; a rebind does")
    func memberKeyMovesOnlyOnRebind() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        a.transport.connect(1)
        a.transport.connect(3)
        let accepted = outcome(await boundedResult(Task {
            try await a.sendAndWait(.register(session: 1, player: 10, gate: "", token: nil), cancellation: .ignoresCancel)
        }))
        await a.send(.startFirstSync(1, gate: "fs1"))
        a.keeper.setEntry(player: 10, session: 2)
        let refused = outcome(await boundedResult(Task {
            try await a.sendAndWait(.register(session: 1, player: 10, gate: "", token: nil), cancellation: .ignoresCancel)
        }))
        f.open("fs1")
        await a.waitForLog(7)
        _ = try? await boundedResult(Task { try await a.sendAndWait(.register(session: 3, player: 30, gate: "", token: nil), cancellation: .ignoresCancel) }).get()
        await a.send(.startFirstSync(3, gate: "fs3"))
        _ = try? await boundedResult(Task { try await a.sendAndWait(.register(session: 3, player: 30, gate: "", token: nil), cancellation: .ignoresCancel) }).get()
        let openAfterSameBinding = await a.snapshot().stats.openRequests
        _ = try? await boundedResult(Task { try await a.sendAndWait(.register(session: 3, player: 31, gate: "", token: nil), cancellation: .ignoresCancel) }).get()
        f.open("fs3")
        await a.waitForLog(20)
        await f.reach("closed 1")
        let s = await a.snapshot()
        #expect(accepted == "success 1")
        #expect(refused == "refused")
        #expect(openAfterSameBinding == 1)
        #expect(s.log == [
            "register 1", "member 1 issued", "registered 1 as 10", "transport 1 generation 1",
            "register 1", "refuse 1", "first sync 1 done",
            "register 3", "member 3 issued", "registered 3 as 30", "transport 3 generation 2",
            "register 3", "registered 3 as 30", "transport 3 generation 2",
            "register 3", "member 3 issued", "registered 3 as 31", "first sync 3 abandoned keyEnded",
            "transport 3 generation 2", "stale first sync 3",
        ])
        #expect(a.transport.closed == [1])
        #expect(a.transport.sessions(of: 31) == [3])
        #expect(s.generations[3] == 2)
    }

    @Test("M5: teardown answers a reading registration and a queued one")
    func teardownAnswersRegistrations() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        let reading = Task {
            try await a.sendAndWait(.register(session: 9, player: 90, gate: "k9", token: nil), cancellation: .ignoresCancel)
        }
        await f.reach("at k9")
        let parked = Task {
            try await a.sendAndWait(.register(session: 11, player: 110, gate: "", token: nil), cancellation: .ignoresCancel)
        }
        await f.reach("park #1")
        await a.send(.teardown)
        let readingResult = outcome(await boundedResult(reading))
        let parkedResult = outcome(await boundedResult(parked))
        f.open("k9")
        await a.waitForLog(4)
        let s = await a.snapshot()
        #expect(readingResult == "abandoned")
        #expect(parkedResult == "withdrawn")
        #expect(s.log == ["register 9", "teardown", "registration 9 abandoned keyEnded", "stale read 9"])
        #expect(s.stats.pendingWaiters == 0)
        #expect(s.stats.queued == 0)
        #expect(s.stats.openRequests == 0)
        #expect(s.stats.heldKeys == 0)
    }

    @Test("M6: the withdraw token is marked first: the registration is withdrawn and no keeper request is made")
    func tokenMarkedBeforeRegistration() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        a.transport.connect(5)
        // The session's end reaches the adapter before its registration does. Nothing of the
        // session exists yet, so no key can carry that; the registration's token does.
        let token = WithdrawToken()
        token.withdraw()
        a.transport.disconnect(5)
        await a.send(.disconnect(5))
        let result = outcome(await boundedResult(Task {
            try await a.sendAndWait(.register(session: 5, player: 50, gate: "", token: token), cancellation: .ignoresCancel)
        }))
        let s = await a.snapshot()
        #expect(result == "withdrawn")
        #expect(s.log == ["disconnect 5"])
        #expect(s.players[5] == nil)
        #expect(s.stats.openRequests == 0)
        #expect(a.transport.sessions(of: 50).isEmpty)
    }

    @Test("M7: the join budget: a queued admission is ended and withdrawn, its final frame out at the answer; a started one is left alone")
    func joinBudget() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        a.transport.connect(6)
        await a.send(.txn(1, gate: "b1"))
        // Not started (queued): the machine ends the token in its own step, answers so, and
        // the final frame and the close leave that step; the admission never runs.
        let waiting = WithdrawToken()
        let parked = Task {
            try await a.sendAndWait(.register(session: 5, player: 50, gate: "", token: waiting), cancellation: .ignoresCancel)
        }
        await f.reach("park #1")
        let ended = await a.query(.endJoinBeforeAdmission(session: 5, token: waiting))
        let frameAtAnswer = await a.snapshot().flushed
        let parkedResult = outcome(await boundedResult(parked))
        await f.reach("closed 5")
        f.open("b1")
        await a.waitForLog(3)
        // Started: the answer says so, and the join goes on to its outcome.
        let running = WithdrawToken()
        let started = Task {
            try await a.sendAndWait(.register(session: 6, player: 60, gate: "k6", token: running), cancellation: .ignoresCancel)
        }
        await f.reach("at k6")
        let endedStarted = await a.query(.endJoinBeforeAdmission(session: 6, token: running))
        f.open("k6")
        f.open("tk6")
        let startedResult = outcome(await boundedResult(started))
        let s = await a.snapshot()
        #expect(parkedResult == "withdrawn")
        #expect(waiting.isWithdrawn)
        #expect(ended == 1)
        #expect(frameAtAnswer == [1005])
        #expect(startedResult == "success 6")
        #expect(!running.isWithdrawn)
        #expect(endedStarted == 0)
        #expect(s.flushed == [1005])
        #expect(a.transport.closed == [5])
        #expect(s.log == [
            "begin 1", "join 5 ended before admission", "end 1",
            "register 6", "join 6 already started", "member 6 issued", "registered 6 as 60", "transport 6 generation 1",
        ])
    }

    @Test("M8: the transport registration in five orders against a disconnect")
    func transportRegistrationOrders() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        let transport = a.transport
        func register(_ session: Int, _ player: Int, _ gate: String, generation: Int? = nil) -> Task<Int, any Error> {
            Task {
                try await a.sendAndWait(
                    .register(session: session, player: player, gate: gate, token: nil, generation: generation),
                    cancellation: .ignoresCancel
                )
            }
        }

        // (a) The disconnect wins at the transport: the registration is refused there.
        transport.connect(7)
        let lost = register(7, 70, "k7")
        f.open("k7")
        await f.reach("at tk7")
        transport.disconnect(7)
        await a.send(.disconnect(7))
        let lostResult = outcome(await boundedResult(lost))
        f.open("tk7")
        await a.waitForLog(6)
        let mapAfterLost = transport.sessions(of: 70)

        // (b) The registration wins and is answered; the disconnect then cleans the map.
        transport.connect(8)
        let won = register(8, 80, "k8")
        f.open("k8")
        f.open("tk8")
        let wonResult = outcome(await boundedResult(won))
        let mapWhileMember = transport.sessions(of: 80)
        transport.disconnect(8)
        await a.send(.disconnect(8))
        let mapAfterWon = transport.sessions(of: 80)

        // (c) The transport mapped the session, then disconnected it, and the adapter's
        //     disconnect steps before the registration's completion does.
        transport.connect(9)
        transport.holdAfterRegister(9)
        let between = register(9, 90, "k9")
        f.open("k9")
        f.open("tk9")
        await f.reach("transport answered 9")
        transport.disconnect(9)
        await a.send(.disconnect(9))
        let betweenResult = outcome(await boundedResult(between))
        f.open("post 9")
        await a.waitForLog(17)

        // (d) The transport refuses (no live queue), and that completion steps before the
        //     adapter's disconnect: the registration stands without a generation until the
        //     disconnect arrives.
        transport.connect(11)
        let refusedThere = register(11, 110, "k11")
        f.open("k11")
        await f.reach("at tk11")
        transport.disconnect(11)
        f.open("tk11")
        let refusedThereResult = outcome(await boundedResult(refusedThere))
        let afterRefusal = await a.snapshot()
        let mapAfterRefusal = transport.sessions(of: 110)
        await a.send(.disconnect(11))

        // (e) A generation passed in: the transport registration still runs, and the passed
        //     one is the one kept.
        transport.connect(12)
        let suppliedResult = outcome(await boundedResult(register(12, 120, "", generation: 77)))
        let afterSupplied = await a.snapshot()
        let mapAfterSupplied = transport.sessions(of: 120)
        transport.disconnect(12)
        await a.send(.disconnect(12))
        let s = await a.snapshot()

        #expect(lostResult == "abandoned")
        #expect(mapAfterLost.isEmpty)
        #expect(wonResult == "success 8")
        #expect(mapWhileMember == [8])
        #expect(mapAfterWon.isEmpty)
        #expect(betweenResult == "abandoned")
        #expect(transport.sessions(of: 90).isEmpty)
        #expect(refusedThereResult == "success 11")
        #expect(afterRefusal.players[11] == 110)
        #expect(afterRefusal.generations[11] == nil)
        #expect(mapAfterRefusal.isEmpty)
        #expect(suppliedResult == "success 12")
        #expect(afterSupplied.generations[12] == 77)
        #expect(mapAfterSupplied == [12])
        #expect(s.players.isEmpty)
        #expect(s.generations.isEmpty)
        #expect(s.stats.heldKeys == 0)
        #expect(s.log == [
            "register 7", "member 7 issued", "registered 7 as 70", "disconnect 7", "registration 7 abandoned keyEnded",
            "stale transport 7",
            "register 8", "member 8 issued", "registered 8 as 80", "transport 8 generation 2", "disconnect 8",
            "register 9", "member 9 issued", "registered 9 as 90", "disconnect 9", "registration 9 abandoned keyEnded",
            "stale transport 9",
            "register 11", "member 11 issued", "registered 11 as 110", "transport 11 not connected", "disconnect 11",
            "register 12", "member 12 issued", "registered 12 as 120", "transport 12 generation 77", "disconnect 12",
        ])
    }

    @Test("M9: a started library join, then a disconnect, in six orders")
    func startedJoinThenDisconnect() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        let keeper = a.keeper
        func join(_ session: Int, _ player: Int, _ gate: String, _ shape: JoinShape) -> Task<Int, any Error> {
            Task {
                try await a.sendAndWait(
                    .libraryJoin(session: session, player: player, gate: gate, shape: shape, token: nil),
                    cancellation: .ignoresCancel
                )
            }
        }

        // (a) The disconnect lands before the keeper's insert: the admission, asked in the
        //     segment of the insert, is refused, and nothing is inserted.
        let first = join(1, 10, "j1", .admitAtInsert)
        await f.reach("at j1")
        await a.send(.disconnect(1))
        let firstResult = outcome(await boundedResult(first))
        f.open("j1")
        await a.waitForLog(5)
        let keeperAfterFirst = keeper.players

        // (b) The keeper inserted before its resolvers, and the disconnect lands during them:
        //     the admission is refused and the keeper rolls its player back in that segment.
        let second = join(2, 20, "j2", .insertThenAdmit)
        await f.reach("at j2")
        let keeperDuringSecond = keeper.players
        await a.send(.disconnect(2))
        let secondResult = outcome(await boundedResult(second))
        f.open("j2")
        await a.waitForLog(10)
        let keeperAfterSecond = keeper.players

        // (c) The disconnect lands after the admission and before the join returns: the
        //     member goes at once; the keeper's leave waits for the join's worker, and is
        //     requested when it has returned.
        f.open("j3")
        let third = join(3, 30, "j3", .admitAtInsert)
        await f.reach("admitted j3")
        let memberDuringThird = await a.snapshot().players[3]
        await a.send(.disconnect(3))
        let thirdResult = outcome(await boundedResult(third))
        let midThird = await a.snapshot()
        let keeperDuringThird = keeper.players
        f.open("after j3")
        await a.waitForLog(17)
        let keeperAfterThird = keeper.players

        // (d) The keeper doesn't ask (the caller admits when the join returns), and the
        //     disconnect lands during the join: the stale completion undoes the keeper's player.
        let fourth = join(4, 40, "j4", .callerAdmits)
        await f.reach("at j4")
        await a.send(.disconnect(4))
        let fourthResult = outcome(await boundedResult(fourth))
        f.open("j4")
        await a.waitForLog(23)
        let keeperAfterFourth = keeper.players

        // (e) A member's disconnect while other membership work is in flight: its leave keeps
        //     its place, behind a registration that was already queued.
        let fifthResult = outcome(await boundedResult(join(5, 50, "", .callerAdmits)))
        a.transport.connect(6)
        await a.send(.txn(9, gate: "x9"))
        let registration = Task {
            try await a.sendAndWait(.register(session: 6, player: 60, gate: "", token: nil), cancellation: .ignoresCancel)
        }
        await f.reach("park #1")
        await a.send(.disconnect(5))
        let midFifth = await a.snapshot()
        let keeperDuringFifth = keeper.players
        f.open("x9")
        let registrationResult = outcome(await boundedResult(registration))
        await a.waitForLog(35)
        let keeperAfterFifth = keeper.players

        // (f) A queued leave outlives `close`.
        let sixthResult = outcome(await boundedResult(join(7, 70, "", .insertThenAdmit)))
        await a.send(.txn(8, gate: "x8"))
        await a.send(.disconnect(7))
        await a.send(.shutdown)
        let keeperDuringSixth = keeper.players
        f.open("x8")
        await a.waitForLog(44)
        let s = await a.snapshot()

        let results = [firstResult, secondResult, thirdResult, fourthResult, fifthResult, registrationResult, sixthResult]
        #expect(results == ["abandoned", "abandoned", "abandoned", "abandoned", "success 5", "success 6", "success 7"])
        let keepers = [
            keeperAfterFirst, keeperDuringSecond, keeperAfterSecond, keeperDuringThird, keeperAfterThird,
            keeperAfterFourth, keeperDuringFifth, keeperAfterFifth, keeperDuringSixth, keeper.players,
        ]
        #expect(keepers == [[:], [20: 2], [:], [30: 3], [:], [:], [50: 5], [:], [70: 7], [:]])
        #expect(memberDuringThird == 30)
        #expect(midThird.players[3] == nil)
        #expect(midThird.stats.openRequests == 0)
        #expect(midThird.stats.heldKeys == 1)
        #expect(midFifth.players[5] == nil)
        #expect(midFifth.stats.queued == 2)
        #expect(s.players == [6: 60])
        #expect(s.stats.heldKeys == 0)
        #expect(s.stats.queued == 0)
        #expect(s.stats.openRequests == 0)
        #expect(s.stats.pendingWaiters == 0)
        #expect(s.log == [
            "join 1", "disconnect 1", "join 1 abandoned keyEnded", "admission 1 refused", "stale join 1",
            "join 2", "disconnect 2", "join 2 abandoned keyEnded", "admission 2 refused", "stale join 2",
            "join 3", "admitted 3 as 30", "disconnect 3", "join 3 abandoned keyEnded", "stale join 3",
            "leave 3 requested", "left 3",
            "join 4", "disconnect 4", "join 4 abandoned keyEnded", "stale join 4", "leave 4 requested", "left 4",
            "join 5", "admitted 5 as 50", "joined 5", "begin 9", "disconnect 5", "end 9",
            "register 6", "member 6 issued", "registered 6 as 60", "transport 6 generation 1",
            "leave 5 requested", "left 5",
            "join 7", "admitted 7 as 70", "joined 7", "begin 8", "disconnect 7", "shutdown", "end 8",
            "leave 7 requested", "left 7",
        ])
    }

    @Test("M10: a disconnect as a call, in six parts, through teardown and after the end")
    func disconnectAsCall() async {
        let f = Fixture()
        let a = MembershipActor(fixture: f)
        let keeper = a.keeper
        func join(_ session: Int, _ player: Int, _ gate: String, _ shape: JoinShape) -> Task<Int, any Error> {
            Task {
                try await a.sendAndWait(
                    .libraryJoin(session: session, player: player, gate: gate, shape: shape, token: nil),
                    cancellation: .ignoresCancel
                )
            }
        }
        func disconnect(_ session: Int) -> Task<Int, any Error> {
            Task { try await a.sendAndWait(.disconnect(session), cancellation: .ignoresCancel) }
        }

        // (a) No leave is due: answered in the disconnect's own step.
        let noneResult = outcome(await boundedResult(disconnect(99)))

        // (b) A member's disconnect arrives behind a transaction in flight: its caller waits,
        //     and is answered after the leave ran against the keeper.
        let firstResult = outcome(await boundedResult(join(1, 10, "", .callerAdmits)))
        await a.send(.txn(9, gate: "x9"))
        let firstLeft = disconnect(1)
        await a.waitForLog(6)
        let waitingFirst = await a.snapshot()
        let keeperBeforeLeave = keeper.players
        f.open("x9")
        let firstLeftResult = outcome(await boundedResult(firstLeft))
        let keeperAfterLeave = keeper.players
        let leavesAfterFirst = keeper.leaveCalls

        // (c) A stop: three sessions' disconnects arrive in an order of their own, behind work
        //     in flight. Each is awaited, and each is answered after its leave.
        let joinResults = [
            outcome(await boundedResult(join(5, 50, "", .callerAdmits))),
            outcome(await boundedResult(join(6, 60, "", .insertThenAdmit))),
            outcome(await boundedResult(join(7, 70, "", .admitAtInsert))),
        ]
        await a.send(.txn(8, gate: "x8"))
        let left7 = disconnect(7)
        await a.waitForLog(20)
        let left5 = disconnect(5)
        await a.waitForLog(21)
        let left6 = disconnect(6)
        await a.waitForLog(22)
        let waitingStop = await a.snapshot()
        let leavesBeforeStop = keeper.leaveCalls
        f.open("x8")
        let stopResults = [outcome(await boundedResult(left5)), outcome(await boundedResult(left6)), outcome(await boundedResult(left7))]
        let keeperAfterStop = keeper.players
        let leavesAfterStop = keeper.leaveCalls

        // (d) The session's own keeper join is still running: the caller is answered when that
        //     worker has returned and the compensating leave has run.
        let eighth = join(8, 80, "j8", .callerAdmits)
        await f.reach("at j8")
        let left8 = disconnect(8)
        await a.waitForLog(32)
        let eighthResult = outcome(await boundedResult(eighth))
        let waitingEighth = await a.snapshot()
        f.open("j8")
        let left8Result = outcome(await boundedResult(left8))
        let leavesAfterEighth = keeper.leaveCalls

        // (e) The end. A leave is still queued behind a worker that keeps its hold, with its
        //     disconnect's caller waiting; the keeper is destroyed (its players cleared); then
        //     the adapter ends. The caller is answered by the ending step. The worker returns
        //     afterwards and reports that it joined, so its stale completion asks for a
        //     compensating leave, which the ended core can't make.
        let secondResult = outcome(await boundedResult(join(2, 20, "", .insertThenAdmit)))
        let fourthResult = outcome(await boundedResult(join(4, 40, "", .callerAdmits)))
        let third = join(3, 30, "j3", .callerAdmits)
        await f.reach("at j3")
        let left2 = disconnect(2)
        await a.waitForLog(43)
        let beforeEnd = await a.snapshot()
        keeper.stop()
        await a.send(.teardown)
        let left2Result = outcome(await boundedResult(left2))
        let thirdResult = outcome(await boundedResult(third))
        let afterEnd = await a.snapshot()
        f.open("j3")
        await a.waitForLog(46)
        let afterWorker = await a.snapshot()

        // (f) A member's disconnect that arrives after the end queues nothing and is answered
        //     at once.
        let lateResult = outcome(await boundedResult(disconnect(4)))
        let s = await a.snapshot()

        let results = [noneResult, firstResult, firstLeftResult] + joinResults + stopResults
            + [eighthResult, left8Result, secondResult, fourthResult, left2Result, thirdResult, lateResult]
        #expect(results == [
            "success 0", "success 1", "success 1", "success 5", "success 6", "success 7",
            "success 1", "success 1", "success 1", "abandoned", "success 1",
            "success 2", "success 4", "success 2", "abandoned", "success 2",
        ])
        #expect(waitingFirst.stats.pendingWaiters == 1)
        #expect(waitingFirst.stats.queued == 1)
        #expect(keeperBeforeLeave == [10: 1])
        #expect(keeperAfterLeave.isEmpty)
        #expect(leavesAfterFirst == 1)
        #expect(waitingStop.stats.pendingWaiters == 3)
        #expect(waitingStop.stats.queued == 3)
        #expect(leavesBeforeStop == 1)
        #expect(keeperAfterStop.isEmpty)
        #expect(leavesAfterStop == 4)
        #expect(waitingEighth.stats.pendingWaiters == 1)
        #expect(leavesAfterEighth == 5)
        #expect(beforeEnd.stats.queued == 1)
        #expect(beforeEnd.stats.heldKeys == 1)
        #expect(beforeEnd.stats.pendingWaiters == 2)
        #expect(afterEnd.stats.queued == 0)
        #expect(afterEnd.stats.heldKeys == 1)
        #expect(afterEnd.stats.liveKeys == 0)
        #expect(afterEnd.stats.openRequests == 0)
        #expect(afterEnd.stats.pendingWaiters == 0)
        #expect(afterWorker.stats.heldKeys == 0)
        #expect(afterWorker.stats.ignoredAfterEnd == 1)
        #expect(s.stats.liveKeys == 0)
        #expect(s.stats.openRequests == 0)
        #expect(s.stats.queued == 0)
        #expect(s.stats.heldKeys == 0)
        #expect(s.stats.ignoredAfterEnd == 2)
        #expect(s.stats.pendingWaiters == 0)
        #expect(keeper.leaveCalls == 5)
        #expect(keeper.players.isEmpty)
        #expect(s.log == [
            "disconnect 99",
            "join 1", "admitted 1 as 10", "joined 1", "begin 9", "disconnect 1", "end 9",
            "leave 1 requested", "left 1",
            "join 5", "admitted 5 as 50", "joined 5", "join 6", "admitted 6 as 60", "joined 6",
            "join 7", "admitted 7 as 70", "joined 7", "begin 8",
            "disconnect 7", "disconnect 5", "disconnect 6", "end 8",
            "leave 7 requested", "left 7", "leave 5 requested", "left 5", "leave 6 requested", "left 6",
            "join 8", "disconnect 8", "join 8 abandoned keyEnded", "stale join 8", "leave 8 requested", "left 8",
            "join 2", "admitted 2 as 20", "joined 2", "join 4", "admitted 4 as 40", "joined 4",
            "join 3", "disconnect 2", "teardown", "join 3 abandoned keyEnded", "stale join 3",
            "disconnect 4",
        ])
    }
}
