// §6.4: seeded orders of inputs, calls, completions, cancellations, deadlines and timers against
// `OrderModel`. After every operation the machine's recorded violations, the sink's view and the
// core's counters are checked against the machine's own view; at the end, every call's answer and
// every queued input's fate. A failing seed is printed; replay it with
// `TURNS_SEED=<seed> swift test --filter GeneratedOrderTests`, and keep it as a fixed replay
// (`replays`). CI runs the fixed seed set; a longer run is `TURNS_SEEDS=<count>`.
//
// Every operation waits for its consequence before the next one starts: a `send` returns after
// its batch; a call is waited for until it has stepped, queued or been answered; a completion,
// a deadline or a timer is waited for by the `notify` its step starts. Time is monotonic: a
// deadline or fire op advances the test clock to one pending item's instant, and every request
// deadline and timer at or before it is due, each waited for by its `notify`. With the large batch
// budget a seed gives one order, run after run. Every third seed runs with a budget of 2, so a
// drain continues in the core's continuation job and interleaves with the operations that follow; those
// seeds keep the invariants but not one fixed schedule.

import Foundation
import SwiftStateTurns
import Testing

/// Counts the machine's notifications and lets the harness wait for one.
final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var waiting: [String: [(count: Int, id: UInt64, continuation: CheckedContinuation<Void, Never>)]] = [:]
    private var nextWaiter: UInt64 = 0

    func post(_ name: String) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let count = (counts[name] ?? 0) + 1
            counts[name] = count
            var ready: [CheckedContinuation<Void, Never>] = []
            waiting[name]?.removeAll { entry in
                if entry.count <= count { ready.append(entry.continuation); return true }
                return false
            }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }

    func count(_ name: String) -> Int {
        lock.withLock { counts[name] ?? 0 }
    }

    /// `wait(name)` under the hang bound: false when `name` isn't posted within it, so a
    /// regression fails the seed instead of parking the run. The bound cancels the wait, which
    /// then resumes, so nothing stays parked after it.
    func reach(_ name: String) async -> Bool {
        await withinTurnHangBound { () -> Bool in
            await self.wait(name)
            return true
        } != nil
    }

    /// Returns once `name` has been posted at least once, or once its task is cancelled.
    func wait(_ name: String) async {
        let id = lock.withLock { () -> UInt64 in
            nextWaiter += 1
            return nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if (counts[name] ?? 0) >= 1 || Task.isCancelled { return true }
                    waiting[name, default: []].append((count: 1, id: id, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard let index = waiting[name]?.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting[name]?.remove(at: index).continuation
            }
            cancelled?.resume()
        }
    }
}

/// A call's answer, once it has one.
final class CallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ text: String) { lock.withLock { value = text } }
    var answer: String? { lock.withLock { value } }
}

