# A player's second session gets no per-player changes (#531): findings and fix spec

**Status:** rev 5; rev 3's spec reviewed GO (2026-11-13). The maintainer answered Q1 (A) and Q2 (a) on 2026-11-13; Q3 is open. No code. Read at `main` d8e70bea (the Sources and Tests read are unchanged since 9755a625). Each fact is marked **checked** (read in the code) or **inferred** (reasoned, to be pinned by a test in the fix).

- **Rev 2** answers review of rev 1 (8572647d):
  - corrected facts: recipient order is unspecified; `registerSession` doesn't touch the keeper, so which session is receive-only depends on the caller's keeper join; the seed doesn't move the first session's baseline; the starvation is scoped to cached diffs; no claim about per-player sync tables, which aren't on `main`;
  - the fix spec: `registerSession` goes through the membership queue (M1), its connection generation is written under a ticket (M2), the supersede's delayed close is generation-aware (S3);
  - every direct test caller of `registerSession` and what A does to it (S4); the lifecycle exceptions and exact OnJoin/OnLeave counts (S5); Q2 decided after the fixtures (S6);
  - Q1–Q3 as the maintainer's questions, each with options and a recommendation.
- **Rev 3** answers review of rev 2 (3c1cc1cc):
  - the adapter and the keeper can still name different sessions, since a host's keeper join isn't in the adapter's queue: a keeper check in the registration (option (a), recommended) or a documented ordering rule (b) (§4.1, Q1);
  - S3 names `endJoinBeforeAdmission` and passes the router's captured generation; the guarantee is limited to transports that implement the generation-aware close;
  - tests hold where the queue is already held, and the M2 test ends the ticket without the queue;
  - Q2's reason, and the OnJoin/OnLeave count conditions.
- **Rev 4**, after the GO:
  - a test of the window between the keeper read and the adapter's commit;
  - S3's generation for `endJoinBeforeAdmission` comes from the router's `joinBudgetExpired`, and covers the final frame and both fallback closes;
  - a refused registration without a generation closes by ID, said beside the counter.
- **Rev 5** records the maintainer's answers to Q1 and Q2 (§5):
  - Q1: A, scoped as the realtime adapter's rule, with a package-level policy enum that has `.replaceOld` only, read by both join paths (§4.1);
  - Q2: (a);
  - several sessions per player is deferred to #539 (§6).

**Summary.** #531's mechanism holds for cached diffs. Two adapter members of one player share one per-player baseline, so one of the two recipients in a sync gets that player's per-player changes and the other doesn't. Which one is unspecified. Only the public `TransportAdapter.registerSession(...)` creates the second member.

