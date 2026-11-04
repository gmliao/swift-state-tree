# Sync dirty-flag window (#68) and merged broadcast gate (#67)

Status: plan, revision 2 after adversarial check (2026-11-04); Part 3 added after the #60 check. Three independent bounded core fixes, **three PRs** (#68, then #67, then #70). All three must land before the ordering change in #60 and before any network-impairment or visibility measurement.

---

## Part 1 — #68: `endSync` clears dirty flags set during the sync cycle

### Problem

`LandKeeper.beginSync()` returns a copy of `state` and sets `isSyncing`; `endSync(clearDirtyFlags:)` resets `isSyncing` and calls `state.clearDirty()` on the **live** state (`LandKeeper.swift` ~661–690). The only production caller is `TransportAdapter.withSyncState` (~1188–1210), which awaits between the two (snapshot extraction is sync, but sends, `Task.yield()` and actor hops are not). `LandKeeper` is a separate actor and can run a tick in that window. A field mutated by that tick:

- is marked dirty on the live state,
- is not in the copy being synced,
- has its dirty bit cleared by `endSync`.

On the default path (`useSnapshotForSync` on, `extractSyncSnapshots` ~1312–1315) a cycle extracts `.dirtyTracking(state.getDirtyFields())`, so the field is skipped and stays stale on clients until it changes again. On the non-snapshot path `computeSyncModes` (~1294–1295) falls back to `.all` for a policy category with no other dirty field, which repairs it — that is why it hides in tests. Hero-defense dirties broadcast fields every tick.

**Second instance (broadcast-only cycles).** `_syncBroadcastOnlyImpl` (~1590) also goes through `withSyncState`, extracts only broadcast fields (`extractAndComputeBroadcastDiff`), and then clears **all** dirty flags, including per-player fields it never diffed. The next `syncNow` on the default path skips them. Triggers: `OnLeave` and any handler calling `requestSyncBroadcastOnly`.

### Design

Move the clearing to the start of the cycle, in the same actor turn that takes the copy, and only for cycles that diff every synced field:

- `beginSync(clearDirtyFlags: Bool = true) -> State?`: if not already syncing, set `isSyncing`, take `let snapshot = state`, then if `clearDirtyFlags` call `state.clearDirty()` on the live state; return `snapshot`. The copy keeps its dirty flags (all dirty state lives in value types: `Sync._isDirty`, `ReactiveDictionary` / `ReactiveSet` dirty sets), so the cycle still sees what changed since the previous full cycle; anything mutated afterwards stays dirty for the next cycle.
- `endSync()`: only resets `isSyncing`. Keep `endSync(clearDirtyFlags:)` for one release as a deprecated no-op (`@available(*, deprecated, message: "dirty flags are cleared in beginSync")`), since `LandKeeper` is public API.
- `TransportAdapter.withSyncState` gains a `clearDirtyFlags:` argument and passes it to `beginSync`; it calls plain `endSync()`.
  - `syncNow` cycles: `clearDirtyFlags: enableDirtyTracking`, **read once at `beginSync`**. Today `endSync(clearDirtyFlags: enableDirtyTracking)` reads the value after `maybeAutoSwitchDirtyTracking` may have flipped it at the end of the cycle (~1970–2000), which on an off→on switch clears flags accumulated during the `.all` cycle — the same lost update.
  - **Broadcast-only cycles: `clearDirtyFlags: false`.** They do not diff per-player fields, so they must not clear their flags. The next `syncNow` re-diffs broadcast fields against the already-updated broadcast cache: some extra comparison work, no extra patches. A land that only ever runs broadcast-only cycles accumulates dirty flags until the next `syncNow`; that is conservative (work, not correctness) — say so in a one-line comment at the call.
