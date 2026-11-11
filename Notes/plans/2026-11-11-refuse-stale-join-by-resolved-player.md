# Plan: refuse a stale join's admission by the resolved player (#234)

Status: revision 2. Read on exp/next 2e1792f3.

## Cause

- **The check runs by the requested player, before the keeper resolves the real one.**
  - `TransportAdapter.performJoinQueued` (TransportAdapter.swift:2224) runs in the adapter's membership queue. In that order it refuses a stale router attempt with `staleJoinAttempt(joinAttempt, sessionID:, playerID: PlayerID(playerSession.playerID))` (:2240, defined at :2324).
  - That is the **requested** player: `staleJoinAttempt` looks at that player's member sessions and their `memberJoinAttempts` (:474).
  - Its doc says so: "a land that maps players in `CanJoin` gets only the ended-session check".
- **The resolved player only appears after an await.**
  - Next, `performJoinQueued` awaits `keeper.joinReportingAdmission` (:2253).
  - The keeper runs CanJoin, with its resolvers awaited, at LandKeeper.swift:1551–1574. That is where the resolved `playerID` P comes from.
  - The keeper then acts on P in its own join, still before any admission callback:
    - Kick Old (:1599–1604): `players[playerID]` has a live session, so `try await leave(...)`, which runs P's other session's OnLeave;
    - then the insert (:1630).
  - The adapter's `supersedeSessions(of: P)` (TransportAdapter.swift:1945) runs later still, from the admission (`admitJoining`).
