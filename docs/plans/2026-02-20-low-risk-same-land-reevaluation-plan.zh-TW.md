[English](2026-02-20-low-risk-same-land-reevaluation-plan.md) | [中文版](2026-02-20-low-risk-same-land-reevaluation-plan.zh-TW.md)

# 低風險同 Land Reevaluation Stream 實作計畫

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在保留 replay 分流路徑的前提下，讓 replay 直接使用同一份 live land 邏輯執行，降低中間轉換成本，移除 replay-only 遊戲行為。

**Architecture:** 不改 `LandRealm` 唯一 landType 註冊模型。Replay 仍走獨立 path / replay suffix，但 replay 路徑改註冊同一份 live `LandDefinition`。透過 `LandManager` 動態決策 keeper 建立模式：live 用 `.live`，replay 用 `.reevaluation + source`，並把 reevaluation 輸出直接串到 transport。

**Tech Stack:** Swift 6、Swift Testing、SwiftStateTree、SwiftStateTreeTransport、SwiftStateTreeNIO、SwiftStateTreeReevaluationMonitor、GameDemo、Tools/CLI E2E。

## Baseline

- Baseline tag：`replay-low-risk-baseline-v2`
- Baseline commit：`86eb25c`
- 約束：不可改變 deterministic 遊戲邏輯語義。

## 效能與複雜度目標

- CPU 目標：HeroDefense replay E2E 相對既有 projector/replay-land 路徑至少改善 15%。
- 記憶體目標：Replay 過程 RSS 峰值至少改善 10%。
- 延遲穩定性目標：10 次 replay 完成時間的 (p95-p50) 至少改善 20%。
- 複雜度目標：移除 replay-only 行為路徑（fallback 合成、重播專用 state re-apply glue）。

## Guardrails

- 不 fork `LandKeeper`。
- 不破壞 `LandRealm` landType 唯一性。
- 保留 admin replay start 的相容性檢查（landType/schema/version）。
- Replay 視覺事件必須來自 deterministic 執行結果，不可回退為猜測事件。

### Task 1: Replay session descriptor 與解碼工具

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplaySessionDescriptor.swift`
- Modify: `Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift`
- Test: `Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift`

**Step 1: 先寫失敗測試（descriptor payload + token roundtrip）**

**Step 2: 跑測試確認失敗**

Run: `swift test --filter NIOAdminRoutesReplayStartTests`
Expected: FAIL。

**Step 3: 實作最小 descriptor 工具**

**Step 4: 重跑聚焦測試**

Run: `swift test --filter NIOAdminRoutesReplayStartTests`
Expected: PASS。

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/ReevaluationReplaySessionDescriptor.swift Sources/SwiftStateTreeNIO/HTTP/NIOAdminRoutes.swift Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift
git commit -m "feat: add replay session descriptor utility"
```

### Task 2: LandKeeper 加入 reevaluation output mode（reevaluation 也可直送 transport）

**Files:**
- Modify: `Sources/SwiftStateTree/Runtime/LandKeeper.swift`
- Test: `Tests/SwiftStateTreeTests/LandKeeperTickSyncTests.swift`
- Create Test: `Tests/SwiftStateTreeTests/LandKeeperReevaluationOutputModeTests.swift`

**Step 1: 先寫失敗測試（sinkOnly / transportAndSink）**

**Step 2: 跑測試確認失敗**

Run: `swift test --filter LandKeeperReevaluationOutputModeTests`
Expected: FAIL。

**Step 3: 實作最小 output mode enum + 分支**

**Step 4: 重跑聚焦測試**