actor OrderActor<Mail: OrderMail & PlainData>: TurnActor {
    typealias View = OrderView
    let core: TurnCore<OrderModel<Mail>>
    nonisolated let mailbox: TurnMailbox<Mail>?
    nonisolated let fixture: Fixture
    nonisolated let notes: Notes
    nonisolated let clock: TestClock
    /// What the sink received, and the outputs flushed after another step had run (invariant 11).
    private var delivered: [Int] = []
    private var lateFlushes: [String] = []

    /// A mail the next flush posts (a post between steps); nil when none is due.
    private var postOnFlush: Int?
    /// Mail accepted by a post this actor made from a flush.
    private var flushPosted: [Int] = []
    /// Mail accepted by a post a check's hook made: a lock, not the actor, because the hook
    /// is a plain closure.
    nonisolated let checkPosted = MailList()

    init(fixture: Fixture, notes: Notes, queueLimit: Int, maxReleasesPerBatch: Int, mailboxCapacity: Int) {
        self.fixture = fixture
        self.notes = notes
        let clock = TestClock(fixture: fixture)
        self.clock = clock
        let core = TurnCore(OrderModel<Mail>(), queueLimit: queueLimit, maxReleasesPerBatch: maxReleasesPerBatch, clock: clock, mailboxCapacity: mailboxCapacity)
        core.onDiagnostic = { event in
            if case .queued = event { notes.post("park") }
        }
        self.core = core
        mailbox = core.mailbox
    }

    /// The next flush posts `mail`.
    func postAtNextFlush(_ mail: Int) {
        postOnFlush = mail
    }

    /// The next mailbox check posts `mail` at its hold point, after its watermark is read.
    func postAtNextCheck(_ mail: Int) {
        let once = Once()
        core.onMailboxCheckForTesting = { [weak self] in
            once.run {
                guard let self else { return }
                if self.postNumber(mail) { self.checkPosted.append(mail) }
            }
        }
    }

    /// Posts the mail numbered `number`; false when refused, or for the mailboxless twin.
    nonisolated func postNumber(_ number: Int) -> Bool {
        Mail.numbered(number).map { post($0) } ?? false
    }

    nonisolated func postNumberForTesting(_ number: Int, afterAppend: @Sendable @escaping () async -> Void) async -> Bool {
        guard let mail = Mail.numbered(number) else { return false }
        return await postForTesting(mail, afterAppend: afterAppend)
    }

    @concurrent nonisolated func perform(_ effect: OrderModel<Mail>.Effect) async -> OrderModel<Mail>.Input? {
        switch effect {
        case .work(let seq):
            await fixture.wait("work \(seq)")
            return .completed(seq: seq)
        case .notify(let name):
            notes.post(name)
            return nil
        }
    }

    func flush(_ outputs: consuming [OrderOutput]) {
        if let mail = postOnFlush {
            postOnFlush = nil
            if postNumber(mail) { flushPosted.append(mail) }
        }
        // Between steps: the machine's step count is the step whose outputs these are.
        let step = core.read { $0.stepCount }
        for output in outputs {
            delivered.append(output.id)
            if output.step != step { lateFlushes.append("output \(output.id) of step \(output.step) flushed after step \(step)") }
        }
    }

    func view() -> View {
        let stats = core.stats
        let delivered = delivered
        let lateFlushes = lateFlushes
        let pendingWork = pendingWork()
        return core.read { machine in
            View(
                violations: machine.violations,
                open: machine.open.keys.sorted(),
                pending: machine.open.keys.sorted() + machine.abandoned.sorted(),
                timers: machine.timers,
                expectedHeld: machine.expectedHeldKeys.count,
                ended: machine.ended,
                stepped: machine.steppedWork,
                expectedOutputs: machine.expectedOutputs,
                delivered: delivered,
                lateFlushes: lateFlushes,
                queued: machine.queued,
                droppedQueued: machine.droppedQueued,
                pendingFollowUps: machine.followUps.count,
                pendingWork: pendingWork,
                stats: stats,
                mailStepped: machine.mailStepped,
                selfPosted: flushPosted + checkPosted.mail
            )
        }
    }
}

/// What the harness checks after an operation.
struct OrderView: Sendable {
    var violations: [String]
    var open: [Int]
    var pending: [Int]
    var timers: [Int: Int]
    var expectedHeld: Int
    var ended: Bool
    var stepped: [Int]
    var expectedOutputs: [Int]
    var delivered: [Int]
    var lateFlushes: [String]
    var queued: Set<Int>
    var droppedQueued: Set<Int>
    var pendingFollowUps: Int
    var pendingWork: Int
    var stats: TurnStats
    var mailStepped: [Int]
    var selfPosted: [Int]
}

/// A small deterministic generator (SplitMix64), so a seed replays on every platform.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One `sendAndWait` the harness made.
struct CallRecord {
    var id: Int
    var box: CallBox
    var task: Task<Void, Never>
}

/// Lets the actor's jobs run until `done` holds: a condition, not a delay. Each round trip into
/// the actor lets a job queued before it (a call's entry, a drain continuation) run first.
func settle<R>(_ actor: OrderActor<R>, rounds: Int = 10_000, until done: (OrderView) -> Bool) async -> Bool {
    for _ in 0 ..< rounds {
        if done(await actor.view()) { return true }
        await Task.yield() // wall-clock: not time: yields until the actor's queued jobs have run (the harness's settle)
    }
    return false
}