- **What goes wrong.** The adapter reads its admission state (P's member sessions and their attempts) in the requested-player check, before the keeper's await. The keeper acts on a different player after it. If older attempt A requests alias "a" (CanJoin maps it to P) and runs after newer attempt B for P:
  1. A's check finds "a" with no member sessions and passes.
  2. The keeper resolves A to P and kicks B: B's OnLeave runs.
  3. The adapter supersedes B's session.
- That's #97's bug for mapped players.
- **The trigger** needs the executor to run A's earlier queue entry after B's admission. The membership queue serializes performJoinQueued per adapter, so this happens when A's router call reaches `admitJoin` after B's (`.admitJoinEntry`, as in the existing tests).

## Fix

The check has to run where P is known and before the keeper acts on it: in the keeper's join, in the segment right after the CanJoin decision (after `guard case let .allow(playerID) = decision`, LandKeeper.swift:1577), before the maxPlayers check, the `.join` hold and Kick Old.

1. **`LandKeeperTransport`** gets a synchronous requirement with a default (public protocol, additive):

   ```swift
   /// Whether the transport refuses this join for `playerID`, the player CanJoin resolved:
   /// a stale attempt that would supersede a newer session of that player (#234).
   func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool
   ```

   The default (in the extension at LandKeeperTransport.swift:216) returns `false`. It is called under the same conditions as `admitJoiningSession`: `admitThroughTransport` and `runsSyncPhaseInTurn`, where the transport shares the keeper's executor, so the call can't suspend.
2. **Keeper:** if it returns `true`, `joinReportingAdmission` returns `JoinOutcome(decision: decision, admitted: false, refusedStale: true)` and changes nothing. There's no kick and no insert yet, so there's nothing to roll back.
   - The flag lives in the **package** `JoinOutcome`, never in the public `JoinDecision`: CanJoin returns `JoinDecision`, so a new case there would break land authors' switches.
   - The check runs before `holds.at(.join)`.
3. **Adapter:** `refusesResolvedJoin` first returns `false` when in-turn sync is off, *before* `assumeIsolated`, as `admitJoiningSession` does, so the legacy path (no shared executor) can't trap. Otherwise it enters its isolation with `assumeIsolated`.
   - It reads the session's attempt from `expectedAdmissions[sessionID]` (it exists, :948). The change adds a `joinAttempt` field to `ExpectedAdmission`, set by `performJoinQueued`.
   - It returns `staleJoinAttempt(attempt, sessionID:, playerID: P)`, now with the resolved P.
   - `performJoinQueued` sees `refusedStale`, removes `memberJoinAttempts[sessionID]`, counts it in `staleJoinAttemptsRefused` (the same counter as the requested-player refusal) and returns nil.
   - The requested-player check at :2240 stays. It still refuses early without running CanJoin, and it covers a land without CanJoin.
   - The docstring of `staleJoinAttempt` (:2322) changes: the resolved player is checked again in the keeper's segment on the in-turn path, and only the legacy path keeps the requested-player limit.
4. **Why the check holds across the keeper's later awaits** (the argument, from the writer list):
   - Every writer of `memberJoinAttempts` or `membershipCoordinator`'s player sessions runs in the adapter's membership queue, or synchronously inside this keeper join:
     - :1539 (the disconnect, a queue entry);
     - :1568 and :1611 (leave and admission bookkeeping, queue entries);
     - :1635 (`registerSession`, called from `performJoinQueued`, in the queue);
     - :1765 (`abandonJoining`, from `performJoinQueued`);
     - :1953 and :1958 (`supersedeSessions`, from the admission, inside this join);
     - :2244, :2261 and :2314 (`performJoinQueued` itself).
   - `performJoinQueued` holds the queue for the whole keeper join, so none of them runs between the check and the kick.
   - No other adapter reaches this keeper, one adapter per keeper.
   - Kick Old re-reads `players[P]` after the `.join` hold (LandKeeper.swift:1599), so it acts on the keeper's current entry.
   - This is the "join/leave resolvers re-check by hand" exception in CLAUDE.md. The check reads adapter state in the keeper's segment, and the queue keeps it current until the act.
5. **Limit (legacy path, `IN_TURN_SYNC=false`):** the keeper and the adapter don't share an executor, so no synchronous call is possible there. It keeps today's requested-player check, and the doc says so. Moving the legacy path into turns is its own work.

## Tests (LandRouterJoinAttemptTests, beside `olderAttemptAfterNewerAdmission` :406)

`AttemptHarness.make` gets a `canJoin` parameter that maps `"alias-<p>"` → `<p>`.

1. **Mapped player, older attempt after a newer admission:**
   1. Session s1 joins requesting `alias-p1`. Hold it at `.admitJoinEntry` (`TestGate`, arrival 1).
   2. Session s2 joins requesting `p1` and is admitted.
   3. Release s1.

   Expect:
   - `staleJoinAttemptsRefused == 1`;
   - s1 gets the stale answer (its join request answered as refused) and stays unbound in the router;
   - s2 still joined, and its connection not closed;
   - `supersededSessionCount == 0`;
   - the land's OnLeave count is 0 (a probe), so the keeper didn't kick s2;
   - `players == ["p1"]` and `keeper.playerCount() == 1`.

   It must fail without the fix.
2. **Mapped player, newer attempt after an older one:** the order reversed. s2 (alias, newer) after s1 (`p1`, older) supersedes s1 as today.
3. **The legacy leg:** test 1 is `.enabled(if: inTurnSync)`. On the legacy leg a sibling test pins the documented limit (s2 superseded). That way the limit is visible, and the test changes when the legacy path moves.
4. **Mutants:**
   - `refusesResolvedJoin` checks the requested player again;
   - the keeper ignores the result;
   - the call is placed after Kick Old;
   - `expectedAdmissions` without the attempt (the check passes).

## Overlap with #504 (#390)

None. #504 changes the router's session binding (LandRouter's `sessionToBoundLandID` → `BoundLand`) and the shutdown steps. #234 changes the adapter's membership admission and the keeper's join, and touches neither the router nor the shutdown. They don't share files except TransportAdapter.swift, in different functions. So it stays apart from #504: it's its own small PR, and they can land in either order.

## Public API

`LandKeeperTransport.refusesResolvedJoin(playerID:sessionID:)`, with a default of `false`: additive and source-compatible (approved 2026-11-11).

## Scope note

Deferred priority stands: no land in the repo maps players in CanJoin. The public `LandKeeperTransport` gains one requirement with a default, which is additive.

## Solutions consulted

- `2026-11-05-await-resumes-on-stale-state.md`: the check sits in the segment where P is known, before the keeper's awaits.
- `2026-11-05-hold-points-not-timing-in-race-tests.md`: the `.admitJoinEntry` gate.