- **Failure after `beginSync`:** not restored, documented. Today `withSyncState` catches and always calls `endSync`, so flags are cleared on failure too (not a regression); restoring would not help anyway because the broadcast cache advances before any send/encode that can throw.
- Cost note: the copy is now guaranteed alive when the live state is cleared, so dirty-key sets of dirty `ReactiveDictionary` fields are reallocated instead of cleared in place. Small (O(dirty keys)); covered by the release `EncodingBenchmark` run.

### Tests (Swift Testing, written first)

Inject the window deterministically: call `beginSync` on the keeper directly, mutate through `keeper.handleActionEnvelope` / `stepTickOnce`, then `endSync`, then a real adapter sync. For tests through `TransportAdapter`, force the window with a transport whose `send` suspends on a continuation the test controls. Do not race a tick against an in-flight cycle.

1. **Reproduce (#68).** Mutate a synced field inside the window; the next `syncNow` with dirty tracking on sends the new value. Run with `useSnapshotForSync` on (default — must fail on main 852b789) and off (also dirty another field of the same policy category in the next cycle so the `.all` fallback does not repair it).
2. **Broadcast-only (B1).** Change a per-player field, run `syncBroadcastOnly`, then `syncNow` with the default config: the per-player change is sent. Must fail on main.
3. **Auto-switch.** Dirty tracking flips off→on at the end of a cycle: no field changed during that cycle is lost.
4. **Rejected request.** A sync request rejected by `beginSync` (returns `nil`) while a cycle is in flight: the mutation is still sent next cycle.
5. Existing `LandKeeperSyncLockTests` "endSync() automatically clears dirty flags" rewritten to the new contract (flags cleared at `beginSync`; mutations after `beginSync` remain dirty after `endSync`; deprecated `endSync(clearDirtyFlags:)` is a no-op).
6. `clearDirtyFlags: false` leaves flags untouched.
7. Through `TransportAdapter` with the suspending transport: a mutation during an in-flight cycle reaches the client next cycle; client copy equals server projection at the end. Run with `useSnapshotForSync` on and off.

The PR names main 852b789 as the pre-fix base on which tests 1 and 2 fail.

---

## Part 2 — #67: merged broadcast is only sent when change metrics are collected

### Problem

In `TransportAdapter.runSyncNowCycle` (~1236–1240), the `opcodeMessagePack` path calls `sendMergedBroadcastUpdateIfNeeded` only inside `if shouldCollectChangeMetrics, let ... = try await ...`. `shouldCollectChangeMetrics = enableChangeObjectMetrics || enableAutoDirtyTracking`. With `AUTO_DIRTY_TRACKING=false` and change metrics off (their default), broadcast diffs and broadcast events are never sent while the broadcast cache keeps advancing. Introduced in 07ad6d9; default configuration (`AUTO_DIRTY_TRACKING` defaults to true) is unaffected.

### Design

Call `sendMergedBroadcastUpdateIfNeeded` unconditionally; gate only `metricUpdates.append(...)` on `shouldCollectChangeMetrics`. No other change. (#60 will later change how this function sends; keep this PR minimal so it can land first.)

Behaviour note: after the fix, an encode error inside `sendMergedBroadcastUpdateIfNeeded` aborts the whole `runSyncNowCycle`, including per-player sends, in metrics-off configurations too. This matches metrics-on behaviour today and is accepted; state it in the PR.

### Tests (written first)

1. `opcodeMessagePack`, `autoDirtyTracking=false`, `changeObjectMetrics=false`: a broadcast field change and a broadcast event both reach a joined session. Fails on main 852b789.
2. Same for `json` and `opcodeJsonArray` (combined path): unaffected, now covered.
3. Default config: unchanged behaviour (regression guard).
4. Check and state in the PR which encoder `SyncStrategyEquivalenceTests` and `TransportAdapterSyncStrategyTests` use (they set `enableAutoDirtyTracking: false`).

---

## Part 3 — #70: targeted events sent twice per cycle (opcodeMessagePack)

### Problem

`PendingEventManager.pendingTargetedBodies` returns copies without consuming them. In `runSyncNowCycle`, `buildSendBatch` (`sendEncodedUpdatesBatch(mergeEvents: false)`, ~1104–1113) puts a session's targeted event frames into the batch **before** its update frame; then `flushTargetedEventBodiesIfNeeded` (~1553–1567) sends `pendingTargetedEventBodies` again for every joined session with bodies, including those already served. `cleanupPendingSyncEvents` runs afterwards (~1269). Broadcast-target events are unaffected (merged opcode-107 frame). Hero-defense emits only broadcast events, so existing measurements are unaffected.

### Design

- Exactly one sender per session per cycle: `buildSendBatch` returns (or records) the set of sessions whose targeted bodies it included; `flushTargetedEventBodiesIfNeeded` skips those sessions and still serves sessions that got no state update this cycle.
- **Order: a cycle's events precede that cycle's state frame**, the existing convention on every path: the SDK routes opcode-107 events before applying the state update (`sdk/ts/src/core/runtime.ts` ~431–436); on json / opcodeJsonArray `LandKeeper.flushOutputs` sends the tick's events before requesting sync (~312–358); `buildSendBatch` already places targeted events before the update frame. Keep that position; fix only the duplicate. Document "events of a cycle precede that cycle's state frame" as the protocol order next to `runSyncNowCycle`. (Changing to state-first would be a protocol-wide decision across SDK and all encodings; out of scope.)

### Tests (written first)

1. Targeted event plus a per-player change in the same cycle: event arrives exactly once, before the state frame. Fails on main 852b789 (arrives twice: before the state frame and again after it).
2. Targeted event in a cycle with no state change for that session: arrives exactly once.
3. `json` / `opcodeJsonArray`: unchanged behaviour (regression guard).
4. SDK test (`sdk/ts`): an opcode-107 frame's events are routed before its state update is applied (pins the protocol order; no test pins it today).

---

## Verification (each PR)

Repository verification rules for `Sources/` + `Tests/`: full `swift test`, `swift build -c release`, required E2E suites (all three encodings). Paste raw closing lines in the PR.

## Execution and review units

- Two PRs, inline, test first. Each PR is one review unit, reviewed through the normal PR review (core PR → dual track).

## Prior notes checked

Searched `Notes/`, `docs/`, `deep-research/` for "endSync", "clearDirty", "dirty flag", "AUTO_DIRTY_TRACKING", "07ad6d9". Hits: the 2026-09-15 snapshot-baseline implementation plan constructs `TransportEnvConfig` with `enableAutoDirtyTracking: false` in tests that use the default (non-MessagePack) encoder, so they never exercised #67's path. No experiment script sets `AUTO_DIRTY_TRACKING=false`. No prior decision about when dirty flags are cleared.

## Adversarial check record (revision 1 → 2)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Broadcast-only cycles call `beginSync(clearDirtyFlags: false)`; test 2 |
| S1 | should | Test 1 runs with `useSnapshotForSync` on (default) and off with a same-category dirty field |
| S2 | should | Problem text corrected (snapshot path vs `.all` fallback) |
| S3 | should | Deterministic window injection; suspending transport for adapter-level tests |
| S4 | should | #67 behaviour note (encode error aborts the cycle) stated |
| N1 | nit | `endSync(clearDirtyFlags:)` kept one release as deprecated no-op |
| N2 | nit | #67 test 4: check the two tests' encoder |
| N3 | nit | Pre-fix base 852b789 named |
| Q1 | — | Failure after `beginSync`: documented, not restored |
| Q2 | — | `enableDirtyTracking` read once at `beginSync` (auto-switch) ; test 3 |
| Q3 | — | Cost note; release benchmark |
| T-a…T-e | tests | Tests 1–4, 7 (Part 1); tests 1–2, 4 (Part 2) |

## Confirmation pass (Part 3 added)

| Id | Severity | Disposition |
|---|---|---|
| S1 | should | Keep events-before-state (existing convention in SDK and all encodings); fix only the duplicate; protocol order documented; SDK test 4 added |
