# Generic Replay Land v2 Integration Recovery Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `HeroDefense` replay fully rely on generic auto-generated snapshot decoding (no manual replay land/state decode glue) and enforce replay correctness with deterministic CLI verification for entity counts.

**Architecture:** Keep replay execution on `registerWithGenericReplay` + `GenericReplayLand<State>`, and move all state reconstruction responsibilities to macro-generated `StateFromSnapshotDecodable` + `SnapshotValueDecodable`. Remove manual replay projection/apply paths in `HeroDefenseReplayLand.swift`. Strengthen verification by turning replay entity presence into hard assertions in `verify-replay-record.ts`.

**Tech Stack:** Swift macros (`@StateNodeBuilder`, `@SnapshotConvertible`), Swift Testing (`@Test`, `#expect`), NIO replay registration, TypeScript CLI (`tsx`, `@swiftstatetree/sdk`).

---

## Current Findings (must preserve as baseline)

1. `verify-replay-record.ts` currently reports base OK but `Players: 0, Monsters: 0, Turrets: 0`, and exits success with WARN.
2. `ReevaluationRunner --export-jsonl` on the same record shows replay state is non-empty from tick 0 (players/monsters exist), so source replay data exists.
3. Existing integration still includes manual decode/bridging artifacts:
- `Examples/GameDemo/Sources/GameContent/States/HeroDefenseState.swift` has manual `StateFromSnapshotDecodable` extension.
- `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift` still exists with manual `applyProjectedState` and event forwarding logic.
4. `@StateNodeBuilder` macro implementation contains extension-generation logic, but declaration in `Sources/SwiftStateTree/StateTree/StateTreeBuilder.swift` is currently `@attached(member, ...)` only, so auto-generated protocol extension path is incomplete.

---

## Task 1: Complete Auto-Generation Contract for `@StateNodeBuilder`

**Files:**
- Modify: `Sources/SwiftStateTree/StateTree/StateTreeBuilder.swift`
- Modify: `Sources/SwiftStateTreeMacros/StateNodeBuilderMacro.swift` (only if required to align attachment behavior)
- Modify: `Tests/SwiftStateTreeMacrosTests/StateNodeBuilderSnapshotDecodeTests.swift`
- Modify: `Tests/SwiftStateTreeTests/StateNodeSnapshotDecodeRuntimeTests.swift`
- Modify: `Tests/SwiftStateTreeNIOTests/GenericReplayLandCompileTests.swift`
- Modify: `Tests/SwiftStateTreeNIOTests/RegisterWithGenericReplayCompileTests.swift`

**Step 1: Write/adjust failing tests first**

- Ensure tests assert that a `@StateNodeBuilder` type auto-conforms to `StateFromSnapshotDecodable` without manual extension.
- Remove manual test-only conformance blocks that should become redundant and let compilation fail first.

**Step 2: Implement macro declaration fix**

- Update `StateNodeBuilder` macro declaration to include extension attachment for `StateFromSnapshotDecodable` and `init(fromBroadcastSnapshot:)`.
- Keep generated assignments via `self._field.wrappedValue = try _snapshotDecode(...)` so dirty tracking is preserved.

**Step 3: Re-run tests**

Run:
```bash
swift test --filter StateNodeBuilderSnapshotDecodeTests
swift test --filter StateNodeSnapshotDecodeRuntimeTests
swift test --filter GenericReplayLand
```

Expected:
- Compile succeeds without manual conformance stubs.
- Snapshot decode runtime tests pass.

---

## Task 2: Remove Manual HeroDefense Replay Glue

**Files:**
- Modify: `Examples/GameDemo/Sources/GameContent/States/HeroDefenseState.swift`
- Delete: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Modify: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift` (replace manual replay-land assertions)
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift` (confirm generic replay only, no fallback manual replay path)

**Step 1: Failing test/spec first**

- Add/adjust tests in `Examples/GameDemo/Tests/` to assert replay state reconstruction from `StateSnapshot` yields non-empty `players/monsters` on representative snapshot payloads.
- Add a compile-time assertion that `HeroDefenseState` satisfies `StateFromSnapshotDecodable` without handwritten extension.

