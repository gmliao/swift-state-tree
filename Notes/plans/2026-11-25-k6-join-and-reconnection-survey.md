# K6 survey: the join in one step, duplicate logins and reconnection (#700, #588, #852)

**Status:** survey, not a plan. Read-only, no code changes. Read at main 73f44915, without the LSP. It prepares K6's plan: what K6 changes, how #852's fix carries into it, what other servers do, and the questions the maintainer decides before the plan is written. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` at that commit.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md`: §3.4's join and leave rows, §5's K6 row, §6.2's K6 tests, §8's K6 row;
- issue #588 (validate a join in the turn that applies it);
- the #852 options note `2026-11-25-852-duplicate-login-cap-options.md`. Its option (a), the returning player keeps the place, is being implemented as a small PR; it isn't on main yet, so this survey cites the note's design (§5 there);
- the K2 plan draft 3 `2026-11-25-k2-cut-over-onto-the-turn-core.md` §7.1 (the adapter's membership queue).

## 1. Two things called "reconnection"

The word covers two different events. The survey keeps them apart, because today's code handles only the first.

- **A duplicate login.** A player joins while their old session is still in `players`. This happens when a player switches devices, or when the old connection is half-open: the client is gone, but the server hasn't seen the close yet.
  - Today the join treats it as a reconnection: `isReconnection = players[playerID] != nil` (LK:2069), and the `maxPlayers` check skips it (LK:2071).
  - The join then kicks the old session with `try await leave(…)` (LK:2088; the public `join` at LK:1884). The old session's OnLeave runs, including its resolvers, and only then does the new session's OnJoin run. The state sees a leave and then a join.
- **A drop, then a rejoin.** The connection closes, and the player joins again later.
  - Today there is no window. The adapter's disconnect path calls `keeper.leave` at once (TransportAdapter.swift:1273–1312). OnLeave runs and the player is removed. A later join is a first join: the cap applies, and OnJoin runs as for a newcomer.
  - The docs tell a client to read the first sync after a rejoin to see whether an earlier action took effect (land-dsl.md, "After a rejoin, use the firstSync state").

So "seat reservation" in the sense other servers use (a place held after a drop) doesn't exist today. #852's hold (§3) covers only the duplicate login.

## 2. What K6 changes (parent §5's K6 row, §3.4, #588)

| Part of the join | Today | After K6 |
|---|---|---|
| `CanJoin` | runs when the join is taken in, before the join's resolvers; its state check can be stale by the time OnJoin applies (#588) | `validate` with `ValidateContext`, in the step that applies the join, reading the current state. It returns a plan that `OnJoin` receives (agreed with the maintainer 2026-11-18) |
| `OnJoin` | applies in a later segment | `apply`, in the same step as `validate` |
| CanJoin's and OnJoin's resolvers | awaited inside `join` | requests under `.entry(PlayerID, EntryID)` (K5's keyed requests). A rejoin ends the old key, which closes its requests; that replaces the generation checks |
| The `maxPlayers` check | in J2, before the kick's await; J3 inserts after it without checking again (#852) | in the one step, with the insert. Nothing frees or takes a place between the check and the insert |
| The duplicate-login kick | `try await leave(…)` between the check and the insert | in the join's step: the membership change, then the old entry's OnLeave as a request under `.land`, not closed by the old entry's end (parent §3.4) |
| The stale-join refusal (#234) and the draining guard | in separate segments | in the one step |
| Refusals | several forms, depending on where the join was refused | one form, whichever check refuses; a refused join is recorded (#588) |
| #548 | — | the join's resolver is held, the land torn down, the resolver released with `.allow`: no membership, slot, joining record or connection generation is left (plus the in-turn variant) |

**What it needs first:** K2 (steps), K5 (resolvers as keyed requests), and #852's fix landed, so its tests carry over (§3).

**What it lets go:** once the join is one step, the transport adapter's membership queue is no longer what keeps #852 closed (K2 §7.1). An adapter slice may retire it after K6.

## 3. How #852's hold carries into K6

**#852 (a), as designed** (#852 note §5):
- While a duplicate login's kick is in flight, the returning player holds their place: the cap counts `players.count` plus the held set, without double-counting a player who appears in both.
- The hold is set in J2, before the kick's await. It is released in J3, in the same segment as the insert, and on every other exit of the join.
- It is keyed by a `GenerationTable` ticket, not by the player alone, so a second duplicate login doesn't clear the first one's hold.

**In K6, the field goes away; the rule stays.**
- K6 runs the check, the kick's membership change and the insert in one step. No await sits between them, so no window exists for the hold to cover. The held set, its ticket and its releases are deleted.
- The rule the hold enforces stays true by construction: a returning player never loses their place to a newcomer during their own rejoin.
- #852's test (the gated OnLeave resolver, P3 refused, P1's rejoin admitted, the count never above the cap) becomes one of K6's tests unchanged. Under K6 the old OnLeave's resolver runs as a request after the step, so the gate no longer opens a window, and the test checks that.

**If K6 also adds a reconnection window (K6-Q1 (b) or (c)), the hold returns in a new form.** A seat held after a drop is a place that a disconnected player holds, which is #852's rule again, over a longer time:
- a model fact, `reservedSeats: [PlayerID: (entry: EntryID, until: tick or deadline)]`;
- counted by the cap, as the held set is;
- ended by a core timer (#762) or by the player's return.

So the code doesn't carry over, but the rule does: **a player who holds a place counts toward the cap**, whether the place is held across a kick (#852) or across a drop (a window).

## 4. Prior art

**Colyseus** (a Node.js room server; sources read 2026-11-25):
- **The window.** A room calls `allowReconnection(client, seconds)` inside `onDrop()` "to hold the client's seat". The seconds expire on their own; `"manual"` holds the seat until the room's code calls `.reject()` ([docs.colyseus.io/room/reconnection](https://docs.colyseus.io/room/reconnection)).
- **The hooks.** `onDrop` runs on a non-consented drop. If the client returns in time, `onReconnect()` runs; if the window expires, `onLeave()` runs. A consented leave (`room.leave()`) skips `onDrop` and goes straight to `onLeave` (same page).
- **The cap counts held seats.** `hasReachedMaxClients()` in Room.ts returns `(this.clients.length + Object.keys(this._reservedSeats).length) >= this.#_maxClients || …DISPOSING`. Its doc: "the sum of connected clients and reserved seats". Reserved seats cover joins in flight; that reconnection holds are stored there too is inferred from `checkReconnectionToken` reading the same table ([github.com/colyseus/colyseus, packages/core/src/Room.ts](https://github.com/colyseus/colyseus/blob/master/packages/core/src/Room.ts)).
- **The reservation timeout** is `seatReservationTimeout`, default 15 seconds (`COLYSEUS_SEAT_RESERVATION_TIME`); `setSeatReservationTime` is deprecated (same file).

**Nakama** (Heroic Labs' game server; sources read 2026-11-25):
- **Duplicate logins at the socket.** The `session.single_socket` option allows one socket per user; older sessions are disconnected. It defaults to `false` ([heroiclabs.com/docs/nakama/getting-started/configuration](https://heroiclabs.com/docs/nakama/getting-started/configuration/)). That is today's kick, at the connection level rather than the match level.
- **No built-in window.** In an authoritative match, the match handler's `MatchJoinAttempt` decides admission, and the docs leave reconnection to the handler: "In the case of disconnects you can decide to temporarily reserve their seat" ([heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative](https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/)). The page doesn't say what happens when a user who is already a presence joins again.

**What they show:**
- The two events are separate mechanisms in both servers: a duplicate-login policy (Nakama's `single_socket`, today's kick) and a drop window (Colyseus's `allowReconnection`).
- Colyseus counts in-flight joins and held seats toward the cap, which is #852 (a)'s rule.
- A window comes with its own hooks (`onDrop`, `onReconnect`), so the land author can tell a drop from a leave. That is public API.

## 5. Questions for the maintainer (one at a time, through Main)

**K6-Q1. Does K6 add a reconnection window after a drop?**

| Option | What it means | For a land author | Cost |
|---|---|---|---|
| **(a) No window in K6 (recommended)** | K6 is #588's structural change. A drop still leaves at once. A window is a separate issue, decided on its own | nothing new | none beyond #588 |
| (b) An opt-in window | a land declares a window (for example `Reconnection(within: .seconds(20))`). A drop holds the seat, counted by the cap; OnLeave runs at expiry; a return within the window resumes the entry | new hooks for a drop and a return, or OnLeave and OnJoin with a flag | public API; a core timer (#762); the adapter must keep the player's views and slot across the gap |
| (c) A window by default | as (b), on for every land | every land's OnLeave runs later than today | as (b), and a behavior change for every land |

Why (a): K6 is already the largest join change (#588's signature break, one step, one refusal form). A window adds hooks and a timer, and its value depends on the clients: a mobile client on a flaky network gains the most. Games here run tens of minutes, so a lost seat costs a rejoin, not a lost evening. A follow-up issue keeps the option open.

**K6-Q2. A duplicate login in one step: which handlers run, in what order?**

Today, the old session's OnLeave finishes (resolvers included) before the new session's OnJoin runs. In K6 the join is one step, so it can't wait for the old OnLeave's resolvers. The parent plan's K6 row says the old OnLeave runs as a request under `.land` after the step. That changes the order: **the new OnJoin applies first, and the old OnLeave applies later.**
- **The hazard.** An OnLeave that removes the player from the state (a common shape) then removes the player who has just rejoined.
- The #852 note's option (c) (replace the old entry in place, K6's shape) and the parent's row (the old OnLeave runs under `.land`) don't say the same thing. The maintainer decides which one K6 implements.

| Option | What it means | For a land author |
|---|---|---|
| **(a) Rebind, no leave and no join (recommended)** | A duplicate login rebinds the existing entry to the new session: no OnLeave, no OnJoin, the player's state untouched. The old session is closed. A session-change notice (an event, or a context flag on the next handler) tells the land, if it cares | a device switch keeps the player's state; a land that resets per session listens for the notice. Matches Colyseus's `onReconnect` (no leave, no join) |
| (b) New order, guarded | OnJoin (new) in the step; the old OnLeave later, and its context says the player has a newer entry (`EntryID`), so a handler can skip the removal | every OnLeave that removes the player needs the guard: easy to miss |
| (c) Today's order, two steps | the join waits for the old OnLeave's resolvers before its step: the kick stays an await, and the join isn't one step | no change, but the window that #852 is about stays, and the hold stays |

Why (a): it is the shape the #852 note already named as K6's, it can't remove the new player by accident, and it is the duplicate-login half of a reconnection model. If K6-Q1 later adds a window, a return within the window takes the same path.

**K6-Q3. Is the old session told why it was closed?** Today the old session is kicked by a leave. A close code or reason that says "logged in elsewhere" lets the client stop its own reconnect loop instead of fighting the new session. Recommendation: yes, a distinct close reason, listed in K6's public changes. This is small, and it can go in the same PR.

**Already decided, for reference:** `CanJoin` takes `ValidateContext` and returns a plan that `OnJoin` receives (#588, maintainer 2026-11-18; parent §8's K6 row). The maintainer confirms in K6's PR that no deprecation step is needed.

## 6. What K6's plan will need to settle (not for the maintainer)

- The one refusal form: which wire shape every join refusal takes, and the goldens it changes.
- The record of a refused join, and replay's handling of it (#586's `rejected` marker).
- The order test for a duplicate login under K6-Q2's answer, with #852's test kept.
- #548's tests, including the in-turn variant.
- The measurement: the parent's K6 row asks for K3's join-churn cell.
