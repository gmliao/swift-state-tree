[English](2026-02-19-replay-generic-baseline-checklist.md) | [中文版](2026-02-19-replay-generic-baseline-checklist.zh-TW.md)

# Replay Generic Baseline Checklist

## Baseline Lock

- Tag: `replay-baseline-v1`
- Branch: `codex/replay-baseline-v1`
- Commit: `efa46072016100de6dc0d2d0916149bf844d85eb`
- Baseline date: 2026-02-19

## Purpose

Use this baseline to compare future generic replay architecture changes against a known working replay version.

## Required Comparison Dimensions

1. Deterministic correctness
- Hash parity from replay tick events (`mismatches=0` on baseline scenario).
- No replay tick regression in total tick count.

2. State parity
- Players, turrets, monsters, base, and score values must match expected replay progression.
- Validate key position fields (`players[*].position`, `turrets[*].position`, `base.position`) on sampled ticks.

3. Server event fidelity
- Replay stream must include visual combat events (`PlayerShoot`, `TurretFire`).
- Replay stream must observe monster removal/defeat transitions.
- No replay-only fabricated fallback event behavior in strict mode.

4. User experience
- Replay start/load failures must surface in UI (not console-only).
- Replay camera behavior remains usable (base-centered start + click-to-move in replay mode).
- Replay start flow remains one-click from monitor UI.

5. API simplicity (future target)
- Server setup: reevaluation should be enable-able with one feature-level declaration.
- Client setup: replay mode switch should be SDK-level API, not custom view glue code.

## Baseline Verification Commands

1. CLI replay E2E
- `cd Tools/CLI && npm run test:e2e:game:replay`

2. Swift unit tests
- `swift test`

3. Web replay proof (Playwright CLI)
- `cd Examples/GameDemo/WebClient && npx playwright test`

## Evidence to Keep Per Comparison Run

- Git commit hash under test.
- E2E output summary (pass/fail and key replay assertions).
- Playwright proof summary (`total`, `correct`, `mismatches`).
- If failure occurs: first failing tick ID and event/state diff snippet.
