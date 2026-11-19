# A differential test harness for TransportAdapter's turn-core rewrite (#555)

**Status:** rev 9 (2026-11-19): the section below changes the comparison from two adoption levels to golden captures; rev 5 was GO. **Issue:** #555 (part of #546). **Base:** `main` at cef7177c.

## Rev 9: one rewrite branch, compared with golden captures

**Decision (maintainer, 2026-11-19).** #546 rewrites `TransportAdapter` onto the turn core on one branch, in one go, instead of slice by slice behind an adoption level on `main`. The harness compares that branch with golden captures recorded on `main`. This section is the delta. Where it and the sections below disagree, this section holds. Q3 and everything else the review passed in rev 5 stay.

Rev 9 answers the review of rev 8 (312483fd):
- the cycle row gets a witness per sync mode;
- the rows' post-conditions read named test observations, not adapter internals;
- sync lag is off through an explicit disable, and the resolver-deadline override is wired into the harness suite and checked there;
- the retirement list is checked as an exact set, and each replacement names a mutant it must kill;
- `keeperJoinReturned` gets its own hold, and the flip is controlled;
- the record-determinism claim is narrowed.

The gate's SHA binding and the recorder's details are settled in step 2's PR (below, "Settled in step 2").

Rev 8 answered the review of rev 7 (2340cf69):
- deterministic record bytes, through injected record metadata;
- a retirement list the runner reads;
- the moved holds placed on boundaries that suspend, with a post-condition per row;
- the inventory's gaps: sync lag, resolver deadlines, tick count, frame order and the exclusions;
- a gate anchored in workflows `main` controls;
- one #638 rule;
- the recorder script's steps.

Rev 7 answered the review of rev 6 (b4ac6e88): cross-process stability, holds as semantic boundaries, the freeze from recording on, the protected paths and the gate, the inventory and the decoded-view check.

**What stays.** The harness still lands on `main` first: the scenarios (§8), the barrier and the two checkpoints (§5.3), the stable identities (§5.4), the record capture and its field list (§5.5), the property oracle (§5.6) and the comparator's strictness (§5.7). Both approaches need them.

**Dropped.**
- §4 as a whole: no `TransportAdapterAdoption`, no `TRANSPORT_ADAPTER_ADOPTION` key, no `adoption` parameter on `LandManager` or the adapter, no configuration override, and no startup refusal. Step 1 had them in code; they are taken out again before its PR, so no new server setting ships.
- The in-process comparison of two levels, and the clean capture under `.build` (§7 (b)).
- §1's "one level only until slice 1" and §9's "twice that once a second level exists".

### Goal and prior art (§1, §2)

The two implementations are `main`'s adapter, as recorded in its golden captures, and the rewrite branch's adapter. Each runs in its own build and process. The harness ships on `main` before the rewrite, and its own checks (§7) run against `main`.

Differential testing still applies: two implementations, the same inputs. But the reference side's outputs are stored, not produced in the same run. Two things follow:
- the golden table's failure modes now cover every scenario;
- variation that both sides used to share in one process (the hash seed, the platform, the toolchain) no longer cancels out. The goldens have to be stable across processes, below.

### Assembly and test support (§3)

Unchanged except that the build forwards no level. Step 1 as built:
- the build is `NIOLandServer`'s `package` init with `autoStartLoops`, which the public init calls with `true`;
- `attach()` installs the router as the transport's delegate, and the host awaits it before the route goes live;
- the failure-stop wiring stays in the init, which is synchronous and runs before any land exists, so `attach()` only installs the delegate.

`Deadline` stays in `Sources` for now. No library code calls `raceDeadline`: `WebSocketSessionHandler`'s close grace uses the event loop's `scheduleTask`. Its callers are tests in all three test targets. Moving it would make `SwiftStateTreeTests` depend on the support target, which step 1 doesn't otherwise need, so the move is a later cleanup. The support target holds `TestGate`, `RecordingConnection` and the record field walk and list.

### Golden captures (§5.8, replaced)

**Rules of §5.8 that stay:** the folder found from the harness's own source file (`#filePath`), with no `resources:` entry; frame-changing env settings pinned through the harness's parameters, else in the file's key; the update key as a named constant beside the harness, printing the changed paths; a PR that changes a golden names each file, and review reads the diff; a missing file fails. **Replaced:** the set, the format, what is compared, and how files are recorded.

