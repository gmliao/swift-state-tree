[English](2026-02-20-low-risk-same-land-reevaluation-plan.md) | [中文版](2026-02-20-low-risk-same-land-reevaluation-plan.zh-TW.md)

# Low-Risk Same-Land Reevaluation Stream Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Run replay with the same live land logic (`LandDefinition`) while keeping separate replay paths, with lower overhead and no replay-only gameplay logic.

**Architecture:** Keep `LandRealm`/routing model unchanged (no duplicate landType registration). Replay stays on a separate WebSocket path/landType suffix, but the replay land registration uses the same live `LandDefinition`. Land creation becomes dynamic via `LandManager` resolver: live sessions create `LandKeeper(mode: .live)`, replay sessions create `LandKeeper(mode: .reevaluation, reevaluationSource: ...)` and stream outputs to transport.

**Tech Stack:** Swift 6, Swift Testing, SwiftStateTree, SwiftStateTreeTransport, SwiftStateTreeNIO, SwiftStateTreeReevaluationMonitor, GameDemo, Tools/CLI E2E.

## Baseline

- Baseline tag: `replay-low-risk-baseline-v2`
- Baseline commit: `86eb25c`
- Constraint: do not change deterministic game logic behavior.

## Performance + Complexity Impact (Target)

- CPU target: replay path CPU time reduced by at least 15% vs projector/replay-land path in HeroDefense replay E2E.
- Memory target: replay peak RSS reduced by at least 10% in replay E2E runs.
- Latency target: replay completion time variance (p95-p50) reduced by at least 20% over 10 runs.
- Complexity target: remove replay-only game behavior code paths (fallback synthesis and replay-state re-apply glue).

## Guardrails

- Do not fork `LandKeeper`.
- Keep `LandRealm` registration uniqueness intact.
- Keep admin replay start compatibility checks (landType/schema/version).
- Ensure replay still emits live visual events (`PlayerShoot`, `TurretFire`) from deterministic execution, not fallback guesses.

### Task 1: Add replay session descriptor and decoding utility

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplaySessionDescriptor.swift`
- Modify: `Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift`
- Test: `Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift`

**Step 1: Write failing tests for replay descriptor payload and token roundtrip**

Add tests asserting:
- replay start response includes enough metadata to build reevaluation session descriptor deterministically.
- token/path decode rejects traversal and invalid payload.

**Step 2: Run focused tests (expect FAIL)**

Run: `swift test --filter NIOAdminRoutesReplayStartTests`
Expected: FAIL on missing descriptor utility and new assertions.

**Step 3: Implement minimal descriptor utility**

Implement parse/encode helpers for replay session info and keep current compatibility behavior.

**Step 4: Re-run focused tests (expect PASS)**

Run: `swift test --filter NIOAdminRoutesReplayStartTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplaySessionDescriptor.swift Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift
git commit -m "feat: add replay session descriptor utility"
```

### Task 2: Add reevaluation output mode to LandKeeper (transport streaming in reevaluation mode)

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/LandKeeper.swift`
- Test: `Tests/SwiftStateTreeTests/LandKeeperTickSyncTests.swift`
- Create Test: `Tests/SwiftStateTreeTests/LandKeeperReevaluationOutputModeTests.swift`

**Step 1: Write failing tests for reevaluation output behavior**

Add tests asserting:
- `mode: .reevaluation` with `outputMode: .sinkOnly` keeps current behavior.
- `mode: .reevaluation` with `outputMode: .transportAndSink` forwards emitted events to transport and sink.

**Step 2: Run focused tests (expect FAIL)**

Run: `swift test --filter LandKeeperReevaluationOutputModeTests`
Expected: FAIL because output mode does not exist.

**Step 3: Implement minimal output mode enum + switch branch**

Add a non-breaking option to `LandKeeper` init, defaulting to current behavior.

**Step 4: Re-run focused tests (expect PASS)**

Run: `swift test --filter LandKeeperReevaluationOutputModeTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/LandKeeper.swift Tests/SwiftStateTreeTests/LandKeeperReevaluationOutputModeTests.swift Tests/SwiftStateTreeTests/LandKeeperTickSyncTests.swift
git commit -m "feat: support transport streaming output in reevaluation mode"
```

