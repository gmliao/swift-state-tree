# Replay on typed inputs and the keeper's turns (#612, with #550)

**Status:** rev 1, design draft for review. Doc only; no code until the maintainer has answered §9 and the prerequisites in §8 have merged.

**Issue:** #612. #550 is folded in (maintainer, 2026-11-20). This plan answers #550's question and #546 L2's open group 5 ("reevaluation keepers: in-turn, or a replay-only cycle").

**Base:** `main` at 533d6f44. Line pointers are at that SHA. "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`; "LM" is `Sources/SwiftStateTreeTransport/LandManager.swift`; "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`; "RF" is `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`.

**Inputs read:** #612 and the issues it names; #550; #521 and its plan (`2026-11-13-typed-events-actions.md`, rev 20); #606 with the strict-decode decision (2026-11-18); #655's plan rev 9 (`2026-11-19-adapter-turn-core-rewrite.md` on its branch, §3.2 L1/L2, §3.3 decision 5); the turn core plan (`2026-11-18-swift-state-turns-core.md`); #387's plan (`2026-11-09-server-turn-inputs.md`).

**Solutions consulted:** `Notes/solutions/` has no entry for replay identity, record readers or mode flags. The reentrancy rule in CLAUDE.md and `2026-11-05-reentrancy-helpers.md` applies to the run service (§5.4).

## 1. Goal

Replay is "feed the recorded inputs, in recorded order and at the recorded turn boundaries, into the same keeper turns a live land runs, and send the turn's outputs where this run needs them".

- **One machine.** A replaying keeper runs `runTickTurn` and `runInputTurn` (LK:4700, :5417): the same functions, with in-turn sync, that a live keeper runs. It has no `LandMode` and no apply-path branch on being a replay.
- **Pluggable input source:** live intake (transport, router, server inputs) or a record reader. Exactly one per keeper, chosen at construction.
- **Pluggable outputs:** the transport to clients, the recorder, and a verifier that compares each turn's outputs with the record. Any combination.
- **No second land type.** No `-replay` suffix, no alias in `LandTypeRegistry`, no keeper mode resolver in `LandManager`.

What this plan doesn't change: the live path's behaviour and bytes, the record's role as the only source of a replay's inputs, and the rule that a land's game logic reads time only as a tick ID (`LandContext.swift:99`).

## 2. Today: three users and five drivers

### 2.1 Recording (live)

- The recorder exists when `mode == .live && enableLiveStateHashRecording` (LK:945–970). The keeper's turn builds a `ReevaluationTickRecord` (`makeTurnRecord`, LK:4795) and submits it after the turn (`finishTickTurn`, LK:4790, :4983–4996). The legacy path records from `processPendingActions` (LK:3776–3793) and `flushOutputs` (LK:591–603).
- The adapter submits the sync stream as drafts (TA:4007–4050, LK:4927–4978), only with in-turn sync (LK:4875).
- Metadata is set in `LandManager.buildLand` after the adapter exists (LM:737–773).
- Inputs are recorded as `AnyCodable` (`ActionRecorder.swift:741`, :777, :799, :831); resolver outputs too (:6–16).
- Format 3.6, canonical MessagePack, read whole into memory (`ReevaluationRecordLog.swift:246–329`).

### 2.2 Headless verification (CLI runner and monitor)

Two near-copies drive a `.reevaluation` keeper without a transport:
- `ReevaluationEngine.run` (`ReevaluationEngine.swift:200–432`), used by the example `ReevaluationRunner` executables;
- `ConcreteReevaluationRunner` (`ReevaluationRunnerImpl.swift:94–523`), stepped by `ReevaluationRunnerService` for the monitor land.

Each calls `stepTickOnce()` per recorded tick. The keeper pulls the tick's inputs from its `reevaluationSource` inside `runTick` (LK:4228–4535). Because `usesInTurnSync` requires `.live` (LK:667), a replaying keeper always runs the off-in-turn path, `processPendingActions` (LK:3739) or `replayRecordedPasses` (LK:4005). Sync outputs are verified by a separate shadow `SyncEngine` that re-plans every recorded output (`SyncOutputVerifier.swift:249–960`), not by the adapter.

The monitor land reads the service's status under a lock on a 100 ms tick (`ReevaluationMonitorLand.swift:28–71`), the mailbox exception named in CLAUDE.md.

### 2.3 Replay viewing

- **Production: `registerWithGenericReplay`** (RF:222–308; GameServer `main.swift:171`, :194, :225). The replay land is `GenericReplayLand` (`GenericReplayLand.swift:50–133`), a *live* keeper of a separate definition registered as `<type>-replay`. Its services start a headless run. Each tick it pops one result, assigns the decoded state (state → `fullStateSnapshot` → JSON → `init(fromBroadcastSnapshot:)`), requests a broadcast-only sync and re-emits the recorded events typed (#632). Viewers get the broadcast view only, so per-player fields are lost.
- **`registerWithReevaluationSameLand`** (RF:47–118): used only in tests. It registers the live definition under `<type>-replay` with the generic runner bootstrap and a `.live` resolver. The live definition never consumes the runner's results, so the viewer sees a fresh land while `resultsQueue` grows (`ReevaluationRunnerService.swift:301`).
- **`registerWithReevaluation`** with a replay definition (RF:120–196) and `LandKeeperModeConfig.reevaluation` (LM:6–11, :626–669): the only path that builds a `.reevaluation` keeper with a transport. Reached only from tests (`ReplayTicketJoinTests.swift:244`, hand-written resolvers in `ReevaluationFeatureRegistrationTests.swift:166`). It ticks on the wall clock (`autoStartLoops: true`, so a tickless land never steps, #324) and forces the adapter's off mode (`inTurnSync && !isReevaluationKeeper`, LM:722).

### 2.4 Where the legacy cycle is still used by replay

- **Adapter side (`beginSync`/`endSync` through `withSyncState`, TA:3294–3350):** only the §2.3 path C keeper. The production viewer (`GenericReplayLand`) is a live keeper with in-turn sync. The headless runners have no transport, so they never call `beginSync`.
- **Keeper side (the off-in-turn path):** both headless runners, through `processPendingActions` and `replayRecordedPasses`, and `syncBroadcastOnlyFromTransport` after a replayed pass (LK:4511), which is a no-op without a transport.

So after #546 L2 removes the live users, what keeps the legacy cycle alive is one test-only viewer path (adapter side) and the two headless runners (keeper side).

## 3. Shape

```
                     ┌──────────── input source (exactly one) ────────────┐
                     │ live intake: transport, router, submitServerInput  │
                     │ record reader: recorded turns, in order            │
                     └───────────────────────┬────────────────────────────┘
                                             │ PendingItems + turn boundary + turn instant
                                             ▼
          ┌──────────────────────── LandKeeper (one machine) ──────────────────────────┐
          │ runTickTurn / runInputTurn: apply inputs, tick handler, events, sync phase │
          └───────┬──────────────────────────┬─────────────────────────┬───────────────┘
                  │ sync phase (in-turn)     │ turn record             │ events
                  ▼                          ▼                         ▼
       LandKeeperTransport port        record outputs:            (to the port)
       · TransportAdapter (clients)    · recorder (live)
       · SyncOutputCheck (verify)      · TurnComparator (replay)
       · none (state checks only)
