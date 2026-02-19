[English](2026-02-19-replay-generic-session-mode-plan.md) | [中文版](2026-02-19-replay-generic-session-mode-plan.zh-TW.md)

# Replay Generic Session Mode Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Provide a user-friendly, production-safe reevaluation replay system where server setup and client replay mode switching are SDK-level features (not app glue code), while preserving deterministic parity and baseline comparability.

**Architecture:** Keep architecture A constraints: no `LandKeeper` fork, replay pipeline stays `ReevaluationRunnerService + projector`, replay state remains live-compatible. Add an extension layer: server-side reevaluation feature registration and SDK session-mode API (`live`/`replay`) with reconnect under the hood. Replay events should prefer projected emitted events; fallback synthesis must be optional compatibility mode, not default behavior.

**Tech Stack:** Swift 6, Swift Testing, SwiftStateTree + SwiftStateTreeNIO + SwiftStateTreeReevaluationMonitor, TypeScript SDK (`sdk/ts` + vitest), GameDemo WebClient (Vue + generated bindings), CLI E2E + Playwright verification.

**Required skills during implementation:** `@superpowers:test-driven-development`, `@superpowers:verification-before-completion`, `@superpowers:systematic-debugging`.

## Baseline and guardrails

- Baseline tag: `replay-baseline-v1`
- Baseline branch: `codex/replay-baseline-v1`
- Baseline checklist: `docs/plans/2026-02-19-replay-generic-baseline-checklist.md`
- Non-goal: changing deterministic tick semantics or introducing replay-specific `LandKeeper` runtime mode.

### Task 1: Server-facing Reevaluation Feature API (one declaration setup)

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift`
- Create: `Sources/SwiftStateTreeNIO/Integration/NIOReevaluationFeatureRegistration.swift`
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`
- Test: `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift`
- Test: `Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift`

**Step 1: Write failing tests for one-declaration registration**

Add tests asserting:
- registering live land + reevaluation feature auto-registers `<landType>-replay` and monitor land when enabled.
- `/admin/reevaluation/replay/start` works without manual replay-land wiring in `main.swift`.

**Step 2: Run tests and confirm failures**

Run:
- `swift test --filter ReevaluationFeatureRegistrationTests`
- `swift test --filter NIOAdminRoutesReplayStartTests`

Expected: new tests fail because feature API does not exist.

**Step 3: Implement minimal feature API**

Implement:
- `ReevaluationFeature` value type with explicit options (`enabled`, `requiredRecordVersion`, `projectorResolver`, `targetFactory`).
- `NIOLandHost` helper extension to register required lands/services from one call.

**Step 4: Re-run focused tests**

Run:
- `swift test --filter ReevaluationFeatureRegistrationTests`
- `swift test --filter NIOAdminRoutesReplayStartTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift Sources/SwiftStateTreeNIO/Integration/NIOReevaluationFeatureRegistration.swift Examples/GameDemo/Sources/GameServer/main.swift Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift
git commit -m "feat: add one-declaration reevaluation feature registration"
```

### Task 2: Type-erased replay event forwarding (remove hard-coded event decoding path)

**Files:**
- Modify: `Sources/SwiftStateTree/Land/LandContext.swift`
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Test: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift`
- Test: `Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift`

**Step 1: Write failing tests for projected event pass-through**

Add tests asserting:
- replay land emits projected events from `typeIdentifier + payload` without manually decoding per event type branch.
- unknown projected events are safely ignored/logged (no crash), known events are emitted deterministically.

**Step 2: Run tests and confirm failures**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `swift test --filter ReevaluationReplayCompatibilityTests`

Expected: failures where hard-coded decode paths are still required.

**Step 3: Implement minimal type-erased emit API**

Implement:
- `LandContext.emitAnyServerEvent(_ event: AnyServerEvent, to: EventTarget)`
- replay land uses a generic projector-event forwarder.

**Step 4: Re-run focused tests**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `swift test --filter ReevaluationReplayCompatibilityTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Land/LandContext.swift Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift
git commit -m "feat: support type-erased replay event forwarding"
```

### Task 3: Replay event policy (strict default, compatibility fallback optional)

**Files:**
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift`
- Test: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift`
- Docs: `docs/plans/2026-02-15-server-replay-compatible-mode-plan.md`
- Docs: `docs/plans/2026-02-15-server-replay-compatible-mode-plan.zh-TW.md` (create if missing)

**Step 1: Write failing tests for event policy behavior**

Add tests asserting:
- default policy is `.projectedOnly` (no synthesized fallback events).
- `.projectedWithFallback` can be enabled explicitly for old records with empty projected events.

**Step 2: Run tests and confirm failures**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`