### Task 3: Add dynamic keeper mode resolver in LandManager

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/LandManager.swift`
- Modify: `Sources/SwiftStateTreeNIO/NIOLandServer.swift`
- Modify: `Sources/SwiftStateTreeNIO/NIOLandHost.swift`
- Modify: `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`
- Test: `Tests/SwiftStateTreeTransportTests/LandManagerRegistryTests.swift`
- Create Test: `Tests/SwiftStateTreeTransportTests/LandManagerReevaluationModeTests.swift`

**Step 1: Write failing tests for dynamic mode selection**

Add tests asserting:
- live land instances use `.live` keeper mode.
- replay instances use `.reevaluation` keeper mode and source file path.

**Step 2: Run focused tests (expect FAIL)**

Run: `swift test --filter LandManagerReevaluationModeTests`
Expected: FAIL because resolver/factory path does not exist.

**Step 3: Implement minimal resolver API**

Add configuration closure to resolve session runtime mode using `(landID, metadata)`; keep default as live mode.

**Step 4: Re-run focused tests (expect PASS)**

Run: `swift test --filter LandManagerReevaluationModeTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeTransport/LandManager.swift Sources/SwiftStateTreeNIO/NIOLandServer.swift Sources/SwiftStateTreeNIO/NIOLandHost.swift Sources/SwiftStateTreeNIO/ReevaluationFeature.swift Tests/SwiftStateTreeTransportTests/LandManagerReevaluationModeTests.swift Tests/SwiftStateTreeTransportTests/LandManagerRegistryTests.swift
git commit -m "feat: add dynamic landkeeper mode resolver for replay sessions"
```

### Task 4: Register replay path with same live land definition

**Files:**
- Modify: `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`
- Modify: `Examples/GameDemo/Sources/SchemaGen/main.swift`
- Test: `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift`

**Step 1: Write failing tests for same-land replay registration**

Add tests asserting:
- replay landType/path can be registered without a dedicated replay gameplay land.
- reevaluation feature still registers monitor land and services.

**Step 2: Run focused tests (expect FAIL)**

Run: `swift test --filter ReevaluationFeatureRegistrationTests`
Expected: FAIL on old replay-land assumptions.

**Step 3: Implement minimal registration switch**

Keep replay suffix/path, but use live land definition for replay registration and dynamic keeper mode.

**Step 4: Re-run focused tests (expect PASS)**

Run: `swift test --filter ReevaluationFeatureRegistrationTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeNIO/ReevaluationFeature.swift Examples/GameDemo/Sources/GameServer/main.swift Examples/GameDemo/Sources/SchemaGen/main.swift Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift
git commit -m "refactor: register replay path using same live land definition"
```

### Task 5: Remove replay-only HeroDefense land dependency from active path

**Files:**
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Modify: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift`
- Modify: `Tools/CLI/src/reevaluation-replay-e2e-game.ts`

**Step 1: Write failing tests for no replay-only behavior dependency**

Add/adjust tests asserting:
- replay visuals come from deterministic emitted server events via same land logic.
- no fallback event synthesis or replay-only wrapper assumptions remain in active path.

**Step 2: Run focused tests (expect FAIL)**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `cd Tools/CLI && npm run test:e2e:game:replay`
Expected: FAIL until active path is switched.

**Step 3: Implement minimal path cleanup**

Retire replay-only path from active server wiring; keep legacy code only if explicitly needed behind opt-in compatibility flag.

**Step 4: Re-run focused tests (expect PASS)**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `cd Tools/CLI && npm run test:e2e:game:replay`
Expected: PASS.

**Step 5: Commit**

```bash
git add Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift Tools/CLI/src/reevaluation-replay-e2e-game.ts
git commit -m "refactor: switch hero replay to same-land reevaluation execution"
```

### Task 6: Full verification + performance proof

**Files:**
- Create: `docs/plans/2026-02-20-low-risk-same-land-reevaluation-verification.md`

**Step 1: Run deterministic correctness tests**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `swift test --filter ReevaluationReplayCompatibilityTests`
- `swift test --filter ReevaluationFeatureRegistrationTests`
- `swift test --filter NIOAdminRoutesReplayStartTests`
Expected: PASS.

**Step 2: Run replay E2E repeatedly for stability**

Run:
- `cd Tools/CLI && for i in 1 2 3 4 5; do LOG_LEVEL=error npm run -s test:e2e:game:replay || break; done`
Expected: 5/5 PASS.

**Step 3: Collect performance evidence**

Run baseline vs new path with same scenario and collect:
- completion time
- process RSS peak
- replay tick coverage
- mismatch count

Expected:
- mismatch=0
- no replay timeout in 10 runs
- meets target improvements or explicitly documents gaps.

**Step 4: Produce verification report**

Write concise report with command outputs and comparison table.

**Step 5: Commit**

```bash
git add docs/plans/2026-02-20-low-risk-same-land-reevaluation-verification.md
git commit -m "docs: add same-land reevaluation verification report"
```

## Final completion gate

Before merge, run:

```bash
swift test
cd Tools/CLI && npm run test:e2e:game:replay
```

If either fails, do not merge.
