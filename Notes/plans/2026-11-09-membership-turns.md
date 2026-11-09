# Membership as turns: join, leave, disconnect grace and reattach

Status: open. The design for the whole membership lifecycle on the request → result-turn shape: all of #363 (joins and leaves no longer wait behind one player's resolvers) and #334 (keep a disconnected player for a grace period). Docs only, for Review and for the maintainer's choices (§ 9). Code lands as a PR series on `exp/membership-turns` (§ 8), which merges into `exp/next` as one reviewed merge PR when the series is done.

Revisions: 2 took in Review's first pass (CanJoin's view, M10; the admission as the session check, M6; parked-input order; a parked disconnect through the grace; the drain's unapplied `.join`). 3 took in the maintainer's **M1 (d), 2026-11-09: a leave never waits on external calls** (§ 4.3): there is no pending leave any more, and OnLeave's external work becomes a post-commit output. 4 takes in Review's phase check of 3: the output can't reach the keeper through a captured context, its start point is named, and it has no order and a per-land cap.

This note supersedes the leave-only draft (`docs/leave-as-turn` at 649e3fb8, never merged). The #334 note (`Notes/plans/2026-11-09-disconnect-grace.md`, PR #370) stays the record of the grace's decisions D1-D7 and of its public API and wire section (§ 9 there, approved by Main as additive); its mechanics (§ 5-8 there) are superseded by § 4-7 here.

Line numbers are from `exp/next` at 6a251cea.

## 1. Problem

**Joins and leaves wait behind one player's resolvers (#363).** `TransportAdapter.enqueueMembership` (`TransportAdapter.swift:2754-2763`) keeps one serial tail per adapter, so one per land. Every join (`admitJoin` → `performJoinQueued`, `:1989`, `:2004`) and every disconnect (`:1303-1314`) runs inside it, and inside it the keeper awaits:
- CanJoin's resolvers (`LandKeeper.swift:1524-1537`), with the player not yet chosen (CanJoin decides the player ID);
- the duplicate-login kick's `leave` (`:1564-1570`), OnLeave's resolvers included;
- OnJoin's resolvers (`:1618-1640`), with the entry already inserted (`:1586-1595`);
- on a tickless land, the OnJoin input's turn (`:1676-1688`);
- on a disconnect, `leave` (`:2255-2391`): OnLeave's resolvers (`:2306-2340`), then the `.leave` input's turn.

So one player's slow CanJoin, OnJoin or OnLeave resolver holds every other player's join and leave on that land, up to `RESOLVER_TIMEOUT_MS` (5 s by default, unbounded at 0). CLAUDE.md lists the join and leave resolvers among the paths not yet in turns.

