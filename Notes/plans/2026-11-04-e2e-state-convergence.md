# E2E state convergence check (issues #79, #80)

Status: plan, revision 2 after adversarial check (2026-11-04). Two PRs: (1) core — a debug projection/freeze capability in `Sources/`; (2) tools — CLI step, scenarios, E2E script variants in `Tools/CLI/` (+ #80).

## Goal

At a stable point, every E2E client's reconstructed state must equal the server's projection for that client (broadcast fields plus that player's per-player view after `SyncPolicy` filtering), in `json`, `jsonOpcode` and `messagepack`. Unit tests pin individual windows (#68, #67, #70, #77); nothing checks convergence on a real server with real clients.

## Findings (origin/main 8e77d91)

1. **E2E harness.** `Tools/CLI/test-e2e-game.sh` (GameServer, hero-defense) and `test-e2e-ci.sh` (DemoServer, restarted per encoding) run `Tools/CLI/src/cli.ts script` per scenario. Scenarios are `{ maxDuration, landID?, steps }`; steps are dispatched in `executeScript` (`cli.ts` ~341–573): `wait`, `waitForState`, `action`, `event`, `assert`, `assertNoPatch`, `log`, `state`. Assertions use `scenarioAssertions.ts` (`deepEqual` ~20, `normalizeForCompare` ~48).
2. **Client state.** `StateTreeView.currentState` (`sdk/ts/src/core/view.ts` ~81), read via `view.getState()`; values are decoded into class instances (e.g. `Position2`), so compare after `normalizeForCompare`.
3. **Server projection.** No route returns state (`NIOAdminRoutes.swift` ~107–135 only lists lands, stats, reevaluation). The exact projection is `SyncEngine.snapshot(for:from:mode:)` (`SyncEngine.swift` ~72), side-effect free; `lateJoinSnapshot` (~1038) also fills the diff cache and must not be used. `TransportAdapter.keeper` / `syncEngine` are private; `LandRealm` only exposes `getLandStats`.
4. **No quiescent point.** Hero-defense ticks every 50 ms, syncs every 100 ms; the tick spawns and moves monsters and players auto-shoot, so stopping inputs does not stop state changes. `LandKeeper` has no pause API (only `autoStartLoops` at init and `stepTickOnce`).
5. **ws-loadtest** decodes frames only to classify them (no patch applier, raw `ws`, no SDK); adding convergence there is costly. Out of scope; the CLI is the place.
6. **In-process precedent.** `SyncStrategyEquivalenceTests` already rebuilds per-session views from patches and compares with `SyncEngine().snapshot(for:)`. Reuse its comparison semantics (same normalization of maps/arrays/absent fields).

## Design

### PR 1 — core: freeze + projection (debug only)

- **Freeze = pause + drain + settle**, as one `debugSettle()` on the adapter/keeper:
  1. set a frozen flag checked **inside** `runTick` / `runSync` (not only in the loop), so no new tick or sync body starts;
  2. **drain**: await the in-flight tick/sync iteration (an iteration counter or continuation released at the end of each iteration); for tickless lands, hold `handleActionEnvelope` / client events while frozen (queue them, release on resume), and await resolver tasks already in flight;
  3. **settle**: wait until no sync cycle is running, then run one `syncNow` cycle and confirm `beginSync` accepted it (retry if rejected) — `syncNow` alone returns silently on rejection;
  4. capture the **projection inputs from the same state copy** the settle cycle used (the copy returned by `beginSync`), not from a later `currentState()`;
  5. return only after the settle cycle's sends were issued; after #60 these sends are awaited, so returning after the cycle means they are in each session's FIFO.
- **The settle cycle is the only sync while frozen.** Gate the `syncNow` and `syncBroadcastOnly` entry points on the frozen flag (defer to resume; the settle cycle is exempt). This covers OnLeave's broadcast-only sync, #82's follow-up sync and external `syncNow` calls. A join's firstSync only goes to the joiner and is allowed. Membership changes during a freeze (join/leave) invalidate the check: the freeze records a membership version, and the projection response carries a `membershipChanged` flag; the CLI reports "membership changed" instead of a mismatch.
- **Second freeze while frozen** (ref-count > 0): return the existing token and projection without a new settle. Auto-resume timeout configurable via env, reset on each freeze call.
- **Projection** from that copy: `SyncEngine().snapshot(for: playerID, from: copy, mode: .all)` (`SyncEngine.swift` ~72) — a fresh engine, side-effect free; compared against **current state, not the broadcast cache**, so a cache/state divergence shows up as a mismatch (that is the point). Also expose the broadcast-only projection (no player).
- **Freeze lifetime:** ref-counted (`freeze` increments, `resume` decrements) so several clients of one room can compare under one freeze; the server **auto-resumes after a timeout** (e.g. 30 s, logged) so a failed scenario cannot leave a land frozen for the rest of the E2E run.
- Admin routes (double gate: admin key **and** `ENABLE_DEBUG_STATE_ROUTES=true` via `getEnvBool` + a `*EnvKeys` constant; the admin surface covers Demo and GameServer through `NIOLandHost`):
  - `POST /admin/lands/:landID/debug/freeze` → response DTO `{ tickId, freezeToken }` after settle;
  - `GET /admin/lands/:landID/debug/projection?playerID=…` (omit `playerID` for broadcast-only) → JSON DTO of the captured projection;
  - `POST /admin/lands/:landID/debug/resume`.
  Document that these routes expose full state and that freeze is a DoS lever if enabled in production.
- **Wire shape:** the route must emit values in the same shape the state wire carries (e.g. fixed-point `Position2`/`Angle` as raw ints `{v:{x,y}}`); assert it in a DTO test.

### PR 2 — tools: CLI step and scenarios (+ #80)

- New scenario step `assertConverged` in `cli.ts`: stop sending, call `freeze`, wait for the settle frames (after #60 the freeze response implies they are queued in FIFO order; wait for one more frame or a short quiet window), `GET projection` for this client's player, compare `normalizeForCompare(view.getState())` with the normalized server JSON via `deepEqual`; on mismatch print the differing paths (first N). **Always `resume` in `finally`.** Admin URL and key from CLI flags/env.
- **Comparison semantics pinned by a unit test in PR 2**, following `SyncStrategyEquivalenceTests`: absent vs `null` (how the SDK applies `.delete`, whether the snapshot emits `null` for a nil optional or omits the key — `deepEqual` is strict on key sets); fixed-point values compared int-to-int in wire shape; key order irrelevant; other players' per-player fields absent on both sides; integers above 2^53 (MessagePack BigInt vs JSON Number) normalized or asserted absent.
- **Multi-client rooms:** one coordinator (the script, or the first client) freezes, all clients of the room compare behind a barrier, then one resume; no client sends during the freeze.
- Add `assertConverged` at the end of the hero-defense scenario(s) and one mid-run checkpoint after a burst of actions; add it to Demo scenarios that exercise per-player fields.
- E2E scripts set `ENABLE_DEBUG_STATE_ROUTES=true` and the admin key for the server.
- **#80:** one extra `messagepack` run with `AUTO_DIRTY_TRACKING=false` in `test-e2e-game.sh` (and Demo if cheap), same scenarios including `assertConverged`.
- Load variant (several concurrent CLI clients in one room, several rooms) — optional flag in the script, using the coordinator above; the full load-test integration is a follow-up.
- Fault injection for the negative test ("drop one patch") lives in the CLI client wrapper (Tools/CLI), not in the SDK; if it ends up in the SDK, `sdk/ts` tests and verification apply.

### Sequencing with #60

Until #60 lands, frames of an earlier cycle (queued `TransportSendQueue` frames, merged frames from unstructured tasks) can arrive after the settle frames, so `assertConverged` can fail intermittently on otherwise correct code. Order: PR 1 and PR 2 may merge before #60, but `assertConverged` is **not a merge gate** until #60 is merged: report-only applies to **state mismatches only**, printed as a distinct greppable line `CONVERGENCE MISMATCH (report-only)`; route/HTTP/auth errors, freeze timeouts and projection fetch failures stay fatal for the script. Record the pre-#60 mismatch count over E2E runs as a baseline. #60's PR switches it to gating and must show the drop from that baseline to 0 over 20 consecutive runs per encoding.

## Tests

- PR 1 (Swift Testing):
  - freeze drains: a tick already running when freeze is called finishes before settle, and its state change is in the projection and in the settle frames; no tick/sync body starts while frozen;
  - tickless: an action sent during freeze is held and processed after resume; a resolver in flight at freeze time completes before settle;
  - settle runs even when a cycle is in flight at freeze time (retries until `beginSync` accepts);
  - projection equals `SyncEngine().snapshot(for:)` of the settle copy and leaves the adapter caches untouched (next diff unchanged); broadcast-only projection;
  - ref-counted freeze/resume; a second freeze returns the same token without a new settle; auto-resume after the (configurable, reset-on-freeze) timeout;
  - while frozen, `syncNow`/`syncBroadcastOnly` from OnLeave, follow-ups or external calls do not send frames; a leave during freeze sets `membershipChanged`;
  - routes: 404 when the env flag is off, 401 without the key; DTO wire shape for fixed-point types.
- PR 2: comparison-semantics unit test; route errors (404/401/timeout) fail the script even in report-only mode; `assertConverged` runs in all three encodings (report-only until #60); the drop-one-patch fault injection makes it fail with a path diff; `resume` happens on scenario failure; #80 run passes.

## Verification

PR 1: core rules (full `swift test`, release build, both E2E). PR 2: both E2E scripts, `cd Tools/CLI && npm test` if present, `cd sdk/ts && npm test` if the SDK is touched.

## Out of scope

- ws-loadtest integration (finding 5), network-impairment runs (use this step later), event-loss accounting.

## Prior notes checked

Searched `Notes/`, `docs/`, `deep-research/` for "convergence", "projection", "debug route", "freeze". No prior design for a state-dump route.

## Adversarial check record (revision 1 → 2)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Freeze = pause inside runTick/runSync + drain in-flight iteration, held actions and resolvers in tickless lands; projection from the settle cycle's own copy |
| B2 | blocking | Settle confirms `beginSync` accepted (retry); report-only until #60, #60 makes it gating with repeated passes |
| S1 | should | Comparison semantics pinned by a PR 2 unit test (absent/null, fixed-point wire shape, BigInt) |
| S2 | should | Ref-counted freeze; coordinator + barrier for multi-client rooms |
| S3 | should | CLI resumes in `finally`; server auto-resume timeout |
| S4 | should | Projection vs current state stated; broadcast-only projection added |
| N1 | nit | Admin route kept, double gate, DoS note |
| N2 | nit | Event-loss accounting out of scope |
| N3 | nit | Fault injection in the CLI wrapper |
| C1 (rev 2 pass) | should | Sync entry points gated while frozen (settle exempt); membership change flagged, not reported as mismatch |
| C2 (rev 2 pass) | should | Report-only for mismatches only; infra errors fatal; greppable line |
| N1/N2 (rev 2 pass) | nit | Re-freeze returns existing token; env timeout reset per freeze; pre-#60 mismatch baseline |