/// Runs one seed and returns its failures (empty: it passed).
func runOrder(seed: UInt64, operations: Int, maxReleasesPerBatch: Int) async -> [String] {
    await runOrder(seed: seed, operations: operations, maxReleasesPerBatch: maxReleasesPerBatch, mail: Int.self)
}

/// Runs one seed with mail of type `R`; `Never`, the mailboxless twin, skips the mailbox
/// operations (their stream is separate, so the other operations are the same).
func runOrder<R: OrderMail & PlainData>(seed: UInt64, operations: Int, maxReleasesPerBatch: Int, mail _: R.Type) async -> [String] {
    var random = SeededGenerator(seed: seed)
    // Follow-up operations draw from their own stream, so the main stream (and the seeds pinned
    // to a mutant) keep their operations.
    var followUpRandom = SeededGenerator(seed: seed ^ 0x702)
    // Mailbox posts draw from a third stream, for the same reason.
    var mailboxRandom = SeededGenerator(seed: seed ^ 0x725)
    var nextMail = 1
    // Mail the harness's own posts had accepted, and held posts whose wakes wait at a gate.
    var accepted: Set<Int> = []
    var heldPosts: [(mail: Int, task: Task<Bool, Never>)] = []
    var nextLabel = 1
    let fixture = Fixture()
    let notes = Notes()
    // The budget-2 seeds also take at most 2 mail per entry, so mailbox batches split too.
    let actor = OrderActor<R>(fixture: fixture, notes: notes, queueLimit: 6, maxReleasesPerBatch: maxReleasesPerBatch,
                           mailboxCapacity: maxReleasesPerBatch == 2 ? 2 : 8)
    var failures: [String] = []
    var nextSeq = 1
    var nextWork = 1
    var nextToken = 1
    var tokens: [(Int, WithdrawToken)] = []
    var log: [String] = []
    // The harness's mirror of each scope's ends (end, supersede, endAll) and of the live keys.
    var ends: [Int: Int] = [:]
    var live: Set<Int> = [0, 1]
    var endedAll = false
    var calls: [CallRecord] = []
    // Each request's deadline instant and each timer's, in nanoseconds: the clock's now when its
    // op ran plus its duration.
    var deadlineAt: [Int: Int64] = [:]
    var timerAt: [Int: Int64] = [:]

    /// Advances the clock to `instant` and waits for every request deadline and timer due by then.
    func advance(to instant: Int64, _ view: OrderActor.View, _ op: String) async {
        actor.clock.advance(to: TurnInstant(nanoseconds: instant))
        for seq in view.open where (deadlineAt[seq] ?? .max) <= instant {
            if !(await notes.reach("abandoned \(seq)")) { failures.append("after `\(op)`: abandoned \(seq) never posted") }
        }
        for seq in view.timers.values where (timerAt[seq] ?? .max) <= instant {
            if !(await notes.reach("fired \(seq)")) { failures.append("after `\(op)`: fired \(seq) never posted") }
        }
    }

    await actor.send(.start(0))
    await actor.send(.start(1))

    for step in 0 ..< operations {
        let view = await actor.view()
        let choice = Int.random(in: 0 ..< 100, using: &random)
        let owner = Int.random(in: 0 ... 1, using: &random)
        let hold = Int.random(in: 10 ... 11, using: &random)
        var op = ""
        switch choice {
        case 0 ..< 22:
            // External work, maybe queued, scoped, tokened; sent, or called (with the caller's
            // cancellation cancelsCall).
            let id = nextWork
            nextWork += 1
            let scoped = Bool.random(using: &random)
            let scopeEnds: Int? = scoped ? ends[owner] ?? 0 : nil
            var token: WithdrawToken?
            var tokenID: Int?
            if Int.random(in: 0 ..< 4, using: &random) == 0 {
                let t = WithdrawToken()
                token = t
                tokenID = nextToken
                tokens.append((nextToken, t))
                nextToken += 1
            }
            let held = Bool.random(using: &random) ? hold : nil
            let asCall = Int.random(in: 0 ..< 3, using: &random) == 0
            let input = OrderModel<R>.Input.work(id: id, hold: held, scope: scoped ? owner : nil,
                                              scopeEnds: scopeEnds, token: token, tokenID: tokenID, pinned: false)
            op = "\(asCall ? "call" : "work") \(id) hold \(held.map(String.init) ?? "-") scope \(scoped ? String(owner) : "-") token \(tokenID.map(String.init) ?? "-")"
            if asCall {
                let parks = notes.count("park")
                let box = CallBox()
                let task = Task {
                    do {
                        box.set("success \(try await actor.sendAndWait(input, cancellation: .cancelsCall))")
                    } catch let error as TurnError {
                        box.set("\(error)")
                    } catch {
                        box.set(error is CancellationError ? "cancelled" : "\(error)")
                    }
                }
                calls.append(CallRecord(id: id, box: box, task: task))
                // Waited for until it has stepped, queued or been answered.
                let entered = await settle(actor) { v in
                    v.stepped.contains(id) || notes.count("park") > parks || box.answer != nil
                }
                if !entered { failures.append("after `\(op)`: the call never entered the core") }
            } else {
                await actor.send(input)
            }
        case 22 ..< 34:
            let seq = nextSeq
            nextSeq += 1
            let retire = Int.random(in: 0 ..< 3, using: &random) == 0
            op = "startHold \(seq) owner \(owner) hold \(hold) retire \(retire)"
            deadlineAt[seq] = actor.clock.peek.nanoseconds + Int64(seq)
            await actor.send(.startHold(seq: seq, owner: owner, hold: hold, untilRetire: retire))
        case 34 ..< 52:
            guard let seq = view.pending.randomElement(using: &random) else { continue }
            op = "complete \(seq)"
            fixture.open("work \(seq)")
            if !(await notes.reach("done \(seq)")) { failures.append("after `\(op)`: done \(seq) never posted") }
        case 52 ..< 58:
            guard let seq = view.open.randomElement(using: &random) else { continue }
            guard let instant = deadlineAt[seq] else { continue }
            op = "deadline \(seq)"
            await advance(to: instant, view, op)
        case 58 ..< 63:
            guard let seq = view.open.randomElement(using: &random) else { continue }
            op = "cancel \(seq)"
            await actor.send(.cancel(seq: seq))
        case 63 ..< 67:
            // A caller's cancellation: answered once it is handled, whether it was queued
            // (withdrawn) or had already stepped (its reply finds no waiter).
            guard let call = calls.filter({ $0.box.answer == nil }).randomElement(using: &random) else { continue }
            op = "cancel call \(call.id)"
            call.task.cancel()
            let answered = await settle(actor) { _ in call.box.answer != nil }
            if !answered { failures.append("after `\(op)`: the cancelled call was never answered") }
        case 67 ..< 71:
            op = "end \(owner)"
            ends[owner, default: 0] += 1
            live.remove(owner)
            await actor.send(.end(owner))
        case 71 ..< 76:
            op = "start \(owner)"
            if !endedAll {
                // Over a live key, a supersede: it ends the old generation's scope.
                if live.contains(owner) { ends[owner, default: 0] += 1 }
                live.insert(owner)
            }
            await actor.send(.start(owner))
        case 76 ..< 81:
            let id = nextWork
            nextWork += 1
            op = "queue \(id) behind \(hold)"
            await actor.send(.queueBehind(id: id, hold: hold))
        case 81 ..< 85:
            guard let (tokenID, token) = tokens.randomElement(using: &random) else { continue }
            if Bool.random(using: &random) {
                op = "revoke \(tokenID)"
                await actor.send(.revoke(token, tokenID: tokenID))
            } else {
                op = "mark \(tokenID)"
                token.withdraw()
                await actor.send(.noteMarked(tokenID: tokenID))
            }
        case 85 ..< 91:
            // A timer's duration is far longer than a request's deadline.
            let seq = 1_000_000 + nextSeq
            nextSeq += 1
            op = "arm \(seq) on \(owner)"
            timerAt[seq] = actor.clock.peek.nanoseconds + Int64(seq)
            await actor.send(.arm(owner: owner, seq: seq))
        case 91 ..< 97:
            guard let (timerOwner, seq) = view.timers.randomElement(using: &random) else { continue }
            guard let instant = timerAt[seq] else { continue }
            op = "fire \(seq) on \(timerOwner)"
            await advance(to: instant, view, op)
        case 97, 98:
            op = "close"
            await actor.send(.close)
        default:
            // endAll is terminal: rarely, and only late in the run.
            guard step > operations * 3 / 4, !view.ended else { continue }
            op = "endAll"
            for key in [0, 1] { ends[key, default: 0] += 1 }
            live.removeAll()
            endedAll = true
            await actor.send(.endAll)
        }
        log.append(op)

        let after = await actor.view()
        failures += check(after, op: op, parkedBound: 6 + nextWork)
        if !failures.isEmpty {
            failures.append("seed \(seed), budget \(maxReleasesPerBatch), operation \(step); the last operations: \(log.suffix(12))")
            break
        }

        // A mailbox operation about a quarter of the time: a post now, a post whose wake is held
        // (released by a later mailbox operation, so a wake is in flight across operations), a
        // post at the next check's hold point, or a post from the next flush (between steps).
        if R.self != Never.self, Int.random(in: 0 ..< 4, using: &mailboxRandom) == 0 {
            let mail = nextMail
            nextMail += 1
            var mailOp: String
            switch Int.random(in: 0 ..< 5, using: &mailboxRandom) {
            case 0:
                mailOp = "post \(mail)"
                if actor.postNumber(mail) { accepted.insert(mail) }
            case 1:
                mailOp = "post \(mail), its wake held"
                let task = Task {
                    let posted = await actor.postNumberForTesting(mail, afterAppend: {
                        notes.post("appended \(mail)")
                        await fixture.wait("wake \(mail)")
                    })
                    // Refused (a full mailbox): no append, so no hold.
                    if !posted { notes.post("appended \(mail)") }
                    return posted
                }
                guard await notes.reach("appended \(mail)") else {
                    failures.append("post \(mail) never appended")
                    break
                }
                heldPosts.append((mail, task))
            case 2:
                mailOp = "post \(mail) at the next check"
                await actor.postAtNextCheck(mail)
            case 3:
                mailOp = "post \(mail) at the next flush"
                await actor.postAtNextFlush(mail)
            default:
                mailOp = "release a held wake"
                if !heldPosts.isEmpty {
                    let held = heldPosts.removeFirst()
                    fixture.open("wake \(held.mail)")
                    if await held.task.value { accepted.insert(held.mail) }
                    mailOp += " (\(held.mail))"
                }
            }
            log.append(mailOp)
            let mailboxView = await actor.view()
            failures += check(mailboxView, op: mailOp, parkedBound: 6 + nextWork)
            let known = accepted.union(mailboxView.selfPosted).union(heldPosts.map(\.mail))
            if let stray = mailboxView.mailStepped.first(where: { !known.contains($0) }) {
                failures.append("after `\(mailOp)`: mail \(stray) stepped, never accepted")
            }
            if !failures.isEmpty {
                failures.append("seed \(seed), budget \(maxReleasesPerBatch), operation \(step); the last operations: \(log.suffix(12))")
                break
            }
        }

        // A follow-up operation about a quarter of the time: arm (in a slot that may hold one
        // already, so some arms join) or consume. Armed ones step in later jobs, interleaved
        // with the operations that follow.
        if Int.random(in: 0 ..< 4, using: &followUpRandom) == 0 {
            let fuOwner = Int.random(in: 0 ... 1, using: &followUpRandom)
            let slot = Int.random(in: 0 ... 1, using: &followUpRandom)
            var fuOp: String
            if Int.random(in: 0 ..< 5, using: &followUpRandom) < 3 {
                let label = nextLabel
                nextLabel += 1
                fuOp = "arm follow-up \(label) on \(fuOwner)/\(slot)"
                await actor.send(.armFollowUp(owner: fuOwner, slot: slot, label: label))
            } else {
                fuOp = "consume follow-up \(fuOwner)/\(slot)"
                await actor.send(.consumeFollowUp(owner: fuOwner, slot: slot))
            }
            log.append(fuOp)
            failures += check(await actor.view(), op: fuOp, parkedBound: 6 + nextWork)
            if !failures.isEmpty {
                failures.append("seed \(seed), budget \(maxReleasesPerBatch), operation \(step); the last operations: \(log.suffix(12))")
                break
            }
        }
    }

    if failures.isEmpty {
        // Let every worker return, so every hold is released and what is queued or queued steps.
        let rest = await actor.view()
        for seq in rest.pending {
            fixture.open("work \(seq)")
            guard await notes.reach("done \(seq)") else {
                failures.append("done \(seq) never posted after its worker returned")
                break
            }
        }
        let drained = await settle(actor) { $0.stats.queued == 0 }
        // Every accepted mail steps once: release the held wakes, then wait for the mailbox.
        for held in heldPosts {
            fixture.open("wake \(held.mail)")
            if await held.task.value { accepted.insert(held.mail) }
        }
        heldPosts = []
        // A check's or a flush's post still due when no check or flush follows isn't made, and
        // isn't counted: only accepted posts are expected to step.
        // Both sides from one view: a flush's post made while settling is in the same view as
        // its step, or in neither.
        let mailboxSettled = await settle(actor) { Set($0.mailStepped) == accepted.union($0.selfPosted) }
        if !mailboxSettled {
            let view = await actor.view()
            failures.append("mailbox: accepted \(accepted.union(view.selfPosted).subtracting(view.mailStepped).sorted()) never stepped")
        }
        // Invariant 20: the wait returns once every follow-up stepped or closed.
        if !(await bounded({ await actor.waitForQuiescence() })) { failures.append("the follow-up wait returned false") }
        let final = await actor.view()
        failures += check(final, op: "the last completions", parkedBound: 6 + nextWork)
        if !drained { failures.append("parked inputs left after every hold was released: \(final.stats.queued)") }
        if final.pendingFollowUps != 0 { failures.append("\(final.pendingFollowUps) follow-ups pending after the wait returned") }
        // Invariant 14: a queued input steps, unless endAll dropped it.
        for id in final.queued.sorted() where !final.stepped.contains(id) && !final.droppedQueued.contains(id) {
            failures.append("queued work \(id) neither stepped nor dropped by endAll")
        }
    }
    // End everything (stopping the core's timer); every queued call is answered.
    if !(await actor.view()).ended { await actor.send(.endAll) }
    // One bound for every call of the seed: a regression that never answers them costs one
    // bound, not one per call.
    let tasks = calls.map(\.task)
    let ended = await withinTurnHangBound { () -> Bool in
        for task in tasks { await task.value }
        return true
    }
    if ended == nil {
        failures.append("a call's task never ended within the hang bound")
    }
    let final = await actor.view()
    // Invariant 10: each call answered once, and its answer matches whether it stepped.
    for call in calls {
        let answer = call.box.answer ?? "none"
        let stepped = final.stepped.contains(call.id)
        let refusals = ["\(TurnError.withdrawn)", "\(TurnError.closed)", "\(TurnError.queueFull)"]
        let consistent = (answer == "success \(call.id)" && stepped)
            || answer == "cancelled"  // withdrawn while queued, or stepped and no longer waited for
            || (refusals.contains(answer) && !stepped)
        if !consistent { failures.append("call \(call.id): answered \(answer), stepped \(stepped)") }
    }
    if final.stats.pendingWaiters != 0 { failures.append("\(final.stats.pendingWaiters) waiters left at the end") }
    if !failures.isEmpty, !failures.contains(where: { $0.hasPrefix("seed ") }) {
        failures.append("seed \(seed), budget \(maxReleasesPerBatch), at the end; the last operations: \(log.suffix(12))")
    }
    return failures
}