**A disconnected player is gone at once (#334).** Every disconnect is a leave: OnLeave runs, and a reconnect seconds later is a new player.

## 2. What the membership queue guarantees, and how it's kept

The maintainer built the queue for this (`Notes/plans/2026-02-01-membership-queue-reconnect.md`): a land's joins and leaves in order, and a half-done leave never crossed by an immediate rejoin. The guarantees stay. What changes is how they're kept: a leave is one turn (it never waits), and a join's resolvers are per-player keeper state ticketed by the entry generation, instead of a held queue.

| Guarantee | Today | After |
|---|---|---|
| A land's membership inputs are taken in arrival order | The queue runs each operation to its end, resolvers included | The queue still submits every membership input in arrival order, and each operation ends at its first keeper turn. What follows a join (its resolvers, result turns, apply) is ordered by the keeper's per-player pending state and by the inputs' sequences |
| One player's join, leave and rejoin never cross | Each waits in the queue for the previous one to finish | A leave completes in its own turn, so there is nothing half-done for a rejoin to cross. A join's pending state (a pending join, or detached) is per player: an input that finds one waits as a parked input (§ 4.6) and applies after it. Each lifecycle input takes its sequence in its own turn, so the record has the live order |
| A late result never acts on a newer entry | — (nothing outlives the queue's await) | Every join request carries a ticket (the entry generation, plus the lifecycle input's sequence), and its result turn acts only when the keeper's pending state still holds that ticket |
| Other players aren't affected by one player's change | Not kept: they wait in the queue (#363) | Kept: another player's input finds no pending state of its own and proceeds |

What the queue itself still serializes, in arrival order: the adapter's per-connection state (connection generations, join attempts, inbound drains, session tickets, sync-lag entries, action-response tickets; `TransportAdapter.swift:1316-1350`), the membership invalidation, the submission of each membership input to the keeper, and the adapter's reactions to the keeper's membership outputs (§ 4.7).

## 3. The rules

The maintainer's phase-separated turn, on every membership path (CLAUDE.md § Reentrancy, `Notes/plans/2026-11-05-reentrancy-helpers.md`):

1. **Keeper state changes only inside a synchronous turn,** with no `await` between a check and the write it guards.
2. **Async work is a request.** It carries a ticket captured in the turn that issued it; its result comes back as a turn input, whose turn validates the ticket against the current state.
3. **What a turn produces outside the keeper is an output,** emitted after the turn commits: the transport's outputs, and (§ 4.3) a handler's post-commit work. The keeper never awaits an output inside a turn.
4. **A timer or task only enqueues an input.** It never reads or writes keeper state from its own task.

§ 5 applies them path by path.

## 4. The model

### 4.1 Per-player state

A player ID's membership state in the keeper:

```
none ──join──▶ joining ──OnJoin applied──▶ attached ──leave (one turn)──▶ none
                  │                          │  ▲
                  │ OnJoin failed            │  └──reattach (token)──┐
                  ▼                          ▼                       │
                none                      detached ──────────────────┘
                                             │
                                             └──grace expiry (the leave turn)──▶ none
```

- **joining:** a pending join: the entry is inserted (as today, before OnJoin's resolvers; `:1586-1595`) and its OnJoin is in flight (its resolvers, or its input not yet applied). Ticket: the new entry generation and the OnJoin input's sequence.
- **attached:** a member with a session.
- **detached:** a member without a session, within its grace (#334). It keeps its last client and session IDs and its token; a separate `detached` mark, not a nil client, so `isFirst` (`:1579`) doesn't treat a reattach as a first join.

There is no leaving state (M1 (d)): a leave ends the entry in the turn that receives it.

Before CanJoin decides the player ID, a join is keyed by its session and join attempt (the adapter's `JoinAttemptEnd`), not by player ID: a **pending CanJoin**. It holds no per-player state, because the player isn't known yet.

### 4.2 The inputs

Each membership change is a turn input, submitted by the adapter from its membership queue (or by the keeper's own timer, for the expiry):

| Input | Turn (one synchronous segment) | Request it may issue |
|---|---|---|
| **join** | Records the pending CanJoin; with no CanJoin resolvers, runs the CanJoin result turn below at once | CanJoin's resolvers |
| **CanJoin result** | Validates the join attempt (not ended by its budget, the session still connected); runs CanJoin's handler, which decides the player ID; then the per-player checks (§ 4.6); then, as today: `maxPlayers` (reconnection exempt), the newest-wins kick (the leave turn below, for the old entry, in this same segment), `isDraining`, the insert with a new entry generation, the transport's admission. Without OnJoin: attached. With OnJoin: takes the sequence, joining | OnJoin's resolvers |
| **OnJoin result** | Validates the ticket; success appends the `.join` input (resolver outputs, `resolvedAtTick`); failure removes the entry if still this join's (as `discardIfFailedJoin`, `:1695-1710`) | — |
| **disconnect** | Matches the entry (client ID, recorded session ID, generation). Grace on and the close eligible (#334 D2, D4 under its limit): detached, timer armed. Otherwise the leave below | — |
| **leave** | Matches the entry; removes it; cancels its generation's action jobs (`:2151`); takes the `.leave`'s sequence and appends the `.leave` input (the entry's client and session IDs, `resolvedAtTick`, no resolver outputs). On a tickless land the same turn applies it (OnLeave's handler, then `shouldSyncBroadcastOnly`); on a tick land it applies at the next tick, as every input does. Emits `playerLeft` and OnLeave's post-commit outputs after the commit | — (never) |
| **expiry** | Validates the entry generation and the `detached` mark (else a no-op); then the leave turn above, with the entry's last client and session IDs | — |
| **reattach** (a join with a token) | Its CanJoin result turn validates the token: the player ID, land and entry generation equal the current entry's, and the entry is still `detached`. Then it clears `detached`, takes a new generation, consumes the token and issues a new one, cancels the grace timer and counts the reattach (D4). OnJoin doesn't run. A token that doesn't fit makes it a fresh join | (CanJoin's resolvers, as any join) |

The **apply** of a `.join` input is unchanged: on a tickless land in the next input turn (or the legacy pass off in-turn sync), on a tick land in the next tick, in the pending-input order (`resolvedAtTick`, then sequence). It runs OnJoin's handler and ends joining (attached; a throwing handler discards, `:1695-1710`).

### 4.3 A leave never waits (M1 (d)): post-commit outputs

**The decision.** A leave, and OnLeave's handler, apply in the turn that receives it (on a tick land, at the next tick, like every input; no external wait either way). External work on a leave (saving stats, notifying a service) is a **post-commit output**: sent after the turn commits, never awaited by the keeper, its result never fed back into land state. This is Photon's model, where OnLeave can't defer. Among the frameworks surveyed, only Colyseus allows async leave hooks, and its reconnect bugs cluster there.

**The output API** (a design for Review; its scope is M11):

```swift
// In a handler, with `ctx: LandContext`: read what the work needs into values first.
let score = state.players[ctx.playerID]?.score ?? 0
ctx.afterCommit("saveScore", timeout: .seconds(5)) { out in
    // `out` is a PostCommitContext: values and services, not the land's context.
    try await out.services.get(StatsService.self)?.save(player: out.playerID, score: score)
}
```

- **What the closure gets:** a `PostCommitContext`, a value type with the land ID, the player, client and session IDs of the handler's context, a logger and the land's `LandServices`. Not `LandContext`: that carries the emit-event and sync-request handlers (`Land/LandContext.swift:143-149`), which write into the keeper's turn output, and `ctx.random`.
- **What it may capture:** the closure is `@Sendable` and escaping, so Swift refuses to capture the handler's `inout` state at compile time. That isn't the whole guarantee, though: `LandContext` is `Sendable` (`Land/LandContext.swift:12`), so the compiler does let the closure capture `ctx` itself. So:
  - the docs and every example read what the work needs into locals, and use the `PostCommitContext` argument, never `ctx`;
  - **`LandContext`'s handlers are turn-scoped.** A context carries its turn's token, closed when the turn commits. After that, `emitEvent`, `requestSyncNow` and `requestSyncBroadcastOnly` are no-ops that log once per land and count (`postCommitContextMisuse`). A closure that captured `ctx` anyway can't emit, request a sync, or reach keeper state from its task. The token holds no strong reference to the keeper, so a captured context doesn't keep a destroyed land alive (#350).
- **When it starts:** at the turn's post-commit point, the same one the turn's other outputs use. In order, for a turn: its handlers apply and the turn's sync phase runs (in-turn sync); its record is **submitted** to the recorder (`submitTurnRecord`'s enqueue, `LandKeeper.swift:4198-4202`; the record is ordered from then on, not yet durable); the `.turnRecord` hold point; then the transport outputs (`playerLeft`, `joinAdmitted`, `joinFailed`), then the turn's post-commit outputs, each started in its own task. The keeper doesn't wait for the record to be written before starting them, and never awaits them. Off in-turn sync (the legacy pass), the same point follows the pass's record submission. A turn whose handler throws discards that handler's outputs, like its other effects.
- **No order between outputs.** Each output runs in its own task, so two outputs (for one player, or two leaves in a row) can finish in either order: leave 1's `saveScore` can land after leave 2's. The keeper doesn't serialize them. A land whose external work must be ordered puts the order in the data (a version or sequence the service checks), not in the timing.
- **A per-land cap.** At most `POST_COMMIT_MAX_IN_FLIGHT_PER_LAND` (default 64; 0 removes it) outputs run at once for a land. Past it, an output isn't started: it is logged and counted (`postCommitRejected`), like the action caps' rejections. A leave flood can't make unbounded tasks. A gauge counts the outputs running (`postCommitInFlight`).
- **Errors and timeouts:** a thrown error or the timeout (per call, default `POST_COMMIT_TIMEOUT_MS`, 5000) is logged with the land, the label and the player, and counted (`postCommitFailures`, `postCommitTimeouts`, in the keeper's metrics and the transport profile). Never retried by the keeper.
- **At most once, live only.** It runs at most once per live apply (once, unless the cap rejected it). A process that stops after the commit and before the output starts loses it; a land that needs durability records the fact in its own state (an outbox the land reads later), not in the output.
- **Not recorded, and not re-executed on replay** (M7). In reevaluation mode `afterCommit` is a no-op. Since no output feeds back into land state, a replay's state equals live without them.
- **Destroy:** outputs already started keep running to their end or timeout; the land's destruction doesn't wait for them, and they hold no strong reference to the keeper (#350's release tests).

**`OnLeave(resolvers:)` on this branch: kept as unavailable shims.** Each `OnLeave(resolvers:…)` overload stays, marked `@available(*, unavailable, message: "OnLeave can't wait on external calls (#334, M1 (d)): read what you need in the handler and send it with ctx.afterCommit")`. A build that uses it fails with that message, which names the replacement. Removing the overloads instead would leave a call site with a generic "no matching overload" error and no hint. The shims cost nothing at run time and can be deleted once nothing uses them.

**Main stays as it is.** On `main` (the measured version) `OnLeave(resolvers:)`, the resolver-test land's leave resolver (`JoinCheckResolver`'s leave side, `RESOLVER_TEST_LEAVE_FAILURE_RATE`) and external-input-failure's `leave10` cell are unchanged. When `exp/membership-turns` reaches `main` later, that topic's leave cells, the resolver-test land and `docs/core/resolver.md` (its OnLeave rows) must change with it. Not now.

### 4.4 Requests always come back

Every join resolver request (CanJoin's, OnJoin's) ends on success, on a resolver failure, at the resolver deadline (the race returns at the deadline even when a resolver ignores cancellation, `ResolverExecutor.swift:107-160`), or on the keeper's cancellation at a drain. Each comes back as its result turn, so a pending state always ends. The exception is `RESOLVER_TIMEOUT_MS=0`, which disables the deadline: a resolver that never ends keeps its player's pending join forever. Today the same resolver holds the land's whole queue forever, so this is no worse; the code documents it.

### 4.5 Destroy and drain

The turn in which the land's destruction starts (`isDraining` set) ends every pending state synchronously, in that turn: it doesn't wait for result turns, since a draining land stops processing inputs and they may never run.
- A pending CanJoin or a pending join (joining): fails with `JoinError.landShuttingDown`; an inserted entry is removed (no OnLeave: OnJoin never applied), as today's `isDraining` guard does (`:1645-1652`). On a tick land, OnJoin's result turn may already have appended the `.join` input, not yet applied: the drain drops it from the pending inputs. The record holds only applied inputs (a turn records what it applied), so replay never sees a `.join` without its effects; its sequence is a gap.
- A detached entry: dropped without OnLeave, as a connected player is at a drain today; its grace timer is cancelled.
- Every parked input fails with `landShuttingDown`.
- Every outstanding request is cancelled. A result that arrives later finds no pending state with its ticket and is stale.
- Post-commit outputs already running are left to finish (§ 4.3).

**The empty-land timer** (`scheduleDestroyIfNeeded`, `:4584-4597`) guards only `players.isEmpty` today, and is armed at the end of `leave`. A pending CanJoin has no entry yet, so a timer can fire under it. The guard becomes `players.isEmpty`, no pending CanJoin or join, and no appended but unapplied `.leave` (a tick land's leave until its tick), and the turn that ends the last of them arms it (M5).

### 4.6 Waiting on a pending join (parked inputs)

An input for a player ID that is joining waits as a **parked input**: kept in the keeper, keyed by the player ID and in arrival order. Parking is keeper state written in a turn; nothing awaits across it, and the membership queue isn't held.
- **The re-run happens inside the turn that ends the pending join,** in park order, each parked input with all its checks re-run in that same segment; it isn't enqueued. A parked input that starts a new pending join stops the re-run there, and the rest stay parked behind it.
- **An input for a player ID with a non-empty parked list parks behind it,** even if no pending join exists at that moment. So a newer input never overtakes a parked one, and the player's inputs keep their arrival order.
- A disconnect or leave of a joining player (OnJoin's resolvers started, the entry inserted) parks until its OnJoin applies or fails (M2). A parked disconnect re-runs as the disconnect turn, not as a leave, so with the grace on it is grace-eligible like any disconnect of an attached player (#334 D2, D4). Under M2 (c), a disconnect while only CanJoin is pending doesn't park: it ends the join attempt, and the CanJoin result turn then writes nothing. The adapter's per-attempt state, the player slot allocated before the keeper join (`TransportAdapter.swift:1553`) included, is released by the disconnect's own teardown or on the `joinFailed` output for the attempt, whichever runs first; neither leaves a slot behind.
- A second join of a joining player parks until the first's OnJoin applies or fails, then runs as newest wins against it (M3).
- **CanJoin's view.** CanJoin runs before the player is known, so its resolvers and handler can run while that player's join is pending, and see the state before its OnJoin applies. Today a second join waits in the queue, so its CanJoin sees the state after. Which state a parked join's CanJoin decides on is M10. (A leave no longer creates such a window: it applies in its own turn, so a rejoin's CanJoin, arriving after it, sees the state after OnLeave on a tickless land; on a tick land, as today, after the tick that applies it.)

### 4.7 The keeper's membership outputs

What the adapter learns from the keeper is an output after the turn commits (rule 3), handled on the adapter's membership queue, and dropped when the entry generation it names isn't the one the adapter last admitted for that player:
- **joinAdmitted** (session, player, generation): the adapter registers the session, runs the initial sync and sends the join response (today's tail of `performJoinQueued`, `TransportAdapter.swift:2036-2095`).
- **joinFailed** (session, attempt, reason): the join response's error.
- **playerLeft** (player, generation): the slot release and the sync-cache clear, and for a detached player's expiry everything the adapter still held. Emitted after the leave turn commits. The player has no session by then, and the slot is read only to encode that player's own updates (`getPlayerSlot`, `TransportAdapter.swift:4651`, `:4936`, `:5343`), so on a tick land the release before the tick's apply is invisible, as today.

Today's in-turn admission (`admitJoiningSession`, `LandKeeperTransport.swift:117`; `noteJoinInputsConsumed`, `:123`) is a synchronous call into the transport inside the keeper's turn, on the executor they share (#69). It isn't an await, but it is a transport effect inside the turn (M6).

## 5. The rules, path by path

| Path | Rule 1 (state in turns) | Rule 2 (requests, tickets) | Rule 3 (outputs after commit) | Rule 4 (timers enqueue) |
|---|---|---|---|---|
| join and CanJoin | The join turn records the pending CanJoin; the CanJoin result turn checks, inserts and admits in one segment | CanJoin's resolvers; ticket: the session and join attempt | joinAdmitted, joinFailed | — |
| OnJoin | The OnJoin result turn appends or discards; the `.join` apply ends joining | OnJoin's resolvers; ticket: generation + sequence | joinAdmitted when the in-turn path completes (M6) | — |
| leave | One turn: removes, appends and (tickless) applies `.leave` | None: a leave never waits (M1 (d)) | playerLeft, the broadcast-only sync, OnLeave's `afterCommit` outputs | — |
| disconnect | The disconnect turn detaches or leaves | — | playerLeft (for a leave) | The grace timer is armed in the turn; it only enqueues the expiry input |
| expiry | The expiry turn checks generation and `detached`, then the leave turn | None | playerLeft, OnLeave's outputs | The timer captures the keeper weakly and enqueues; cancelled at drain |
| reattach | Its CanJoin result turn validates the token and reattaches in one segment | CanJoin's resolvers, as any join | joinAdmitted | Cancels the grace timer in the turn |
| empty-land timer | Armed by the turn that ends the last pending join or unapplied leave | — | — | Its fire only enqueues the destroy check, whose turn re-checks |
| post-commit outputs | Collected in the turn; they get a `PostCommitContext` (values and services), and a captured `LandContext` is closed at commit, so they never touch state or output | Not a request: no result comes back | Started at the post-commit point (after the record is submitted and the transport outputs), never awaited, capped per land | — |

## 6. Interleavings

"Held" means the land's membership queue waits. Today's column is what the code does at 6a251cea; "n/a" means today has no grace, so a disconnect is a leave. A row is acceptable only if the new outcome is equal or better. Where OnLeave's behavior differs from today, it is because `OnLeave(resolvers:)` no longer exists on this branch (M1 (d)); a land's OnLeave then reads nothing external before it applies.

**Same player**

| First, then | Today | After | Verdict |
|---|---|---|---|
| join, then join (newest wins) | The second waits in the queue for the first to finish; its CanJoin then sees the state after the first's OnJoin; its keeper join kicks the first (OnLeave inline) and inserts. OnJoin, OnLeave, OnJoin | The second's CanJoin resolvers and handler run at once; its result turn finds the player joining and parks (M3 (a)); when the first's OnJoin applies, it re-runs as newest wins: the leave turn for the first (OnLeave applied on a tickless land, appended on a tick land), then the insert. OnJoin, OnLeave, OnJoin | Changed: CanJoin's view (M10). Other players not held |
| join, then disconnect during CanJoin's resolvers | The disconnect waits in the queue for the join to finish: CanJoin, the insert, OnJoin, then the leave (OnLeave) | Under M2 (c) the disconnect ends the attempt; CanJoin's result turn writes nothing: no insert, no OnJoin, no OnLeave, nothing recorded | Changed (M2 (c)): no land handler had seen the player; under M2 (a), as today |
| join, then disconnect during OnJoin's resolvers | The disconnect waits in the queue for the join to finish, then leaves: OnJoin, OnLeave | The disconnect parks on the pending join (M2 (a) and (c)); after OnJoin applies, it runs: OnJoin, OnLeave | Equal |
| join, then disconnect during the join's resolvers, with the grace on | n/a | The parked disconnect re-runs as the disconnect turn: the now-attached player detaches (grace-eligible), and a reattach can follow | Better (#334) |
| leave, then join | The rejoin waits in the queue behind the whole leave, OnLeave's resolvers included; then CanJoin and OnJoin. On a tickless land CanJoin sees the state after OnLeave; on a tick land `leave` returns after the append, so CanJoin sees the state before the tick applies OnLeave | The leave completes in its turn. On a tickless land the rejoin's CanJoin sees the state after OnLeave, as today. On a tick land the leave's turn is the next tick (inputs apply at tick boundaries in `resolvedAtTick`, sequence order, which replay depends on): the rejoin's CanJoin sees the state before it, and its `.join` applies after the `.leave` by sequence, as today | Equal on both; no wait for OnLeave's external calls (there are none) |
| leave, then leave | The second finds no entry and returns (`:2258-2262`) | The second leave turn finds no entry: a no-op | Equal |
| disconnect → detached, then reattach | n/a (a new player: OnLeave, OnJoin) | The reattach's turn finds detached with its token's generation: reattached, no OnLeave, no OnJoin, firstSync | Better (the point of #334) |
| detached, then join without a token | n/a | Newest wins over the detached entry: the leave turn for it (OnLeave), then the insert (OnJoin) | Equal to today's reconnect |
| detached, expiry, then reattach | n/a | The expiry turn ends the entry; the reattach's turn finds no detached entry: a fresh join. OnLeave, OnJoin | Equal to today's reconnect |
| detached, reattach, then expiry | n/a | The reattach's turn took a new generation; the expiry turn sees a generation that isn't its own: a no-op | Better |
| reattach, then reattach (one token) | n/a | The first's turn consumes the token; the second's turn sees a consumed token: a fresh join, newest wins over the reattached entry | Equal to today's newest wins |
| reattach, then disconnect during its CanJoin | n/a | The disconnect matches no session of the entry yet (the reattach hasn't reached its turn), so the entry stays detached and its grace runs on. The reattach's CanJoin result turn then fails its admission (the session is gone, M6 (a)) before writing anything: the entry stays detached and the token unconsumed | Equal or better |

**Another player** (B's change while A's is pending)

| A's state | Today | After | Verdict |
|---|---|---|---|
| A's CanJoin or OnJoin resolvers | B's join and leave wait in the queue, up to the deadline | B's inputs find no pending state of B's and proceed | Better (#363) |
| A leaving (OnLeave's resolvers) | B waits in the queue, up to the deadline | No such state: A's leave is one turn | Better (#363) |
| A detached | n/a | B is unaffected | Equal |
| A's parked input | (today it would be in the queue, holding B) | B is unaffected | Better |
| A's post-commit outputs running | n/a | B is unaffected: outputs aren't awaited | Equal |

**Destroy and drain** (§ 4.5)

| State at the drain | Today | After | Verdict |
|---|---|---|---|
| A pending CanJoin or join | The join's `isDraining` checks fail it (`landShuttingDown`) after its resolvers return; the queue is held until then | The drain's turn fails it at once and removes an inserted entry; its later result is stale | Equal outcome, sooner |
| A leave in progress | OnLeave dropped if the drain started during its resolvers (`:2344-2352`, `onLeaveDropped`) | No leave is ever in progress across turns. A tick land's appended `.leave` is handled like any pending input at a drain, as today | Equal; `onLeaveDropped` can no longer come from a resolver |
| A detached entry | n/a | Dropped without OnLeave; timer cancelled | Equal to a connected player at a drain |
| A parked input | (in the queue: fails `landShuttingDown` when it runs) | Fails `landShuttingDown` in the drain's turn | Equal |
| The empty-land timer during a pending join | A pending CanJoin can see the land destroyed under it | Not armed while a join is pending | Better |
| Post-commit outputs running | n/a | They run to their end or timeout; the land is released without waiting | New, bounded by the timeout |

**What M1 (d) removed from revision 2:** the leaving state and `pendingLeaves`; the OnLeave request and its result turn; the parks on a pending leave (old M1, and the "leave, then join" park); the drain's dropping of pending leaves; the empty timer's hold on pending leaves (M5 simplified); M4 (the slot release's timing is now fixed by `playerLeft` after the leave turn, § 4.7); PR 1's interim wait inside the keeper join.

## 7. Record and replay

**No record format change** (M7).
- The recorded membership inputs stay today's lifecycle inputs: `.join` and `.leave` (`PendingLifecycleItem`, `:2354-2368`, `:1654-1667`), with their IDs, device ID, guest flag, metadata, resolver outputs and `resolvedAtTick`. A `.leave` on this branch has no resolver outputs (the field stays, empty). Replay applies them as today (`:3150-3196`).
- What isn't recorded, as today: CanJoin (a decision before any entry exists), the pending states and parked inputs (scheduling, not state), and, under #334 D3 (a), the detach and the reattach. The expiry's `.leave` carries the detached entry's last client and session IDs, so replay doesn't skip it (`:3174-3180`).
- **Post-commit outputs aren't recorded and aren't re-executed on replay** (§ 4.3): `afterCommit` is a no-op in reevaluation mode, and nothing it does reaches land state.
- Sequences are taken in the turns that take them today (the `.join`'s at the insert, the `.leave`'s at the removal). A parked input takes its sequence when it re-runs, after the change it waited on, so the record's order is the live one. A dropped input is a sequence gap, as today.
- **Tickless lands rely on the recorded passes.** Another player's join or action can apply before A's OnJoin although A's `.join` sequence is lower: A's join is pending while B's input is ready. Replay reproduces that order only because `exp/next` records each pass's inputs in apply order (record format 3.1, `ReevaluationTickFrame.passes`, #325, #321). On tick lands both live and replay sort by (`resolvedAtTick`, sequence), so they agree. (A leave no longer opens such a window.)
- The sync-stream record: a leave's `clear` marker and a join's `seed` marker are recorded by the adapter outside turns, as today; under #334, a detach records the `clear` and a reattach's firstSync the `seed`, with no `.join`/`.leave` between them (to confirm in code: the replay's sync-stream check must accept that pair).

## 8. The PR series

On `exp/membership-turns`, each PR reviewable alone, with its hold tests (`KeyedGates.freshKey()`, #358; each test in both in-turn sync modes, and the record tests with `recordsSyncStream` on and off). New keeper hold points are named per PR.

**PR 1: the leave as one turn, and post-commit outputs** (#363's leave half, M1 (d)). Now small.
- `submitLeave` and the leave turn; `OnLeave(resolvers:)` as unavailable shims; `ctx.afterCommit` with its metrics and its reevaluation no-op; `playerLeft`; the empty-timer guard on an unapplied `.leave`. The public `leave(...)` keeps its contract (M8).
- Tests: a leave applies in its own turn (tickless) or at the next tick (tick land), and another player's join and leave are never held by it; `afterCommit` starts after the record is submitted (hold at `.turnRecord`: the record is enqueued, no output started), isn't awaited (a held output doesn't hold the next turn), is logged and counted on a throw and on its timeout and not retried, isn't run in replay and isn't in the record; a closure that captures `ctx` and calls `ctx.emitEvent` and `ctx.requestSyncNow` after the commit: nothing reaches the turn output or the transport, and `postCommitContextMisuse` counts both; the per-land cap (past it, `postCommitRejected` counts and the output doesn't run); two outputs held on gates and released in reverse order finish in that order (no ordering is promised, and none is imposed); a land released while an output still runs (`waitUntilReleased`, #350); a stale `playerLeft` (hold the adapter's handling, let a fresh join of the same player complete, release: dropped, the new entry's slot stays); a tick land's sole player leaving with a short `destroyWhenEmptyAfter` (no destroy before the tick applies the `.leave`); record and replay of leaves with OnLeave handlers (0 mismatches, the `.leave` IDs as live).

**PR 2: the join** (#363's join half).
- The join, CanJoin-result and OnJoin-result turns; pending CanJoins and pending joins; parked inputs (§ 4.6); joinAdmitted and joinFailed; the join budget's end of a pending CanJoin (`JoinAttemptEnd`).
- Tests: parked order against a newer arrival (end the pending join while a newer same-player input is queued: the parked input applies first); a parked disconnect with the grace on (it detaches, not leaves; PR 3 adds this case to PR 2's test); CanJoin's view under the chosen M10; two same-player joins parked on one pending join (the first re-run admits as newest wins; the second re-runs against it, so OnLeave and OnJoin alternate correctly); every admission check re-run after a park (an entry inserted, `maxPlayers` reached, a drain started, or a new pending join from a kick, meanwhile); another player isn't held during A's CanJoin or OnJoin resolvers; join then disconnect during OnJoin's resolvers (parked, then OnJoin, OnLeave); join then disconnect during CanJoin's resolvers under the chosen M2 (with (c): nothing inserted, nothing recorded, the late CanJoin result stale, and no player slot or other per-attempt adapter state left behind); the join budget ending a pending CanJoin; a drain during a pending CanJoin and a pending join; a failing OnJoin (entry discarded, a parked disconnect then a no-op); the in-turn flip (#69) and join-pending phase (#224) unchanged; record and replay with non-commuting OnJoin handlers of two players whose resolvers finish out of order (replay `.passed`, as live); with in-turn sync off, a `joinAdmitted` for a session that is already gone: the adapter submits a disconnect input, which leaves (OnLeave) or, with the grace on, detaches (its own test: running the suite in both modes doesn't reach this path); a drain on a tick land with an appended but unapplied `.join`: the drain drops it from the pending inputs, the record shows its sequence as a gap, and replay matches.

**PR 3: the disconnect grace** (#334's detach and expiry).
- `LandConfig.reconnectGrace`, the close code through `onDisconnect`, the disconnect turn (detach or leave), the keeper's grace timer (enqueue-only), the expiry turn on PR 1's leave turn, D4's limit.
- Tests: a detach and an expiry (OnLeave with the last IDs, recorded, replayed with them); close kinds (a 4012 and a 1000 leave at once); the timer only enqueues (state unchanged while `.inputDrain` is held); a drain during the grace (timer cancelled, land released); the empty land with only detached players; the limit.

**PR 4: the reattach** (#334's token and wire).
- `reconnectToken` in the join and join response, per encoding (#334 note § 9), the reattach's validation in its CanJoin result turn, the new token.
- Tests: reattach vs expiry, both orders (held at `.graceExpiry` and at the reattach's CanJoin result); tokens that don't fit (consumed, another land, another player); two reattaches with one token; a disconnect during a reattach's join-pending phase; #360's round-trip with the token in every encoding; old and new client against old and new server; a reattach whose admission fails: hold at the reattach's CanJoin result, close its session, release; the entry stays detached, the token unconsumed, and the grace running (M6 (a)).

The series' order is M9.

## 9. Choices

**M1. Decided (d)** (the maintainer, 2026-11-09): a leave never waits on external calls; external work on a leave is a post-commit output (§ 4.3). Options (a) park, (b) refuse and (c) supersede, about a same-player join during a pending leave, are moot: there is no pending leave.

**M2. A disconnect (or leave) during a pending join.** (Open; Main is asking.)
- (a) It parks until the join's OnJoin applies or fails, then runs: OnJoin, then OnLeave, as today.
- (b) It cancels the pending join at any stage: no OnJoin, no OnLeave, the entry removed.
- (c) **Split by stage.** While only CanJoin is pending (no entry inserted, no OnJoin started), the disconnect cancels the join: its CanJoin result turn, when it comes, finds the attempt ended and writes nothing. Once OnJoin's resolvers have started (the entry is inserted), the disconnect parks until OnJoin applies or fails, then runs: OnJoin, then OnLeave.

**Recommended: (c).** Nothing of the land has seen the player before OnJoin starts, so cancelling there changes no handler's view and records nothing; after it, the outcome is today's. This is Colyseus's split (§ 10). (a) waits for a CanJoin that can no longer admit anyone; (b) would drop an OnJoin whose resolvers already ran.

**M3. A second join of a player whose first join is pending.**
- (a) **It parks until the first's OnJoin applies or fails,** then runs as newest wins: OnJoin, OnLeave, OnJoin, as today.
- (b) It supersedes the first: the first's pending join is cancelled (no OnJoin), and the second proceeds.

**Recommended: (a),** today's outcome. (b) is the same kind of semantic change as M2 (b).

**M4. Removed** by M1 (d): `playerLeft` is emitted after the leave turn commits, which is when the slot is released and the sync cache cleared (§ 4.7).

**M5. The empty-land timer** (simplified by M1 (d): only joins and a tick land's unapplied `.leave` remain to guard).
- (a) **Guard it with no pending CanJoin or join and no unapplied `.leave`,** armed by the turn that ends the last of them.
- (b) Arm it as today, and have its fire's turn re-check.

**Recommended: (a).**

**M6. The transport's in-turn admission.** Today's `admitJoiningSession` and `noteJoinInputsConsumed` are synchronous calls into the transport inside the keeper's turn, on their shared executor (#69).
- (a) **Keep them synchronous, in the turn,** as the transport's half of the same state change: they don't await, and the join-pending phase (#224) depends on the admission being atomic with the insert.
- (b) Make them outputs after the commit, like `playerLeft`.

**Recommended: (a),** with the reason written into the code: rule 3 forbids awaiting the transport inside a turn, and these don't. (b) would reopen the flip's atomicity (#69), which isn't this series' question. Under (a), two things are pinned:
- **The admission is also the session-still-connected check.** In the CanJoin result turn, `admitJoiningSession` runs before any keeper write in that segment (the insert, a reattach's clear of `detached`, the token's consumption). A failed admission (the session is gone) writes nothing: a fresh join ends as `joinFailed`, and a reattach leaves the entry exactly as it was, still detached, with its token unconsumed and its grace running. Tested in PR 4.
- **Off in-turn sync (the legacy path),** keeper and adapter don't share an executor, so there is no in-turn admission. There the admission is the `joinAdmitted` output, and an adapter that finds the session gone when it handles it submits a disconnect input for it. The series supports both modes, as the codebase does today (the CI matrix runs both): every PR's tests run in both.

**M7. The record format.**
- (a) **No change:** `.join` and `.leave` as today (a `.leave` without resolver outputs); pending states, parked inputs, the detach, the reattach and post-commit outputs not recorded (#334 D3 (a); § 4.3).
- (b) Record the detach and the reattach (#334 D3 (c)'s OnDisconnect and OnReconnect), a format minor bump.

**Recommended: (a)** for this series. (b) is its own decision, after.

**M8. The public `LandKeeper.join(...)` and `leave(...)`.**
- (a) **They keep their contracts** (return once the change is applied or failed), as a submit plus a wait on the change's sequence; only the adapter uses the submit-only forms. This mirrors `handleActionEnvelope` over `submitAction` (`:2399-2441`).
- (b) They return after their first turn.

**Recommended: (a).** 18 test and example files call `leave(...)`, and more call `join(...)`, expecting today's return point.

**M9. The series' order** (re-checked after M1 (d)).
- (a) **Leave, join, grace, reattach.** The leave PR is now small and self-contained (one turn, `afterCommit`, `playerLeft`), and the grace's expiry and the join's newest-wins kick both build on its leave turn; the reattach needs the join path.
- (b) Join, leave, grace, reattach.
- (c) Join with the leave folded in, then grace, then reattach: one PR fewer, but the join PR (the largest) grows.

**Recommended: (a).** The small PR first gives the join PR a finished leave turn to call, and with no pending leave there's no interim wait between PR 1 and PR 2 any more.

**M10. Which state a parked join's CanJoin decides on** (Review's must-fix). CanJoin's resolvers and handler run before the player is known, so they can run while that player's join is pending (§ 4.6).
- (a) **On the re-run, CanJoin's handler runs again** in the re-run turn, on the state after the change it waited on, with the resolvers' outputs kept (no second resolver run). A handler that now picks another player ID or rejects is followed (the join re-parks or fails). Only the resolvers' external reads are earlier than today.
- (b) The first decision stands: the handler's view is the state before the change. Documented as a difference from today.

In both, the record is the same as today: CanJoin isn't recorded, and the applied `.join` and `.leave` keep their live order (§ 7), so replay sees the same order. The difference is only which live state CanJoin's handler read.

**Recommended: (a),** the closest to today, at no second resolver run.

**M11. Where `ctx.afterCommit` is available** (new with M1 (d)).
- (a) **In OnLeave only,** in this series: it replaces what `OnLeave(resolvers:)` did, and nothing else changes.
- (b) In every handler (actions, client events, OnJoin, OnLeave, ticks): the general pattern for fire-and-forget external work.

**Recommended: (a)** for this series, with the API built so that (b) is a later, separate decision with no redesign: the same `afterCommit`, opened to more handlers.

## 10. Prior art

How established frameworks handle each choice, from pinned sources: Colyseus `Room.ts` at [18ccca0](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts), Nakama `match_handler.go` at [4833594](https://github.com/heroiclabs/nakama/blob/48335942699609b8742393f33495b2c8a4d79c47/server/match_handler.go), Netcode for GameObjects (NGO) `NetworkConnectionManager.cs` at [d7534e5](https://github.com/Unity-Technologies/com.unity.netcode.gameobjects/blob/d7534e55b1305ba435c58738bdff29f33f00be37/com.unity.netcode.gameobjects/Runtime/Connection/NetworkConnectionManager.cs), and the Unreal Engine and Photon documentation for the APIs named. Line links are to those files.

| Choice | What others do | Bearing |
|---|---|---|
| Async admission, sync leave (M1 (d)) | Async admission is common: Unreal `AGameModeBase::PreLoginAsync`, NGO's pending `ConnectionApprovalResponse`, Photon plugins' `BeforeJoin` with `Defer()`, Colyseus `onAuth`. An async leave is rare: only Colyseus allows it, and Photon forbids deferral in `OnLeave` | Supports a join on resolvers and a leave that never waits |
| M2, a disconnect during a pending join | Colyseus cancels during `onAuth` ([L1821](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L1821), [L1899](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L1899); the client isn't in `clients` until [L1902](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L1902), so no leave hook runs), and during `onJoin` waits, then runs `onLeave` (`early_leave`, [L1922](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L1922), [L1933](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L1933)). Nakama drops a queued attempt when its context is done. NGO doesn't clear `ClientsToApprove` on a disconnect, so a late add for a gone client is possible | (c) is Colyseus's split; the ticket check is what avoids NGO's late add |
| M3, a second join during a pending one | Newest wins in outcome: Nakama's `single_socket`, Colyseus closing the stale socket. Colyseus [#950](https://github.com/colyseus/colyseus/issues/950): a deferred close of the old socket killed the reconnected client, fixed with a generation check (`client.ref === ref`) | (a) newest wins after the first settles, with the entry generation as the check; against superseding (b) |
| Release at leave (old M4) | Synchronous release at leave: NGO ([L1391-1596](https://github.com/Unity-Technologies/com.unity.netcode.gameobjects/blob/d7534e55b1305ba435c58738bdff29f33f00be37/com.unity.netcode.gameobjects/Runtime/Connection/NetworkConnectionManager.cs#L1391-L1596)), Nakama ([L552-558](https://github.com/heroiclabs/nakama/blob/48335942699609b8742393f33495b2c8a4d79c47/server/match_handler.go#L552-L558)), Colyseus ([L2410](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L2410)). On reconnect Colyseus resends full state ([L2359-2366](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L2359-L2366)) rather than reuse a delta baseline | `playerLeft` releases after the leave turn; a reattach gets a firstSync, as Colyseus does |
| M5, the empty-land timer | Colyseus `#_disposeIfEmpty` requires no reserved seats and no `onLeave` in flight ([L2252-2258](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L2252-L2258)), and a seat reservation re-arms the timer ([L2201](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L2201)). Nakama counts presences only ([L316-319](https://github.com/heroiclabs/nakama/blob/48335942699609b8742393f33495b2c8a4d79c47/server/match_handler.go#L316-L319)), so it can end a match with an accepted, not yet applied join | (a) matches Colyseus |
| M6, the in-turn admission | NGO approves in one call (`HandleConnectionApproval`, [L1012-1130](https://github.com/Unity-Technologies/com.unity.netcode.gameobjects/blob/d7534e55b1305ba435c58738bdff29f33f00be37/com.unity.netcode.gameobjects/Runtime/Connection/NetworkConnectionManager.cs#L1012-L1130)); Nakama likewise ([L512-520](https://github.com/heroiclabs/nakama/blob/48335942699609b8742393f33495b2c8a4d79c47/server/match_handler.go#L512-L520)). Colyseus buffers until the client's join acknowledgement, then sends full state; Colyseus [#917](https://github.com/colyseus/colyseus/issues/917): a stale cached full state was sent to a joiner | (a): admission and the first snapshot in the same turn as the insert |
| M7, recording membership | Colyseus, Nakama and NGO don't record membership for replay. Photon Quantum carries presence in its per-tick input flags | (a): the existing `.join`/`.leave` recording is already stricter than all but Quantum |
| M8, when a join returns | Colyseus sends its join confirmation after `onJoin` resolves ([L1964](https://github.com/colyseus/colyseus/blob/18ccca0ec931bb941d74d2578d668ebf7096f35f/packages/core/src/Room.ts#L1964)); Nakama acknowledges before `MatchJoin` runs ([L391](https://github.com/heroiclabs/nakama/blob/48335942699609b8742393f33495b2c8a4d79c47/server/match_handler.go#L391), [L395](https://github.com/heroiclabs/nakama/blob/48335942699609b8742393f33495b2c8a4d79c47/server/match_handler.go#L395)) | (a) is Colyseus's order |
| M10, CanJoin's view on a re-run | NGO applies a stored approval unchanged ([L890-928](https://github.com/Unity-Technologies/com.unity.netcode.gameobjects/blob/d7534e55b1305ba435c58738bdff29f33f00be37/com.unity.netcode.gameobjects/Runtime/Connection/NetworkConnectionManager.cs#L890-L928)). Colyseus [#678](https://github.com/colyseus/colyseus/issues/678): `maxClients` not respected | (a) is stricter than all: the decision is re-made on the current state |
| The grace (#334) | Grace windows: about 10-30 s in Colyseus's examples, 300 s in Unreal (`InactivePlayerStateLifeSpan`). No framework caps reattaches on the server; Colyseus caps retries only in its client SDK (15 retries, 5 s minimum uptime). Colyseus [#962](https://github.com/colyseus/colyseus/issues/962): one bad token ended the grace timer; [#354](https://github.com/colyseus/colyseus/issues/354): reconnecting by session ID could be spoofed | A server-side reattach limit (D4) goes further than others; checking the ticket before any state change and a new token per attach answer #962 and #354 |

## 11. Out of scope

- A cap on abandoned join and OnInitialize resolvers (only actions are capped today; the 11-08 resolver review's finding (b)). Post-commit outputs have their own per-land cap from PR 1 (§ 4.3).
- OnInitialize's and the destroy handlers' resolvers.
- Buffering `.player` events during a grace; an explicit leave message.
- On `main`: `OnLeave(resolvers:)`, the resolver-test land's leave resolver and external-input-failure's `leave10` cell stay until this branch reaches `main` (§ 4.3).
