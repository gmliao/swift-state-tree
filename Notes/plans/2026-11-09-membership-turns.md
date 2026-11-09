# Membership as turns: join, leave, disconnect grace and reattach

Status: open. The design for the whole membership lifecycle on the request → result-turn shape: all of #363 (joins and leaves no longer wait behind one player's resolvers) and #334 (keep a disconnected player for a grace period). Docs only, for Review and for the maintainer's choices (§ 9, M1-M10). Revision 2 takes in Review's first pass: CanJoin's view (M10), the admission as the session check (M6), parked-input order, a parked disconnect through the grace, and the drain's unapplied `.join`. Code lands as a PR series on `exp/membership-turns` (§ 8), which merges into `exp/next` as one reviewed merge PR when the series is done.

This note supersedes the leave-only draft (`docs/leave-as-turn` at 649e3fb8, never merged); Review's pass on that draft is folded in. The #334 note (`Notes/plans/2026-11-09-disconnect-grace.md`, PR #370) stays the record of the grace's decisions D1-D7 and of its public API and wire section (§ 9 there, approved by Main as additive); its mechanics (§ 5-8 there) are superseded by § 4-7 here.

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

The maintainer built the queue for this (`Notes/plans/2026-02-01-membership-queue-reconnect.md`): a land's joins and leaves in order, and a half-done leave never crossed by an immediate rejoin. The guarantees stay. What changes is how they're kept: by per-player state in the keeper, ticketed by the entry generation, instead of by holding the queue across a resolver's await.

