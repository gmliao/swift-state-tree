# #852: which join the player cap refuses on a duplicate login (options)

**Status:** options note for the maintainer, one decision. Read at main 7baba4c4, without the LSP. No code changes here.

`LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` at main 7baba4c4.

## 1. The bug, in one paragraph

A land with `maxPlayers = 2` holds P1 and P2. P1 logs in again from a new client (a duplicate login). In `joinReportingAdmission` (LK:2017), the cap check skips P1 because P1 is still in `players` (a reconnection). Then the join kicks P1's old session: `await leave(...)`. `leave` removes P1's old entry at once, then suspends in its OnLeave resolvers or, on a tickless land, in `awaitInputTurn`. While it is suspended, P3 joins: the count is 1, so P3 passes the cap and is inserted. Then P1's join resumes and inserts P1 without checking the cap again. The land holds 3 players. That is check-then-act across an `await`, the class the CLAUDE.md reentrancy rule names.

## 2. Who can reach it today

- **A client, through the transport: no.** Every transport join, from the adapter or from the router, goes through `TransportAdapter.admitJoin`, which runs the whole keeper join inside the adapter's membership queue (`enqueueMembership`, TransportAdapter.swift:3071). It awaits `keeper.joinReportingAdmission` (:2253) before the next queued join or disconnect starts. P3's join waits behind P1's rejoin, kick included. I checked the callers: `joinReportingAdmission` has one caller outside the keeper (the adapter), and `admitJoin` has three (the adapter twice, `LandRouter` once).
- **Server code that calls the keeper's public `join(session:clientID:sessionID:services:)`** (LK:1984) while clients join through the transport: yes. That call doesn't go through the adapter's queue. The repository's own callers are `ReevaluationRunner` and `HashCostBenchmark`, and neither runs next to transport joins.
- **The other public `join(playerID:clientID:sessionID:services:)`** (LK:1871) has the same kick and no cap check at all. That is a separate, older gap. It is listed here so the fix doesn't miss it, and it is out of this decision.
- **After K2 and K6.** If K2 retires the adapter's membership queue in favor of the keeper's turns, the window opens to clients, unless K6 has closed it first (§4).

So the issue's `priority: before-release` label is worth a second look: by Main's rule ("deferred unless a client can hit it in practice"), this is `deferred`. The fix is small either way (§5).

## 3. The decision: which join the cap refuses

### (a) The returning player keeps the place; the newcomer is refused (recommended)

- **The rule.** A duplicate login holds its player's place across the kick. While P1's rejoin is in flight, P1 still counts toward the cap, so P3 sees a full land and gets `JoinError.roomIsFull`.
- **For a player.**
  - The player who switches device, or reconnects after a network change, always gets back in.
  - A newcomer sees "room full", which is what they would have seen a moment before and a moment after. The place was never really free: its owner was moving it to a new connection.
- **It matches the plan.** #700's K6 row already says "`maxPlayers` (reconnection exempt)", with the kick and the insert in one step (§4). (a) is that behavior, made true across today's await.
- **Prior art.** This is the reserved-seat pattern. A server that lets a player reconnect keeps their seat reserved, and counts reserved seats in the capacity check. Colyseus, for example, counts its reserved seats in `hasReachedMaxClients` while a client may reconnect (`allowReconnection`).
- **Cost.** One model field: the set of players whose rejoin holds a place. It is set in the segment that checks, cleared on every exit of the join, and counted by the cap check.

### (b) The newcomer keeps the place; the rejoin is refused

- **The rule.** J3 (the segment after the kick, §5) re-checks the cap with no reconnection exemption. P3 took the place, so P1's rejoin is refused with `roomIsFull`.
- **For a player.**
  - The returning player loses their place entirely. Their old session was already kicked, and OnLeave already ran, so their player is gone from the state. Their new session is refused. From their side: "I logged in from my phone, and both my PC and my phone are out of the game".
  - The newcomer gets in.
- **It conflicts with the plan.** K6's "reconnection exempt" would flip this behavior back later.
- **Cost.** One re-check, the smallest change of the three.

### Other shapes, not recommended