**Step 2: Remove manual code paths**

- Delete manual `StateFromSnapshotDecodable` extension in `HeroDefenseState.swift`.
- Delete `HeroDefenseReplayLand.swift` and migrate/replace any remaining test dependencies.
- Keep `GameServer` replay registration exclusively on `registerWithGenericReplay`.

**Step 3: Validate no references remain**

Run:
```bash
rg -n "HeroDefenseReplay\.makeLand|applyProjectedState|buildProjectedServerEvents|StateFromSnapshotDecodable" Examples/GameDemo
```

Expected:
- No runtime dependency on `HeroDefenseReplayLand` helpers.
- `StateFromSnapshotDecodable` in GameDemo comes from macro-generated path.

---

## Task 3: Turn Replay Entity Checks into Hard Verification (`verify-replay-record.ts`)

**Files:**
- Modify: `Tools/CLI/src/verify-replay-record.ts`
- Modify: `Tools/CLI/src/verify-replay-helpers.ts`
- Modify: `Tools/CLI/scripts/internal/test-verify-replay-helpers.ts`

**Step 1: Write failing helper tests first**

- Add tests for entity count extraction and threshold checks:
- max seen players/monsters/turrets during wait window
- fail decision when `maxMonsters < minMonsters`
- fail decision when no non-default replay activity is observed

**Step 2: Implement strict verification behavior**

- Add CLI options (with defaults for hero-defense replay):
- `--min-players` (default `1`)
- `--min-monsters` (default `1`)
- `--min-turrets` (default `0`)
- `--wait-ms` (default existing window)
- Poll state over window and track maximum counts seen.
- Keep base position validation.
- Change current WARN-only path into FAIL when minimum thresholds are not reached.
- Print deterministic summary: `maxPlayers`, `maxMonsters`, `maxTurrets`, and pass/fail reasons.

**Step 3: Run CLI unit tests**

Run:
```bash
cd Tools/CLI && npm run test:cli:unit
```

Expected:
- Updated helper tests pass.

---

## Task 4: End-to-End Replay Validation Gate

**Files:**
- No new files required (command gate + CI checklist)

**Step 1: Reproduce pre-fix failure (document once)**

Run:
```bash
cd Examples/GameDemo && ENABLE_REEVALUATION=true TRANSPORT_ENCODING=messagepack swift run GameServer
```

In another shell:
```bash
cd Tools/CLI && npx tsx src/verify-replay-record.ts --record-path=../../Examples/GameDemo/reevaluation-records/3-hero-defense.json --min-players=1 --min-monsters=1
```

Expected before fix:
- Script fails (entity thresholds unmet).

**Step 2: Verify post-fix success**

Re-run the same command after Tasks 1-3.

Expected after fix:
- Base position check passes.
- Entity thresholds pass (`maxPlayers >= 1`, `maxMonsters >= 1`).
- Exit code is 0.

**Step 3: Full regression set**

Run:
```bash
swift test
cd Tools/CLI && npm run test:e2e:game:ci
```

Expected:
- No regressions in replay registration or encoding-mode behavior.

---

## Commit Strategy (small, reviewable)

1. `feat(macros): attach StateFromSnapshotDecodable extension generation to StateNodeBuilder`
2. `refactor(gamedemo): remove manual HeroDefense replay land glue and rely on generic replay`
3. `test(cli): enforce replay entity count verification in verify-replay-record`
4. `test(e2e): add replay verification gate using min entity thresholds`

---

## Risks and Mitigations

1. Risk: macro attachment change causes duplicate conformances in tests/app types.
- Mitigation: remove manual conformance stubs first, then compile.

2. Risk: deleting `HeroDefenseReplayLand.swift` breaks schema/event expectations.
- Mitigation: verify generated schema for `hero-defense-replay` and update tests that assumed manual replay-only events.

3. Risk: stricter `verify-replay-record.ts` becomes flaky on slow machines.
- Mitigation: configurable `--wait-ms`, deterministic max-count-over-window logic instead of single-sample assertion.