**Comparing the record.** The record's bytes are compared first. If they differ, the comparison walks the two decoded records by field path (§5.5) and lists each differing path:
- a `recordField` expected difference (§6, the #548 entry) excuses its path, with its exact values;
- every other differing path fails;
- bytes that differ while no path differs fail too: the record format is shared code, and the rewrite doesn't change it.

**Set.** Every scenario, in every cell it applies to (sync mode × land kind × encoding), one file per scenario and cell. An index file in the golden folder lists every expected scenario and cell. A cell without a file fails, and so does a file that no scenario and cell claims.

**Format.** JSON with sorted keys, stable and diffable:
- per connection, each frame as base64 bytes plus its decoded view;
- the closes and the responses;
- the record as base64 bytes of the saved file, plus its decoded view;
- the commit, platform and Swift version it was recorded with.

**Deterministic record bytes.** The land manager writes `createdAt: Date()` and `HardwareInfoCollector.collect()` into the record's metadata (`LandManager.swift:728–747`), and `setMetadata` puts them in the file's header. So step 2 adds a `package` record-identity override to the assembly: a fixed `createdAt` and no hardware info, applied when the metadata is built, before the first header is written. With it, the two identity fields no longer vary between processes: they are pinned at the source instead of rewritten afterwards. The rest of the record (caller metadata, payloads, failure details) is as deterministic as the scenario's fixtures and the order rules below make it; the five-process check is what proves the whole file stable. The field list keeps them, with the rule "pinned by the override", so a new wall-clock field still fails until it is classified.

**A golden's decoded view is derived from its bytes, and checked against them,** when it is recorded and each time it is compared. The harness decodes each frame's bytes with the cell's encoding, and the record's bytes with the record decoder. Each must equal the stored decoded view. At recording, a mismatch writes nothing; at comparison, the file fails as corrupt. So review can trust the readable diff: a decoded view can't differ from its bytes.

**Nondeterminism inventory.** Every value that can reach a capture without being fixed by the code under test, and how it is pinned. The list comes from a search of the library's sources for `UUID()`, `Date()`, `random` and process identity, plus hash-seeded order. It is the full list; the five-process recording below catches a source it misses.

| Value | Where it reaches a capture | Pinned by |
|---|---|---|
| `ClientID` (random six characters) | record entries, event targets | the client-ID supplier, by connection attempt (§5.4) |
| `SessionID.mint()` (random UUID) | frames, record | not used: the runner names every session (§5.4) |
| `LandID.generate` (random instance) | frames, record | not used: every join and create names its instance |
| player IDs, request IDs, join metadata | frames, record | fixed in the scenario (§5.4) |
| record `createdAt` | record metadata, file header | the record-identity override: a fixed date |
| record `hardwareInfo` | record metadata, file header | the record-identity override: none |
| `rngSeed` and the land's `random` | record metadata, state | derived from the land ID, which the scenario fixes |
| tick IDs, sequences, sync marker indices | frames, record | advanced only by stepped inputs, with the step rule below |
| dictionary and set order | any encoded map | not pinned in-process: per-process hash seeds; caught by the five-process recording |
| real ports and addresses | none | the fake connections have none (§5.2) |
| join budget and flip timer | whether a join times out | pinned off (§8) |
| resolver deadline (5 s, `ContinuousClock`) | a held resolver's outcome | off, through `.resolverDeadlinesOff` (below) |
| sync lag (`SyncLag.swift:94–104`, `ContinuousClock`) | a resync, suppressed output or a lag close on a slow runner | off, through an explicit disable (below) |
| frame order on one connection | frames | the frame-order rule below |
| env-derived configuration (`TRANSPORT_ENCODING`, `IN_TURN_SYNC`, `USE_SYNC_TABLES`, `PER_PLAYER_SYNC_TABLES`, `ROW_ADDRESSING` and the other `SERVER_ENV` keys) | frames, record | pinned through the harness's parameters; the golden's key stores the effective values, and the comparison refuses a run whose values differ |

**Sync lag off.** Passing no policy doesn't turn lag off: `LandManager` hands a policy to the adapter only when one is given (`:704–706`), and otherwise the adapter keeps `SyncLagPolicy.fromEnvironment()` (`TransportAdapter.swift:348`), whose `ContinuousClock` decisions stay live. Step 2 adds an explicit `package` disable: a policy value that makes no lag decision, which the assembly passes to every adapter it builds. The runner asserts, through a `package` read, that each adapter in the run has it.

**Resolver deadlines off.** `.resolverDeadlinesOff` is a trait in the core and Transport test targets. It sets `ResolverDeadline`'s two task-local overrides to `.zero`. Step 2 adds the same trait to the NIO test target and applies it to the harness suite. A task-local reaches only work started inside its scope, so step 2 also checks that it reaches the adapter's resolver work: one harness self-check runs a resolver that reads the effective deadline from inside `resolve` and asserts it is off.

**Excluded, with the reason.** `ProcessInfo` and hardware values reach only the record's metadata, pinned by the override above. Wall-clock values outside this list don't reach a capture: the land manager's activity and creation times and the transport's log throttling feed admin routes and logs, which aren't compared (§3), and the recorder's spool file name is a path, not record content.

**Step rule (tick count).** The runner never steps in a loop on a condition. Before each step it waits for the event that makes the step do its work: the input is enqueued, or the join's transport registration is done. Then it steps once. Each scenario lists its steps, so the tick count is part of the scenario, and the record's tick IDs pin it. The follow-up turn a sync phase can request (`requestJoinSyncTurn`) is a milestone the runner awaits before the next step, not something it steps for. A scheduler-dependent extra tick would change the record and fail the five-process check.

**Frame-order rule.** On each connection the frames come from a known set of producers: the router's join response, the adapter's initial sync, sync updates, events, action replies, error frames and the close. Each step declares the frames it expects per connection, by kind and in order. The runner waits for them before the next step that can write to that connection. Within one step, at most one producer writes to a connection, unless the step's holds order them. So the order before each flush is fixed by milestones, not by the scheduler.

**Cross-process stability.** Swift seeds hashing per process, so dictionary and set order can differ between two processes and agree within one. The recorder script, which step 2 adds:
1. **Build once,** in the pinned image named by digest and architecture (`swift:6.2.4-noble@sha256:…`, `linux/amd64`), the one CI uses: `swift build --build-tests`.
2. **Run five times, in sequence,** each a separate `swift test --skip-build` process filtered to the harness, with `SWIFT_DETERMINISTIC_HASHING` unset (the recorder refuses if it is set). The harness suite is serialized within each process. Each run writes its candidates into its own output folder, emptied before the run.
3. **Check each candidate set** against the full index: every scenario and cell present, nothing extra, each decoded view equal to its bytes, and the oracle passed.
4. **Compare the five sets** byte for byte. A difference fails, naming the scenario, the cell and the first differing field.
5. **Publish** into the golden folder only after all five pass every check. Otherwise it writes nothing.

Five, not two: an order over two keys agrees between two seeds half the time, so two processes miss a seed dependency often; five miss it one time in sixteen. After that, every CI run is one more fresh process compared with the goldens, so a dependency that slipped through shows as a failing cell with its decoded diff.

The recording also writes nothing when the property oracle (§5.6) fails on any of the runs, so a shared bug isn't frozen into a golden.

**Where it is the gate.** The CI jobs in the pinned image compare bytes and decoded views. A run on another platform or toolchain (a local macOS run on Swift 6.3) compares the decoded views only and skips the byte comparison. It prints one line naming the golden's platform and Swift version and its own, and says the pinned-image CI is the gate.

**Recording on `main`.** Only with `SST_UPDATE_GOLDEN=1`, through the script, on a branch for `main`. Step 2 lands the recorder and the first goldens in one PR:
- the code commits come first;
- the goldens are recorded by the script at the last code commit, in their own commit that adds only golden files and names that commit;
- the PR's CI then compares the goldens in a fresh process, which is the first cross-process check after the five;
- Review checks that the golden commit touches only the golden folder and names the commit before it.

### Expected differences (§6)

The list applies to golden versus branch. `legacy:` becomes `golden:` and `adopted:` becomes `branch:`. The rules (exact, one cell, one use, stale and overlap fail, masked cells) are unchanged. The first list moves from slice 1 to the rewrite branch: the #548 entry, and the pre-admission disconnect as no difference (Q3). For #588, each refusal source is compared with its golden.

### Checks of the harness itself (§7)

- **(a) Determinism:** the five-process recording above. A normal run compares each cell once with its golden.
- **(b) Mutants:** each mutant's run is compared with the goldens, and the scenario that claims its channel must fail.
- **(d) Golden:** adds three checks:
  - an update whose processes differ writes nothing;
  - a golden whose decoded view doesn't match its bytes is refused at recording and fails at comparison;
  - a record whose bytes differ while no field path differs fails;
  - under the verify key (below), `SST_UPDATE_GOLDEN=1` fails the run at start.
- **(f) Oracle:** a mutant that breaks a property on `main` must fail the recording, not only a normal run.
- (c), (e) and (g) are unchanged.

### Holds as semantic boundaries (§8)

A rewrite onto the turn core can't keep "the matching await": inside a turn there is none, and the adapter's operations change shape. So each hold is defined by a semantic boundary, and every gate sits where the code suspends, outside the adapter's turns. A hold is one of:
- **(a) A neighbour's boundary:** a hold point in the router, the keeper or the transport, or a gated land resolver, at a point where that code already suspends. These components aren't rewritten, so the hold is the same on both sides.
- **(b) The adapter's input boundary:** where a call or a reply enters the adapter, before the adapter acts on it; or where an input is accepted and waits for its turn.
- **(c) The adapter's output boundary:** where the adapter has issued a request to a neighbour and awaits it, before the neighbour takes it.

On `main`, each of these is an await in an adapter operation. On the branch, (b) and (c) are where an input arrives and where a turn's request leaves; both are outside any turn. The branch provides each hold under the same name. No hold sits inside a synchronous function of the adapter or of a neighbour.

Reaching a hold proves only that the code passed there. So each row also states a **post-condition** that proves the race happened, and the runner asserts it.

**Named test observations.** The post-conditions don't read adapter internals (`joiningSessions` is private, and `transportRegistered`, `syncSkips` and `teardownTicketEnds` may not exist in a rewrite). Each is a named observation with a meaning. Step 2 adds a `package` read for each on `main`. The branch provides each with the same meaning, as with the hooks of §5.3 and §5.4, and they are part of the harness's interface.

| Observation | Meaning | Read on `main` from |
|---|---|---|
| `admittedNotRegistered(session)` | the keeper admitted the player and the adapter holds the admission, but the session isn't registered with the transport | the in-turn join record with `transportRegistered == false`, and the transport's registration table |
| `joinFlipped(session)` | the in-turn join's flip completed | the join waiter resolved with success |
| `disconnectQueuedBehind(session)` | the session's disconnect is accepted and waits behind a held membership operation | the `membershipQueued` arrival, with no leave applied |
| `syncDeferredByCycle` | a sync request met a cycle in flight and was deferred to run after it | in-turn off: `syncSkips.busy`; in-turn on: the keeper's `syncOnlyTurnAfterLegacyCycle` (`LandKeeper.swift:4610–4614`) |
| `teardownTicketsEnded(session)` | the membership teardown was applied to the session's tickets | `teardownTicketEnds` and the session's ended tickets |
| `pendingActionOwned(session, requestID)` | the pending action's job is still owned by that session | the adapter's tracked action-response tasks |

| Row | Hold | Kind | Post-condition |
|---|---|---|---|
| router rows (`beforeAdmit`, `afterAdmit`, `sendingJoinResponse`, `sendingInitialSync`) | as today | (a) | as §8.1 states each |
| keeper `.join` | as today | (a) | the disconnect's `membershipQueued` arrival is observed while held, and its leave hasn't applied: the keeper still has no player; after release, admitted then left |
| a disconnect before the keeper's admission | adapter `admitJoinEntry` | (b) | `disconnectForwarded` completes while the hold is closed; after release, the attempt is refused as stale (`staleJoinAttemptsRefused == 1`), with no OnJoin, no OnLeave and no join response |
| a disconnect at the in-turn registration | adapter `keeperJoinReturned`, then `joinSyncRequested` (below) | (b), (c) | at `keeperJoinReturned`: `admittedNotRegistered(A)`, the keeper has the player, no join response, not `joinFlipped(A)`; the disconnect is sent and `disconnectQueuedBehind(A)` holds. At `joinSyncRequested`: registered, still not `joinFlipped(A)`, and `disconnectQueuedBehind(A)` still holds. After release, per land kind (below): the flip and the leave each happen once, in the order the golden fixes, and the observations agree with the frames (a join response only if `joinFlipped(A)`) |
| a join while a sync cycle is in flight | adapter `cycleBeforeEndSync` | (c) | while held, the runner makes a state change and steps a tick; `syncDeferredByCycle` rises by one, and A has not received the change. After release, A receives it exactly once, as `syncDuringLegacyCycleRunsAfterEndSync` asserts. B's join is a second step under the same hold, and completes after the cycle |
| a stale action reply after a leave | adapter `actionResponse` | (b) | A's answer is held across A2's join and A2's pending action; after release, A's request gets no reply and no error frame on A or A2, A2 gets its own reply, and `pendingActionOwned(A2, its request)` holds until that reply |
| #548, a teardown during the keeper join | keeper `.join`, then the teardown input | (a), (b) | `teardownTicketsEnded(A)` while `.join` is held. The membership-and-generation snapshot is taken at the router's held `afterAdmit` (§8.1), after the admission returns and before the join response |
| a land stop | router `stopLeave(A)`, `stopLeave(B)` | (a) | both holds reached before either leave is queued; A's `membershipQueued` before B's release; OnLeave order A, B |

**The moved holds.**
- **`keeperJoinReturned`** replaces `registerSession`. `WebSocketTransport.registerSession` (`:500`) is synchronous, so a hold can't sit there. It is a hold of its own, `await holds.at(.keeperJoinReturned)`, right after a successful `await keeper.joinReportingAdmission` (`TransportAdapter.swift:2173`), taken only when the join completes in the turn (`completesInTurn`), as today's hold is (`:2205–2209`). The keeper's admission has already run, through the transport admission callback, so `admittedNotRegistered` holds there. On the branch it is where the keeper's join result arrives as an input.
- **`joinSyncRequested`** is a new (c) hold before `await keeper.requestJoinSyncTurn()` (`:2234`). That call can run a sync-only turn that flips the join (`LandKeeper.swift:1909–1923`) before the membership queue reaches the queued disconnect, so the row controls the flip with this hold instead of inferring it from the queue. After its release:
  - **tickless land:** the sync-only turn flips the join inside that call, and the join's queued operation then returns, so the leave applies after the flip;
  - **tick land with periodic sync:** the call returns without a turn when the tick's cadence sync is due; the runner then steps once, and the golden fixes the order of the flip and the leave in that tick.
  Either way the order is fixed by the code and the step rule, not by the scheduler, and the five-process check confirms it.
- **`cycleBeforeEndSync`** stays where it is on `main`: after the cycle's plan and before `await keeper.endSync()`. That is an await on a call into the keeper, so the cycle is suspended there, with the keeper's sync flag still set. `LandKeeper.endSync()` itself is synchronous, so no hold goes inside it. On the branch it is where the cycle's end-of-sync request leaves the adapter.

Step 2 rewrites these rows' schedules in §8.1 and refreshes §8.1's line references against the code it lands on.

The test hooks of §5.3 and §5.4 keep their meaning on the branch. One that returns early leaves frames or record entries out of the capture, and the golden comparison reports that.

**Retired rows: a list the runner reads.** The scenarios and the runner are protected (below), so retiring a row can't be a note in the PR body: the row would still run its hold, and the reach rule would fail it. Instead:
- `RetiredRows.swift`, beside `ExpectedDifferences.swift`, is unprotected. Each entry names the scenario, the cells, the reason, and a replacement test. The replacement is a function value the runner itself calls, so it is compiled and run, not only named.
- In each listed cell, the runner skips the row's run and its golden comparison, and runs the replacement instead. The index still claims the cell's golden.
- The entries are expanded to unique (scenario, cell) keys, and the runner checks exact set equality: the index's cells are the compared cells plus the replaced cells, and the two sets are disjoint. A duplicate key, a key the index doesn't have, and an expected difference aimed at a retired cell each fail.
- Each entry names a mutation witness: a source mutant that breaks the invariant the row protected. The replacement must fail with it. The branch PR shows each witness's failing output, as §7 (b) does for the harness's own mutants. So an empty replacement can't pass review.
- Replacement tests live in `Tests/SwiftStateTreeNIOTests/Differential/Branch/`, which is unprotected.
- Review reads each entry and its test; Main approves each one; the maintainer is told of the list at merge.

**New and changed scenarios** go to `main` first, with their goldens recorded there, and reach the branch by merging `main`. That replaces §8.1's "Growth" paragraph: the branch adds no scenario of its own, because no golden would exist for it.

### Matrix and CI cost (§9) and what it can't see (§10)

- One run per cell in CI: about 162 runs in the unrestricted leg and 84 in the `IN_TURN_SYNC=false` leg. Recording runs five times per cell, on `main`, only when goldens are updated. Step 2 states the golden set's file count and size.
- E2E and the load test compare the branch's server build with `main`'s, as for any PR. There is no level to choose.

### Freeze, protection and the gate

**Freeze.**
- It starts at the recording commit, the commit in step 2 that adds the goldens, and ends when the rewrite branch merges.
- From the recording commit until step 2 merges, step 2 merges `main` before it merges itself. If an adapter change landed on `main` in that window and changes a golden, step 2 re-records before it merges. Main announces the freeze when the recording commit is pushed.
- While the freeze holds, the adapter's files on `main` (`Sources/SwiftStateTreeTransport/TransportAdapter*.swift`, `MembershipCoordinator.swift`, `AdapterErrorMapping.swift`) take only the harness's own hooks.
- A fix that can't wait goes to the maintainer. Its PR re-records the cells it changes, with the diffs reviewed, and the same fix lands on the branch.
- **#638:** the planned order is that #638 merges before step 2 records. If #638 isn't merged when step 2 is otherwise ready, step 2 records without waiting, and #638 then re-records the hybrid cells in its own PR with an empty-diff check.

**Protected paths.** The branch may not change:
- the golden folder and its index;
- the harness's runner, scenarios, barrier, comparator and oracle (`Tests/SwiftStateTreeNIOTests/Differential/`), except `ExpectedDifferences.swift`, `RetiredRows.swift` and `Differential/Branch/`;
- the record field walk and list (`Tests/SwiftStateTreeTestSupport/RecordField*.swift`);
- the harness workflow and its scripts: the gate run's workflow file, the gate script and the recorder script.

A change to them goes to `main` first, under the same review, and reaches the branch by merging `main`.

**The gate, anchored in `main`'s workflows.** A `pull_request` workflow runs from the PR's own branch, so the branch could change the gate outside the protected paths. So the gate has two jobs:
1. **The path check**, a `pull_request_target` job. It runs `main`'s copy of the workflow and executes none of the PR's code: it only reads git objects, with a read-only token and no secrets. It:
   - fetches `main` and records the SHA it fetched;
   - takes the PR's head SHA from the event, not from a checkout;
   - requires that the head contains the fetched `main` tip (`git merge-base --is-ancestor`);
   - requires that the protected paths at the head equal the fetched `main` (`git diff --quiet <main-sha> <head-sha> -- <paths>`).
2. **The harness run**, in the PR's own workflow. Its workflow file and scripts are protected paths, so job 1 has proved they are `main`'s. It:
   - runs in the pinned image by digest, and checks the image digest and `swift --version` before the build;
   - sets the verify key `SST_DIFFERENTIAL_VERIFY=1`. Under it, `SST_UPDATE_GOLDEN=1` fails at start, and a missing golden is fatal, as it always is;
   - always runs the full matrix (`SST_DIFFERENTIAL_FULL_MATRIX=1`). §9's messagepack-only fallback applies to ordinary PRs on `main`, never to the rewrite PR;
   - fails closed: a skipped or filtered-out suite, zero runs, the wrong image or toolchain, or fewer cells run than the index lists (less the retired cells) each fail the job. It prints the counts.

**A fresh check at merge.** The rewrite PR merges only with both gate jobs green at its current head, against `main`'s current tip. When the branch opens, Main asks the maintainer to make both jobs required with strict up-to-date protection for it, or to use a merge queue. Until that setting exists, Main re-runs both jobs right before the merge, and doesn't merge if `main` moves in between.

**Branch rules.**
- Commits are sized so Review can take them one at a time.
- The branch merges `main` to stay current, and never rebases.
- It merges when every scenario in every cell matches its golden, a listed expected difference or a listed retirement, the oracle passes, both gate jobs pass, and the usual gates pass.

### Settled in step 2

These concern the gate and the recorder, which step 2 builds. Each is settled and reviewed in step 2's PR, to this requirement:
- **Gate binding:** both gate results are bound to one PR head SHA and one `main` SHA. Job 1 (`pull_request_target`, explicit `contents: read`) checks the fetched PR object against the event's immutable head SHA. Job 2 reports the SHA it built. The required check names the workflow, not only a job.
- **Merge queue:** if one is used, both jobs handle `merge_group`.
- **The rerun gap:** if a manual rerun stands in for strict protection, step 2's PR names who checks that the head and `main` didn't move between the rerun and the merge.
- **One schedule text:** §8 and §8.1 are rewritten against the step rule (no "steps until"), with the moved holds, the controlled flip and the cycle row's own milestones, and each step that emits several frame kinds lists its producer order.
- **The image:** the recorder and job 2 use the digest the other CI jobs already pin (`swift:6.2.4-noble@sha256:3459518b2e723a7c363d0f8cfa44fc796c77ecd8c18e92fd10e6f92dd78c0b12`, from `e2e-tests.yml`).
- **One matrix environment:** the recorder and the verifier run under the same effective matrix environment (including `IN_TURN_SYNC`, which masks cells), and each refuses to run if it differs from what the index records.

### Steps (§11)

- Step 1 loses the adoption items.
- Step 2 adds:
  - the harness, the record-identity override, the recorder script and the index;
  - the `keeperJoinReturned` and `joinSyncRequested` holds, the named observations' reads, and the rows' post-conditions;
  - the sync-lag disable and the resolver-deadline trait in the NIO target, with their checks;
  - both gate jobs;
  - the first goldens, in their own commit.
- Step 3 is the rewrite branch (#546), instead of slice 1.

**Rev 5** answered the review of rev 4 (432e4221):
- a witness client B in each single-player disconnect row, and the turn that completes each join (§8);
- the join budget and the flip timer pinned off (§8);
- #548's assertion at a held `afterAdmit`, and the action row's reuse after the transport's own disconnect (§8.1);
- the barrier ordered by dependency, the stop flight finished, and the cleanup bounded (§5.3);
- the counts, `package` access, and how the golden files are found.

**Rev 4** answered the review of rev 3 (e10c8869):
- every hold row now has its await chain, written out from the code (§8.1);
- a disconnect behind a held queue operation is observed when it is enqueued (`membershipQueued`), not when it is forwarded;
- the pre-admission schedule is `.admitJoinEntry`, and keeper `.join` is its own row;
- the stale-reply mutant removes the early guard too;
- the barrier waits for the inbound drains and the pending answers;
- the land-stop holds are on `closeSessions(boundTo:)`;
- the core tests depend on the support target;
- the run counts are corrected;
- Q3 is decided by the maintainer (§6, §12).

**Rev 3** answered the review of rev 2 (6f8a44df):
- the capture barrier is the transport's flush marker, after the producers settle (§5.3);
- each join stage is its own schedule, and the pre-admission disconnect holds before the keeper's admission (§8);
- the mutants compare against a stored clean capture (§7 (b));
- the assembly splits into a synchronous build and an async attach, and the refusal moves to the throwing init (§3, §4);
- the oracle uses per-request outcomes, live checkpoints and lifecycle counts (§5.6);
- the stop order is forced before the membership queue, client IDs are keyed by attempt, and capture is live then terminal (§5.3, §5.4);
- the count, the nightly switch and the record's completeness flag are stated (§9, §5.5);
- a shared test-support target is added (§3).

**Rev 2** answered the review of rev 1 (458c247c):
- a quiescence condition and positive milestones for the capture point (§5.3);
- a cell rule and a reach check for every hold (§8);
- stable identities instead of positional normalisation, and a forced leave order (§5.4);
- exact, one-use expected differences (§6);
- the `IN_TURN_SYNC=false` leg and the corrected counts (§9);
- an independent property oracle (§5.6);
- source mutants per channel (§7);
- one extracted assembly (§3);
- the record's 3.5 format (§5.5);
- the access path for the level (§4).

## 1. Goal

#546 moves `TransportAdapter` onto the turn core (`SwiftStateTurns`, #551) one slice at a time. An adoption level selects each slice, so a slice can land switched off and be compared with the code it replaces. This plan is the test that does that comparison. It runs the same scenarios at two adoption levels. It fails on any difference in what clients and the replay record see, unless the slice lists that difference as expected.

The harness ships before slice 1, with one level only, so its own checks (§7) run against the current adapter first.

## 2. Prior art

The harness borrows from two classic techniques. From each, it takes the failure modes the technique is known for, and §7 has a check for each row.

**Differential testing** (McKeeman, "Differential Testing for Software", Digital Technical Journal 10(1), 1998). Two implementations of one specification get the same inputs, and any difference in their outputs is a bug in one of them, found without writing the expected output down. Its known failure modes:

| Failure mode | What goes wrong | Where this plan handles it |
|---|---|---|
| Non-determinism | Two runs of the same side differ, so every comparison is noise | §5.4: stable client identities, fixed request IDs, a forced leave order, named record fields; §7 (a) same-level runs |
| A shared bug | Both sides run the same faulty code, so they agree and the bug passes | §5.6: a property oracle checked on each side alone, independent of both |
| Triage of differences | Real differences drown among known ones | §6: each entry names its cell and both outcomes, and is used exactly once |
| Input coverage | Only the orders the inputs reach are compared | §8: holds with a cell rule, and a hold that isn't reached fails; §10 lists what no scenario reaches |
| A vacuous or weak comparison | Two empty captures compare equal, or the comparator ignores what changed | §5.3: the flush barrier, two checkpoints and positive milestones; §5.7: per session, in order, byte for byte; §7 (b) source mutants per channel |

**Golden (snapshot) testing.** A run's output is stored as a file, later runs are compared with it, and a change to the file is reviewed like code. It detects an unintended change in output, here in the code both levels share. It is not a correctness oracle: a file records today's output, bugs included. Its known failure modes:

| Failure mode | What goes wrong | Where this plan handles it |
|---|---|---|
| Blind update | The update command rewrites every file, and nobody reads the diff | §5.8: an explicit key, readable files, and the PR names each changed file |
| A missing file passes | A new scenario without a file is accepted silently | §5.8: a missing file fails, except under the update key |
| Brittle output | Unrelated noise changes the file | §5.4's identities and field rules, the same as the differential side |
| Unreadable diffs | Binary frames give a diff nobody can review | §5.8: decoded frames and the decoded record, one file per cell |

## 3. Boundary and assembly

**The boundary** is the assembler: `LandRouter`, `LandManager` and the host's wiring, with a fake `WebSocketConnection` for each client. Everything below it is real: the transport, the adapter, the keeper, the sync engine, the encoders and the recorder. The adapter isn't driven directly. A slice can move work between the adapter and its neighbours, and a test at the adapter's own API would miss what moved.

**One assembly (Q1), in two parts.** Step 1 extracts `NIOLandServer`'s assembly, and both the host and the harness call both parts.
- **Build:** a synchronous `package` construction in `SwiftStateTreeNIO`. It builds the transport, the manager, the router and the adapter factory, and forwards `autoStartLoops` and `adoption`. `NIOLandServer.init` calls it, passing `true` and the configured level.
- **Attach:** an `async` `package` step. It installs the router as the transport's delegate, and wires the server's failure-stop callback onto the same stop registry an explicit stop uses.
  - It has to be async: `WebSocketTransport` is an actor whose `setDelegate` is actor-isolated (`WebSocketTransport.swift:242`).
  - The host awaits it before it publishes the route, as `NIOLandHost.swift:373–412` does today. So no frame arrives before the router is installed.
  - A direct caller of the public init keeps its own delegate, because the attach isn't part of the init.

Both callers get the same wiring, so no copy and no configuration test is needed. Sockets and HTTP stay in `NIOLandHost` and are out of scope (§10).

**Test targets.** The harness lives in `SwiftStateTreeNIOTests`, which already depends on `SwiftStateTreeNIO`, `SwiftStateTreeTransport` and `SwiftStateTree`. It needs two helpers that live elsewhere today:
- `TestGate` is in `SwiftStateTreeTransportTests`;
- `ShutdownConnection` is private in `GracefulShutdownTests`.

`Sources/SwiftStateTree/Support/Deadline.swift` already names the follow-up: move it and `TestGate` into a shared test-support target "once a second shared helper needs it". `RecordingConnection` is that second helper.

So step 1 adds a `SwiftStateTreeTestSupport` target to `Package.swift`:
- `.target(name: "SwiftStateTreeTestSupport", path: "Tests/SwiftStateTreeTestSupport")`;
- it depends on `SwiftStateTree` (for `safeTaskSleep`) and `SwiftStateTreeTransport` (for `WebSocketConnection`), and only test targets depend on it, so the graph stays acyclic;
- it holds `TestGate`, `Deadline` (`raceDeadline`) and `RecordingConnection` (`ShutdownConnection`, renamed, with its file-local helpers and its timeout). None of them imports `Testing`. Their declarations become `package`, so the test targets can use them across the target boundary;
- `RecordingConnection` keeps the close reason with the code. Its JSON convenience decoder stays for other tests; the strict comparator reads only the raw bytes.

`SwiftStateTreeTests` (`WithinDeadline.swift`, `LandKeeperLoopPhaseOffsetTests`), `SwiftStateTreeTransportTests` and `SwiftStateTreeNIOTests` depend on it. Each move is its own commit, and the existing users switch to the shared copies. `Deadline` leaves `Sources`, so its `package` access no longer has to be there for tests.

**Compared, per scenario:**
- each session's frames, in order, byte for byte;
- each session's close: code and reason, or none;
- each request's response, derived from the frames (§5.7);
- the replay record (§5.5).

**Not compared:** counters, logs, admin routes and timing. A slice that needs one of them compared adds it explicitly.

**Shared code.** The keeper, the sync engine, the encoders, the transport and the recorder run on both sides. The property oracle (§5.6) checks them for correctness, and the golden files (§5.8) detect changes to their output.

## 4. Adoption levels

As #555 and #546 say: an environment key plus a `package` parameter, never public.

- **The enum:** `TransportAdapterAdoption`, a `package` enum in `SwiftStateTreeTransport`. `.legacy` is today's adapter. Each slice adds one case (`.membership` for slice 1, and so on), and each level includes the slices before it.
- **The env parser:** `TransportAdapterAdoption.fromEnvironment(_:)`, a `package` static function in Transport. It reads `TRANSPORT_ADAPTER_ADOPTION` (a constant in `TransportEnvKeys`) through `getEnvString`. NIO calls it, so `TransportEnvKeys` stays internal. Unset means `.legacy`. An unknown value is an error naming the known levels.
- **The parameter:**
  - `LandManager`'s existing `package` init (`LandManager.swift:303`) gains `adoption:`.
  - `NIOLandServerConfiguration` gains a `package var adoption: TransportAdapterAdoption?`, nil by default. A public init can't take a `package` type, so no public signature changes. Tests set the property as an override.
  - `NIOLandServer.init`, which throws (`NIOLandServer.swift:45`), resolves the level: the override if set, or else the parser's result. An unknown env value throws there. The configuration's public init doesn't throw, so the refusal can't be in it.
  - The extracted assembly (§3) passes the resolved level on.
- **Who uses which:** the harness passes the parameter, so both levels run in one process. The env key is for E2E and the load test, where the server runs in its own process.
- **Operator-facing behaviour:** the key is a server setting even though every declaration is `package`. In step 1, an unknown value is refused at startup with the list of known levels. That is new behaviour, and step 1's PR states it. The key goes into the server env docs when a second level exists.
- **Start:** the harness lands with `.legacy` only. Slice 1 adds `.membership` and the first real comparison.

## 5. The harness

### 5.1 Shape

```swift
struct DifferentialScenario {
    let name: String
    let cells: CellRule                  // sync modes and land kinds it applies to (§8)
    let connections: [ConnectionName]    // "A", "B", ...: the stable identities (§5.4)
    let steps: [ScenarioStep]            // connect, join, send(requestID:), tick, hold, release, disconnect, stop
    let milestones: [Milestone]          // what must be observed before capture (§5.3)
    let outcomes: [RequestOutcome]       // per request and connection attempt (§5.6)
}

struct Capture: Equatable {
    var frames: [ConnectionName: [Data]]          // in arrival order
    var closes: [ConnectionName: CloseInfo?]
    var responses: [ConnectionName: [RequestID: Data]]
}

struct RunResult: Equatable {
    var live: Capture                             // before the stop (§5.3)
    var terminal: Capture                         // after the stop
    var record: DecodedRecord                     // §5.5, after the stop
}
```

A scenario is data. One runner executes it at any level, sync mode and encoding, so a new scenario is one value and needs no new test code.

### 5.2 Fake connections

`RecordingConnection` (§3) captures each frame and the close (code and reason) in arrival order. There is no separate response callback, so responses come from the frames (§5.7).

### 5.3 The capture point

A run ends at a defined point, not when its last step returns. The trap is the one in `Notes/solutions/2026-11-10-a-returned-send-is-not-a-delivered-frame.md`: a returned send isn't a delivered frame. Three producers can still be busy after the last step:
- **`stepTickOnce()`** can return before its frames are sent. On a tickless land the input drain may be scheduled but not yet applied.
- **The adapter's outbound writer** hands frames to a per-session send queue in `WebSocketTransport`, which a drain task delivers later.
- **In-turn admission** starts a separate flip waiter.

**The barrier.** A session's drain task can't be awaited: it is a `for await` over a stream that lives as long as the connection (`WebSocketTransport.swift:110`), so awaiting it waits until the session ends. Outbound idle alone isn't enough either: it can return while a producer is about to enqueue, such as a deferred sync retry after `cycleBeforeEndSync` is released, or a pending action reply. And a join reply on the wire doesn't show that the router's `awaitFlip` (`LandRouter.swift:1309`) has set the session to joined.

The transport already has the right primitive. A `.flush(id)` element in a session's queue resumes its waiter when the drain reaches it (`flushSessionQueues`, `SessionFlushWaiters`). It is a barrier through the queue, not a wait for its end. The capture waits, in this order:
The order follows what waits on what. An answer can wait for an input that still has to drain and for a tick that still has to apply, and a drain can start a sync after a first quiescence check. So:
1. **The scenario's own work ends:** the runner's ingress tasks and any explicit `syncNow` tasks are joined, and the flips settle: no pending flip wait in the router. Step 1 adds that report. The flip is registered before its task is spawned, and the registration ends on every exit of `awaitFlip`, error sends included.
2. **The adapters settle, as one pass, repeated until it finds all of them idle together, the whole loop under one deadline:**
   - the deferred inbound drains: the flip starts each in a task of its own (`TransportAdapter.swift:4130–4135`), and they produce frames after it. The harness awaits `waitForInboundDrainForTesting(session)` for each flipped session. That registry is filled in debug builds only, so the harness is compiled under `#if DEBUG`, as the suites that run it are;
   - `waitForActionResponsesFinishedForTesting` with the scenario's count of *pending* answers: actions whose job outlived their turn. It counts finished pending answers (`TransportAdapter.swift:5679`), so passing the total action count would hang when some actions reply directly;
   - each adapter's `waitForSyncQuiescenceForTesting`, which returns `Bool` (`TransportAdapter+Outbound.swift:179`). `false` fails the run.
3. **Each adapter's outbound is idle:** `waitForOutboundIdleForTesting()`.
4. **The queues are flushed:** `flushSessionQueues()`, awaited, so every frame enqueued before it has reached its connection.

**Bounds and cleanup.** Each wait has a bound, through `raceDeadline`. A wait that hits its bound fails the run, naming the producer it waited on.
- `raceDeadline` leaves the timed-out work running (`Deadline.swift:13–19`). So after a failure or a missed milestone, the runner:
  1. opens every gate first, resolver gates included;
  2. stops the land, under its own bound;
  3. closes the fake connections through the transport, under its own bound;
  4. awaits its own spawned tasks, under a final bound.
- `waitForActionResponsesFinishedForTesting` installs a checked continuation (`TransportAdapter.swift:5679–5683`), so a count that can't be reached would leave it hanging past the run. Step 1 makes the waiter cancellable: each waiter has an ID, is removed under actor isolation and resumed exactly once, and checks for cancellation when it is installed. The runner keeps the task handle, because `raceDeadline` starts the work unstructured, and cancels it in cleanup.
- Every run builds its own transport, manager, router and adapters. Work left running after the final bound touches only that run's instances, never the next run's.

**Two checkpoints.** The stop produces leaves, closes and record entries of its own, so a capture taken before it misses them, and one taken only after it misses the live state.
- **Live:** the barrier, then a capture of frames, closes and responses. Convergence is checked here (§5.6).
- **Terminal:** stop each land once and wait for its stop flight to finish, then the barrier again, a second capture, and then the record (§5.5). The public stop can return `timedOut: true` while teardown goes on (`NIOLandServer.swift:154–185`, `224–235`). In that case the runner waits for the flight itself, under a bound, and a run whose stop never finishes fails. The flight registry's `flight(for:)` is get-or-create, and its entry is removed when the flight completes (`NIOLandServer.swift:499–534`), so a lookup after a timeout could start a second flight. The stop entry the harness uses hands back the original `Flight.task`, and the runner awaits its value. The sessions-closed latch and the after-destroy hook fire before the flight completes, so neither is the signal.

**Positive milestones.** Each scenario lists what it must observe before capture. Examples: the join reply and the first sync for each session; each input applied; each response; each close. A milestone that isn't observed fails the run. A scenario with no milestone is refused as vacuous. So two empty captures can't compare equal.

### 5.4 Stable identities and order

- **Client identity:** `WebSocketTransport.handleConnection` makes a random `ClientID` from `UUID()` (`:435`). It appears in the record's lifecycle, action and client-event entries, and in event targets.
  - Step 1 adds a `package` hook on the transport that supplies the client ID, keyed by connection attempt, not by `SessionID`. So a scenario that reuses a session ID, as #548's reconnect may, still gets a distinct identity per attempt. The harness names each attempt (`A`, `A2`), and that name is in every reference to it on both sides. The public entry point and its six-character default stay as they are.
  - Positional normalisation ("first", "second") is not used. It would make "both actions came from A" equal to "the second action came from B", and hide exactly the routing difference a membership slice could introduce.
- **Other IDs:**
  - session IDs, player IDs and land IDs are named by the scenario;
  - request IDs are fixed in the input frames;
  - `rngSeed` is kept as it is, since both sides seed the same way.
- **Leave order at a land stop:** the scenario stops a land, which is `closeSessions(boundTo:)` (`LandRouter.swift:513` on), not the host shutdown (`closeSessionsForShutdown`, `:433` on). It snapshots the bound sessions from a dictionary and runs `leaveAndClose` for each in a task group (`:532–538`). So two leaves on one land can be enqueued in either order.
  - A hold at the keeper's `.leave` is too late: by then the tasks have already raced to enter the adapter's serial membership queue.
  - Step 1 adds a router hold `stopLeave(SessionID)` in `leaveAndClose`, before its `adapter.onDisconnect`. `leaveAndClose` is `static`, so the hold is passed in with the other arguments.
  - The order is forced as §8.1's stop row says, with the adapter's `membershipQueued` arrival as the acknowledgement that a leave is in the queue.
  - A scenario with one player per land doesn't need it.

### 5.5 The record

- **Format.** `recorder.save` finalises a binary SSTR 3.5 record: metadata, ordered turns, the sync stream, sequence watermarks and a footer. The harness compares that format, decoded into its Swift types. `encodeJSONViewForTesting()` gives only the older 2.6 view, so it isn't used.
- **Capture.** At the terminal checkpoint (§5.3): after the stop, the barrier and the recorder's submissions have settled, the record is saved.
- **Completeness.** A 3.5 footer can say it is incomplete (`ReevaluationRecordCompleteness.incomplete`, `ReevaluationRecordLog.swift:51`), so having a footer isn't enough. The harness asserts that the decoded completeness is `.complete`.
- **Decoder access.** The log decoder (`ReevaluationRecordLog.read`) is internal to `SwiftStateTree`. Step 1 adds a `package` entry that returns the decoded contents, so the comparison keeps the sync stream and the watermarks. `@testable` would work too, but it needs testing builds, which a release test run doesn't have.
- **Fields.** Each field that depends on the wall clock or the process is named in a list in the harness, with its rule:
  - wall-clock and machine metadata (`createdAt`, `hardwareInfo`): pinned by the record-identity override (rev 8), before the header is written;
  - client IDs: already stable (§5.4);
  - everything else: compared as it is.
- **Field-list test.** A test walks the decoded record type itself, nested fields included, not fixtures. It fails when a field is neither on the list nor known to be stable. So a new optional field that no fixture has still fails until it is classified.

### 5.6 The property oracle

The differential comparison can't see a bug both levels share. An oracle independent of both sides can. Each run checks, on each side alone:
- **convergence, at the live checkpoint:** each client's decoded state equals the keeper's per-player view for that player, as the E2E convergence check and `RowAddressingAdapterTests`' oracle do. A scenario must have at least one live client at its live checkpoint, or it is refused, so the check can't compare nothing. The single-player race rows get a witness client for this (§8);
- **request outcomes:** each request gets the outcome its scenario states for its connection attempt: one reply, an error frame correlated by request ID (`ErrorPayload.details["requestID"]`), or none. "A stale action reply after a leave" states none, so a correct run passes it. Each joined attempt gets exactly one join reply;
- **lifecycle:** the record's join and leave entries match the identities and counts the scenario states (for example A joins and leaves, A2 joins and leaves). So a record with both of a pair dropped fails too. No OnLeave lacks its OnJoin.

A property failure fails the run whether or not the two sides agree.

### 5.7 Comparison and responses

- **Frames:** per session, in order, byte for byte. Same encoding on both sides, so the bytes match when the behaviour matches. Today's `expectSameFrames` (`DirtyTrackingByteIdentityTests.swift:241`) already compares ordered bytes per target, after a total count. The harness has its own comparison for its report shape, and for the closes, responses and record.
- **Responses:** derived from each side's frames by request ID, strictly. A frame that should be a response but doesn't decode as one fails the run. So does a response that differs from the outcome the scenario states (§5.6). Nothing is dropped by a `compactMap`.
- **Report:** on a mismatch it names the scenario, the cell (sync mode, encoding, land kind), the connection and the index of the first differing frame. It shows both frames decoded (JSON), and the steps run before that frame.

### 5.8 Golden files (Q2)

Golden files are change detection on shared code, not a correctness check (§5.6 is that).
- **Set:** two scenarios, each with a file per cell: the two-player join–act–leave scenario and the land stop with players. File name: `Tests/SwiftStateTreeNIOTests/Differential/Golden/<scenario>.<sync>.<encoding>.<land>.json`. Each file holds the decoded frames per connection, the closes, the responses and the decoded record.
- **Location:** the harness finds the folder from its own source file (`#filePath`), not as a SwiftPM resource. The NIO test target declares no resources, and the update has to write the files in the source tree anyway. So `Package.swift` needs no `resources:` entry.
- **Compare:** the `.legacy` result against the file. A missing file fails.
- **Environment:** the CI legs differ by env settings that change frames (the tables-off and per-player-tables-off runs in `build-and-test.yml`). The harness pins each such setting through its parameters, so a golden doesn't depend on the leg. A setting it can't pin goes into the file's key.
- **Update:** with `SST_UPDATE_GOLDEN=1` only, a named constant beside the harness. The update rewrites the files and prints the changed paths. A PR that changes a golden file names it in its body, and review reads the diff.

## 6. Expected differences

A slice may change behaviour on purpose, mostly where it fixes a race. It lists those differences in its test file:

```swift
struct ExpectedDifference {
    let issue: Int
    let scenario: String
    let cell: Cell                    // sync mode, encoding, land kind; one cell per entry
    let connection: ConnectionName?
    let legacy: Outcome               // the exact outcome on the reference side
    let adopted: Outcome              // the exact outcome on the slice's side
    let why: String
}

enum Outcome: Equatable {
    case frames([Data])               // the whole frame list for that connection
    case close(code: UInt16, reason: String)
    case noClose
    case response(RequestID, Data?)   // nil: no response
    case recordField(path: String, value: DecodedValue)   // value may be .absent
}
```

- **Exact:** an entry excuses a difference only when both sides' outcomes equal its `legacy` and `adopted` values in its cell. There is no "from this frame on" form. A wrong close code or a different later frame stays a failure.
- **One use:** each difference consumes at most one entry, and each entry is consumed exactly once per run. These fail:
  - an unused entry (stale);
  - two entries that match the same difference (overlap);
  - one entry that matches two differences.
- **Several cells:** an entry for several cells is written once per cell. A helper builds those, so the cells stay explicit.
- **Absent on one side:** an outcome can be `absent`, for something one side has and the other doesn't, such as a lifecycle entry the adopted side never records. `recordField(path:value:)` takes `.absent` as its value, and `frames([])` means no frames at all.
- **Masked cells:** selectors are checked against the cells that ran. An entry for a cell the run masked (the in-turn-on cells under `IN_TURN_SYNC=false`) is not reported as stale.
- **The PR body:** each slice's PR states its list, one line per entry.

**The first list** (slice 1, membership) starts from the two cases #555 names. The first is an entry; the second is decided as no difference:
- **#548, a teardown during the keeper join.** Today the admission re-creates membership and the connection generation on a torn-down adapter. With the turn core, the join's ticket is captured when it is enqueued, so after the teardown the admission does nothing.
  - Both levels may send nothing to the disconnected socket, and a reconnect can supersede the stale entry before its action, so both levels would give the same reconnect frames. So the scenario asserts the first attempt's membership and connection generation at a defined point: after `.allow` is released and the admission returns, before the reconnect.
  - The teardown is `endSessionTicketsForTeardown()`, which is synchronous on the adapter. The adapter is free while the keeper's `.join` holds, because the join's queued operation is suspended in its `await keeper.joinReportingAdmission` (`TransportAdapter.swift:2164`). The adapter's `teardownTicketEnds` counter is a milestone showing it ran while `.join` was held. So the scenario can't pass by never racing.
  - The reconnect (attempt `A2`) follows, and joins and acts, for the record and routing outcome.
  - The teardown is the adapter's membership teardown, not a keeper shutdown. A full keeper shutdown at the keeper's `.join` hold can set `isDraining` and stop the admission the scenario is meant to test.
  - The entries name each side's exact membership state at the assertion point, and the exact frames and record fields for `A2`.
- **A disconnect before the keeper's admission, with in-turn sync on.** Today neither OnJoin nor OnLeave runs. The schedule is the one `LandRouterJoinAttemptTests.disconnectBeforeAdmissionQueued` (`:357–383`) already uses: hold the adapter's `.admitJoinEntry`, before the admission is queued, and let the disconnect through (§8.1). Its milestone is `staleJoinAttemptsRefused == 1`, with no player and no join response. The absence of a record entry isn't used as the proof: an unapplied input leaves nothing either way.
  - **Decided (maintainer, 2026-11-19):** neither runs, as today, and slice 1 keeps that behaviour. The player was never admitted, and an OnLeave without its OnJoin would break the pairing a land relies on (§5.6).
  - So this case is not a difference, and it has no entry. The scenario stays in the set, and the comparison holds both levels to "neither runs".

### Fit with resolve, apply and sync, and with #588

The harness compares outputs only, so it doesn't depend on how a slice splits its phases. The scenarios still place their holds at the phase edges, because that is where slices move work:
- **resolve → apply:** between a join's resolvers and its admission, and between an action's resolvers and its answer;
- **apply → sync:** a sync cycle in flight, and a joiner's initial sync.

**#588** moves a state-dependent join check into the turn that applies the join, as a validate step before a non-throwing apply. When the join slice adopts that shape, the refusal can move from before the resolvers to after them. #588 requires the client to get the same refusal whichever check refuses.
- The harness has a scenario for each refusal source: `CanJoin`, `maxPlayers`, and later validate. Each is compared at both levels.
- A refusal that moves in time but reaches the client as the same frame is no difference.
- A different frame or close is a difference that #588 rules out, so it never goes on the expected list.

## 7. Checks of the harness itself

The rows of §2's tables, each with a check:

- **(a) Determinism.** Every scenario runs twice at each level it runs at, in every applicable cell, and the two runs must match. Until slice 1, this is the whole harness run.
- **(b) Source mutants, one per compared channel.** Until slice 1, both sides are `.legacy` from the same source, so a hand edit changes both runs alike and the differential comparison can't fail on it. A mutation test compares the mutant's output with the unmutated program's, so these mutants do that:
  - **Clean capture:** before the mutants, the first scenario set runs at `.legacy` and its `RunResult`s are stored, in the golden files' decoded form. It is a test artifact for this check, under `.build`, not a reviewed file.
  - **Each mutant** is one hand edit, run, recorded and reverted, as for other gates. Its run is compared with the clean capture, and the scenario that claims its channel must fail. That also proves the scenario reaches the code.
  - **frames:** skip one event frame in the adapter's event loop;
  - **closes:** change a close code in the adapter's close path;
  - **record:** skip one record entry in the keeper's submit;
  - **a race:** the stale action reply. `finishActionResponse` checks the ticket three times: an early guard right after the hold (`TransportAdapter.swift:5638`), and again on each of the two final enqueue branches (`:5732`, `:5783`). Removing one alone survives. The scenario is the leave-first schedule of `TransportAdapterActionJobTests.staleAnswerAfterReconnect` (`:276–300`), which reaches `:5783`, so the mutant removes the early guard and that branch's check. The scenario asserts zero replies to the old request on both A and A2;
  - **responses:** a mutant on the extractor's input, changing the request ID in one response frame. A join-response field edit would change frames too, so it wouldn't show that response extraction works on its own.

  The PR body has each mutant's failing output.
- **(c) Comparator.** One test applies transforms to one side's `RunResult`: drop a frame, swap two adjacent frames, change a close, drop a record entry, add a stray expected entry. Each must be reported. This shows the comparator is strict; (b) shows the runner captures what the adapter does.
- **(d) Golden.** A missing file fails. A changed file fails without the update key. With the key, the update prints the changed paths.
- **(e) Record fields.** The field-list test of §5.5.
- **(f) Property oracle.** For each property, one mutant breaks it on both sides alike, so the comparison passes and only the oracle fails. Example: an OnLeave dropped in the shared keeper path.
- **(g) Vacuity.** A scenario with no milestones is refused. A milestone that isn't observed fails.

## 8. Scenarios and holds

**Cell rule.** Each scenario names the cells it applies to: sync mode (in-turn on, off) and land kind (tick, tickless). It runs in exactly those, with every encoding. A test checks that each scenario's cell set is nonempty before the `IN_TURN_SYNC=false` mask is applied, so a scenario can't disappear by its rule.

**One schedule per row.** A row's holds are all reached in one run. Holds that exclude each other, such as a disconnect at `beforeAdmit` that returns before `afterAdmit`, are separate rows.

**Disconnects at a hold.** Where the hold stops an operation inside the adapter's membership queue, the disconnect queues behind it. So `disconnectForwarded`, which the router reaches only after `await adapter.onDisconnect` returns (`LandRouter.swift:361–364`), can't be reached while the hold is closed. There the runner observes the disconnect when it is *enqueued*: the adapter's `membershipQueued` hold point, "the event that it is queued", reached as a pass-through. Then it releases the hold, and then waits for `disconnectForwarded`. §8.1 says, per row, which case applies.

**TestGate in the NIO target** comes from the shared test-support target (§3).

**A witness client.** Each single-player race row (`beforeAdmit`, `afterAdmit`, the two send holds, `.admitJoinEntry`, keeper `.join`, `registerSession`) has a second client B. B joins and settles before the race, and stays. So the live checkpoint has a client to check convergence on, and B's frames show whether A's race leaked anything to the others. "B settled" means that, before the observer is installed, B's ingress, its router flip and its sync work have all been awaited, with both join timers already off when B joins (§8.1). The race fixtures admit two players, and their `CanJoin` admits A while B is present.

The plain join–act–leave row has no witness, so its live checkpoint comes before its final leave.

**Loops off, every input stepped.** The harness builds the assembly with `autoStartLoops: false` (`LandKeeper.swift:1169`), so no tick or sync runs during a hold, changes a capture, or keeps the settle pass busy. So the runner steps every input itself, not only joins:
- **Tick land:** after each step that submits inputs (a join, an action, a leave), the runner calls `stepTickOnce()` until those inputs have applied, before the next step and before each checkpoint.
- **Tickless land:** the input's own turn applies it.
- **The flip:** with in-turn sync on, an in-turn join's flip can complete in a later turn than the one that applied the join, because it also waits for the transport's registration (`TransportAdapter.swift:2218–2225`). So the runner steps until the barrier's flip report (§5.3) shows no pending flip. With in-turn sync off, the flip is the router's own path.
- **The tick stop row:** the runner steps after both leaves have enqueued and before the stop, so the leaves apply in the order the holds forced.

**Timers pinned off.** The join budget (the router's, `LandRouter.swift:1227–1262`) can end an attempt held before admission, and the flip timer can enqueue `timeOutJoin` on the membership queue (`startJoinWaiter`, `TransportAdapter.swift:1687–1698`). That enqueue passes `membershipQueued` too, and could be counted as the disconnect's arrival. On a slow CI runner a hold can last as long as either budget. So every scenario runs with both off:
- the router's budget override set to `.zero`, which already means none (`LandRouter.swift:229–232`);
- the flip timeout through `setJoinFlipLimitsForTesting`. Step 1 makes an explicit `.zero` there mean none, as the router's override does. Today `nil` only means "no override", and the 12 s `JOIN_TIMEOUT_MS` default would still apply. The "none" branch is taken only for the explicit override, before the fallback: a `.zero` computed by `JoinTimeoutConfig.flipWait(deadline:)` from an expired deadline keeps today's immediate timeout. No caller passes `.zero` to the setter today.

Arrivals are counted from the moment the observer is installed.

**Reach rule.** Every hold a scenario names must be reached in each cell it runs in. A hold that isn't reached fails the run with the hold's name. The runner waits through `TestGate`, whose 60 s guard is the backstop. The cell rule keeps a hold out of cells that can't reach it, so the guard isn't what ends a correct run.

| Scenario | Cells | Holds | Covers |
|---|---|---|---|
| one player joins, acts, leaves | all | none | the plain path |
| two players, an action and an event, broadcast and per-player state | all | none | merged broadcast frame, per-player updates |
| a second session of the same player | all | none | #531's rule, supersede |
| a join refused by `CanJoin`, and one refused by `maxPlayers` | all | none | refusal frames (§6, #588) |
| a disconnect at the router's `beforeAdmit` | all | router `beforeAdmit` | the router returns before admission |
| a disconnect at the router's `afterAdmit` | all | router `afterAdmit` | a disconnect after the router's admission step |
| a disconnect while the join response is sent | in-turn off | router `sendingJoinResponse` | only on the path without the in-turn flip (`LandRouter.swift:1052–1093`) |
| a disconnect while the initial sync is sent | in-turn off | router `sendingInitialSync` | the same path |
| a disconnect before the keeper's admission | all | adapter `.admitJoinEntry` | the pre-admission case (§6): neither OnJoin nor OnLeave runs, at both levels |
| a disconnect during the keeper's join | all | keeper `.join` | admitted, then left |
| a disconnect at the in-turn registration | in-turn on | adapter `registerSession` | after the keeper's admission (`TransportAdapter.swift:2164–2200`), before registration and flip |
| a teardown during the keeper join (#548) | all | keeper `.join`, then `endSessionTicketsForTeardown()`, then `.allow`, the membership assertion, then a reconnect | #548's entry (§6) |
| a stale action reply after a leave | all, with an action whose resolver is held | adapter `actionResponse` | reached only when a pending action job's reply comes back after the session left; an action that replies in its turn doesn't reach it |
| a join while a sync cycle is in flight | in-turn off, and in-turn on with an explicit legacy cycle | adapter `cycleBeforeEndSync` | as `TransportAdapterInTurnSyncTests` drives it |
| a land stop with players connected | all | router `stopLeave(A)`, `stopLeave(B)` | closes, OnLeave order, the record's end |

`drainWait` from rev 1 is gone. It fires only when a land is created again while its previous instance drains (`LandManager.swift:465`), and no scenario here does that yet.

### 8.1 The await chain of each hold row

For each row: where the hold stops, what the scenario does while it is closed, the chain to the milestone the runner waits for, and why that chain doesn't pass through the held operation. "Observed" means a hold point the runner registers as a pass-through: it notes the arrival and doesn't block.

- **beforeAdmit.** The join handler is suspended on the router at `holds.at(.beforeAdmit)` (`LandRouter.swift:1011`), after the session was bound and before `adapter.admitJoin`. Nothing of this join is in the adapter's membership queue yet.
  - Disconnect: router `onDisconnect` → `removeSession` (bound) → `forwardDisconnect` → `liveAdapter` → a task → `adapter.onDisconnect` → `enqueueMembership`. The queue is empty, so it runs → `disconnectForwarded` (`:363`).
  - Milestone: `disconnectForwarded`, reachable while the hold is closed, because the router is reentrant at the hold and the queue holds nothing.
  - Release: `isCurrent` is false, so the join returns (`:1015`). No `admitJoin` call.
- **afterAdmit.** The handler is at `holds.at(.afterAdmit)` (`:1039`). `admitJoin` has returned, so its queued operation has finished.
  - Disconnect: the same chain; the queue is free → `disconnectForwarded`.
  - Release: `isCurrent` is false → `adapter.onDisconnect` again, idempotent → return (`:1041–1048`).
- **sendingJoinResponse** (in-turn off). The handler is at `:1067`, after `admitJoin` returned on the path without the flip.
  - Disconnect: the same chain → `disconnectForwarded`; the leave runs in the free queue.
  - Release: the response goes to a session the transport has already removed, then `joinResponseSent`, and `isCurrent` false → return (`:1081–1084`).
- **sendingInitialSync** (in-turn off). The handler is at `:1092`, with the phase already `.joined`.
  - Disconnect: the same chain → `disconnectForwarded`.
  - Release: `syncStateForNewPlayer` for a player the leave already removed.
- **admitJoinEntry** (the pre-admission row). The adapter is at `holds.at(.admitJoinEntry)` (`TransportAdapter.swift:2116`), before `enqueueMembership`. The router is suspended in `await adapter.admitJoin`, so it is free.
  - Disconnect: the router's chain → `adapter.onDisconnect` → `enqueueMembership`. The queue is empty, because the join isn't queued yet → `handleDisconnectQueued` ends the attempt → `disconnectForwarded`.
  - Release: the join is queued → `performJoinQueued` refuses it as stale → `staleJoinAttemptsRefused` becomes 1, the milestone. Then the router's `afterAdmit` → `isCurrent` false → return.
- **keeper `.join`** (the "during the keeper's join" row). The keeper is at `holds.at(.join)` (`LandKeeper.swift:1675`), after the `maxPlayers` check and before the player's insertion. The caller is the join's queued operation, suspended in `await keeper.joinReportingAdmission` (`TransportAdapter.swift:2164`), so that operation is the queue's current one.
  - Disconnect: the router's chain → `adapter.onDisconnect` → `enqueueMembership` → its task reaches `membershipQueued` (`:2960`), observed. It then waits for the previous operation, the held join. `disconnectForwarded` is therefore not reachable yet.
  - Milestone while held: the `membershipQueued` arrival after the join's own. The runner registers the observer after the keeper's hold is reached, so the next arrival is the disconnect's: the witness B has settled, and the join timers are off (§8), so nothing else enqueues.
  - Release: the keeper inserts the player, the join's operation finishes (in-turn: through `registerSession`), and the queue runs the disconnect → `disconnectForwarded`. Outcome: admitted, then left.
- **registerSession** (in-turn on). The join's queued operation is at `holds.at(.registerSession)` (`:2199`), after the keeper's admission, still inside the queue.
  - Disconnect: the same as the keeper `.join` row: `membershipQueued` observed while held, `disconnectForwarded` after release.
- **#548.** The keeper's `.join` holds the join's queued operation, as above. The adapter actor is free.
  - While held: `adapter.endSessionTicketsForTeardown()` runs synchronously on the adapter → `teardownTicketEnds` becomes 1, the milestone. There is no disconnect, so no queue wait.
  - Release, and the keeper's land allows the join: `admitJoining` issues a ticket after the teardown (the bug). The router reaches `afterAdmit`, which this row *holds*, since past it the router sends the join response and, in-turn, waits for the flip, and either can change A's state.
  - While `afterAdmit` holds: the runner reads A's membership and connection generation together, the assertion of §6.
  - Release, then settle A's handler and any flip (the barrier's step 1).
  - Then attempt A2 connects with a new `SessionID`, joins and acts, and its frames and record entries are compared. A new `SessionID` needs no wait for the transport's cleanup of A's.
- **actionResponse.** The leave-first schedule of `staleAnswerAfterReconnect`:
  1. A joins.
  2. The `actionResponse` hold is armed for arrival 1.
  3. A sends an action whose resolver is held by a gate; the milestone is that the resolver arrived.
  4. A disconnects through the transport. The router's chain → `adapter.onDisconnect` → the leave rejects the pending job, whose answer reaches `finishActionResponse` → `holds.at(.actionResponse)` (`:5636`). The milestone is the hold's arrival; the answer runs in its own task, outside the membership queue.
  5. The runner awaits the transport's own disconnect, the `handleDisconnection` call it made, which clears `closingSessions` before it returns (`WebSocketTransport.swift:411–418`, `452–477`). `disconnectForwarded` comes from the router's task and doesn't show that.
  6. A2 connects with the same `SessionID`. The runner requires that the connection was accepted and that A2's join finished. Then A2 sends an action of its own, whose resolver is held too.
  7. Release A's `actionResponse` hold, then `waitForActionResponsesFinishedForTesting(1)` for A's answer, then `waitForOutboundIdleForTesting()`, then a flush. The waiter returns once the answer is in the adapter's writer (`TransportAdapter.swift:5671–5683`), and the flush covers only frames already handed to the transport (`WebSocketTransport.swift:502–511`), so the outbound wait sits between them. A's checkpoint: no reply and no error frame for A's request ID on A or A2, matched by request ID in replies and in `ErrorPayload.details["requestID"]`. With the mutant, the stale answer goes out as an error frame stamped with A2's generation, so the error-frame match is what catches it.
  8. Release A2's resolver, then wait for a count of 2. A2's own action gets its reply.
  9. A's resolver gate is opened and its job's cleanup awaited, as `TransportAdapterActionJobTests:286–309` does. The resolver has its own 5 s deadline (`ResolverDeadline.swift:23`), so the join timers being off doesn't make this row deterministic by itself.
- **cycleBeforeEndSync.** A legacy cycle is started explicitly, `Task { adapter.syncNow() }`, as `syncDuringLegacyCycleRunsAfterEndSync` does. It stops at `holds.at(.cycleBeforeEndSync)` (`:3222`), holding the keeper's sync flag and suspended on the adapter.
  - While held: B starts a join. Milestone: B's `admitJoinEntry`, observed. The router reaches it through `preparePlayerSession`, an adapter call that the suspended cycle doesn't block. Nothing waits on the sync flag before it.
  - Release: the cycle's `endSync`, then B's admission, initial sync and the rest, all captured by the barrier.
- **Land stop.** `closeSessions(boundTo:)` snapshots A and B and reaches the task group. Each task stops at `stopLeave(<its session>)`, before its `adapter.onDisconnect`.
  - Milestone: both holds reached. Neither leave is in the membership queue yet.
  - Release `stopLeave(A)` → A's `adapter.onDisconnect` → `enqueueMembership` → `membershipQueued`, observed (A is in the queue). Then release `stopLeave(B)`, so B's leave queues behind A's.
  - On a tick land, `stepTickOnce()` after both leaves have enqueued, so they apply in the forced order.
  - Then the barrier, the terminal capture and the record.

**Growth.** Each slice's PR adds scenarios for the orders it moves, each with its cell rule, and names the hold points it adds. A slice that moves a path no scenario holds adds the hold point first, as its own commit. A slice's review checks that every await the slice removes or adds has a scenario holding it.

## 9. Matrix and CI cost

- **Sync modes in one process:**
  - `LandManager`'s `inTurnSync` parameter turns in-turn sync off for one manager. `IN_TURN_SYNC=false` in the environment turns it off for all of them, since "an explicit off in either place wins".
  - The required CI matrix in `build-and-test.yml` has one leg with `IN_TURN_SYNC=false`. In that leg the harness runs only the in-turn-off cells. It records the in-turn-on cells as disabled, with that reason. The other leg runs every cell in one process.
- **Count.** The first set has 15 scenarios after the split rows (§8). Their cell rules give about 162 cells (scenario × sync mode × land kind × encoding) in the unrestricted leg, and about 84 in the `IN_TURN_SYNC=false` leg. With two runs per level (§7 (a)), that is about 324 runs at one level in the unrestricted leg and 168 in the masked leg, and twice that once a second level exists (648 and 336). The tables-off jobs come on top. Step 2 states the exact numbers from the cell rules.
- **Build configuration.** The harness is compiled under `#if DEBUG` (§5.3). No CI job runs the NIO suite in release today, so every leg that runs the suite runs the harness. A release NIO job added later would skip it, and the PR that adds such a job states that.
- **Time.** Each run has real holds, flushes and a stop, so "a few milliseconds per run" is an assumption to measure, not a number. Step 2 measures it at that count, on the CI runner.
- **Other jobs.** `build-and-test.yml` also runs the NIO suite in its tables-off and per-player-tables-off runs, so the harness's time counts in each of them. Step 2 states the total.
- **Cost of a missed hold:** one unreached hold costs `TestGate`'s 60 s guard on its own. So the reach rule (§8) is what keeps the budget, and a harness run that hits the guard fails.
- **Budget:** the whole matrix runs in the PR CI's NIO suite while it stays under 30 s on the CI runner, summed over the jobs that run it. Past that, the PR CI runs messagepack only, and the nightly (#625) runs all three encodings.
  - `full_matrix` is a workflow input, so `swift test` doesn't see it. The workflow sets an env var from it, `SST_DIFFERENTIAL_FULL_MATRIX`, which the harness reads through `getEnvBool` and a constant in the test-support target's env keys. It is set in every job that runs the NIO suite, the tables-off runs included, not only the main test step.
  - The PR that makes the split states the numbers.

## 10. What it can't see

As #555 lists, and where each is covered instead:
- **orders no scenario forces:** the growth rule in §8, and review of each slice's awaits;
- **load-dependent behaviour** (sync lag, back-pressure, slow-reader closes): the A/B and the load test;
- **lifetimes** (leaks, reference cycles): not covered here;
- **counters, logs, admin:** compared only when a slice adds them explicitly;
- **real sockets and the NIO host's HTTP layer:** E2E, which the env key runs at a chosen level.

## 11. Steps

1. **Groundwork (one PR, `package` additions and tests):**
   - `TransportAdapterAdoption` with `.legacy`, its env parser, the `LandManager` parameter, the configuration override and the resolution in `NIOLandServer.init` (§4), with the startup refusal stated in the PR;
   - the extracted assembly, its build and attach parts, with `NIOLandServer` and the host calling them (§3);
   - the `SwiftStateTreeTestSupport` target with `TestGate`, `Deadline` and `RecordingConnection`, and their users switched over (§3);
   - the hooks: client identity by attempt (§5.4), the router's `stopLeave` hold (§5.4), the no-pending-flip report (§5.3), the record decoder entry (§5.5), `.zero` as "no flip timeout" (§8), and a cancellable action-response waiter (§5.3);
   - the record field list and its test (§5.5).
2. **The harness (one PR):**
   - the runner, the barrier, the two checkpoints and the milestones;
   - the comparison, responses and the property oracle;
   - golden files;
   - the first scenario set, with its cell and reach rules;
   - the same-level check;
   - the clean capture, the source mutants and the comparator transforms (§7), with their outputs in the body;
   - the measured CI time and count.
3. **Slice 1** (#546) adds `.membership`, its expected-difference list (§6) and its scenarios. That is #546's work. Its plan carries the maintainer's decision on the pre-admission disconnect.

## 12. Decisions from review

- **Q1:** one extracted `package` assembly that both `NIOLandServer.init` and the harness call (§3).
- **Q2:** two golden files, as change detection on shared code (§5.8). The property oracle (§5.6) handles shared bugs.
- **Q3:** decided (maintainer, 2026-11-19): on a pre-admission disconnect neither OnJoin nor OnLeave runs, as today. Slice 1 keeps that, and the oracle's pairing rule holds (§6).