- **(c) Replace the old entry in place, now.** Don't remove P1's entry on a duplicate login: rebind it to the new client, and issue the old session's OnLeave without awaiting it. Then no place is ever free. This is K6's shape (#588). Today it would change what a duplicate login does to the game state (today OnLeave removes the player, then OnJoin adds them back), so it belongs to K6 with #588's other join changes, not to a bug fix.
- **(d) Serialize all joins in the keeper.** Move the adapter's membership queue into the keeper, so the public `join` waits behind it too. That closes this window and every other check-then-act in join, but it is K2's job (membership changes as turns). Done now, it duplicates the adapter's queue.
- **(e) Leave it until K6, with a doc line.** No client can reach it today (§2). The public `join`'s doc says the cap isn't held across a concurrent duplicate login. This is the cheapest option, but it leaves a known overshoot in a public API.

## 4. How it ends in the plan

- **K1b-5** (`2026-11-25-k1b5-turn-bodies-and-segments.md` §3.1) splits the join at its awaits and names the segments:
  - J2, the decision: CanJoin's handler, the stale-join refusal, the cap check, then the kick;
  - J3, the insert, after the kick's await.

  K1b-5 changes no behavior, so it doesn't close #852 by itself.
- **K2:** J3 becomes the kick's completion, a turn input. The re-check (b), or the release of the held place (a), runs in that turn.
- **K6** (#588): the join is one step. The kick is a membership change in the step, and the old OnLeave is a request under `.land`. Nothing frees the place between the check and the insert, so (a)'s field goes away. (a) is K6's behavior early. (b) would be undone by K6.

## 5. Where the fix goes (today's code)

**(a):**
- In J2, when `isReconnection` is true and the player has an old session to kick: insert `playerID` into the held set, before `await leave(...)`.
- The cap check counts `players.count + heldForRejoin.count`, not counting a player who appears in both (the held player's own entry is gone during the kick, and is back after the insert).
- In J3, in the same segment as `players[playerID] = …`: remove `playerID` from the held set. Every exit of the join removes it too, with a `defer` that checks the join's own generation: a throw from `leave`, the `isDraining` refusal, a later OnJoin failure.
- Use a generation (`GenerationTable`) ticket, not the bare key. A second duplicate login of the same player must not clear the first one's hold (CLAUDE.md: "never remove keyed state by key alone from a callback that can outlive its instance").

**(b):**
- In J3, in the same segment as the insert: `if let maxPlayers, players.count >= maxPlayers { throw JoinError.roomIsFull }`, with no exemption.

**Either way:**
- The public `join(playerID:…)` (LK:1871) gets the same treatment only if the maintainer wants that overload capped at all (§2). Today it ignores the cap.

## 6. The test (`HoldPoints` / `TestGate`, no timing)

This shape avoids the issue's draft problem: a tickless land's `.inputDrain` hold also holds P3's own OnJoin.

- **Land:** a tick land, `maxPlayers = 2`. OnLeave declares one resolver, and that resolver awaits a `TestGate`. Its OnJoin has no resolvers, so a join on a tick land returns once it is inserted, without waiting for a tick.
- **Steps:**
  1. Join P1 and P2, and step one tick.
  2. Start P1's second join (a new client ID) in a task. Wait until the gate has an arrival. P1's old entry is removed, and the kick is suspended in the OnLeave resolver.
  3. Join P3, and await its result.
  4. Open the gate, and await P1's rejoin.
- **Assertions:**
  - always: `players.count <= 2`;
  - under (a): P3 throws `JoinError.roomIsFull`, and P1's rejoin succeeds with its new client ID;
  - under (b): P3 succeeds, and P1's rejoin throws `JoinError.roomIsFull`;
  - today: both succeed, and `players.count == 3`, so the test fails on main.
- **Controls:**
  - the same land without an OnLeave resolver: the kick doesn't suspend, P3 is refused, and the count stays 2;
  - (a) only: P1's rejoin fails during the kick (the resolver throws). The hold is released, and a later P3 join succeeds;
  - (a) only: two duplicate logins of P1 in a row, the second while the first is held. The first's exit must not clear the second's hold.
- **Mutants:**
  - (a): the `defer` that clears the hold is dropped (the failure control fails);
  - (a): the hold is cleared by key, not by ticket (the double-login control fails);
  - (b): the re-check is placed before the `await` instead of after it (the main test fails).

## 7. Recommendation

- **The policy: (a).** The returning player keeps the place, and the newcomer is refused. It is what a player expects, it is the reserved-seat pattern, and it is the behavior K6 will have.
- **The timing: a small PR now, not K6.**
  - The public `join` reaches the bug today.
  - The fix is one field, its ticket and a few lines in J2 and J3, plus §6's test.
  - It doesn't touch K1b's moves: the field joins `KeeperModel` with the other join facts.

  If the maintainer would rather not add a field that K6 deletes, (e) is the fallback: relabel `deferred`, add the doc line, and K6's test takes §6's assertions under (a).
- **The label:** `deferred` by Main's rule, since no client can reach it through the transport (§2), whichever policy is chosen.