The fix (option A, the maintainer's answer to Q1) is that `registerSession` supersedes, as the library's own joins do, runs in the adapter's membership queue like every other membership change, and refuses a registration whose session the keeper's entry doesn't name (§4.1). One session per player is `TransportAdapter`'s rule, not the library's: another adapter may allow several connections per user.

## 1. The reproduction path

1. **Join** a player through any library join (`performJoin`). Admission supersedes other sessions and registers the member in one synchronous segment (`admitJoining`, `TransportAdapter.swift:1773-`; `supersedeSessions`, :1956-1987). Checked.
2. **Register a second session** for the same player with the public `registerSession(sessionID:clientID:playerID:authInfo:connectionGeneration:)` (`TransportAdapter+Membership.swift:13-33`). It calls `_registerSessionImpl` (`TransportAdapter.swift:1632-1663`), which adds the member without admission and outside the membership queue. Its DocC says so: "the player's other sessions stay members". It doesn't call the keeper. Checked.
3. **Seed it**, as the tests do with `syncStateForNewPlayer(playerID:sessionID:)` (`TransportAdapterSyncLagTests.swift:366-367`, :488-489).
4. **Change a per-player field** and run a normal sync. Both sessions are recipients (`syncPhaseRecipients`, :4199-4209, every joined member). With the default cached baseline, each recipient diffs against `staged.perPlayer[playerID] ?? lastPerPlayerSnapshots[playerID]` and stages its new snapshot under the same `playerID` (`collectPerPlayerOnlyPendingUpdates`, :5133-5172; `collectCombinedPendingUpdates`, :5174-5212). So:
   - the recipient that comes first gets the changes;
   - the other diffs against what the first staged and gets `.noChange`, which is skipped (:5157-5159). In the combined frame it gets the broadcast part only. Checked.

**Scope: cached diffs only** (checked). A diff with the `.empty` baseline, or a full snapshot, emits a `.set` for every field on every call, whatever is staged (`SyncEngine.swift:787-797`). So the second recipient isn't starved there; the bug is the cached path, the default sync.

**Which session is first** (checked): recipients come from `MembershipCoordinator.allJoinedEntries()`, which maps over the `sessionToPlayer` dictionary (`MembershipCoordinator.swift:237-239`). Dictionary order is unspecified: it isn't join order and isn't a contract under any setting. The red test therefore asserts that exactly one of the two sessions gets the patch, not which one.

**The seed doesn't move the first session's baseline** (checked). The late-join snapshot stages the player's per-player snapshot only when none is staged or cached (`SyncEngine.swift:1530-1531`). The bug stands through the shared cached diff alone.

**In the library:** `registerSession`'s only library caller is `performJoin` (:2320), inside the membership queue and right after admission, so it never makes a second member. Hosts and tests are the remaining callers (§4.2).

## 2. Code that assumes one session per player

**Keyed by player in the sync path:**

| State | Where (checked) | With two members |
|---|---|---|
| Per-player baseline `lastPerPlayerSnapshots: [PlayerID: StateSnapshot]` | `SyncEngine.swift:66`; written by `applyStaged` (:94-102) | one baseline for two views: the #531 bug (cached diffs) |
| Staged per-player caches `StagedCaches.perPlayer` | `SyncEngine.swift:85-91` | the second recipient diffs against the first's staged snapshot |
| `hasReceivedFirstSync: Set<PlayerID>` | `SyncEngine.swift:85-108` | a second session's first diff isn't a `firstSync`, since the player already had one (inferred from the set's key) |
| `initialSyncingPlayers[playerID]` | `TransportAdapter.swift:1756-1761`; skipped in `syncPhaseRecipients` (:4203) | while one session seeds, every session of the player is left out of the sync phase |
| Cache clear `clearCacheForDisconnectedPlayer(playerID)` | `SyncEngine.swift:1186-1189`; called at supersede (:1984) and at the player's last disconnect (:1604) | per player; the disconnect path already guards it by "no other session" (:1595-1610) |

**The keeper, outside the adapter** (checked). `registerSession` never calls the keeper, so what a second member can do depends on whether the caller also joined the keeper for it:
- **The keeper holds one entry per player** (`players: [PlayerID: InternalPlayerSession]`, `LandKeeper.swift:280`).
- **No second keeper join** (the sync-lag fixtures: `simulateRouterJoin` joins the first session, :224-227, and the second is only registered, :366, :488). The entry names the first session, so the second session's inputs are the ones rejected (`rejectSenderIfSuperseded`, :1844-1864, #92). The second still receives sync.
- **A second keeper join** (a host that joins the keeper again before `registerSession`). The kick-old path leaves with the old client and session and rejoins (:1619-1633), so the entry names the second session, and the first session's inputs are rejected.
- **No keeper entry at all** (a caller that never joined the keeper). Nothing is rejected: the check returns when the player has no entry (:1850-1851).
- **Leave** returns early when the session isn't the entry's last (:2366-2371), so only the entry's session ends the player.

**Disconnect** invalidates the player's membership version, which drops the player's queued `.player` events "for every session of the player, a remaining one included" (`TransportAdapter.swift:1569-1578`). Checked.

**Code that already handles several sessions** (checked): `classifySyncLag` gives every session of a resyncing player the resync view (:3365-3410); `.player` targets expand to all the player's sessions (:2985); the disconnect path keeps the player's state while another session remains (:1595-1610). They don't make two members correct, since the baseline and the keeper entry are per player.

## 3. Fix options

| | What | Public API impact | Other impact |
|---|---|---|---|
| **A. Supersede in `registerSession`** (newest wins, as `performJoin`) | the public `registerSession` enqueues on the membership queue; inside, an internal implementation supersedes the player's other sessions in the same synchronous segment as the member insert, as `admitJoining` does (§4.1) | no signature change. The DocC's "the player's other sessions stay members" becomes "newest wins, as a join". Behavior change: a host's older session is closed (superseded) instead of kept | matches the keeper's kick-old and #92. The sync-lag two-member cases become supersede cases (§4.2). The multi-session branches become unreachable from the public API (Q2) |
| **B. Refuse a second registration** | `registerSession` refuses when the player already has a member | a source break: `async` becomes `async throws`, or a `@discardableResult` outcome callers can ignore. A new error case | the host chooses what happens to the older session. The membership queue change (§4.1 M1) applies here too |
| **C. Support several sessions per player** | a per-session baseline: `lastPerPlayerSnapshots`, the staged per-player caches, `hasReceivedFirstSync` and the initial-sync marker keyed by session; and the keeper's one-entry model changed (kick-old, `rejectSenderIfSuperseded`, `leave`'s session check) | additive in the adapter; a public behavior change of joins (#92's newest wins) in the keeper | per-player sync memory and diff work × sessions. The largest change; no repository use needs it |

## 4. The fix, under option A

### 4.1 Changes

- **The rule, in one place (rev 5).** How sessions map to a player is the adapter's concern. For `TransportAdapter`, the realtime adapter, the rule is newest wins and the older session is logged out, as in typical games. Another adapter, such as a future request-based one, may allow several concurrent connections per user; nothing here constrains it.
  - A package-level enum, `SessionPerPlayerPolicy` (name to settle in the fix), with one case, `.replaceOld`. Both join paths read it: the library's join (`admitJoining`'s supersede) and `registerSession`'s. So the two can't drift onto different rules.
  - No public policy API, and no other case: `rejectNew` and `allowMultiple` aren't added. `allowMultiple` needs #539 first (§6).
  - The DocC of `TransportAdapter` and `registerSession` states the rule as the adapter's.

- **M1. `registerSession` goes through the membership queue.** Today it runs outside it, beside `performJoinQueued` and `_onDisconnectImpl`, which both enqueue (`TransportAdapter.swift:2234`, :1531). The split:
  - the public `registerSession` calls `enqueueMembership { … }` (:3035) with an internal implementation;
  - `performJoinQueued` calls that internal implementation directly (:2320), since it already runs inside the queue. An enqueue from inside the queue would wait on its own tail.
  - Order-sensitive per-player work then goes through one serial queue, as the reentrancy rule requires: a host's `registerSession` can't interleave with a join's admission or a disconnect's leave.
- **The supersede.** The internal implementation calls `supersedeSessions(of: playerID, keeping: sessionID)` in the same synchronous segment as `registerPlayer`/`registerClient` (:1646-1651), before the transport await. A rebind (the session moved from another player, :1641-1645) keeps its existing handling first.
- **The keeper check (rev 3).** A queued registration still trusts the caller's keeper join, which isn't in the adapter's queue, so the two can pick different sessions:
  1. the host joins S2 in the keeper and hasn't registered it yet;
  2. the library joins S3 through the queue, so the keeper and the adapter both name S3;
  3. the host registers S2, and under A it supersedes S3.

  The adapter then keeps S2 and the keeper keeps S3, so S2's inputs are rejected (`LandKeeper.swift:1844-1863`), and S3 was closed. The M2 ticket can't see this: nothing ended S2. Two options:
  - **(a) Check the keeper's entry in the registration** (recommended). A package read on the keeper, `entrySession(for: PlayerID) -> (clientID: ClientID?, sessionID: SessionID?)?`, returns the entry's `clientID` and `lastSessionID` (`InternalPlayerSession`, :5344-5345); no such query exists today. The public registration reads it first, inside the queue; the rest of the registration runs after that await in one synchronous segment, re-reading the adapter's state there.
    - The entry names this session (or this client, for a session the keeper hasn't seen): register, superseding the others.
    - The entry names another session or client: refuse. The session isn't registered; it is closed (generation-aware, S3), and a counter `staleRegistrationRefusals` counts it, with a warning. That is what the library does to a join that lost (`endJoinBeforeAdmission`). The close uses the registration's `connectionGeneration` argument; a direct caller that passes none gets a close by ID, without the protection.
    - No entry: register, as today. The keeper's sender check has the same rule (:1850-1851), and callers that drive the adapter without a keeper join keep working.
    - `performJoinQueued` (:2320) calls the internal implementation without the check: its own keeper join just ran in the queue, and #234's `refusesResolvedJoin` already covers a stale one.
    - Cost: one keeper hop per public registration, none for the library's joins.
    - **The window after the read.** A host keeper join can move the entry to S3 after the read and before the commit. Then the adapter commits S2 while the keeper names S3. It is transient: this registration holds the queue, so S3 isn't an adapter member yet, and when the host registers S3, its check passes and supersedes S2. The test pins both steps (§4.4).
  - **(b) Document the ordering rule.** The API docs and Q1/Q3 say: the caller must order its keeper join and its registration against the library's joins, and "newest registration" in the adapter is separate from "newest join" in the keeper. No code, and the mismatch above stays possible.
  - The test: the interleaving above, forced with holds. Under (a), the registration of S2 is refused, S2 is closed, and the adapter and the keeper both name S3, with S3's inputs accepted. Under (b), it pins the documented mismatch.
- **M2. The connection generation under a ticket.** `connectionGenerations[sessionID] = …` is written after `await webSocketTransport.registerSession(…)` (:1656-1660). A disconnect or supersede during that await ends the session, and the write would then bring back an entry for an ended session. The fix:
  - capture the session's ticket before the await (`sessionTickets.ticket(for:) ?? sessionTickets.issue(_:)`, as :1748 does);
  - write the generation inside `sessionTickets.ifCurrent(ticket) { … }` after it.
  - The `else if` branch (no `WebSocketTransport`, :1661-1662) has no await and is unchanged.
- **S3. Generation-aware delayed closes.** `supersedeSessions` closes the old session by ID in a detached task (`Task { await transport.closeSession(old) }`, :1982). If the old session ID reconnects before that task runs, the new connection is closed. The fix:
  - capture `connectionGenerations[old]` before it is removed (:1972);
  - close with `closeSession(old, with: .normal, generation:)`.
  - `endJoinBeforeAdmission` (:1833-1848) has the same pattern for a join that ran out of time before admission. The router's `joinBudgetExpired` calls it (`LandRouter.swift:1085-1115`), not `performJoinQueued`. That session was never admitted, so it has no `connectionGenerations` entry, and both its paths act by ID today:
    - **with a final frame**, `sendFinalFrameAndClose` (`TransportAdapter+Outbound.swift:70-85`) stamps the frame with `connectionGenerations[sessionID]` (nil here, :84-85), queues the close behind it, and falls back to a close by ID when the session has ended or the writer refuses (:72-74, :78-80);
    - **without one**, the close by ID at :1844-1846.

    The fix: `joinBudgetExpired` passes the generation it already reads for the router's own close (`sessionToConnectionGeneration[sessionID]`, :1102) into `endJoinBeforeAdmission(_:finalFrame:attemptEnd:connectionGeneration:)`. That generation goes on the final frame, on the queued close (inferred: the writer's close for `closingSessions` must then take the frame's generation; checked in the fix), and on both fallback closes, as `closeSession(_:with:generation:)`. Without a generation (no router), every path closes by ID as today.
  - **Limit:** the generation-aware close is a `Transport` requirement (`Transport.swift:73`), but its default ignores the generation and closes by ID (:97-100). Only a transport that implements it, `WebSocketTransport` (`WebSocketTransport.swift:585-588`), gets the protection; others close by ID as today.

### 4.2 Direct test callers of `registerSession` (S4)

| Caller (checked) | What it does | Under A |
|---|---|---|
| `TransportAdapterSyncLagTests.swift:361-367` (`twoSessions`) and :480-489 (`profileCounters`) | a second member for the fixture's player, without a keeper join | the first session is superseded. Rewritten: the resync view's fan-out is tested through `.player` events (or removed with the branch, Q2), and the profile counters with two players |
| `TransportAdapterSyncLagTests.swift:700` and :917 (rebind cases) | rebinds the fixture's session to another player | unchanged: the other player has no member, so nothing is superseded |
| `TransportAdapterDisconnectOwnershipTests.swift:86-115` | registers S2 while S1's disconnect is held at `keeper.leave` | the disconnect holds the membership queue (:1531), so a queued `registerSession` waits behind it and the test as written can't make progress. Rewritten: the registration completes after the leave, and the test pins that order (S2's registration waits for the leave; the player's state is then cleared and rebuilt by S2's seed) |
| `TransportAdapterJoiningAdmissionTests.swift:373-374` | rebinds S1 to p2 and back to p1 during a held initial sync | the initial-sync hold isn't in the membership queue (inferred; checked in the fix), so it still runs; nothing to supersede |
| `TransportAdapterSyncBackPressureTests.swift:262`, `SyncStreamProducerTests.swift:276`, :430, `AtomicPatternIndexAdapterTests.swift:165`, `NFCPlayerIDJoinTests.swift:54`, `TransportTestHelpers.swift:51` | one fresh session per player, after the caller's keeper join | unchanged; each now runs through the queue |

### 4.3 Lifecycle (S5)

- **Exceptions today** (checked): in reevaluation mode, replay viewers skip OnJoin (`LandKeeper.swift:1434-1436`, :1657-1659), and their leave skips OnLeave (:2382-2383).
- **A's supersede calls neither.** It is adapter-only: the keeper isn't called, so no OnJoin and no OnLeave run for the superseded session. The keeper's entry is whatever the caller's keeper joins made it.
- **The tests assert exact counts,** in live mode with OnJoin and OnLeave handlers installed: a host path of keeper join + `registerSession` for S1, then keeper join + `registerSession` for S2 of the same player, runs OnJoin twice and OnLeave once (the keeper's kick-old). Without the second keeper join, S2's registration is refused under (a) (the entry names S1), and the counts stay OnJoin once, OnLeave zero. The same two-join path in reevaluation mode runs OnJoin zero times and OnLeave zero times (the exceptions above).
- **The newer session survives the old one's delayed close:** S1's ID reconnects as a new connection before the supersede's close task runs, and that connection stays open (S3).

### 4.4 Tests

- **Red first:** two members via `registerSession`, a per-player change, a normal cached sync. Exactly one of the two sessions gets the patch (`.noChange` or broadcast only for the other). No assertion on which.
- **After A:** the older session is superseded (closed, its membership and ticket ended) in the registration's segment. The newer one gets the change; no sync phase has two recipients for one player.
- **The library path:** `performJoin` → admission → the internal registration supersedes nothing (admission already did), counted by `supersededSessionCount`.
- **Queue order (M1):** holds where the queue is already held, not at `.admitJoinEntry`, which sits before `enqueueMembership` (`TransportAdapter.swift:2233-2234`):
  - a library join held at the keeper's `.join` hold (`LandKeeper.swift:1618`), reached from `performJoinQueued` inside the queue;
  - a disconnect held at `keeper.leave`, inside the queue (:1531);
  - in each, a `registerSession` for the same player is issued during the hold and runs only after it; no state shows two members.
- **Ticket (M2):** a hold at the registration's transport await. The registration holds the queue across it, so a public disconnect would queue behind it. The ticket is ended without the queue instead, by `endSessionTicketsForTeardown()` (:1669-1673); after the await, `connectionGenerations` has no entry for the session.
- **A disconnect during the registration** (separately): issued during the same hold, it waits for the registration and then removes the session.
- **The keeper check:** the rev 3 interleaving (§4.1).
- **The window after the keeper read:** S2's registration is held after `entrySession(for:)` returns S2's entry; meanwhile the host's keeper join moves the entry to S3. Released, S2 is committed: the test asserts the transient state (adapter S2, keeper S3, S2's inputs rejected). Then the host registers S3; the test asserts that its check passes, S2 is superseded, and the adapter and the keeper both name S3, with S3's inputs accepted.
- **Generation-aware join timeout:** a join that runs out of time before admission while its session ID reconnects; the new connection gets neither the timeout frame nor the close, with a final frame and without one.
- **Delayed close (S3):** as §4.3.
- **The lifecycle counts:** as §4.3.

## 5. Questions for the maintainer

- **Q1: the fix.**
  - (a) A: `registerSession` supersedes (newest wins, no signature change).
  - (b) B: it refuses a second registration (a source break or an ignorable result).
  - (c) C: several sessions per player (adapter and keeper changes).
  - **Recommendation: (a), with the keeper check (§4.1 (a)).** The library's own joins keep one session per player in the adapter and the keeper; `registerSession` is the path that breaks it. A with the check brings it in line with no signature change. Without the check, A still leaves the adapter and the keeper able to name different sessions when a host's keeper join races a library join, and the ordering rule (§4.1 (b)) has to be documented instead. C is a feature for its own issue if wanted.
  - **Answer (the maintainer, 2026-11-13): A.** Newest wins and the older session is logged out, as in typical games. It is scoped as the realtime adapter's rule (`TransportAdapter`); another adapter may allow several concurrent connections per user. No public policy API: a package-level enum with only `.replaceOld`, read by both join paths, keeps them on one rule (§4.1). The keeper check stays as specified in the reviewed spec (§4.1 (a)). C is deferred to #539 (§6).
- **Q2 (under A): the multi-session branches** (`classifySyncLag`'s fan-out, the disconnect path's "another session remains").
  - (a) Keep them, and add an assertion in `syncPhaseRecipients` that no player appears twice.
  - (b) Keep them without an assertion.
  - (c) Remove them, with a test that two members can't exist.
  - **Recommendation: (a), as defensive code.** `.player` targets never create a second member, and once membership is serialized (M1) and superseded (A), the branches are unreachable from the public API. The assertion catches a regression. It needs §4.2 decided first: the sync-lag two-member fixtures become supersede cases and no test-only two-member fixture remains, or the assertion would fail in them. The sync-lag fan-out test goes with this answer: rewritten as a supersede case under (a) or (b), removed under (c).
  - Removing them (c) needs a reachability review of every path that adds a member, beyond this issue.
  - **Answer (the maintainer, 2026-11-13): (a).** The branches stay as defensive code, with the assertion. #539 revisits them (§6).
- **Q3: `registerSession`'s visibility.**
  - (a) Keep it public with A's semantics.
  - (b) Make it `package`: a larger source break, and it removes the host path that #531 found.
  - (c) Deprecate it in favour of `performJoin`.
  - **Recommendation: (a), with the keeper check.** With it, a registration the keeper's entry doesn't back is refused. Without it, the docs carry the ordering rule (§4.1 (b)). (c) can follow if no host needs it.
  - **Answer:** open (with the maintainer).

## 6. Out of scope

- **Several sessions of one user (#539, deferred).** What would make several sessions per player correct, for tabs or chat-room style use, is keying the sync baseline per session and keeping the projection per player: the per-player snapshot and staged caches, `hasReceivedFirstSync` and the initial-sync marker per session (option C's adapter half, §3). The keeper's one-entry model (kick-old, `rejectSenderIfSuperseded`, `leave`'s session check) would need its own decision there. The multi-session branches kept under Q2 (a) are revisited in #539.

## Related

#92 (newest wins), #514 (per-player sync tables), #531, #539 (several sessions per player, deferred).
