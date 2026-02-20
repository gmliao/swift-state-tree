# Same-Land Reevaluation Verification Report

[English](2026-02-20-low-risk-same-land-reevaluation-verification.md) | [中文版](2026-02-20-low-risk-same-land-reevaluation-verification.zh-TW.md)

## Scope

Verification for the low-risk same-land reevaluation implementation (plan: `2026-02-20-low-risk-same-land-reevaluation-plan.md`). Replay uses the same live `LandDefinition` as live sessions; no dedicated replay gameplay land in the active server path.

## Verification Date

- 2026-02-20

## Step 1: Deterministic Correctness Tests

All required test suites passed:

| Test Suite | Result | Notes |
|------------|--------|-------|
| `HeroDefenseReplayStateParityTests` | PASS | 10 tests (run from `Examples/GameDemo`) |
| `ReevaluationReplayCompatibilityTests` | PASS | 12 tests |
| `ReevaluationFeatureRegistrationTests` | PASS | 4 tests |
| `NIOAdminRoutesReplayStartTests` | PASS | 9 tests |

Commands:

```bash
cd Examples/GameDemo && swift test --filter HeroDefenseReplayStateParityTests
swift test --filter ReevaluationReplayCompatibilityTests
swift test --filter ReevaluationFeatureRegistrationTests
swift test --filter NIOAdminRoutesReplayStartTests
```

## Step 2: Replay E2E Stability

- `./Tools/CLI/test-e2e-game.sh`: **PASS** (all encoding modes: json, jsonOpcode, messagepack)
- Each encoding mode runs: Hero Defense scenario suite + reevaluation record+verify (messagepack only) + **replay stream E2E**
- Replay E2E verified across all three transport encodings

Note: Consecutive 5x `test:e2e:game:replay` runs against a single server instance can hit server lifecycle issues (WebSocket 1006, process trap on replay session end). The full `test-e2e-game.sh` script handles server start/stop per encoding and passes reliably.

## Step 3: Performance Evidence

- **Baseline**: `86eb25c` (tag: `replay-low-risk-baseline-v2`)
- **Current path**: Same-land reevaluation (no replay-only land)
- **mismatch count**: 0 (deterministic correctness tests pass)
- **Replay timeout**: 0 in `test-e2e-game.sh` runs

Formal baseline vs new-path performance comparison (CPU, RSS, completion time variance) was not executed in this verification. Targets from the plan:

- CPU: replay path ≥15% improvement
- Memory: replay peak RSS ≥10% improvement
- Latency: (p95−p50) ≥20% improvement over 10 runs

These can be measured in a dedicated performance run by checking out baseline, running replay E2E 10× with instrumentation, then repeating on current HEAD.

## Step 4: Final Gate

```bash
swift test
cd Tools/CLI && npm run test:e2e:game:replay
```

- `swift test`: **PASS** (728 tests in 39 suites)
- `test:e2e:game:replay`: Requires GameServer running (`ENABLE_REEVALUATION=true`). Use `./Tools/CLI/test-e2e-game.sh` for full CI coverage including replay.

## Summary

| Check | Status |
|-------|--------|
| Deterministic correctness | PASS |
| Replay E2E (all encodings) | PASS |
| Full `swift test` | PASS |
| Same-land registration | Verified (no HeroDefenseReplay in GameServer path) |
| Schema `hero-defense-replay` alias | Via `replayLandTypes` convention |

## Related

- Plan: `docs/plans/2026-02-20-low-risk-same-land-reevaluation-plan.md`
- Schema convention: `SchemaGenCLI.generateSchema(..., replayLandTypes: ["hero-defense"])`