Expected: tests fail because policy switch does not exist yet.

**Step 3: Implement policy switch**

Implement:
- replay event policy enum in reevaluation feature options.
- hero-defense replay land reads policy and chooses strict vs compatibility fallback path.

**Step 4: Re-run focused tests**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`

Expected: PASS.

**Step 5: Commit**

```bash
git add Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift docs/plans/2026-02-15-server-replay-compatible-mode-plan.md docs/plans/2026-02-15-server-replay-compatible-mode-plan.zh-TW.md
git commit -m "feat: add replay event policy with strict default"
```

### Task 4: SDK core session mode API (`live` <-> `replay`)

**Files:**
- Create: `sdk/ts/src/core/session.ts`
- Modify: `sdk/ts/src/core/index.ts`
- Modify: `sdk/ts/src/core/runtime.ts`
- Test: `sdk/ts/src/core/session.test.ts`
- Test: `sdk/ts/src/core/runtime.test.ts` (create if missing)

**Step 1: Write failing SDK tests for mode switching**

Add tests asserting:
- `switchToReplay()` disconnects/reconnects using replay `connectSpec` and updates `mode`.
- `switchToLive()` restores live connection settings.
- mode-switch errors surface through one unified error channel.

**Step 2: Run tests and confirm failures**

Run:
- `cd sdk/ts && npm test -- session`

Expected: FAIL because session module does not exist.

**Step 3: Implement minimal core API**

Implement:
- `StateTreeSession` abstraction with `mode`, `connectLive`, `switchToReplay`, `switchToLive`.
- reconnect semantics are internal; app sees mode switch API.

**Step 4: Re-run focused SDK tests**

Run:
- `cd sdk/ts && npm test -- session`

Expected: PASS.

**Step 5: Commit**

```bash
git add sdk/ts/src/core/session.ts sdk/ts/src/core/index.ts sdk/ts/src/core/runtime.ts sdk/ts/src/core/session.test.ts sdk/ts/src/core/runtime.test.ts
git commit -m "feat(ts): add sdk-level live replay session switching"
```

### Task 5: Codegen session composable generation

**Files:**
- Modify: `sdk/ts/src/codegen/generateStateTreeFiles.ts`
- Modify: `sdk/ts/src/codegen/index.ts`
- Test: `sdk/ts/src/codegen/generateStateTreeFiles.replay-session.test.ts`
- Regenerate: `Examples/GameDemo/WebClient/src/generated/**`

**Step 1: Write failing codegen tests**

Add tests asserting generated composables include:
- `use<Land>Session()` with `mode`, `switchToReplay`, `switchToLive`.
- no app-level manual replay bootstrap boilerplate in generated API shape.

**Step 2: Run tests and confirm failures**

Run:
- `cd sdk/ts && npm test -- replay-session`

Expected: FAIL because generated output lacks session-mode API.

**Step 3: Implement minimal codegen additions**

Implement:
- generate session composable when replay counterpart exists in schema.
- keep existing `use<Land>()` API for backward compatibility.

**Step 4: Regenerate and verify**

Run:
- `cd Examples/GameDemo/WebClient && npm run codegen`
- `cd sdk/ts && npm test -- replay-session`

Expected: PASS and generated files updated.

**Step 5: Commit**

```bash
git add sdk/ts/src/codegen/generateStateTreeFiles.ts sdk/ts/src/codegen/index.ts sdk/ts/src/codegen/generateStateTreeFiles.replay-session.test.ts Examples/GameDemo/WebClient/src/generated
git commit -m "feat(ts): generate session-mode composables for replay switching"
```

### Task 6: GameDemo client migration to SDK session API

**Files:**
- Modify: `Examples/GameDemo/WebClient/src/utils/gameClient.ts`
- Modify: `Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue`
- Modify: `Examples/GameDemo/WebClient/src/views/GameView.vue`
- Delete: `Examples/GameDemo/WebClient/src/utils/LandClient.ts` (if no longer used)
- Test: `Examples/GameDemo/WebClient` vitest suites
- Test: Playwright scripts/config in `Examples/GameDemo/WebClient`

**Step 1: Write failing integration tests (or Playwright assertions)**

Add checks asserting:
- monitor view replay start uses session API (single switch call path).
- route/sessionStorage hacks are not required for replay mode persistence.

**Step 2: Run tests and confirm failures**

Run:
- `cd Examples/GameDemo/WebClient && npm test`

Expected: FAIL where old flow assumptions remain.

**Step 3: Implement migration**

Implement:
- use generated SDK session composable in game client.
- replace manual replay boot flow in monitor view with `switchToReplay({ recordFilePath })`.
- game view reads `session.mode` as source of truth.

**Step 4: Re-run focused web tests**

Run:
- `cd Examples/GameDemo/WebClient && npm test`

Expected: PASS.

**Step 5: Commit**

```bash
git add Examples/GameDemo/WebClient/src/utils/gameClient.ts Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue Examples/GameDemo/WebClient/src/views/GameView.vue Examples/GameDemo/WebClient/src/utils/LandClient.ts
git commit -m "refactor(web): migrate replay flow to sdk session mode api"
```

### Task 7: End-to-end verification and baseline comparison report

**Files:**
- Modify: `Tools/CLI/src/reevaluation-replay-e2e-game.ts` (only if needed)
- Modify: `docs/plans/2026-02-19-replay-generic-baseline-checklist.md`
- Modify: `docs/plans/2026-02-19-replay-generic-baseline-checklist.zh-TW.md`
- Create: `docs/plans/2026-02-19-replay-generic-session-mode-verification.md`
- Create: `docs/plans/2026-02-19-replay-generic-session-mode-verification.zh-TW.md`

**Step 1: Run full verification matrix**

Run:
- `swift test`
- `cd sdk/ts && npm test`
- `cd Examples/GameDemo/WebClient && npm test`
- `cd Tools/CLI && npm run test:e2e:game:replay`
- `cd Examples/GameDemo/WebClient && npx playwright test`

Expected: all PASS.

**Step 2: Compare against baseline**

Record:
- mismatch count parity (target: same as baseline or better).
- replay events presence (`PlayerShoot`, `TurretFire`, monster removals).
- user-facing setup simplification (before/after API steps).

**Step 3: Publish verification notes**

Write markdown report with:
- command outputs summary
- known deltas
- rollback notes to baseline tag if required

**Step 4: Commit**

```bash
git add Tools/CLI/src/reevaluation-replay-e2e-game.ts docs/plans/2026-02-19-replay-generic-baseline-checklist.md docs/plans/2026-02-19-replay-generic-baseline-checklist.zh-TW.md docs/plans/2026-02-19-replay-generic-session-mode-verification.md docs/plans/2026-02-19-replay-generic-session-mode-verification.zh-TW.md
git commit -m "docs: publish generic replay session mode verification report"
```

## Expected user-facing API outcome

### Server (before)

- manual live land registration
- manual replay land registration
- manual reevaluation service injection
- manual monitor/replay wiring

### Server (after)

- one declaration to enable reevaluation + replay capability for a land type.

### Client (before)

- monitor page custom fetch to `/admin/reevaluation/replay/start`
- manual ws URL + replay landID plumbing
- route/sessionStorage replay mode glue

### Client (after)

- SDK session-level API:
  - `connectLive(...)`
  - `switchToReplay({ recordFilePath })`
  - `switchToLive()`
- single `mode` source of truth for UI (camera/input toggles).

