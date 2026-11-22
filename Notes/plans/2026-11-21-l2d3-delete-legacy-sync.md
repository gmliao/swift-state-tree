# L2d-3: delete the keeper's legacy sync and pass, and require the in-turn phase (#546)

Status: implemented on `refactor/546-l2d3-delete-legacy-sync` (rev 2 GO); what the implementation found is in §7. Part of `2026-11-20-remove-adapter-off-mode.md` §3.8 (the L2d-3 row of §3.8.5).
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
- (A) green with every entry stopped → the pass is dead in both modes; delete it wholesale as the
  plan says, and replace each else branch with a `fatalError` (Q1, decided): these are public
  entries, so a `.reevaluation` keeper fed a live input is host misuse, and `preconditionFailure`
  would drop its message in `-O` (the L2d-2 (r) rule). One private helper, called at each branch
  before anything is appended or awaited where the branch allows it, with the message
  `LandKeeper(\(landID)): a re-evaluation keeper takes no live input; it replays recorded passes (#612)`.
  Only the tickless else branches get it: a `.reevaluation` tick land still queues inputs for its
  `runTick` (#612 decides that path).
  Superseded at review: no stop is added (§7, "No stop on a re-evaluation keeper").
- (B) some `.reevaluation` test reaches it → per test, in this order (Q4, decided):
  1. the test is about replay → it replays a recorded record (the path Sources uses);
  2. the test is about live behaviour → it uses a live keeper;
  3. only a test that truly needs a replay keeper fed live inputs keeps the entry it hits until
     #612, listed in the PR body with its reason.

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
   and add one at each else branch listed in §0 (the probe may keep `preconditionFailure`: a debug
   test run prints its message); full `swift test`. Record outcome A/B, and for B each test with its
   §0 step, in the PR body.
2. **Keeper: delete the legacy pass** (outcome A; B keeps what its tests hit):
   - `runLegacyPass` :4142, `finishTicklessLegacyPass` :4072, `deliverLegacyPass` :4116,
     `legacyDeliveries` :844, `legacyPassCallers` :4128 and the `legacyPass*` dicts, `runTicklessJobPass`
     :2465, `ticklessJobTurns` filter in processPendingActions :4002–4010.
   - the else branches in join/joinReportingAdmission/leave/submit/completeAction/runForceShutdown/
     handleClientEvent/kickServerInputTurn (`inTurn` local goes).
   - hooks `runTicklessJobPassForTesting` :2461, `runLegacyPassForTesting` :2462.
   - hold points `.legacyShutdownPass` (:2907), `.ticklessJobPass`, `.legacyDelivery`.
   - the `fatalError` helper of §0 (A) at each tickless else branch (superseded at review: no helper is added, see §7).
   - Tests (superseded at review, see §7): `LegacyEntryStopTests` becomes "A re-evaluation keeper stops on a live input (#546 L2d-3)":
     exit tests per entry kind, each checking the message (in every build: `fatalError` keeps it),
     covering at least join, action, client event and server input; all 8 branches if the toolchain
     allows. Parameterized over the branches with a `Codable & Sendable` entry enum in an explicit
     capture list if the pinned 6.2.4 accepts it (an implicit capture is what failed in L2d-2: "C
     function pointer cannot be formed from a closure that captures context"); otherwise one test per
     entry kind. `TicklessActionJobTests` off arm (:271, :286, `.ticklessJobPass` :425) deleted,
     `inTurn:` parameter dropped.
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
     SyncStreamProducerTests 2 (:519), TransportAdapterDebugFreezeTests 2, SettleFenceBindingTests 2:
     `syncInFlightLeavesNoBinding` (:63) is deleted with its refusal. Its claim, "a refused settle
     leaves no binding" (#739's should), stays pinned by `nonSettlePortLeavesNoBinding` (:50, "A port
     that runs in turn but isn't a settle port is refused and leaves no binding", `.refused(.notCurrent)`);
     the suite's title already states the rule. If review wants a second refusal kind pinned, the
     same check on `.refused(.released)` (a stale fence generation) is one more test.
     TransportAdapterSyncConcurrencyTests comment :4.
4. **Adapter: settle retry** — delete `case .refused(.syncInFlight)` and its 2 ms retry (TA :6242–6252,
   `TODO(#546 L2d-3)`). Same commit as 3 or right after (the case stops compiling with 3).
5. **Forwards**: do-nothing defaults for `syncNowFromTransport` / `syncBroadcastOnlyFromTransport` in
   LKT's extension. The adapter keeps both forwards until #612 (Q2, decided): its
   `syncBroadcastOnlyFromTransport` forward (TA+LandKeeperTransport.swift:22), `_syncBroadcastOnlyImpl`
   (TA :5098) and `SyncTurnReason.broadcastOnly` stay, so does
   `TransportAdapterRequestedSyncTurnTests.broadcastOnlyBridgeIsARequestedTurn`; `_syncNowImpl`
   (TA :3126) stays. Reason: a `.reevaluation` keeper with `transportAndSink` may hold an adapter, and
   its `processPendingActions` / replayed passes still call the forward (the same shape as #739's MF).
   Their doc comments say they serve only re-evaluation keepers until #612.
   `ReleasedLandTransport` (LKT :467–468) keeps its overrides (they count drops).
6. **(c1) Remove the defaults** of the three requirements §3's table makes required:
   `runsSyncPhaseInTurn(of:)` (LKT :370), `runSyncPhaseInTurn` (LKT :402) and
   `waitForWriterDrainForInTurnSync()` (LKT :390). The other defaults stay (table).
   Conformers (26 types: 24 test fakes, the adapter, `ReleasedLandTransport`; a grep of `func <name>` per file, to be confirmed by the compile errors):
   - `TransportAdapter` and `ReleasedLandTransport` implement all three.
   - Lacking `runsSyncPhaseInTurn` and `runSyncPhaseInTurn`: `LandKeeperReevaluationOutputModeTests.MockTransport`
     (:41, a `.reevaluation` fake → `false` and `InTurnSyncOutput(.unsupported)`) and
     `TransportRefusalTests.NonOptingPort` (:8: the refusal's own fake, so it now states `false` and
     `.unsupported` explicitly; the refusal tests keep their meaning).
   - Lacking `waitForWriterDrainForInTurnSync`: all 24 test fakes: the 22 that already implement the phase pair, plus MockTransport and
     NonOptingPort (ActionEventSync's MockLandKeeperTransport, DrainTurn ×2, InTurnSyncFoldReport,
     InitializeResolverFailure, LandDSL, LandFailure, LiveRoutingPin, PerSequenceResult ×3,
     ReplaySequenceWatermark, RequestedSyncTurnKeeper, ResolverDeadline, ResolverDelivery, ServerInput,
     ShutdownTurn, SyncRegistration, TicklessActionJob, TicklessReplayPass, TransportRefusal.OneKeeperPort,
     TwoPhaseHandler, SwiftStateTreeTransportTests' MockLandKeeperTransport). Each gets
     `func waitForWriterDrainForInTurnSync() async {}`, except a fake that returns `.deferredBackPressure`:
     of the keeper fakes only InTurnSyncFoldReportTests' mentions it (check at implementation); a fake
     that defers gets a real wait or a gate, not the empty one.
   `TransportAdapterBenchmarkHandle` only returns the adapter.
   Must-not-compile, one case per removed default, each a class implementing every other requirement,
   first line `// expect-error: does not conform to protocol 'LandKeeperTransport'`:
   - `transport-without-in-turn-phase.swift`: no `runsSyncPhaseInTurn`, no phase;
   - `transport-without-sync-phase.swift`: `runsSyncPhaseInTurn` but no `runSyncPhaseInTurn`;
   - `transport-without-writer-drain.swift`: both, but no `waitForWriterDrainForInTurnSync`.
   Run `scripts/check-must-not-compile.sh`.
7. **pendingFold nit** (#739): a tick turn with no port (`setTransport(nil)` after a folded sync)
   never calls `takePendingFold` (LK :4955 `if let transport`), so `pendingFold` / `inTurnSyncDue`
   stay set. Fix: `else { pendingFold = nil; inTurnSyncDue = false }` at :4955, plus a test (fold,
   detach, tick, attach → no late-tick report from the stale fold; `inTurnSyncDue` false).
8. **Census**: every deleted symbol at allowlist 0 (beginSync, beginSyncLocated, endSync, isSyncing,
   syncOnlyTurnAfterLegacyCycle, runLegacyPass, finishTicklessLegacyPass, deliverLegacyPass,
   legacyDeliveries, runTicklessJobPass, syncInFlight, the 4
   hold points); drop the allow lines for the removed test files/decls; revert check (census fails
   on the parent).
9. **Docs** en + zh-TW: `docs/core/runtime.md` :41–62, :94–104, :444–478 (the legacy section and
   beginSync code blocks go; sync described as the in-turn phase only); `docs/transport/README.md`
   (c1: a transport must implement the three; what each kept default means for it, per §3's table); `LandError.swift:21` comment; TA :405 comment;
   `Examples/GameDemo/docs/benchmarks/WORKER_POOL_ANALYSIS.md:230` (`keeper.beginSync()` → the
   in-turn sync phase; separate Examples commit). CLAUDE.md/AGENTS.md: already at the L2d end state since #739; check the wording still holds,
   change nothing unless it doesn't (the maintainer's OK).
10. **Plan status**: §3.8.5 L2d-3 row done with commit SHAs; §3.8.12 correction (legacy pass scope,
    outcome A/B); status index row in Notes/plans index.

Gate: full `swift test`, census + revert check, must-not-compile script, GameDemo build, harness,
portless fixtures + ReevaluationRunner records byte-identical base vs head, pre-push, privacy grep.

## 3. Public API

**Decided (the maintainer, 2026-11-21):** remove the APIs and defaults below directly, no
deprecation (foundation-before-release: no external users). This covers any further in-turn
requirement this plan makes required (the same kind of removal). Code starts only after Review GOs
this revision.

Removed APIs (source break):
- `LandKeeper.beginSync(clearDirtyFlags:) -> State?`
- `LandKeeper.endSync()` and the deprecated `LandKeeper.endSync(clearDirtyFlags:)`

Removed defaults (source break for conforming types; each pinned by a must-not-compile case):
- `LandKeeperTransport.runsSyncPhaseInTurn(of:)`
- `LandKeeperTransport.runSyncPhaseInTurn(state:events:includeSync:recording:)`
- `LandKeeperTransport.waitForWriterDrainForInTurnSync()`
Today the default `false` makes a conformer fall to the attach refusal (L2d-2 (r)) at run time; the
break moves that to compile time.

### Defaults that a transport answering `runsSyncPhaseInTurn` true could inherit

Read from each default (LKT :368–410) and every keeper read (LK, at 90aa89a6). "In-turn join" means
an admission through `joinReportingAdmission(admitThroughTransport: true)`, a `package` entry only the
adapter calls (TA :2235); the public `join(session:clientID:sessionID:services:)` passes `false` (LK
:1913), so for any transport outside the package `admitJoiningSession` is never called.

| Requirement | Default | Keeper reads it when | Decision | Reason |
|---|---|---|---|---|
| `runsSyncPhaseInTurn(of:)` | `false` | attach (refusal), and once per turn (`syncsInTurn`) | required | the whole c1 point: `false` is never right for a live keeper's transport |
| `runSyncPhaseInTurn(...)` | `.unsupported` | every turn's output step when `syncsInTurn` | required | a transport that answers true and inherits `.unsupported` sends nothing, silently |
| `waitForWriterDrainForInTurnSync()` | returns at once | after a phase returns `.deferredBackPressure` on a land without periodic sync (LK :5374, `retrySyncOnlyTurnAfterWriterDrain`) | required | the default is right only for a transport that never defers; one that defers and inherits it retries a sync-only turn at once, again and again, until its writer drains (a hot loop on the keeper's executor). `.deferredBackPressure` is a public case, so an outside transport can return it |
| `admitJoiningSession(...)` | `.notAdmitted` | `admitJoiningInTurn` (LK :2133), only on the package in-turn join path, `syncsInTurn` | keep | unreachable outside the package (above); and `.notAdmitted` is a complete path, not a starvation: the join awaits its OnJoin turn (LK :2121) and its caller admits after it returns |
| `refusesResolvedJoin(...)` | `false` | `refusesResolvedJoinInTurn` (LK :2141), same conditions | keep | same; `false` = no stale-join refusal, the caller keeps its check by the requested player |
| `noteJoinInputsConsumed(_:)` | nothing | a turn that applied join inputs (LK :4235), live, `syncsInTurn` | keep | it matters only after `.admittedCompletesInTurn`, which only the package path can produce; a transport that never admits in turn has nothing to complete |
| `hasJoinsAwaitingSync` | `false` | land without periodic sync, deciding whether a turn runs a phase for ready joins (LK :2156) | keep | same: only joins admitted in turn wait on it |
| `recordsInTurnSyncFolds` | `false` | at attach (LK :486, :1053) | keep | profiling switch; `false` means the two notes below are never called |
| `noteInTurnSyncFold(_:)` | nothing | tick turn with a fold, only if `recordsInTurnSyncFolds` (LK :5041) | keep | profiling counter |
| `noteInTurnJoinSyncTick()` | nothing | join-only phase tick, only if `recordsInTurnSyncFolds` (LK :5012) | keep | profiling counter |
| `landDidFail(_:)` | nothing | teardown of a failed land (LK :5821) | keep | not in-turn specific; the keeper still tears down and calls the required `onLandDestroyed`, where a transport closes its sessions (with a generic code instead of 4016). Doc already says a transport holding sessions must close them |
| `closeOutputs(for:)` | nothing blocked | the failure's segment (LK :5818) | keep | an in-turn transport sends state and events only from `runSyncPhaseInTurn`, and the keeper runs no phase after a failure (LK :5320 `guard failure == nil`, `applyPendingTransportFailure`); only a transport with its own send schedule needs it, as its doc says |
| `syncNowFromTransport()` / `syncBroadcastOnlyFromTransport()` | nothing (new, §2 step 5) | only a `.reevaluation` keeper's legacy tail (until #612) | keep (new default) | no live keeper calls them after L2d-2 |

Doc change with the kept in-turn join defaults: `admitJoiningSession`'s doc names the pairing (a
transport that returns `.admittedCompletesInTurn` must also implement `noteJoinInputsConsumed` and
`hasJoinsAwaitingSync`), since that is the one combination that would starve a join. §6's follow-up asks whether
that group should leave the public protocol instead.

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

## 5. Open questions (rev 1; answers in §6)

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

## 6. Answers (rev 1 review and the maintainer)

- Q1: overturned in review: `fatalError` with the land named, exit tests per entry kind (§0 (A), §2 step 2).
- Q2: confirmed: the adapter keeps both forwards until #612; the defaults are still added.
- Q3: confirmed: no A/B cell of its own; Mac byte-identical output check.
- Q4: confirmed, with the order in §0 (B).
- Q5: confirmed: one PR, commits split as §2.
- Public API: decided by the maintainer (§3).

Follow-up, not L2d-3 (filed as its own issue after GO):
- The in-turn join group (`admitJoiningSession`, `refusesResolvedJoin`, `noteJoinInputsConsumed`,
  `hasJoinsAwaitingSync`) is reachable only through a package entry. Should it move to a package
  refinement protocol (as `LandKeeperSettlePort` did) instead of staying public with defaults? That
  is a further public removal, so it would be its own change after L2d-3; this plan keeps the
  defaults and documents the pairing.

## Rev 2: what changed

- Status line; §0 (A) and §2 step 2: `fatalError` naming the land with the #612 message, at the
  tickless else branches only; exit tests per entry kind (at least join, action, client event,
  server input; all 8 if the capture list works on 6.2.4); the probe may keep `preconditionFailure`.
- §0 (B): the per-test order (recorded replay → live keeper → keep the entry, listed with a reason).
- §2 step 3: `syncInFlightLeavesNoBinding`'s claim stays pinned by `nonSettlePortLeavesNoBinding`
  (named), not just dropped.
- §2 step 5: the adapter's forwards, `_syncBroadcastOnlyImpl` and `.broadcastOnly` stay until #612
  (Q2); the census list in step 8 no longer counts them as deleted.
- §3: the maintainer's decision recorded with the final removal list; a table for every defaulted
  requirement; `waitForWriterDrainForInTurnSync` becomes required too; the in-turn join pairing
  documented.
- §2 step 6: three removed defaults, the full fake-fix list (2 fakes for the phase pair, 24 for the
  drain wait), and three must-not-compile cases (one per removed default).
- §6: answers recorded; the join-group refinement protocol noted as a follow-up outside L2d-3.

## 7. Implementation notes

- **Probe: outcome A.** A stderr marker (no trap) at the 8 tickless else branches and the 3 legacy
  entry functions, then the full `swift test` at 6f568ff6: 0 hits, every test run green. The legacy
  pass was deleted wholesale; no entry is kept for #612.
- **No stop on a re-evaluation keeper (review of #746, maintainer chose option a).** The first
  implementation put a `fatalError` at the start of join, session join and leave on a tickless
  `.reevaluation` keeper. Its premise was wrong: at 6f568ff6 no `.reevaluation` keeper, tick or
  tickless, reached the legacy pass from those entries. Each inserted or removed the player as an
  observer and returned at its `mode != .reevaluation` guard before the OnJoin / OnLeave append,
  which is why the probe found 0 hits. So the stop removed working behaviour, and a tick
  re-evaluation keeper never "queued" those calls either. The stop is dropped: both kinds take a
  live join or leave as observer membership only, as at base, and L2d-3 stays a pure deletion.
  How a re-evaluation keeper takes live input is for #612 to design by structure or type, not by a
  runtime special case. `ReevaluationLiveInputTests` pins today's behaviour on both kinds (player
  count, nothing queued, no OnJoin / OnLeave); action, client event and server input get the plain
  test that they are refused and apply nothing. Its other live entries refuse a `.reevaluation`
  keeper before any branch: `submit` (actions, and so their job completions) and
  `handleClientEvent` return without applying, `submitServerInput` answers `.refused(.notLive)`,
  `submitLandFailure` returns, and `forceShutdown`'s queued path needs `mode == .live`.
- **`TicklessActionJobTests` keeps both arms.** Since L2d-2 the `inTurn: false` arm is a portless
  live keeper, which routes through turns too; dropping it would lose the portless coverage the
  benchmark worker pool relies on. The parameter is renamed `withPort:`, and the two legacy-named
  tests are renamed for the portless keeper.
- **`ReleasedLandTransport` relied on the removed defaults** (§2 step 6 said it implemented them).
  It now answers `runsSyncPhaseInTurn` false, returns `.unsupported` (counted as a dropped call)
  and returns from the drain wait at once.
- **Must-not-compile:** a compiling control (a transport with exactly the required calls) plus one
  refused case per removed default.
- **Fakes:** 27 test conformers changed, not 24: §2 step 6's list has 25 types (its count was off
  by one), plus the dirty-flags spy this PR adds to `LandKeeperSyncLockTests` and `SettlePortFake`
  (#739), which conforms through `LandKeeperSettlePort` and so wasn't in the plan's grep.
