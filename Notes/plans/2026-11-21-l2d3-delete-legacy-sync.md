# L2d-3: delete the keeper's legacy sync and pass, and require the in-turn phase (#546)

Status: rev 1, plan only, for review. Part of `2026-11-20-remove-adapter-off-mode.md` §3.8 (the L2d-3 row of §3.8.5).
Base: `refactor/546-l2d2-route-by-mode` @ 90aa89a6 (#739); L2d-3 branches from main after #739 merges.
Line numbers are at that head (LK = `Sources/SwiftStateTree/Runtime/LandKeeper.swift`, LKT =
`LandKeeperTransport.swift`, TA = `Sources/SwiftStateTreeTransport/TransportAdapter.swift`).
Gathered with `git grep`/`git show` only; no build.

## 0. Finding that changes the plan's scope

The plan (§3.8.5) deletes the legacy pass wholesale. At this head the legacy entries are
`precondition(mode == .reevaluation)`, and the #739 review called them "unreachable in both
modes". That is not proven for `.reevaluation`: the else branches (join :1885, joinReportingAdmission
:2123, leave :2831, submit :3157, completeAction :2446, runForceShutdown :2906, handleClientEvent
:3298, kickServerInputTurn :3404) are taken by ANY keeper with `!routesThroughTurn`, i.e. every
`.reevaluation` keeper that receives a live input. Sources never does that (ReevaluationEngine,
ReevaluationRunnerImpl: 0 input calls; replay goes through runTick's replayed passes), but 11 test
files build `.reevaluation` keepers and some of them call join/handleAction (AsyncResolverConsistency 7,
ReplaySequenceWatermark 8, ServerInput 13, ShutdownTurn 9, TicklessReplayPass 21, LoopPhaseOffset 4 —
counts are per file and include their live keepers, not yet split).

So commit 1 is a probe, not a deletion (see §2). Two outcomes:
- (A) green with every entry `preconditionFailure` → the pass is dead in both modes; delete wholesale
  as the plan says, and replace each else branch with `preconditionFailure("a re-evaluation keeper
  takes no live input; it replays recorded passes")` — or route the else to the turn (Q1).
- (B) some `.reevaluation` test reaches it → those tests feed a replay keeper live inputs. Either
  convert them to replay a record (preferred: that is the path Sources uses) or keep the entry they
  hit until #612. List per test in the PR.

## 1. What stays for `.reevaluation` until #612

- `runSync` tail `else if mode == .reevaluation { await transport?.syncNowFromTransport() }` (#739 MF;
  `ReevaluationOutputMode.transportAndSink`, test `transportAndSinkSyncLoopReachesTransport`).
- `processPendingActions` (LK :3987): runTick's non-replay branch (:4732) and replay passes use it.
  Only its `mode == .live` tickless tail (:4002–4010, `finishTicklessLegacyPass`) goes.
- `transport?.syncBroadcastOnlyFromTransport()` in `processPendingActions` and runTick's replayed
  passes (census allowlist entries stay).
- runTick / the sync loop / the legacy tick path of `.reevaluation` keepers (#612).
- `legacyPassCallers`/`legacyPassResults`/`legacyPassAppliedBy` (:3997, :4128, :5862) only in outcome (B).

## 2. Commit order

1. **Probe** (local only, not committed): turn the 3 entry preconditions into `preconditionFailure`
   and add one at each else branch listed in §0; full `swift test`. Record outcome A/B in the PR body.
2. **Keeper: delete the legacy pass** (outcome A; B keeps what its tests hit):
   - `runLegacyPass` :4142, `finishTicklessLegacyPass` :4072, `deliverLegacyPass` :4116,
     `legacyDeliveries` :844, `legacyPassCallers` :4128 and the `legacyPass*` dicts, `runTicklessJobPass`
     :2465, `ticklessJobTurns` filter in processPendingActions :4002–4010.
   - the else branches in join/joinReportingAdmission/leave/submit/completeAction/runForceShutdown/
     handleClientEvent/kickServerInputTurn (`inTurn` local goes).
   - hooks `runTicklessJobPassForTesting` :2461, `runLegacyPassForTesting` :2462.
   - hold points `.legacyShutdownPass` (:2907), `.ticklessJobPass`, `.legacyDelivery`.
   - Tests: `LegacyEntryStopTests` deleted (or, outcome A with preconditionFailure branches, rewritten
     as one exit test "a re-evaluation keeper refuses a live input" — Q1); `TicklessActionJobTests`
     off arm (:271, :286, `.ticklessJobPass` :425) deleted, `inTurn:` parameter dropped.
3. **Keeper: delete beginSync/endSync/isSyncing and the latch**:
   - `beginSync(clearDirtyFlags:)` :1468, `beginSyncLocated` :1482, `endSync()` :1499, deprecated
     `endSync(clearDirtyFlags:)` :1524–1526, `isSyncing` :753 and its reads :1469/:1472/:1500,
     settle :1712 (`.refused(.syncInFlight)`), tick turn :4861–4865 (always false on live: no Sources
     caller of beginSync), sync-only turn :5330–5333.
   - latch: `syncOnlyTurnAfterLegacyCycle` :810, `...ForTesting` :813, endSync's follow-up :1502–1510,
     `latchSyncOnlyTurnAfterLegacyCycle` :5359–5361 and its share of `requestedSyncWork`,
     `runSyncOnlyTurnAfterLegacyCycle`, hold point `.syncOnlyAfterLegacyCycle`.
   - `InTurnSettleRefusal.syncInFlight` (LKT :302, package enum) goes.
   - Tests (`.beginSync/.endSync` call counts): LandKeeperSyncLockTests 26 → delete 4 (:47, :142,
     :175, :202), convert 5 (:339, :385, :403, :465, :524) to sync-only turns through an opted-in fake
     (§3.8.8); TransportAdapterOrderedSendTests 2 (:575), TransportAdapterSyncDirtyWindowTests 4 (:250),
     SyncStreamProducerTests 2 (:519), TransportAdapterDebugFreezeTests 2, SettleFenceBindingTests 2
     (`syncInFlightLeavesNoBinding` → deleted: its refusal no longer exists; the binding-last rule is
     still pinned by the `notCurrent` test). TransportAdapterSyncConcurrencyTests comment :4.
4. **Adapter: settle retry** — delete `case .refused(.syncInFlight)` and its 2 ms retry (TA :6242–6252,
   `TODO(#546 L2d-3)`). Same commit as 3 or right after (the case stops compiling with 3).
5. **Forwards**: do-nothing defaults for `syncNowFromTransport` / `syncBroadcastOnlyFromTransport` in
   LKT's extension. Adapter: per plan delete the `syncBroadcastOnlyFromTransport` forward
   (TA+LandKeeperTransport.swift:22), `_syncBroadcastOnlyImpl` (TA :5098), `SyncTurnReason.broadcastOnly`;
   retire `TransportAdapterRequestedSyncTurnTests.broadcastOnlyBridgeIsARequestedTurn`. `_syncNowImpl`
   (TA :3126) stays. **But see Q2** (a `.reevaluation` keeper may hold an adapter; same shape as the #739 MF).
   `ReleasedLandTransport` (LKT :467–468) keeps its overrides (they count drops).
6. **(c1) Remove the defaults** of `runsSyncPhaseInTurn(of:)` (LKT :370) and `runSyncPhaseInTurn`
   (LKT :402). Conformers: LKT's own 3 (ReleasedLandTransport + 2 internal) and TA's implement both.
   Test fakes lacking `func runsSyncPhaseInTurn` (grep, to confirm by the compile errors):
   LandKeeperReevaluationOutputModeTests (MockTransport), ReplaySequenceWatermarkTests
   (RecordingTransport :358), TransportRefusalTests (1 of 2), LandKeeper.swift itself has none. Each
   gets the explicit `false` / a phase that returns the deferred result — choose per fake by what it
   tests (a `.reevaluation` fake: `false`). TransportAdapterBenchmarkHandle only returns the adapter.
   Must-not-compile: `scripts/must-not-compile/transport-without-in-turn-phase.swift`, first line
   `// expect-error: does not conform to protocol 'LandKeeperTransport'`, a class implementing every
   other requirement; run `scripts/check-must-not-compile.sh`.
7. **pendingFold nit** (#739): a tick turn with no port (`setTransport(nil)` after a folded sync)
   never calls `takePendingFold` (LK :4955 `if let transport`), so `pendingFold` / `inTurnSyncDue`
   stay set. Fix: `else { pendingFold = nil; inTurnSyncDue = false }` at :4955, plus a test (fold,
   detach, tick, attach → no late-tick report from the stale fold; `inTurnSyncDue` false).
8. **Census**: every deleted symbol at allowlist 0 (beginSync, beginSyncLocated, endSync, isSyncing,
   syncOnlyTurnAfterLegacyCycle, runLegacyPass, finishTicklessLegacyPass, deliverLegacyPass,
   legacyDeliveries, runTicklessJobPass, _syncBroadcastOnlyImpl, .broadcastOnly, syncInFlight, the 4
   hold points); drop the allow lines for the removed test files/decls; revert check (census fails
   on the parent).
9. **Docs** en + zh-TW: `docs/core/runtime.md` :41–62, :94–104, :444–478 (the legacy section and
   beginSync code blocks go; sync described as the in-turn phase only); `docs/transport/README.md`
   (c1: a transport must implement both); `LandError.swift:21` comment; TA :405 comment;
   `Examples/GameDemo/docs/benchmarks/WORKER_POOL_ANALYSIS.md:230` (`keeper.beginSync()` → the
   in-turn sync phase; separate Examples commit). CLAUDE.md/AGENTS.md: already at the L2d end state since #739; check the wording still holds,
   change nothing unless it doesn't (the maintainer's OK).
10. **Plan status**: §3.8.5 L2d-3 row done with commit SHAs; §3.8.12 correction (legacy pass scope,
    outcome A/B); status index row in Notes/plans index.

Gate: full `swift test`, census + revert check, must-not-compile script, GameDemo build, harness,
portless fixtures + ReevaluationRunner records byte-identical base vs head, pre-push, privacy grep.

## 3. Public API (for the maintainer; foundation-before-release: no external users, no deprecation)

Removed (source break):
- `LandKeeper.beginSync(clearDirtyFlags:) -> State?`
- `LandKeeper.endSync()` and deprecated `LandKeeper.endSync(clearDirtyFlags:)`
Changed (source break for conforming types):
- `LandKeeperTransport.runsSyncPhaseInTurn(of:)` and `runSyncPhaseInTurn(...)` lose their default
  implementations: every conformer must implement both; one that doesn't stops compiling
  (must-not-compile case pins it). Today the default `false` makes a conformer silently fall to a
  refusal at attach (L2d-2 (r)) — the break moves that from run time to compile time.
Added (additive):
- default (do-nothing) implementations of `syncNowFromTransport()` and `syncBroadcastOnlyFromTransport()`.
Not public (package/internal): `beginSyncLocated`, `InTurnSettleRefusal.syncInFlight`,
`syncOnlyTurnAfterLegacyCycleForTesting`, `SyncTurnReason.broadcastOnly`, the hold points, the two
ForTesting hooks.

## 4. A/B (sized to risk)

Live tick path touched: (3) removes `isSyncing` checks that are always false on a live keeper (no
Sources caller of beginSync), (7) adds a branch on the no-port tick path only (worker-pool arms
build portless keepers, so they take it: one nil-store per tick). Everything else is off the live
path (legacy pass, latch, settle, docs, compile-time defaults).
Recommendation: no host A/B; Mac output check instead (portless fixtures + Runner records
byte-identical; the pendingFold branch writes nothing to output). If review wants evidence for (7),
it is a 1-cell portless smoke (instructions:u), not a full A/B — Q3.

## 5. Open questions

Q1. Outcome A: else branches on a `.reevaluation` keeper → `preconditionFailure` (with one exit test),
    or remove the branch and let `.reevaluation` route through the turn? Recommend preconditionFailure:
    a replay keeper's inputs come from the record; #612 decides its turn routing.
Q2. Adapter `syncBroadcastOnlyFromTransport` forward: the plan deletes it, but `.reevaluation` +
    `transportAndSink` may attach an adapter (refusal exempts `.reevaluation`), and processPendingActions /
    replayed passes still call it — deleting changes that keeper's output, the same shape as #739's MF.
    No Sources path builds such a keeper. Recommend: keep the forward + `_syncBroadcastOnlyImpl` until
    #612 (consistent with the MF), still add the defaults; or delete and state the behavior change.
Q3. pendingFold fix: its own A/B cell or none (recommend none, Mac output check)?
Q4. Outcome B: convert `.reevaluation` tests that feed live inputs to record replays (scope grows), or keep
    the entries they hit until #612?
Q5. One PR or two (keeper/adapter deletions vs c1 + forwards defaults)? Recommend one; commits split as §2.

## 6. Provisional answers (to be confirmed in review)

- Q1: `preconditionFailure`, plus one exit test.
- Q2: keep the adapter's `syncBroadcastOnlyFromTransport` forward and `_syncBroadcastOnlyImpl` until #612; still add the defaults (same shape as #739's must-fix).
- Q3: no A/B cell of its own when the live-path edits are only the always-false `isSyncing` checks and one nil-store on the no-port tick; a Mac byte-identical output check instead. Review confirms the tier.
- Q4: if the probe is red, convert a test when it is really about live behaviour; keep an entry until #612 only where a test needs a `.reevaluation` keeper fed live inputs, and list those tests.
- Q5: one PR, commits split as §2.
- Public API removals (§3) go to the maintainer before code starts.
