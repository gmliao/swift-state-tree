# Experiment design: replay verification at scale + FP perturbation sensitivity

Design run under `sst-experiment` (step 2b). Topic: `deep-research/replay-scale-fp-perturbation/`.
Card approved by the maintainer in chat on 2026-08-31. Everything in this round (knobs, this
note, data) lands via the `experiment/replay-scale-fp-perturbation` PR.

## Question

(A) Over dozens of recordings and tens of thousands of ticks, does per-tick hash replay
verification stay at 0 mismatches? (B) When a floating-point / fixed-point perturbation is
injected into replay, does the verification detect it, and with what latency in ticks?

## Design decisions

### D1: Headless batch recording — `ReevaluationRunner --record`

**Chosen:** a new `--record` mode runs an in-process live `LandKeeper` with
`enableLiveStateHashRecording`, joins 5 players, injects a deterministic `MoveTo` client
event per player every 20 ticks (integer-math targets, same style as the EncodingBenchmark
`--active-players` injector), steps N ticks, and saves via `ReevaluationRecorder.save`.
`landID = "hero-defense:batch-<seed>"` — the RNG seed is derived from the landID, so each
seed index yields a distinct recording.

**Rejected:** looping the WebSocket E2E recorder against a live GameServer — orders of
magnitude slower, adds transport nondeterminism unrelated to the question, and cannot run
30 recordings unattended in reasonable time.

**Why this answers the Question:** live-mode `LandKeeper` records injected actions/client
events and per-tick hashes exactly as the server path does; replaying these records through
`ReevaluationEngine` is the same verification the paper describes, now at ~30 × 1,200 ticks.

### D2: Perturbation hook — env-driven, inside `MovementSystem.updatePlayerMovement`

**Chosen:** three env vars (read once per process), `HERO_PERTURB_TICK`,
`HERO_PERTURB_MODE` (`float` | `fixed`), `HERO_PERTURB_EPS`. At the configured tick, every
player currently moving gets perturbed: `float` adds eps to the Float `moveSpeed` before
fixed-point quantization; `fixed` adds eps raw LSB units (1 LSB = 0.001 world units) to the
quantized x coordinate after the movement step. Unset env = hook fully inert (recording and
normal replay are untouched).

**Rejected:** a perturbation flag inside `ReevaluationEngine` (core `Sources/`, would need a
core PR and couples the engine to an experiment concern); patching the record file itself
(tests the parser, not the determinism pipeline).

**Why this answers the Question:** the reviewer objection is about sensitivity to FP
non-determinism in game logic. Perturbing the actual movement computation during replay is
exactly that failure mode; sub-LSB float noise vs >=1 LSB shifts separates "absorbed by
fixed-point quantization" from "detected by hash comparison".

### D3: Metric semantics (mandatory)

- Part A, per recording: `total_ticks` = maxTickId+1; `mismatch_ticks` = count of ticks where
  the replayed hash differs from the recorded ground-truth hash (second check: run1 vs run2
  of the replay); `total_actions` / `total_client_events` from record statistics. One unit =
  one tick compared.
- Part B, per (recording, eps) cell: `detected` = verification exited with >=1 recorded-hash
  mismatch; `detection_latency_ticks` = first mismatched tickId − perturb tick (600); null
  when not detected. One unit = one perturbed replay run.
- All runs `swift run -c release`; runner stdout kept as `results/<run-id>.log`.

### D4: Matrix

| Part | axis | values |
|---|---|---|
| A | seed | 1…30 (landID-derived), 1,200 ticks each |
| B | eps | float 1e-7 (sub-LSB), fixed +1 LSB, fixed +1000 LSB | 
| B | recordings | seeds 1…10, perturb tick 600 |

Fixed: 5 players, MoveTo every 20 ticks, no turrets, single room, same host (Apple M2, arm64).

## Risks

- Same-architecture only this round (arm64 record → arm64 replay); the 2026-02 evidence
  already covers arm64 → x86_64. Stated in Caveats.
- Sub-LSB float perturbation may be absorbed (0 detections) — that is a result, not a failure.
- If players are not moving at tick 600 the perturbation is a no-op; the 20-tick MoveTo
  cadence with far targets keeps all players moving throughout.

## Findings during execution (2026-08-31)

1. **Replay sequence-counter gap.** Re-evaluation replays recorded inputs with their recorded
   sequence numbers but never advances the shared output-sequence counter past them, so server
   events emitted during replay carry different `sequence` values than the recording even when
   state evolution is identical. The runner now re-checks such mismatches by content (tickId,
   type, payload, target) and reports a pure sequence difference as an explicit warning instead
   of a failure. A core fix (advancing the counter during replay) is tracked as follow-up work.
2. **Order-dependent game logic (real determinism bug, found by scaling).** The first full run
   failed 28/30: replays diverged from recordings at scattered ticks, and one seed even diverged
   between two replays in the same process. Field-level diff at the first divergent tick showed
   players' `lastFireTick`/`rotation`/`resources` differing — firing order and target selection
   depended on `Dictionary` iteration order (`for (id, x) in dict` in the tick handler, and a
   strict `<` nearest-target comparison that broke ties by iteration order). Fix: sorted-key
   iteration for players/monsters/turrets and a lowest-id tie-break in
   `CombatSystem.findNearestMonsterInRange`. After the fix: 30/30 recordings verify with zero
   mismatches. The five short recordings used previously never surfaced this because sparse
   combat rarely hit an order-dependent branch.
3. The pre-existing committed fixtures (`reevaluation-records/1..3-hero-defense.json`, January)
   no longer replay against current game logic — expected staleness, they are not used by tests.