Run: `swift test --filter LandKeeperReevaluationOutputModeTests`
Expected: PASS。

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Runtime/LandKeeper.swift Tests/SwiftStateTreeTests/LandKeeperReevaluationOutputModeTests.swift Tests/SwiftStateTreeTests/LandKeeperTickSyncTests.swift
git commit -m "feat: support transport streaming output in reevaluation mode"
```

### Task 3: LandManager 加入動態 keeper mode resolver

**Files:**
- Modify: `Sources/SwiftStateTreeTransport/LandManager.swift`
- Modify: `Sources/SwiftStateTreeNIO/NIOLandServer.swift`
- Modify: `Sources/SwiftStateTreeNIO/NIOLandHost.swift`
- Modify: `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`
- Test: `Tests/SwiftStateTreeTransportTests/LandManagerRegistryTests.swift`
- Create Test: `Tests/SwiftStateTreeTransportTests/LandManagerReevaluationModeTests.swift`

**Step 1: 先寫失敗測試（live/replay 模式選擇）**

**Step 2: 跑測試確認失敗**

Run: `swift test --filter LandManagerReevaluationModeTests`
Expected: FAIL。

**Step 3: 實作最小 resolver API（預設 live）**

**Step 4: 重跑聚焦測試**

Run: `swift test --filter LandManagerReevaluationModeTests`
Expected: PASS。

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeTransport/LandManager.swift Sources/SwiftStateTreeNIO/NIOLandServer.swift Sources/SwiftStateTreeNIO/NIOLandHost.swift Sources/SwiftStateTreeNIO/ReevaluationFeature.swift Tests/SwiftStateTreeTransportTests/LandManagerReevaluationModeTests.swift Tests/SwiftStateTreeTransportTests/LandManagerRegistryTests.swift
git commit -m "feat: add dynamic landkeeper mode resolver for replay sessions"
```

### Task 4: Replay 路徑改註冊同一份 live land definition

**Files:**
- Modify: `Sources/SwiftStateTreeNIO/ReevaluationFeature.swift`
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`
- Modify: `Examples/GameDemo/Sources/SchemaGen/main.swift`
- Test: `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift`

**Step 1: 先寫失敗測試（無 replay gameplay land 也可註冊）**

**Step 2: 跑測試確認失敗**

Run: `swift test --filter ReevaluationFeatureRegistrationTests`
Expected: FAIL。

**Step 3: 實作最小註冊切換（仍保留 replay suffix/path）**

**Step 4: 重跑聚焦測試**

Run: `swift test --filter ReevaluationFeatureRegistrationTests`
Expected: PASS。

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeNIO/ReevaluationFeature.swift Examples/GameDemo/Sources/GameServer/main.swift Examples/GameDemo/Sources/SchemaGen/main.swift Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift
git commit -m "refactor: register replay path using same live land definition"
```

### Task 5: 移除 active path 對 HeroDefense replay-only land 的依賴

**Files:**
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Modify: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift`
- Modify: `Tools/CLI/src/reevaluation-replay-e2e-game.ts`

**Step 1: 先寫失敗測試（同 land deterministic 事件）**

**Step 2: 跑測試確認失敗**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `cd Tools/CLI && npm run test:e2e:game:replay`
Expected: FAIL。

**Step 3: 實作最小路徑清理**

**Step 4: 重跑聚焦測試**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `cd Tools/CLI && npm run test:e2e:game:replay`
Expected: PASS。

**Step 5: Commit**

```bash
git add Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift Tools/CLI/src/reevaluation-replay-e2e-game.ts
git commit -m "refactor: switch hero replay to same-land reevaluation execution"
```

### Task 6: 全量驗證與效能證明

**Files:**
- Create: `docs/plans/2026-02-20-low-risk-same-land-reevaluation-verification.md`

**Step 1: 跑 deterministic correctness 測試**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `swift test --filter ReevaluationReplayCompatibilityTests`
- `swift test --filter ReevaluationFeatureRegistrationTests`
- `swift test --filter NIOAdminRoutesReplayStartTests`
Expected: PASS。

**Step 2: Replay E2E 穩定性回歸**

Run:
- `cd Tools/CLI && for i in 1 2 3 4 5; do LOG_LEVEL=error npm run -s test:e2e:game:replay || break; done`
Expected: 5/5 PASS。

**Step 3: 效能證據收集（baseline vs 新路徑）**

至少收集：
- completion time
- RSS peak
- replay tick coverage
- mismatch count

Expected:
- mismatch=0
- 10 次內無 timeout
- 達成目標改善或明確記錄差距。

**Step 4: 產出驗證報告**

**Step 5: Commit**

```bash
git add docs/plans/2026-02-20-low-risk-same-land-reevaluation-verification.md
git commit -m "docs: add same-land reevaluation verification report"
```

## 最終 gate

```bash
swift test
cd Tools/CLI && npm run test:e2e:game:replay
```

任一失敗不可合併。
