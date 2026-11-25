# K6 survey: the join in one step, duplicate logins and reconnection (#700, #588, #852)

**Status:** survey, not a plan, rev 1.3. Read-only, no code changes. Read at main 73f44915, without the LSP. Rev 1.3 records K6-Q2, decided (a), and K6-Q3, decided yes, and sizes both (§6). All three K6 questions are decided. Rev 1.2 recorded K6-Q1, decided (a), with #334 as its follow-up. Rev 1.1 took Review's fact-check: §1's details, K6-Q2's options and their relation to the #852 note and the parent plan, and the prior art's versions (§8). It prepares K6's plan: what K6 changes, how #852's fix carries into it, what other servers do, and the questions the maintainer decides before the plan is written. `LK` is `Sources/SwiftStateTree/Runtime/LandKeeper.swift` at that commit.

**Inputs:**
- the parent plan `2026-11-22-keeper-on-turncore.md`: §3.4's join and leave rows, §5's K6 row, §6.2's K6 tests, §8's K6 row;
- issue #588 (validate a join in the turn that applies it);
- the #852 options note `2026-11-25-852-duplicate-login-cap-options.md`. Its option (a), the returning player keeps the place, is being implemented as a small PR; it isn't on main yet, so this survey cites the note's design (§5 there);
- the K2 plan draft 3 `2026-11-25-k2-cut-over-onto-the-turn-core.md` §7.1 (the adapter's membership queue).

## 1. Two things called "reconnection"

The word covers two different events. The survey keeps them apart, because today's code handles only the first.

- **A duplicate login.** A player joins while their old session is still in `players`. This happens when a player switches devices, or when the old connection is half-open: the client is gone, but the server hasn't seen the close yet.
  - Today the join treats it as a reconnection: `isReconnection = players[playerID] != nil` (LK:2069), and the `maxPlayers` check skips it (LK:2071).
  - The `maxPlayers` exemption is in the reporting join only (`joinReportingAdmission`, the transport's path). The legacy public `join(playerID:…)` (LK:1871) has no cap check at all.
  - If the old entry has a client ID (LK:2083), the join kicks the old session with `try await leave(…)` (LK:2088; in the legacy join, LK:1884). The leave removes the entry from `players` at once (LK:2796) and cancels its action jobs (`cancelActionJobs(ofEntryGeneration:)`, LK:2797). Then it awaits the old session's OnLeave resolvers and enqueues the OnLeave item.
  - On a tick land the kick returns once the OnLeave item is enqueued, not once it has applied. OnLeave's sequence is taken before OnJoin's, so the old OnLeave applies first. The two can apply in the same tick. The state sees a leave and then a join.
- **A drop, then a rejoin.** The connection closes, and the player joins again later.
  - Today there is no window. The adapter's disconnect path (`handleDisconnectQueued`, TransportAdapter.swift:1273–1312) runs in the adapter's membership queue and calls `keeper.leave` at once. The leave refuses a client ID or session ID that doesn't match the entry (LK:2777–2788), so the drop of a session that a newer login already replaced does nothing.
  - The player is removed from `players` when the leave is called (LK:2796), before the OnLeave resolvers run. The OnLeave handler applies later, in the tick or the input turn. A later join is a first join: the cap applies, and OnJoin runs as for a newcomer.
  - The only grace in the code is the WebSocket close grace (#339), which is about frames, not players.
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
- #852's test (the gated OnLeave resolver, P3 refused, P1's rejoin admitted, the count never above the cap) keeps its claim and changes its shape. Under K6-Q2 (a) a duplicate login runs no OnLeave, so the gate is never reached: the test becomes P1's duplicate login rebinding while P3's join is refused at the cap, with the count never above it.

**If K6 also adds a reconnection window (K6-Q1 (b) or (c)), the hold returns in a new form.** A seat held after a drop is a place that a disconnected player holds, which is #852's rule again, over a longer time:
- a model fact, `reservedSeats: [PlayerID: (entry: EntryID, until: tick or deadline)]`;
- counted by the cap, as the held set is;
- ended by a core timer (#762) or by the player's return.

So the code doesn't carry over, but the rule does: **a player who holds a place counts toward the cap**, whether the place is held across a kick (#852) or across a drop (a window).

## 4. Prior art

**Colyseus** (a Node.js room server; the current docs, whose site announces 0.18, and the master branch's Room.ts, read 2026-11-25):
- **The window.** A room calls `allowReconnection(client, seconds)` inside `onDrop()` "to hold the client's seat". The seconds expire on their own; `"manual"` holds the seat until the room's code calls `.reject()` ([docs.colyseus.io/room/reconnection](https://docs.colyseus.io/room/reconnection)).
- **The hooks.** `onDrop` runs on a non-consented drop. If the client returns in time, `onReconnect()` runs; if the window expires, `onLeave()` runs. A consented leave (`room.leave()`) skips `onDrop` and goes straight to `onLeave` (same page).
- **The cap counts held seats.** `hasReachedMaxClients()` in Room.ts returns `(this.clients.length + Object.keys(this._reservedSeats).length) >= this.#_maxClients || …DISPOSING`. Its doc: "the sum of connected clients and reserved seats". Reserved seats cover joins in flight; that reconnection holds are stored there too is inferred from `checkReconnectionToken` reading the same table ([github.com/colyseus/colyseus, packages/core/src/Room.ts](https://github.com/colyseus/colyseus/blob/master/packages/core/src/Room.ts)).
- **The reservation timeout** is `seatReservationTimeout`, default 15 seconds (`COLYSEUS_SEAT_RESERVATION_TIME`); `setSeatReservationTime` is deprecated (same file).
- **Earlier versions** called `allowReconnection` inside `onLeave(client, consented)`. The 0.15 docs say it "must be used inside `onLeave()`", with `await this.allowReconnection(client, 20)` in `async onLeave (client: Client, consented: boolean)` ([0-15-x.docs.colyseus.io/server/room](https://0-15-x.docs.colyseus.io/server/room/)). Which version introduced `onDrop` and `onReconnect` isn't stated in the pages read.

**Nakama** (Heroic Labs' game server; sources read 2026-11-25):
- **Duplicate logins at the socket.** The `session.single_socket` option allows one socket per user, and older sessions are disconnected; it defaults to `false` ([configuration docs](https://heroiclabs.com/docs/nakama/getting-started/configuration/); the usage text in [server/config.go](https://github.com/heroiclabs/nakama/blob/master/server/config.go) says the same: "Only allow one socket per user. Older sessions are disconnected. Default false."). `session.single_match` requires it. That is today's kick, at the connection level rather than the match level. How the older socket is closed wasn't read.
- **No built-in window.** In an authoritative match, the match handler's `MatchJoinAttempt` decides admission, and the docs leave reconnection to the handler: "In the case of disconnects you can decide to temporarily reserve their seat" ([heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative](https://heroiclabs.com/docs/nakama/concepts/multiplayer/authoritative/)). The page doesn't say what happens when a user who is already a presence joins again.

**What they show:**
- The two events are separate mechanisms in both servers: a duplicate-login policy (Nakama's `single_socket`, today's kick) and a drop window (Colyseus's `allowReconnection`).
- Colyseus counts in-flight joins and held seats toward the cap, which is #852 (a)'s rule.
- A window comes with its own hooks (`onDrop`, `onReconnect`), so the land author can tell a drop from a leave. That is public API.

## 5. Questions for the maintainer (one at a time, through Main)

**K6-Q1. Does K6 add a reconnection window after a drop? Decided (a)** (maintainer, 2026-11-25): no window in K6. The follow-up is #334 (a grace period for a disconnected player), which carries this survey's points: held seats count toward the cap, the window ends by a #762 timer, and §4's prior art.

| Option | What it means | For a land author | Cost |
|---|---|---|---|
| **(a) No window in K6 (decided)** | K6 is #588's structural change. A drop still leaves at once. A window is a separate issue, decided on its own | nothing new | none beyond #588 |
| (b) An opt-in window | a land declares a window (for example `Reconnection(within: .seconds(20))`). A drop holds the seat, counted by the cap; OnLeave runs at expiry; a return within the window resumes the entry | new hooks for a drop and a return, or OnLeave and OnJoin with a flag | public API; a core timer (#762); the adapter must keep the player's views and slot across the gap |
| (c) A window by default | as (b), on for every land | every land's OnLeave runs later than today | as (b), and a behavior change for every land |

Why (a): K6 is already the largest join change (#588's signature break, one step, one refusal form). A window adds hooks and a timer, and its value depends on the clients: a mobile client on a flaky network gains the most. Games here run tens of minutes, so a lost seat costs a rejoin, not a lost evening. A follow-up issue keeps the option open.

**K6-Q2. A duplicate login in one step: which handlers run, in what order, and what happens to the entry? Decided (a)** (maintainer, 2026-11-25): rebind the entry with no OnLeave and no OnJoin, close the old session, cancel its in-flight actions in the step, and send a session-change notice. §6 sizes it.

Today the old session's OnLeave applies before the new session's OnJoin (§1). In K6 the join is one step, so it can't wait for the old OnLeave's resolvers.

What the existing texts say:
- **The parent plan** (§3.4's kick row): in the join's step, the membership change, then the old entry's OnLeave as a request under `.land`. A rejoin ends the old key (§3.4's resolver row), so the new session gets a new `EntryID`.
- **The #852 note's (c)**: rebind the old entry to the new client, and issue the old session's OnLeave without awaiting it. Its §4 restates the parent's row for K6.
- So both run the old OnLeave unawaited. They differ only on the entry: (c) keeps it and rebinds it, while the parent ends it and makes a new one.

**The hazard, and when it applies.** When the old OnLeave has resolvers, its apply comes back after the join's step, so the new OnJoin applies first and the old OnLeave later. A typical OnLeave (`state.players.removeValue(forKey: ctx.playerID)`) then removes the player who has just rejoined. When the old OnLeave has no resolvers, the parent's row doesn't say whether its handler applies in the join's step, before OnJoin, or later. K6's plan must settle that reading either way, and the question below does.

| Option | What it means | For a land author |
|---|---|---|
| **(a) Rebind, no leave and no join (decided; new, not in either text)** | The duplicate login rebinds the existing entry to the new session: no OnLeave, no OnJoin, the player's state untouched. The old session is closed, and its in-flight actions are cancelled in the rebind step, as the kick cancels them today (LK:2797): the step ends the old session's requests explicitly, because a rebind doesn't end the `.entry` key. A session-change notice (an event, or a flag on the next handler's context) tells the land, if it cares | a device switch keeps the player's state; a land that resets per session listens for the notice. The same shape as Colyseus's `onReconnect` (no leave, no join) |
| (b) The parent's row, made safe | new `EntryID`; OnJoin (new) in the step; the old OnLeave applies in the step before OnJoin when it has no resolvers, and later when it has some. A late OnLeave's context carries its `EntryID` and says the player has a newer entry, so the handler can skip the removal | every OnLeave that removes the player needs that guard when it has resolvers: easy to miss |
| (c) The #852 note's (c) | rebind the entry, and still issue the old OnLeave unawaited | the same hazard as (b), and the entry's identity no longer says which session it is |
| (d) Today's order, two steps | the join waits for the old OnLeave's resolvers before its step: the kick stays an await, and the join isn't one step | no change, but the window #852 is about stays, and so does the hold |

Why (a): it can't remove the new player by accident, it needs no guard in land code, and it is the duplicate-login half of a reconnection model: if K6-Q1 later adds a window, a return within the window takes the same path. Its cost is a visible change: a land that relied on OnLeave and OnJoin for a device switch gets the notice instead.

**K6-Q3. Is the old session told why it was closed? Decided yes** (maintainer, 2026-11-25): the superseded session gets a distinct "logged in elsewhere" close, so a client can tell it from a drop and doesn't reconnect into a kick loop. §6.4 sizes it. Today the old session is kicked by a leave. A close code or reason that says "logged in elsewhere" lets the client stop its own reconnect loop instead of fighting the new session. Recommendation: yes, a distinct close reason, listed in K6's public changes. This is small, and it can go in the same PR.

**Already decided, for reference:** `CanJoin` takes `ValidateContext` and returns a plan that `OnJoin` receives (#588, maintainer 2026-11-18; parent §8's K6 row). The maintainer confirms in K6's PR that no deprecation step is needed.

## 6. Sizing K6-Q2 (a) and K6-Q3

The maintainer asked how complex (a) is. This section lists every place it changes, the land code and tests that see the difference, and its size against K6's other parts. Read at main 548a14ac.

### 6.1 Where it changes

| Place | Today | Under (a) |
|---|---|---|
| Join admission (keeper) | the join finds an entry with a client ID and awaits `leave(…)` (LK:2088; legacy join LK:1884), which removes the entry, cancels its action jobs and runs OnLeave; then OnJoin | in the join's step: the entry stays in `players` and takes the new session's client ID, session ID, device ID, guest flag and metadata. No OnLeave, no OnJoin. The seat is the same seat, so the cap isn't checked again (today's exemption, by construction) |
| The old session's in-flight work | the kick's leave cancels its action jobs by entry generation (`cancelActionJobs(ofEntryGeneration:)`, LK:2797) | the same cancel, in the rebind step. The simplest form for K6's plan: the rebind takes a new `EntryID`. Ending the old `.entry` key closes its keyed requests as any rejoin does (K5), and the action-job cancel by generation stays as it is. What the rebind keeps is the seat and the land state, not the entry's identity |
| `CanJoin` | runs for the new session, as for any join | still runs, as an admission check (a ban or an auth rule must see the new session). K6's plan says so in its tests |
| The adapter's per-session state | newest wins (#92, #531): `admitJoining` supersedes the player's other sessions, closes them and gives the new one its initial sync; the sync stream records a clear and the seed is a rejoin | unchanged in shape. The admission no longer waits behind a keeper leave for the old session. The old session's later disconnect still clears nothing, because the leave refuses its session ID (LK:2777–2788) |
| The sync binding | on a supersede the adapter clears the player's sync cache and per-player tables and records the clear (`supersedeSessions`, TransportAdapter.swift:1937–1940), and the keeper's leave and join reset the keeper's side, so the new session's first sync is a full snapshot | the adapter's clear stays. The keeper's side must be reset by the rebind step itself, because no leave does it any more |
| `playerServices` | keyed by player, tagged with the entry generation; rebuilt by the join | the rebind step replaces them with the new session's services under the new generation; the old ones are dropped in the step |
| The recorder and replay | a duplicate login records a `leave` then a `join` lifecycle item (`LifecycleKind`: `initialize`, `join`, `leave`) | a new lifecycle kind, `rebind`, so replay takes the same path. That is a record format step (`ReevaluationRecordLog.formatVersion` 3.5 → 3.6), with the refusal of an unknown kind by older readers. Older records hold `leave` plus `join` and replay as today |
| #852's hold | the held set, its ticket and its releases (#852 (a)) | gone: no await between the check and the rebind, and the rebind takes no new seat (§3) |
| The session-change notice | none | additive public API: a rule the land may declare, run in the rebind step with the old and new session IDs in its context. A land that declares nothing sees no change in its state. Its name and shape are for K6's plan; it is listed under the PR's Public API |
| Handler context fields | `ctx.sessionID`, `ctx.clientID`, `ctx.metadata`, `ctx.isGuest`, `ctx.deviceID` come from the entry | the same fields, now the new session's values after the rebind |
| Docs | `land-dsl.md` (both languages) says a duplicate login runs OnLeave then OnJoin (land-dsl.md:141) | the new behaviour, the notice, and what to do for a land that resets per session |

### 6.2 Land code and tests that see the difference

**Demo lands.** None needs OnLeave and OnJoin to run again on a re-login to stay correct. Two show a visible change:
- Hero Defense: OnJoin spawns the player at the base with level-based health (HeroDefenseLand.swift:215). Today a device switch respawns the player; under (a) the player keeps their position, health and resources.
- Cookie demo: OnJoin sets the display name from the new session's JWT `username` (or `Guest-` plus the session ID's prefix) and resets the cookie counts (CookieDemoDefinitions.swift:183). Under (a) the name and counts stay. A name change on a new login needs the notice.
- Card game: OnJoin creates state only when it is missing (CardGameLand.swift:22), so no change.
- The encoding benchmark's `--rejoin-every` (Rejoin.swift) and the ws-loadtest reconnect are a leave then a new join, not a duplicate login, so no change.

**Tests that assert today's handlers on a re-login** (these change):
- `TransportAdapterNewestWinsTests`: "A second join of the player supersedes the first session" and "Legacy join: the second join supersedes the first" (`joins == 2 && leaves == 1`); the disconnect check (`leaves == 1`); two tests about the old session's action between the kick and the admission, which keep their claim with the rebind in place of the kick.
- `TransportAdapterConcurrencyTests`: "Duplicate playerID login kicks old session" (`OnLeave should be called`, `joinCount == 2`).
- `TransportAdapterRegisterSessionTests`: "A host's second keeper join and registration supersede the first session: OnJoin twice, OnLeave once".
- #852's test (§3).
- The differential scenarios `second-session` and `stale-action-reply` (with `-diff-first`): 3 scenarios × 6 cells = 18 goldens, regenerated if their frames show the old leave and join.

Tests that keep passing unchanged: the newest-wins membership and close checks, the stale targeted-event drop (`TransportAdapterMembershipTests`), the sync-lag survivor test, the sync stream's rejoin seed.

### 6.3 Size against K6's other parts

| K6 part | Size |
|---|---|
| `CanJoin` → `validate` with a plan, and OnJoin in the same step (#588) | the largest: every join path, the context type, the plan type, docs and goldens |
| Join resolvers as keyed requests | middle; most of it is K5's work, which K6 uses |
| One refusal form, refused joins recorded (#586) | middle: wire shape, goldens, replay marker |
| #548's tests | small |
| **The duplicate login, (a)** | **middle-small**: one step's code in the keeper, a lifecycle kind with a record format step, the notice rule, the sync reset, about 6 test rewrites and up to 18 goldens. It removes code as well: the kick's await, #852's hold, and the parent's unawaited OnLeave under `.land`, which (b) would have needed together with a guard in every OnLeave |

Compared with the parent's row ((b) made safe), (a) is about the same size in the keeper and smaller for land authors. It adds a record kind and a public rule; (b) would have added a context flag and the guard.

### 6.4 K6-Q3: the "logged in elsewhere" close

**Today.** `supersedeSessions` closes the old session with `closeSessionDetached(old, generation:)` (TransportAdapter.swift:1936), which sends `SessionClose.normal`: code 1000 with no reason (TA:1505, Transport.swift:225). A client can't tell it from a normal close.

**The TS SDK.** It surfaces the raw code and reason: `onDisconnect(code, reason, wasClean)` (runtime.ts:300), and the views get a `ConnectionClosedError` with `closeCode` and `closeReason`. It names two codes as constants (`INVALID_ROW_ENTRY_CLOSE_CODE` 4013, `LAND_FAILED_CLOSE_CODE` 4016, protocol.ts). The runtime never rejoins by itself; the app decides (runtime.ts:204). So the kick loop the question is about lives in app code, and the app needs a code it can test.

**What the new close needs:**
- **A code in the application range.** The assigned codes are 4008, 4010–4012 (4012 reserved), 4013 (client-sent), 4014 and 4016; 4009 and 4015 are unassigned on purpose, with a note each. The next free code is **4017**, named `superseded` in `SessionClose.Code`, with the reason "logged in elsewhere" and the same short close grace as `landStopped`, so the frame arrives before the channel closes (#339). The reason string is for people; clients test the code.
- **The adapter's change.** `supersedeSessions` passes the new close in place of `.normal`. That is one call site; under K6 it is the rebind's close.
- **The SDK.** A constant `SUPERSEDED_CLOSE_CODE = 4017` with a doc saying "don't rejoin on your own: another login of this player took over". `onDisconnect` already carries the code, so no new event is needed. A named `kind` on `ConnectionClosedError` is optional.
- **The load client.** `Examples/GameDemo/ws-loadtest` counts server closes by code (`closes.serverByCode`, run.ts:92), so 4017 shows up there without a change.
- **Docs.** The close-code list in `docs/core/failure-handling.md` and its `.zh-TW.md`, and the duplicate-login text in `land-dsl.md` (both languages).
- **Tests.** The newest-wins tests check the old session's close code; an SDK test checks the constant.

**Size:** small, and independent of K6's core. It doesn't need the rebind: it can ship before K6, as its own small PR on today's supersede path, which is a candidate for a cloud worker. K6 then reuses it for the rebind.

### 6.5 Open points for K6's plan (not for the maintainer)

- The notice's name and shape, and whether it can have resolvers (recommended: no, so the rebind stays one step).
- Whether the new `EntryID` (§6.1) is the form K6 takes, or the entry keeps its ID and the step cancels by session.
- The record format step's compatibility line, in the PR's Public API.

## 7. What K6's plan will need to settle (not for the maintainer)

- The one refusal form: which wire shape every join refusal takes, and the goldens it changes.
- The record of a refused join, and replay's handling of it (#586's `rejected` marker).
- The order test for a duplicate login under K6-Q2 (a), with #852's test in its new shape (§3).
- K6-Q2 (a)'s open points, listed in §6.5.
- #548's tests, including the in-turn variant.
- The measurement: the parent's K6 row asks for K3's join-churn cell.

## 8. Rev 1 → rev 1.1 (Review's fact-check)

| Change | Where |
|---|---|
| The drop goes through the adapter's membership queue; the leave refuses a mismatched client or session, so a superseded session's drop does nothing; the entry leaves `players` at the call, before OnLeave's resolvers; the only grace is the WebSocket close grace | §1 |
| The kick runs only when the old entry has a client ID; on a tick land it returns when OnLeave is enqueued; OnLeave applies first by sequence, possibly in the same tick; the cap exemption is the reporting join's only, and the legacy join has no cap | §1 |
| K6-Q2: the #852 note's (c) and the parent agree that the old OnLeave runs unawaited, and differ only on the entry; the hazard applies when the old OnLeave has resolvers; option (a) is new and says what happens to the old session's in-flight actions; the parent's reading for an OnLeave without resolvers is part of the question | §5 |
| Colyseus: the docs read are the current (0.18) ones; earlier versions used `allowReconnection` inside `onLeave(client, consented)`. Nakama: `single_socket`'s usage text from the source | §4 |
| K6-Q1 decided (a), no window in K6; #334 is the follow-up (rev 1.2) | §5 |
| K6-Q2 decided (a), K6-Q3 decided yes; §6 sizes both; #852's test in its new shape (rev 1.3) | §3, §5, §6 |