| Guarantee | Today | After |
|---|---|---|
| A land's membership inputs are taken in arrival order | The queue runs each operation to its end, resolvers included | The queue still submits every membership input in arrival order, and each operation ends at its first keeper turn. What follows (resolvers, result turns, applies) is ordered by the keeper's per-player pending state and by the inputs' sequences |
| One player's join, leave and rejoin never cross | Each waits in the queue for the previous one to finish | A player ID has at most one pending membership change in the keeper (a pending join, a pending leave, or detached). An input that finds one waits as a parked input (§ 4.5) and applies after it. Each lifecycle input takes its sequence in its own turn, so the record has the live order |
| A late result never acts on a newer entry | — (nothing outlives the queue's await) | Every request carries a ticket (the entry generation, plus the lifecycle input's sequence), and its result turn acts only when the keeper's pending state still holds that ticket |
| Other players aren't affected by one player's change | Not kept: they wait in the queue (#363) | Kept: another player's input finds no pending state of its own and proceeds |

What the queue itself still serializes, in arrival order: the adapter's per-connection state (connection generations, join attempts, inbound drains, session tickets, sync-lag entries, action-response tickets; `TransportAdapter.swift:1316-1350`), the membership invalidation, the submission of each membership input to the keeper, and the adapter's reactions to the keeper's membership outputs (§ 4.6).

## 3. The rules

The maintainer's phase-separated turn, on every membership path (CLAUDE.md § Reentrancy, `Notes/plans/2026-11-05-reentrancy-helpers.md`):

1. **Keeper state changes only inside a synchronous turn,** with no `await` between a check and the write it guards.
2. **Async work is a request.** It carries a ticket captured in the turn that issued it; its result comes back as a turn input, whose turn validates the ticket against the current state.
3. **What a turn produces for the transport is an output,** emitted after the turn commits. The keeper never awaits the transport inside a turn.
4. **A timer or task only enqueues an input.** It never reads or writes keeper state from its own task.

§ 5 applies them path by path.

## 4. The model

### 4.1 Per-player state

A player ID's membership state in the keeper:

```
none ──join──▶ joining ──OnJoin applied──▶ attached ──disconnect, no grace──▶ leaving ──.leave applied/dropped──▶ none
                  │                          │  ▲
                  │ OnJoin failed            │  └──reattach (token)──┐
                  ▼                          ▼                       │
                none                      detached ──────────────────┘
                                             │
                                             └──grace expiry──▶ leaving
```

- **joining:** a pending join: the entry is inserted (as today, before OnJoin's resolvers; `:1586-1595`) and its OnJoin is in flight (its resolvers, or its input not yet applied). Ticket: the new entry generation and the OnJoin input's sequence.
- **attached:** a member with a session.
- **detached:** a member without a session, within its grace (#334). It keeps its last client and session IDs and its token; a separate `detached` mark, not a nil client, so `isFirst` (`:1579`) doesn't treat a reattach as a first join.
- **leaving:** a pending leave: the entry is removed and its OnLeave is in flight (its resolvers, or its `.leave` not yet applied). Ticket: the removed entry's generation and the `.leave`'s sequence.

Before CanJoin decides the player ID, a join is keyed by its session and join attempt (the adapter's `JoinAttemptEnd`), not by player ID: a **pending CanJoin**. It holds no per-player state, because the player isn't known yet.

### 4.2 The inputs

Each membership change is a turn input, submitted by the adapter from its membership queue (or by the keeper's own timer, for the expiry):

| Input | Turn (one synchronous segment) | Request it may issue |
|---|---|---|
| **join** | Records the pending CanJoin; with no CanJoin resolvers, runs the CanJoin result turn below at once | CanJoin's resolvers |
| **CanJoin result** | Validates the join attempt (not ended by its budget, the session still connected); runs CanJoin's handler, which decides the player ID; then the per-player checks (§ 4.5); then, as today: `maxPlayers` (reconnection exempt), the newest-wins kick (as a leave input of the old entry, which this join then waits on, § 4.5), `isDraining`, the insert with a new entry generation, the transport's admission. Without OnJoin: attached. With OnJoin: takes the sequence, joining | OnJoin's resolvers |
| **OnJoin result** | Validates the ticket; success appends the `.join` input (resolver outputs, `resolvedAtTick`); failure removes the entry if still this join's (as `discardIfFailedJoin`, `:1695-1710`) | — |
| **disconnect** | Matches the entry (client ID, recorded session ID, generation). Grace on and the close eligible (#334 D2, D4 under its limit): detached, timer armed. Otherwise the leave below | — |
| **leave** | Matches the entry; removes it; cancels its generation's action jobs (`:2151`); takes the `.leave`'s sequence; with no OnLeave resolvers appends the `.leave` at once; otherwise leaving | OnLeave's resolvers |
| **OnLeave result** | Validates the ticket; success appends the `.leave` (outputs, `resolvedAtTick`); failure or the deadline drops it (logged, `onLeaveDropped`, a sequence gap, as `:2330-2338`) | — |
| **expiry** | Validates the entry generation and the `detached` mark (else a no-op); then the leave turn above, with the entry's last client and session IDs | OnLeave's resolvers |
| **reattach** (a join with a token) | Its CanJoin result turn validates the token: the player ID, land and entry generation equal the current entry's, and the entry is still `detached`. Then it clears `detached`, takes a new generation, consumes the token and issues a new one, cancels the grace timer and counts the reattach (D4). OnJoin doesn't run. A token that doesn't fit makes it a fresh join | (CanJoin's resolvers, as any join) |

The **apply** of a `.join` or `.leave` input is unchanged: on a tickless land in the next input turn (or the legacy pass off in-turn sync), on a tick land in the next tick, in the pending-input order (`resolvedAtTick`, then sequence). The `.join` apply runs OnJoin's handler and ends joining (attached; a throwing handler discards, `:1695-1710`). The `.leave` apply runs OnLeave's handler, sets `shouldSyncBroadcastOnly` (`:3193`) and ends leaving.

### 4.3 Requests always come back

Every resolver request ends on success, on a resolver failure, at the resolver deadline (the race returns at the deadline even when a resolver ignores cancellation, `ResolverExecutor.swift:107-160`), or on the keeper's cancellation at a drain. Each comes back as its result turn, so a pending state always ends. The exception is `RESOLVER_TIMEOUT_MS=0`, which disables the deadline: a resolver that never ends keeps its player's pending state forever. Today the same resolver holds the land's whole queue forever, so this is no worse; the code documents it.

### 4.4 Destroy and drain

The turn in which the land's destruction starts (`isDraining` set) ends every pending state synchronously, in that turn: it does not wait for result turns, since a draining land stops processing inputs and they may never run (Review's point on the leave-only draft).
- A pending CanJoin or a pending join (joining): fails with `JoinError.landShuttingDown`; an inserted entry is removed (no OnLeave: OnJoin never applied), as today's `isDraining` guard does (`:1645-1652`). On a tick land, OnJoin's result turn may already have appended the `.join` input, not yet applied: the drain drops it from the pending inputs. The record holds only applied inputs (a turn records what it applied), so replay never sees a `.join` without its effects; its sequence is a gap, as a dropped leave's is.
- A pending leave (leaving): dropped, counted with `onLeaveDropped`, as today (`:2344-2352`).
- A detached entry: dropped without OnLeave, as a connected player is at a drain today; its grace timer is cancelled.
- Every parked input fails with `landShuttingDown`.
- Every outstanding request is cancelled. A result that arrives later finds no pending state with its ticket and is stale.

**The empty-land timer** (`scheduleDestroyIfNeeded`, `:4584-4597`) guards only `players.isEmpty` today. A leave removes its entry before OnLeave's resolvers return, so a timer armed there could destroy the land before the `.leave` is recorded. The guard becomes `players.isEmpty` and no pending state (no pending CanJoin, join or leave), and the turn that ends the last pending state arms it (M5, § 9).

### 4.5 Waiting on a pending state (parked inputs)

An input for a player ID that has a pending state of another kind waits as a **parked input**: it is kept in the keeper, keyed by the player ID and in arrival order. Parking is keeper state written in a turn; nothing awaits across it, and the membership queue isn't held (M1, § 9).
- **The re-run happens inside the turn that ends the pending state,** in park order, each parked input with all its checks re-run in that same segment; it isn't enqueued. A parked input that starts a new pending state (a re-run join that goes joining, or kicks) stops the re-run there, and the rest stay parked behind it.
- **An input for a player ID with a non-empty parked list parks behind it,** even if no pending state exists at that moment. So a newer input never overtakes a parked one, and the player's inputs keep their arrival order.
- A join (or a newest-wins join) whose CanJoin result turn finds the player leaving parks until the `.leave` is applied or dropped. Its re-run checks everything again: the entry (none, attached, or detached), newest wins, `maxPlayers`, `isDraining`, and that no other pending state for the ID exists (a kick may have started a new one).
- A disconnect or leave of a joining player parks until its OnJoin applies or fails (M2). A parked disconnect re-runs as the disconnect turn, not as a leave, so with the grace on it is grace-eligible like any disconnect of an attached player (#334 D2, D4).
- A second join of a joining player parks until the first's OnJoin applies or fails, then runs as newest wins against it (M3).
- **CanJoin's view.** CanJoin runs before the player is known, so its resolvers and handler run while another change of that player may be pending, and see the state before that change's OnJoin or OnLeave applies. Today a rejoin or second join waits in the queue, so its CanJoin sees the state after. Which state a parked join's CanJoin decides on is M10 (§ 9): under M10 (a) its handler re-runs in the re-run turn, on the state after the change, with its resolver outputs kept; under M10 (b) the earlier decision stands.

### 4.6 The keeper's membership outputs

What the adapter learns from the keeper is an output after the turn commits (rule 3), handled on the adapter's membership queue, and dropped when the entry generation it names isn't the one the adapter last admitted for that player:
- **joinAdmitted** (session, player, generation): the adapter registers the session, runs the initial sync and sends the join response (today's tail of `performJoinQueued`, `TransportAdapter.swift:2036-2095`).
- **joinFailed** (session, attempt, reason): the join response's error.
- **playerLeft** (player, generation): the slot release and the sync-cache clear (M4), and for a detached player's expiry everything the adapter still held.

Today's in-turn admission (`admitJoiningSession`, `LandKeeperTransport.swift:117`; `noteJoinInputsConsumed`, `:123`) is a synchronous call into the transport inside the keeper's turn, on the executor they share (#69). It isn't an await, but it is a transport effect inside the turn (M6).

## 5. The rules, path by path

| Path | Rule 1 (state in turns) | Rule 2 (requests, tickets) | Rule 3 (outputs after commit) | Rule 4 (timers enqueue) |
|---|---|---|---|---|
| join and CanJoin | The join turn records the pending CanJoin; the CanJoin result turn checks, inserts and admits in one segment | CanJoin's resolvers; ticket: the session and join attempt | joinAdmitted, joinFailed | — |
| OnJoin | The OnJoin result turn appends or discards; the `.join` apply ends joining | OnJoin's resolvers; ticket: generation + sequence | joinAdmitted when the in-turn path completes (M6) | — |
| leave | The leave turn removes and appends (or goes leaving); the OnLeave result turn appends or drops | OnLeave's resolvers; ticket: generation + sequence | playerLeft, the broadcast-only sync | — |
| disconnect | The disconnect turn detaches or leaves | — | playerLeft (for a leave) | The grace timer is armed in the turn; it only enqueues the expiry input |
| expiry | The expiry turn checks generation and `detached`, then the leave turn | OnLeave's resolvers, as a leave | playerLeft | The timer captures the keeper weakly and enqueues; cancelled at drain |
| reattach | Its CanJoin result turn validates the token and reattaches in one segment | CanJoin's resolvers, as any join | joinAdmitted | Cancels the grace timer in the turn |
| empty-land timer | Armed by the turn that ends the last pending state | — | — | Its fire only enqueues the destroy check, whose turn re-checks |

## 6. Interleavings

"Held" means the land's membership queue waits. Today's column is what the code does at 6a251cea; "n/a" means today has no grace, so a disconnect is a leave. A row is acceptable only if the new outcome is equal or better.

**Same player**

| First, then | Today | After | Verdict |
|---|---|---|---|
| join, then join (newest wins) | The second waits in the queue for the first to finish; its CanJoin (resolvers and handler) then sees the state after the first's OnJoin; its keeper join kicks the first (OnLeave inline) and inserts. OnJoin, OnLeave, OnJoin | The second's CanJoin resolvers and handler run at once; its result turn finds the player joining and parks (M3 (a)); when the first's OnJoin applies, it re-runs as newest wins: a leave of the first, then it parks on that leave, then inserts. OnJoin, OnLeave, OnJoin | Changed: CanJoin's view. Under M10 (a) the handler re-runs on the state after the first's OnJoin, as today; only its resolvers read earlier. Under M10 (b) it decided on the state before. Other players not held |
| join, then disconnect during the join's resolvers | The disconnect waits in the queue for the join to finish, then leaves: OnJoin, OnLeave | The disconnect parks on the pending join (M2 (a)); after OnJoin applies, it runs: OnJoin, OnLeave | Equal |
| join, then disconnect during the join's resolvers, with the grace on | n/a | The parked disconnect re-runs as the disconnect turn: the now-attached player detaches (grace-eligible), and a reattach can follow | Better (#334) |
| leave (OnLeave resolvers), then join | The rejoin waits in the queue behind the whole leave; then CanJoin (on the state after OnLeave) and OnJoin. OnLeave, OnJoin | The rejoin's CanJoin resolvers and handler run at once; its result turn finds the player leaving and parks (M1 (a)); after the `.leave` applies, it re-runs and inserts. OnLeave, OnJoin | Changed: CanJoin's view. Under M10 (a) the handler re-runs on the state after OnLeave, as today (a ban flag OnLeave sets is seen); only its resolvers read earlier. Under M10 (b) it decided before OnLeave. Other players not held |
| leave, then leave | The second finds no entry and returns (`:2258-2262`) | The second leave turn finds no entry: a no-op | Equal |
| disconnect → detached, then reattach | n/a (a new player: OnLeave, OnJoin) | The reattach's turn finds detached with its token's generation: reattached, no OnLeave, no OnJoin, firstSync | Better (the point of #334) |
| detached, then join without a token | n/a | Newest wins over the detached entry: a leave of it (OnLeave), the join parks on that leave, then inserts (OnJoin) | Equal to today's reconnect |
| detached, expiry, then reattach | n/a | The expiry turn ends the entry (leaving); the reattach's turn finds no detached entry: a fresh join, parked on the pending leave. OnLeave, OnJoin | Equal to today's reconnect |
| detached, reattach, then expiry | n/a | The reattach's turn took a new generation; the expiry turn sees a generation that isn't its own: a no-op | Better |
| reattach, then reattach (one token) | n/a | The first's turn consumes the token; the second's turn sees a consumed token: a fresh join, newest wins over the reattached entry | Equal to today's newest wins |
| reattach, then disconnect during its CanJoin | n/a | The disconnect matches no session of the entry yet (the reattach hasn't reached its turn), so the entry stays detached and its grace runs on. The reattach's CanJoin result turn then fails its admission (the session is gone, M6 (a)) before writing anything: the entry stays detached and the token unconsumed | Equal or better |

**Another player** (B's change while A's is pending)

| A's pending state | Today | After | Verdict |
|---|---|---|---|
| A's CanJoin or OnJoin resolvers | B's join and leave wait in the queue, up to the deadline | B's inputs find no pending state of B's and proceed | Better (#363) |
| A's OnLeave resolvers | Same | Same | Better (#363) |
| A detached | n/a | B is unaffected | Equal |
| A's parked input | (today it would be in the queue, holding B) | B is unaffected | Better |

**Destroy and drain** (§ 4.4)

| Pending state at the drain | Today | After | Verdict |
|---|---|---|---|
| A pending CanJoin or join | The join's `isDraining` checks fail it (`landShuttingDown`) after its resolvers return; the queue is held until then | The drain's turn fails it at once and removes an inserted entry; its later result is stale | Equal outcome, sooner |
| A pending leave | Dropped after its resolvers return (`onLeaveDropped`) | Dropped in the drain's turn, counted the same | Equal outcome, sooner |
| A detached entry | n/a | Dropped without OnLeave; timer cancelled | Equal to a connected player at a drain |
| A parked input | (in the queue: fails `landShuttingDown` when it runs) | Fails `landShuttingDown` in the drain's turn | Equal |
| The empty-land timer during a pending state | Armed only after `leave`'s resolvers; a pending CanJoin can see the land destroyed under it | Not armed while any pending state exists | Better |

## 7. Record and replay

**No record format change** (M7).
- The recorded membership inputs stay today's lifecycle inputs: `.join` and `.leave` (`PendingLifecycleItem`, `:2354-2368`, `:1654-1667`), with their IDs, device ID, guest flag, metadata, resolver outputs and `resolvedAtTick`. Replay applies them as today (`:3150-3196`).
- What isn't recorded, as today: CanJoin (a decision before any entry exists), the pending states and parked inputs (scheduling, not state), and, under #334 D3 (a), the detach and the reattach. The expiry's `.leave` carries the detached entry's last client and session IDs, so replay doesn't skip it (`:3174-3180`).
- Sequences are taken in the turns that take them today (the `.join`'s at the insert, the `.leave`'s at the removal). A parked input takes its sequence when it re-runs, after the change it waited on, so the record's order is the live one. A dropped input is a sequence gap, as today.
- **Tickless lands rely on the recorded passes.** Another player's join or action can now apply before A's `.leave` although A's leave sequence is lower: A's leave is pending while B's input is ready. Replay reproduces that order only because `exp/next` records each pass's inputs in apply order (record format 3.1, `ReevaluationTickFrame.passes`, #325, #321). This is a change from today, where the queue held B's join (not B's actions), and the passes are what keep it replay-safe. On tick lands both live and replay sort by (`resolvedAtTick`, sequence), so they agree.
- The sync-stream record: a leave's `clear` marker and a join's `seed` marker are recorded by the adapter outside turns, as today; under #334, a detach records the `clear` and a reattach's firstSync the `seed`, with no `.join`/`.leave` between them (to confirm in code: the replay's sync-stream check must accept that pair).

## 8. The PR series

On `exp/membership-turns`, each PR reviewable alone, with its hold tests (`KeyedGates.freshKey()`, #358; each test in both in-turn sync modes, and the record tests with `recordsSyncStream` on and off). New keeper hold points are named per PR.

**PR 1: the pending-state core and the leave** (#363's leave half).
- `pendingLeaves`, the leave and OnLeave-result turns, the parked list per player ID (in PR 1 only the interim wait uses it), the drain's synchronous ending of pending leaves, the empty-timer guard, `playerLeft`. The public `leave(...)` keeps its contract (M8).
- Joins are still awaited in the queue in this PR; a same-player join that meets a pending leave waits inside its keeper join (the interim, and the only `await` across a pending state in the series; removed in PR 2).
- Tests: another player isn't held during A's OnLeave resolvers; a same-player rejoin waits and applies after OnLeave; a failing, timed-out and cancellation-ignoring OnLeave resolver (dropped, counted, the waiter proceeds); a drain while a leave is pending, held at `.leaveResolved` so the drain's own path ends it (dropped, counted, the waiter fails, the land released); the empty timer held by a pending leave; a stale result; two same-player joins waiting on one pending leave (one admits, the other kicks it as newest wins); the public `leave(...)` returns after the apply; a stale `playerLeft`: hold the adapter's handling of A's `playerLeft`, let a fresh join of A complete, then release: the notification names an older generation and is dropped, and the new entry's slot stays; record and replay on a tickless land with B joining and acting during A's pending leave, with non-commuting handlers (A's OnLeave and B's OnJoin both append to one list in state): replay `.passed`, with B's entries before A's leave, as live.

**PR 2: the join** (#363's join half).
- The join, CanJoin-result and OnJoin-result turns; pending CanJoins and pending joins; parked inputs (§ 4.5) replacing PR 1's interim wait; joinAdmitted and joinFailed; the join budget's end of a pending CanJoin (`JoinAttemptEnd`).
- Tests: parked order against a newer arrival (end the pending state while a newer same-player input is queued: the parked input applies first); a parked disconnect with the grace on (it detaches, not leaves; PR 3 adds this case to PR 2's test); CanJoin's view under the chosen M10 (a handler reading a flag OnLeave sets); two same-player joins parked on one pending leave (the first re-run admits; the second re-runs as newest wins against it, so OnLeave and OnJoin alternate correctly); every admission check re-run after a park (an entry inserted, `maxPlayers` reached, a drain started, or a new pending state from a kick, meanwhile); another player isn't held during A's CanJoin or OnJoin resolvers; join then join (newest wins, parked, then kicks); join then disconnect during OnJoin's resolvers (parked, then OnJoin, OnLeave); the join budget ending a pending CanJoin; a drain during a pending CanJoin and a pending join; a failing OnJoin (entry discarded, a parked disconnect then a no-op); the in-turn flip (#69) and join-pending phase (#224) unchanged; record and replay with non-commuting OnJoin handlers of two players whose resolvers finish out of order.

**PR 3: the disconnect grace** (#334's detach and expiry).
- `LandConfig.reconnectGrace`, the close code through `onDisconnect`, the disconnect turn (detach or leave), the keeper's grace timer (enqueue-only), the expiry turn on PR 1's leave path, D4's limit.
- Tests: a detach and an expiry (OnLeave with the last IDs, recorded, replayed with them); close kinds (a 4012 and a 1000 leave at once); the timer only enqueues (state unchanged while `.inputDrain` is held); a drain during the grace (timer cancelled, land released); the empty land with only detached players; the limit.

**PR 4: the reattach** (#334's token and wire).
- `reconnectToken` in the join and join response, per encoding (#334 note § 9), the reattach's validation in its CanJoin result turn, the new token.
- Tests: reattach vs expiry, both orders (held at `.graceExpiry` and at the reattach's CanJoin result); tokens that don't fit (consumed, another land, another player); two reattaches with one token; a disconnect during a reattach's join-pending phase; #360's round-trip with the token in every encoding; old and new client against old and new server.

The series' order is itself a choice (M9).

## 9. Open choices (for the maintainer, one at a time)

**M1. A same-player join while that player's leave is pending.**
- (a) **It parks** (§ 4.5), and re-runs every check after the `.leave` applies or drops. The queue isn't held (PR 2 on; PR 1's interim waits inside the keeper join).
- (b) It is refused with a retryable error (`JOIN_IN_PROGRESS`), and the client retries.
- (c) It supersedes the pending leave. Not viable: the entry is removed and its jobs cancelled, and a dropped OnLeave can't be undone.

**Recommended: (a).** Today's order (OnLeave, then OnJoin) without holding anyone else and without a client change.

**M2. A disconnect (or leave) during a pending join.**
- (a) **It parks until the join's OnJoin applies or fails,** then runs: OnJoin, then OnLeave, as today.
- (b) It cancels the pending join: no OnJoin, no OnLeave, the entry removed.

**Recommended: (a).** It's today's outcome. (b) saves work, but changes what a land's handlers see and what is recorded; it would be its own decision.

**M3. A second join of a player whose first join is pending.**
- (a) **It parks until the first's OnJoin applies or fails,** then runs as newest wins: OnJoin, OnLeave, OnJoin, as today.
- (b) It supersedes the first: the first's pending join is cancelled (no OnJoin), and the second proceeds.

**Recommended: (a),** today's outcome. (b) is the same kind of semantic change as M2 (b).

**M4. When the adapter releases a left player's slot and clears its sync cache.**
- (a) **On `playerLeft`,** after the leave turn commits. The player has no session by then, and the slot is read only to encode that player's own updates (`getPlayerSlot`, `TransportAdapter.swift:4651`, `:4936`, `:5343`), so the release is invisible before the `.leave` applies. On tick lands this is already today's order.
- (b) After the `.leave` applies.

**Recommended: (a).** Review checked it on the leave-only draft: no row gets worse.

**M5. The empty-land timer and pending states.**
- (a) **Guard it with no pending state,** armed by the turn that ends the last one.
- (b) Arm it as today, and have its fire's turn re-check for pending states.

**Recommended: (a).** The timer never runs while a change is pending; (b) starts early and must re-check every time.

**M6. The transport's in-turn admission.** Today's `admitJoiningSession` and `noteJoinInputsConsumed` are synchronous calls into the transport inside the keeper's turn, on their shared executor (#69).
- (a) **Keep them synchronous, in the turn,** as the transport's half of the same state change: they don't await, and the join-pending phase (#224) depends on the admission being atomic with the insert.
- (b) Make them outputs after the commit, like `playerLeft`.

**Recommended: (a),** with the reason written into the code: rule 3 forbids awaiting the transport inside a turn, and these don't. (b) would reopen the flip's atomicity (#69), which isn't this series' question. Under (a), two things are pinned:
- **The admission is also the session-still-connected check.** In the CanJoin result turn, `admitJoiningSession` runs before any keeper write in that segment (the insert, a reattach's clear of `detached`, the token's consumption). A failed admission (the session is gone) writes nothing: a fresh join ends as `joinFailed`, and a reattach leaves the entry exactly as it was, still detached, with its token unconsumed and its grace running. Tested in PR 4: hold at the reattach's CanJoin result, close its session, release.
- **Off in-turn sync (the legacy path),** keeper and adapter don't share an executor, so there is no in-turn admission. There the admission is the `joinAdmitted` output, and an adapter that finds the session gone when it handles it submits a disconnect input for it. The series supports both modes, as the codebase does today (the CI matrix runs both): every PR's tests run in both.

**M7. The record format.**
- (a) **No change:** `.join` and `.leave` as today; pending states, parked inputs, the detach and the reattach not recorded (#334 D3 (a)).
- (b) Record the detach and the reattach (#334 D3 (c)'s OnDisconnect and OnReconnect), a format minor bump.

**Recommended: (a)** for this series. (b) is its own decision, after.

**M8. The public `LandKeeper.join(...)` and `leave(...)`.**
- (a) **They keep their contracts** (return once the change is applied or failed), as a submit plus a wait on the change's sequence; only the adapter uses the submit-only forms. This mirrors `handleActionEnvelope` over `submitAction` (`:2399-2441`).
- (b) They return after their first turn.

**Recommended: (a).** 18 test and example files call `leave(...)`, and more call `join(...)`, expecting today's return point.

**M9. The series' order.**
- (a) **Leave, join, grace, reattach.** The leave is the smaller change and builds the pending-state core the join then extends; the grace needs the leave path; the reattach needs the join path.
- (b) Join, leave, grace, reattach.

**Recommended: (a).** PR 1's interim (a same-player join waiting inside the keeper join) exists only between PR 1 and PR 2, on `exp/membership-turns`, never on `exp/next`.

**M10. Which state a parked join's CanJoin decides on** (Review's must-fix). CanJoin's resolvers and handler run before the player is known, so they can run while another change of that player is pending (§ 4.5).
- (a) **On the re-run, CanJoin's handler runs again** in the re-run turn, on the state after the change it waited on, with the resolvers' outputs kept (no second resolver run). A handler that now picks another player ID or rejects is followed (the join re-parks or fails). Only the resolvers' external reads are earlier than today.
- (b) The first decision stands: the handler's view is the state before the change. Documented as a difference from today.

In both, the record is the same as today: CanJoin isn't recorded (it decides before any entry exists), and the applied `.leave` and `.join` keep their live order (§ 7), so replay sees the same order. The difference is only which live state CanJoin's handler read.

**Recommended: (a),** the closest to today, at no second resolver run.

## 10. Out of scope

- A cap on abandoned join, leave and OnInitialize resolvers (only actions are capped today; the 11-08 resolver review's finding (b)).
- OnInitialize's and the destroy handlers' resolvers.
- Buffering `.player` events during a grace; an explicit leave message.