```

### 3.1 The input source

A keeper is built with an `InputSource`:
- `.live`: today's intake. `submitAction`, client events, joins and leaves through the router, and `submitServerInput` (#387).
- `.record(RecordCursor)`: the public intake is closed. Every live entry point refuses with one reason (`.replaying`, which replaces #387's `.notLive` and today's mode checks at LK:2776, :2960, :3088).

The record cursor yields **recorded turns**: a tick turn (its tick ID, its inputs in recorded order, its turn instant) or, for a tickless land, an input turn per recorded pass (#325's passes, with their ordinals). A replay driver (§3.4) takes one recorded turn, enqueues its inputs as `PendingItem`s with their recorded sequence and `resolvedAtTick`, sets the sequence watermark (#72), and runs the matching live turn function synchronously. No await sits between enqueue and apply, so #342's "the queue changed across the awaits" can't happen, and a tickless land steps because the driver steps it (#324).

Inputs come from the record **already typed**: the reader decodes each payload once with the land definition's registries and the same strict decode the live intake uses after #606 (the 2026-11-18 decision applies to recorded client input). A payload that doesn't decode fails the run with its tick, sequence and type (#521's rev 8 rule). Resolver outputs are recorded and decoded the same way, by their declared `ResolverOutput` type.

### 3.2 The recorded clock

Game logic reads time only as `tickId`. What the keeper reads from a clock today is turn scheduling (the tick loop, `TickLoopClock`, LK:3286–3325) and, on the adapter, sync lag (`SyncLag.swift`). Replay needs neither from the wall clock:
- **Turn boundaries** come from the record (tick IDs, pass ordinals), not from a clock.
- **Outcomes that depended on time** (an action job's deadline, a resolver timeout, a join that timed out) are recorded as their outcome (`rejected`, `landFailure`, resolver outputs), never re-derived.
- **Turn instant:** each recorded turn carries its `TurnInstant` offset from the land's start (8 bytes per turn). Nothing reads it in this plan except pacing a viewer (§5.5). It is recorded now so that, when keeper deadlines or timers move into turns, a replay hands the machine the recorded instant through a stepped `TurnClock` instead of needing a format change (§9 Q6).

A replay driver arms no timer and makes no holding request (turn core plan, §3.3–3.4, rule 18).

### 3.3 The outputs

**The sync phase goes through the `LandKeeperTransport` port in every run.** That's what lets a replaying keeper run in-turn sync and drop the off path. Three port implementations:
- **`TransportAdapter`**: live, and replay viewing (§5.5). After #546 it's the adapter on the turn core, in-turn only.
- **`SyncOutputCheck`** (headless verification): runs the sync phase's plan in the turn (the adapter's `planAndCommit` minus the writer, after #554's extraction), and compares each planned output with the recorded sync stream entry by entry. It replaces `SyncOutputReplayDriver`/`SyncOutputShadow`'s separate re-plan (`SyncOutputVerifier.swift:249–960`): the plan runs once, in the turn, as live.
- **None**: state-hash and event checks only. The keeper then runs no sync phase. That's today's headless behaviour when a record has no sync stream.

**Record outputs** take the turn record that `makeTurnRecord` already builds:
- **The recorder** (live): today's submission (LK:4983–4996). #275's bound and async read and #526's levels attach here later; this plan only keeps the seam a protocol (`TurnRecordSink`).
- **`TurnComparator`** (replay): compares the replayed turn record with the recorded one field by field: state hash, emitted events (typed values, then their encoded bytes), sequence watermarks, passes, rejected inputs, land failure. It returns a typed verdict per turn, `match`, `mismatch(field, detail)`, or `notVerified(reason)`, with tick, sequence and output index. The CLI, the monitor and tests all use the same comparator (#478).

Both kinds are optional and independent. A live land with recording has `{TransportAdapter, recorder}`. A headless verify has `{SyncOutputCheck or none, TurnComparator}`. A replay viewer has `{TransportAdapter}`, optionally `+TurnComparator` to show verdicts.

### 3.4 One replay driver, one run

`ReplayRun` replaces `ReevaluationEngine.run` and `ConcreteReevaluationRunner`, along with their duplicated setup and their two `CapturingSink`s:
- opens the record once (§5.1), checks it before the first step (§5.2), builds the keeper with `.record(cursor)` and the outputs the caller asked for;
- `step()` runs one recorded turn and returns its verdict; `runToEnd()` loops it;
- owns its keeper. The keeper is single-use and dropped at the end of the run.

`step()` is called serially by its one owner. The CLI calls it in a loop, the viewer's pacing task calls it on its schedule (§5.5), and the monitor's run calls it from the run service (§5.4). The `step()` race in #100 goes, because there's one caller per run by construction.

## 4. What goes away

| Today | Fate |
|---|---|
| `LandMode`, `ReevaluationOutputMode`, `LandKeeperModeConfig` (LK:32–43, LM:6–11) | Deleted. The input source and the output set replace them. |
| The keeper's mode branches (LK:431, 585–623, 636, 668, 935–973, 1044–1119, 1583, 1805, 2499, 2631, 2776, 2960, 3088, 3614, 3753, 3971, 4213–4514, 4876, 4907, 5149–5250) | Each becomes: intake closed (input entry points), driver work (watermarks, recorded passes, rejected), an output choice (`flushOutputs`, the sync stream), or nothing (viewers aren't players, §5.5). S2 lists each site with its fate in its PR. |
| `runTick`'s replay pull from `reevaluationSource` (LK:4228–4535) | Replaced by the driver feeding recorded turns. |
| The off-in-turn path for replay: `processPendingActions` (LK:3739), `replayRecordedPasses` (LK:4005), `deliverLegacyPass` (LK:3867), the legacy `runSync` loop (LK:5504), `syncNowFromTransport` | Deleted in S6, with `beginSync`/`endSync` (LK:1331–1387) and the adapter's `withSyncState` if L2 hasn't already removed it. |
| `ReevaluationEngine`, `ConcreteReevaluationRunner`, `CapturingSink`, `SyncOutputReplayDriver`/`SyncOutputShadow` | Replaced by `ReplayRun`, `TurnComparator`, `SyncOutputCheck`. |
| `GenericReplayLand`, `ReevaluationReplayProjector` (the hard-coded "hero-defense" projector), `DecodeReplayState`, `fromBroadcastSnapshot` replay use | Replaced by a replaying keeper with a real adapter (§5.5). |
| `registerWithReevaluationSameLand`, `registerWithReevaluation`, `registerWithGenericReplay`, `replayLandSuffix` (RF:9–18, `NIOLandServer.swift:92–100`, `LandTypeRegistry.swift:54–61`), `checkRecord(replayLandSuffix:)` (`SchemaFingerprint.swift:295–305`), `ReevaluationReplaySessionDescriptor` | Replaced by one `enableReplay(...)` on the host (§5.5). |
| Reader branches for records before the new major (#211, #607) | Deleted with the 3.x replay readers (§5.1). |

## 5. The parts in detail

### 5.1 Record format 4.0 and the reader

A new major, because input payloads change form:
- **Inputs typed:** each action, client event, server input, join payload and resolver output is stored as its typed wire form, the bytes the live intake decodes (#606), under its registry ID (#521's static wire name, EV2). Server events are stored the same way, by the typed writer (#521 PR 1a).
- **Per turn:** the turn kind, tick ID or pass ordinal, turn instant (§3.2), the inputs in applied order, and today's outputs (state hash, events, watermarks, rejected, land failure, sync stream).
- **Header, written once at keeper init, from the running keeper** (never recomputed):
  - land type and land ID, fixed at init (#575: no `setLandID` afterwards);
  - the RNG seed the keeper holds (#575);
  - the schema fingerprint (#604);
  - an effective-config fingerprint: a hash over values the land and its services declare as replay-relevant (#441, §9 Q8);
  - the sync config and whether the sync stream is recorded.
- **Reader:** streaming, one turn at a time (`RecordCursor`). It is opened once from a path resolved to its real absolute form (symlinks and a relative `REEVALUATION_RECORDS_DIR` resolved, containment checked on the resolved path), and the open handle is what the run keeps (#366 items 1–3). It has an async read (#275). The version gate is in the open (#213): a major other than 4, or a missing or malformed version, is refused with one error that admin maps to 409 `RECORD_VERSION_MISMATCH`.
- **3.x records:** replay already refuses anything before 3.6 (#604). From 4.0 on it refuses 3.x too. What non-replaying readers keep is §9 Q2.

### 5.2 Checks before the first step

In this order, each refusing the run with its own code: version (open), schema fingerprint (#604), effective config (#441), land type registered on this host. The seed comes from the header. A record whose sync stream wasn't recorded runs with no sync output (none), and its sync verdicts are `notVerified(.notRecorded)`.

### 5.3 Verification layers

- **Keeper layer (`TurnComparator`):** everything the keeper decides. This is the determinism claim.
- **Sync-plan layer (`SyncOutputCheck`):** what the sync phase planned for each session, from the replayed state, compared with the recorded drafts.
- **Not replayed:** what the adapter decides from wall-clock or socket state after planning: sync-lag pauses and resyncs, writer backpressure, a socket closed mid-send. These are recorded as the adapter saw them, and the verifier treats them as recorded facts. That's #572's option A (2026-11-17): a player the adapter withheld is listed as unverified in the recorded output, and `SyncOutputCheck` skips that player.

### 5.4 The monitor and the run service

- `ReevaluationRunnerService` keeps runs keyed by a run ticket (`GenerationTable`). Starting a run supersedes the previous one, and a stale run's results are dropped by its ticket (#100).
- The run reports to the monitor land through `submitServerInput` (#387): `RunProgress` and `TurnVerdict` inputs, handled in the monitor's turns. The monitor's tick no longer reads the service (CLAUDE.md's monitor-land exception and #522's item go away). A refused submission (`.overCap`) pauses the run until the monitor drains, so results are bounded by #387's in-flight cap instead of the unbounded `resultsQueue` (`ReevaluationRunnerService.swift:301`).
- `isMatch` is the comparator's verdict, which includes events and sync outputs. The monitor's `TickProcessedEvent` gets the recorded state hash as `expectedState`, not the actual one (`ReevaluationMonitorLand.swift:56–58`).

### 5.5 Replay viewing

A replay session is a `ReplayRun` whose outputs include a real `TransportAdapter`, paced in wall time:
- **Addressing:** `POST /admin/replay/start` (record path, land type) opens and checks the record (§5.1–5.2), creates the session, and returns a replay ticket and a WebSocket path. The ticket is HMAC-signed with the session ID inside, and no record path is in the ticket, the instance ID or any client message (#366 items 4–6). The session isn't a land of a `-replay` type. It's hosted by a `ReplaySessions` component on the host, outside `LandManager`'s type registry. How it reaches the router is §9 Q4.
- **Readiness:** the start call returns after the session's keeper is initialized and its adapter accepts sessions, so a viewer that connects with the ticket can't race the session's creation (#428's question).
- **Viewers are observers, not players:** they get a session in the adapter but no `PlayerID` in the land's state, no OnJoin and no OnLeave. Today's replay keeper inserts viewers as players and skips OnJoin (LK:1580–1583). Here the replayed state has exactly the recorded players. Which view an observer gets is §9 Q3.
- **Pacing:** a driver task steps the run at the recorded turn instants, scaled by a speed factor (1× by default), and supports pause and seek-forward. Seek-backward needs snapshots (#526) and isn't in scope.
- **Same definition:** the session's keeper is built from the registered `LandDefinition` of the recorded land type, so path hashes, event hashes and the fingerprint are the live land's by construction (#386). A replay with a different state type isn't supported.

### 5.6 Recording

- The recorder is an output (`TurnRecordSink`) attached to a live keeper. A live keeper records when the host enables it, through a host-level configuration instead of the state-hash flag (today recording is tied to `enableLiveStateHashRecording`, LK:945).
- The sync stream is recorded through the port as today (drafts back to the keeper in the phase's output, #553).
- `ReevaluationRecordSaver.saveOnShutdown` stays the land's call (no change). #526's production stream is out of scope, but the sink protocol is where it attaches.

## 6. Steps

Each step is its own PR to `main` (core paths), with its own short plan note if review asks for one.

- **S0 (independent; before #546 L2 if the maintainer agrees, §9 Q1).** Remove the test-only viewer paths that build a `.reevaluation` keeper with a transport: `registerWithReevaluationSameLand`, `registerWithReevaluation`, `LandKeeperModeConfig.reevaluation`, `injectingReevaluationKeeperModeResolver` and their tests (§2.3 B and C). Production keeps `registerWithGenericReplay` until S5. After S0 no replay path calls the adapter's `beginSync`/`endSync`, so L2 removes the adapter's off mode completely, and B2 has no replay-only cycle to support. The keeper's off path stays for the headless runners until S6.
- **S1: format 4.0 and the reader** (§5.1–5.2). The writer records typed inputs, the turn instant and the init-time header; the streaming reader with the resolved handle and the version gate. 3.x replay readers are deleted (#211, #213, #607). Covers #575 and #441's header part.
- **S2: the input source and the driver** (§3.1, §3.4). `InputSource`, `RecordCursor` feeding `runTickTurn`/`runInputTurn`, `ReplayRun` with `TurnComparator`. The CLI runner and the monitor's runner move to it. `LandMode` is deleted, with each mode branch's fate listed in the PR. The replaying keeper now runs the in-turn path. Covers #324, #342 and #478.
- **S3: `SyncOutputCheck`** (§3.3, §5.3). The sync-plan check through the port; `SyncOutputReplayDriver`/`SyncOutputShadow` deleted. Covers #572's verifier side.
- **S4: the run service and the monitor** (§5.4). Run tickets and #387 inputs. Covers #100 and #522's monitor-land item.
- **S5: replay viewing** (§5.5). `enableReplay`, `ReplaySessions`, observer sessions, pacing; `GenericReplayLand`, the projector, `registerWithGenericReplay` and every suffix site deleted; admin routes and the CLI E2E (`reevaluation-replay-e2e-game.ts`) moved. Covers #366, #386 and #428.
- **S6: the deletion.** The keeper's off-in-turn path, `beginSync`/`endSync`, `syncNowFromTransport`, `IN_TURN_SYNC` leftovers, and the #655 plan decisions that guard the legacy cycle (decisions 1 and 4, already superseded by L2). This is #550's outcome and #522's "legacy tick path" item.

S2 and S3 can merge in either order. S4 needs S2. S5 needs S2 and S3. S6 needs S2 through S5 and #546 L2.

## 7. Verification

- **The determinism claim, before and after.** For each scenario under `Tools/CLI/scenarios/game/` and the Demo counter land, record with `main` before S1 (3.6) and verify with today's engine, then record with S1 (4.0) and verify with S2. The verdicts must match turn for turn (all `match`), and the live bytes to clients must be identical, by the differential harness's goldens (#555), since recording must not change what clients receive.
- **Mutants:** a replayed input applied in another order, a dropped recorded input, a wrong seed, a changed config value and a stale fingerprint must each fail with their own verdict. A recorded payload with an extra field must fail the run (#606 strict).
- **Interleavings by holds, not time:** run supersede during `step()`, a viewer connecting before readiness, the monitor over its cap (`HoldPoints`/`TestGate`).
- **A separate-process verify in CI (#51):** the game E2E now verifies a recorded session with `swift run ReevaluationRunner --verify`, a new process (`Tools/CLI/src/reevaluation-e2e-game.ts:96–97`). That looks like the gap #51's 2026-11-05 comment left open, so check it against #51 and close #51 if it is. S2 keeps that run and adds a tickless land to it.
- **Tickless:** a tickless land recorded and replayed with passes (#324, #325).
- **E2E:** `test-e2e-game.sh` and the Demo reevaluation E2E in all three encodings.
- **The measured path without recording doesn't change.** ws-loadtest runs with `ENABLE_REEVALUATION=false` (`run-ws-loadtest.sh:376`), and GameServer records only when it's set (`main.swift:69`). ServerLoadTest (`config.record`) and EncodingBenchmark (`records`) have a recording option. S1 changes the recorder's encode on a recording land, so S1 runs those with recording on, base against change, in release builds on the same toolchain. A host A/B is needed only if that check moves the numbers.

## 8. Order relative to #521, #606 and #546

- **S0** can go now, and should land before #546 L2 if Q1 is yes.
- **S1** needs #521's remaining PRs (the typed writer for every payload, EV2's static names) and #606 (the strict typed decode the reader reuses). It's independent of #546.
- **S2–S3** need #546 through B2: the adapter on the turn core with in-turn sync only, and `planAndCommit` extracted (#554) for `SyncOutputCheck`. The replaying keeper then runs the same in-turn path the live keeper runs after B2.
- **S4** also needs #387 PR 2 (the monitor migration), or it does that migration itself.
- **S6** ends the legacy path. #546's B3–B6 don't depend on it, because after S0 and L2 the adapter has no off mode left. Only the keeper keeps its off path, and only for the headless runners, until S6.

So the sequence is: S0 → #546 L1, L2 → … → B2 and #606 → S1 → S2, S3 → S4, S5 → S6. S1 can start in parallel with B2 once #606 lands.

## 9. Questions for the maintainer

- **Q1: S0, early removal of the test-only replay viewers.** Removing §2.3 B and C (public: `registerWithReevaluationSameLand`, `registerWithReevaluation`, `LandKeeperModeConfig.reevaluation`) makes L2 complete on the adapter, and B2 never sees a replay-only cycle. Production viewing (`registerWithGenericReplay`) is unaffected until S5. *Recommended: yes.* No external users, so no deprecation (2026-11-18 rule).
- **Q2: What non-replaying readers keep for 3.x records.** These are the admin record list (#493), `verify-replay-record.ts` and the runner's `--convert`. *Recommended:* the list reads only the header's version and shows 3.x as "not replayable"; the converter and the 3.x readers go (#343 closes as obsolete).
- **Q3: What a viewer sees.** Today it's the broadcast view only. With a real adapter a viewer could also take a recorded player's per-player view. *Recommended:* broadcast by default, and a player's view only when the replay ticket names that player (admin decides at start).
- **Q4: How a viewer's WebSocket reaches the session.** Option (a): a replay path served by `ReplaySessions`, which reuses the adapter's join for observer sessions but never enters `LandManager`/`LandRealm`. Option (b): the session registered as an instance of the recorded land type, with an instance ID minted by the session. (b) puts replay sessions in the land listings and the router's create path again. *Recommended: (a).*
- **Q5: The keeper's own move onto SwiftStateTurns.** No issue tracks it, and #612's wording ("the land keeper's move onto the turn core") assumes it. This plan designs on the keeper's existing synchronous turns (`runTickTurn`, `runInputTurn`), which already take an ordered input list. The input-source and output seams are the same whether or not the keeper later adopts `TurnCore`. *Recommended:* don't wait for it, and file the keeper's adoption as its own issue if it's wanted.
- **Q6: Record the turn instant now.** It costs 8 bytes per turn, and nothing reads it except viewer pacing until keeper timers move into turns. *Recommended: yes*, so that move doesn't need a format change.
- **Q7: Names.** "Reevaluation" and "replay" mean the same thing today. *Recommended:* "replay" for the public surface (`ReplayRun`, `enableReplay`, `/admin/replay/*`) and "record" for the format. The `Reevaluation*` names go with the types they name, as a breaking change listed per PR.
- **Q8: #441's config fingerprint: declared or inferred.** Lands and services declare replay-relevant values (explicit and reviewable), or the host hashes every env key a land reads (automatic, but noisy). *Recommended: declared.* A value that isn't declared and changes behaviour is the land's bug, and the docs say so.
- **Q9: #526 (production stream, levels, snapshots) stays out.** This plan keeps the seams (`TurnRecordSink`, `RecordCursor`). *Recommended:* yes, out.

## 10. Issues against this design

| Issue | Outcome |
|---|---|
| #550 | Answered: replay keepers run in-turn from S2, and the legacy path is deleted in S6. Close #550 when this plan is GO, pointing here. |
| #211, #213, #607 | S1 (3.x replay readers deleted; one version gate at open) |
| #538 | Already closed (#590, #632). |
| #366 | Items 1–3 in S1 (resolved path, one open); 4–6 in S5 (no path in IDs or tickets) |
| #100 | S2 (one caller per run) and S4 (run tickets) |
| #575 | S1 (header from the running keeper, land ID at init) |
| #343 | Closes as obsolete if Q2 drops the converter; otherwise stays |
| #275 | Partly S1 (async read); the bounded writer stays with #526 |
| #324, #342 | S2 |
| #572 | Stays open as the adapter fix (option A). S3's verifier honours it. |
| #386 | S5 (same definition by construction) |
| #441 | S1 (header) and §5.2 (check); Q8 |
| #493 | Stays open; S1's header makes it a small change |
| #478 | S2 (typed verdicts) |
| #428 | S5 (the test goes; readiness is part of start) |
| #51 | Possibly already covered by the E2E's separate-process verify (§7); S2 adds a tickless land |
| #526 | Out of scope (Q9); the seams are kept |
| #387 PR 2 | S4 uses it, or does the migration itself |
| #522 (monitor, legacy tick path) | S4 and S6 |

## 11. Risks

- **Seeing a replay as a live keeper's twin can hide a difference.** The live keeper's intake, deadlines and router admission make decisions that replay takes as recorded facts. If a live decision isn't recorded, replay can't reproduce it. Mitigation: every input-side decision that changes state (accepted, refused, timed out) is a recorded outcome, and S2's mutants cover each one.
- **S1 changes what is recorded on every recording land.** DemoServer always records (`Examples/Demo/Sources/DemoServer/main.swift:94`), and GameServer records when `ENABLE_REEVALUATION=true`, as the game E2E sets it. S1's encode-cost check (§7) and the E2E cover that.
- **Observer sessions are new adapter surface during #546.** S5 comes after B2–B3 (membership moved), so it's built on the rewritten adapter, not added to the old one.