/// What must hold between any two operations.
func check(_ view: OrderView, op: String, parkedBound: Int) -> [String] {
    var failures: [String] = []
    if !view.violations.isEmpty { failures.append("after `\(op)`: \(view.violations)") }
    if view.stats.openRequests != view.open.count {
        failures.append("after `\(op)`: the core has \(view.stats.openRequests) open requests, the machine \(view.open.count)")
    }
    if view.stats.heldKeys != view.expectedHeld {
        failures.append("after `\(op)`: the core holds \(view.stats.heldKeys) keys, the machine expects \(view.expectedHeld)")
    }
    if view.stats.queued > parkedBound { failures.append("after `\(op)`: \(view.stats.queued) parked") }
    // Invariant 19, and the wait's count (invariant 20): the core's pending follow-ups are the
    // machine's, one per key and slot.
    if view.stats.pendingFollowUps != view.pendingFollowUps || view.pendingWork != view.pendingFollowUps {
        failures.append("after `\(op)`: the core has \(view.stats.pendingFollowUps) pending follow-ups (pendingWork \(view.pendingWork)), the machine \(view.pendingFollowUps)")
    }
    if view.ended, view.stats.liveKeys != 0 { failures.append("after `\(op)`: \(view.stats.liveKeys) live keys after endAll") }
    // Invariants 11 and 12: outputs leave before the next step, and only under a live key.
    if !view.lateFlushes.isEmpty { failures.append("after `\(op)`: \(view.lateFlushes)") }
    if view.delivered != view.expectedOutputs {
        failures.append("after `\(op)`: the sink got \(view.delivered.suffix(6)), the machine expects \(view.expectedOutputs.suffix(6))")
    }
    if view.stats.droppedOutputs != view.stepped.count - view.expectedOutputs.count {
        failures.append("after `\(op)`: \(view.stats.droppedOutputs) dropped outputs, the machine expects \(view.stepped.count - view.expectedOutputs.count)")
    }
    return failures
}

@Suite("Generated orders (§6.4)", .timeLimit(.minutes(3)))
struct GeneratedOrderTests {
    static var seeds: [UInt64] {
        let environment = ProcessInfo.processInfo.environment
        if let seed = environment["TURNS_SEED"].flatMap(UInt64.init) { return [seed] }
        let count = environment["TURNS_SEEDS"].flatMap(Int.init) ?? 32
        return (1 ... UInt64(count)).map { $0 }
    }

    /// Every third seed drains in small batches, so continuations interleave with operations.
    static func budget(for seed: UInt64) -> Int { seed % 3 == 0 ? 2 : 1_000 }

    @Test("Seeded orders keep the core's invariants and its counters match the machine's view", arguments: seeds)
    func seededOrder(seed: UInt64) async {
        let failures = await runOrder(seed: seed, operations: 300, maxReleasesPerBatch: Self.budget(for: seed))
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// The mailboxless twin (`Mail == Never`) on every fourth seed: the same operations
    /// without the mailbox's, so the driver's `!usesMailbox` branches keep the invariants too.
    @Test("Seeded orders keep the invariants on the mailboxless twin", arguments: seeds.filter { $0 % 4 == 2 })
    func mailboxlessOrder(seed: UInt64) async {
        let failures = await runOrder(seed: seed, operations: 300, maxReleasesPerBatch: Self.budget(for: seed), mail: Never.self)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Seeds that kill a known mutant, run by default at their own budget, each with the mutant
    /// it kills. 79: a supersede that doesn't withdraw the inputs queued under the old
    /// generation's scope (`Turn.start` without its `withdraw`).
    @Test("Fixed replays of seeds that kill a known mutant", arguments: [UInt64(79)])
    func replays(seed: UInt64) async {
        let failures = await runOrder(seed: seed, operations: 300, maxReleasesPerBatch: Self.budget(for: seed))
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}

/// Mail a mailbox check's hook posted, from a plain closure.
final class MailList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Int] = []

    func append(_ mail: Int) { lock.withLock { list.append(mail) } }

    var mail: [Int] { lock.withLock { list } }
}
