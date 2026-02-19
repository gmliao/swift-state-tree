[English](2026-02-19-replay-generic-session-mode-plan.md) | [中文版](2026-02-19-replay-generic-session-mode-plan.zh-TW.md)

# Replay Generic Session Mode 實作計畫

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 提供對使用者友善且可上線的 reevaluation replay 系統，讓伺服器啟用與客戶端 replay mode 切換都變成 SDK 層能力，而不是應用端自行拼裝流程，同時維持決定論與 baseline 可比性。

**Architecture:** 維持 architecture A 約束：不 fork `LandKeeper`，replay pipeline 仍為 `ReevaluationRunnerService + projector`，replay state 維持 live-compatible。新增擴充層：伺服器端的 reevaluation feature 註冊介面，以及 SDK 的 session mode API（`live`/`replay`，底層可重連）。Replay 事件優先使用 projected emitted events；fallback 合成僅作為可選相容模式，非預設。

**Tech Stack:** Swift 6、Swift Testing、SwiftStateTree + SwiftStateTreeNIO + SwiftStateTreeReevaluationMonitor、TypeScript SDK（`sdk/ts` + vitest）、GameDemo WebClient（Vue + generated bindings）、CLI E2E + Playwright 驗證。

**Required skills during implementation:** `@superpowers:test-driven-development`、`@superpowers:verification-before-completion`、`@superpowers:systematic-debugging`。

## Baseline 與防護線

- Baseline tag：`replay-baseline-v1`
- Baseline branch：`codex/replay-baseline-v1`
- Baseline checklist：`docs/plans/2026-02-19-replay-generic-baseline-checklist.md`
- Non-goal：不改變 deterministic tick semantics、不新增 replay 專用 `LandKeeper` runtime mode。

### Task 1: 伺服器端 Reevaluation Feature API（單一宣告啟用）

**Files:**
- Create: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift`
- Create: `Sources/SwiftStateTreeNIO/Integration/NIOReevaluationFeatureRegistration.swift`
- Modify: `Examples/GameDemo/Sources/GameServer/main.swift`
- Test: `Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift`
- Test: `Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift`

**Step 1: 先寫失敗測試（單一宣告註冊）**

新增測試驗證：
- 註冊 live land + reevaluation feature 後，會自動註冊 `<landType>-replay` 與 monitor land（enable 時）。
- `main.swift` 不手動 wiring replay land 也可通過 `/admin/reevaluation/replay/start`。

**Step 2: 跑測試確認失敗**

Run:
- `swift test --filter ReevaluationFeatureRegistrationTests`
- `swift test --filter NIOAdminRoutesReplayStartTests`

Expected：新測試失敗（feature API 尚不存在）。

**Step 3: 實作最小功能**

實作：
- `ReevaluationFeature` 型別（`enabled`、`requiredRecordVersion`、`projectorResolver`、`targetFactory`）。
- `NIOLandHost` extension：一次註冊所需 lands/services。

**Step 4: 重跑聚焦測試**

Run:
- `swift test --filter ReevaluationFeatureRegistrationTests`
- `swift test --filter NIOAdminRoutesReplayStartTests`

Expected：PASS。

**Step 5: Commit**

```bash
git add Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift Sources/SwiftStateTreeNIO/Integration/NIOReevaluationFeatureRegistration.swift Examples/GameDemo/Sources/GameServer/main.swift Tests/SwiftStateTreeNIOTests/ReevaluationFeatureRegistrationTests.swift Tests/SwiftStateTreeNIOTests/NIOAdminRoutesReplayStartTests.swift
git commit -m "feat: add one-declaration reevaluation feature registration"
```

### Task 2: Type-erased replay event forwarding（移除硬編碼事件解碼路徑）

**Files:**
- Modify: `Sources/SwiftStateTree/Land/LandContext.swift`
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Test: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift`
- Test: `Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift`

**Step 1: 先寫失敗測試（projected event 直通）**

新增測試驗證：
- replay land 可從 `typeIdentifier + payload` 泛型轉發 projected events，不必每種事件硬編碼分支解碼。
- 未知 projected event 安全忽略/記錄（不 crash），已知事件可決定論發送。

**Step 2: 跑測試確認失敗**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `swift test --filter ReevaluationReplayCompatibilityTests`

Expected：因仍仰賴硬編碼解碼而失敗。

**Step 3: 實作最小功能**

實作：
- `LandContext.emitAnyServerEvent(_ event: AnyServerEvent, to: EventTarget)`
- replay land 改用 generic projector-event forwarder。

**Step 4: 重跑聚焦測試**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`
- `swift test --filter ReevaluationReplayCompatibilityTests`

Expected：PASS。

**Step 5: Commit**

```bash
git add Sources/SwiftStateTree/Land/LandContext.swift Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift Tests/SwiftStateTreeTests/ReevaluationReplayCompatibilityTests.swift
git commit -m "feat: support type-erased replay event forwarding"
```

### Task 3: Replay event policy（預設 strict，fallback 可選）

**Files:**
- Modify: `Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift`
- Modify: `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift`
- Test: `Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift`
- Docs: `docs/plans/2026-02-15-server-replay-compatible-mode-plan.md`
- Docs: `docs/plans/2026-02-15-server-replay-compatible-mode-plan.zh-TW.md`（若不存在則建立）

**Step 1: 先寫失敗測試（policy 行為）**

新增測試驗證：
- 預設為 `.projectedOnly`（不做 fallback 合成）。
- 可顯式啟用 `.projectedWithFallback` 以相容舊紀錄（projected events 為空）。

**Step 2: 跑測試確認失敗**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`

Expected：policy 切換尚未存在而失敗。

**Step 3: 實作 policy 切換**

實作：
- reevaluation feature options 加入 replay event policy enum。
- hero-defense replay land 依 policy 選擇 strict 或 compatibility fallback。

**Step 4: 重跑聚焦測試**

Run:
- `swift test --filter HeroDefenseReplayStateParityTests`

Expected：PASS。

**Step 5: Commit**

```bash
git add Examples/GameDemo/Sources/GameContent/HeroDefenseReplayLand.swift Sources/SwiftStateTreeReevaluationMonitor/ReevaluationFeature.swift Examples/GameDemo/Tests/HeroDefenseReplayStateParityTests.swift docs/plans/2026-02-15-server-replay-compatible-mode-plan.md docs/plans/2026-02-15-server-replay-compatible-mode-plan.zh-TW.md
git commit -m "feat: add replay event policy with strict default"
```

### Task 4: SDK 核心 session mode API（`live` <-> `replay`）

**Files:**
- Create: `sdk/ts/src/core/session.ts`
- Modify: `sdk/ts/src/core/index.ts`
- Modify: `sdk/ts/src/core/runtime.ts`
- Test: `sdk/ts/src/core/session.test.ts`
- Test: `sdk/ts/src/core/runtime.test.ts`（若不存在則建立）

**Step 1: 先寫失敗測試（mode 切換）**

新增測試驗證：
- `switchToReplay()` 會使用 replay `connectSpec` 斷線重連並更新 `mode`。
- `switchToLive()` 可恢復 live 連線設定。
- mode 切換錯誤統一走同一個 error channel。

**Step 2: 跑測試確認失敗**

Run:
- `cd sdk/ts && npm test -- session`

Expected：`session` 模組不存在而 FAIL。

**Step 3: 實作最小 API**

實作：
- `StateTreeSession` 抽象，提供 `mode`、`connectLive`、`switchToReplay`、`switchToLive`。
- 重連細節封裝在 SDK 內，app 僅用 mode switch API。

**Step 4: 重跑 SDK 聚焦測試**

Run:
- `cd sdk/ts && npm test -- session`

Expected：PASS。

**Step 5: Commit**

```bash
git add sdk/ts/src/core/session.ts sdk/ts/src/core/index.ts sdk/ts/src/core/runtime.ts sdk/ts/src/core/session.test.ts sdk/ts/src/core/runtime.test.ts
git commit -m "feat(ts): add sdk-level live replay session switching"
```

### Task 5: Codegen 產生 session composable

**Files:**
- Modify: `sdk/ts/src/codegen/generateStateTreeFiles.ts`
- Modify: `sdk/ts/src/codegen/index.ts`
- Test: `sdk/ts/src/codegen/generateStateTreeFiles.replay-session.test.ts`
- Regenerate: `Examples/GameDemo/WebClient/src/generated/**`

**Step 1: 先寫失敗測試（codegen 輸出）**

新增測試驗證 generated composable 包含：
- `use<Land>Session()`，含 `mode`、`switchToReplay`、`switchToLive`。
- generated API 不需要 app 端手動 replay bootstrapping。

**Step 2: 跑測試確認失敗**

Run:
- `cd sdk/ts && npm test -- replay-session`

Expected：目前輸出缺少 session-mode API，FAIL。

**Step 3: 實作最小 codegen 擴充**

實作：
- 若 schema 有 replay counterpart，生成 session composable。
- 保留既有 `use<Land>()` 以維持相容。

**Step 4: 重新產生並驗證**

Run:
- `cd Examples/GameDemo/WebClient && npm run codegen`
- `cd sdk/ts && npm test -- replay-session`

Expected：PASS，generated 檔案更新。

**Step 5: Commit**

```bash
git add sdk/ts/src/codegen/generateStateTreeFiles.ts sdk/ts/src/codegen/index.ts sdk/ts/src/codegen/generateStateTreeFiles.replay-session.test.ts Examples/GameDemo/WebClient/src/generated
git commit -m "feat(ts): generate session-mode composables for replay switching"
```

### Task 6: GameDemo 客戶端遷移到 SDK session API

**Files:**
- Modify: `Examples/GameDemo/WebClient/src/utils/gameClient.ts`
- Modify: `Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue`
- Modify: `Examples/GameDemo/WebClient/src/views/GameView.vue`
- Delete: `Examples/GameDemo/WebClient/src/utils/LandClient.ts`（若已無使用）
- Test: `Examples/GameDemo/WebClient` vitest
- Test: Playwright scripts/config in `Examples/GameDemo/WebClient`

**Step 1: 先寫失敗整合測試（或 Playwright 斷言）**

新增驗證：
- monitor view 的 replay start 改為 session API 單一路徑。
- 不再依賴 route/sessionStorage hack 來持有 replay mode。

**Step 2: 跑測試確認失敗**

Run:
- `cd Examples/GameDemo/WebClient && npm test`

Expected：舊流程假設仍存在導致 FAIL。

**Step 3: 實作遷移**

實作：
- game client 使用 generated SDK session composable。
- monitor view 將手工 replay boot 改為 `switchToReplay({ recordFilePath })`。
- game view 以 `session.mode` 作為唯一模式來源。

**Step 4: 重跑 Web 測試**

Run:
- `cd Examples/GameDemo/WebClient && npm test`

Expected：PASS。

**Step 5: Commit**

```bash
git add Examples/GameDemo/WebClient/src/utils/gameClient.ts Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue Examples/GameDemo/WebClient/src/views/GameView.vue Examples/GameDemo/WebClient/src/utils/LandClient.ts
git commit -m "refactor(web): migrate replay flow to sdk session mode api"
```

### Task 7: E2E 驗證與 baseline 對比報告

**Files:**
- Modify: `Tools/CLI/src/reevaluation-replay-e2e-game.ts`（必要時）
- Modify: `docs/plans/2026-02-19-replay-generic-baseline-checklist.md`
- Modify: `docs/plans/2026-02-19-replay-generic-baseline-checklist.zh-TW.md`
- Create: `docs/plans/2026-02-19-replay-generic-session-mode-verification.md`
- Create: `docs/plans/2026-02-19-replay-generic-session-mode-verification.zh-TW.md`

**Step 1: 跑完整驗證矩陣**

Run:
- `swift test`
- `cd sdk/ts && npm test`
- `cd Examples/GameDemo/WebClient && npm test`
- `cd Tools/CLI && npm run test:e2e:game:replay`
- `cd Examples/GameDemo/WebClient && npx playwright test`

Expected：全部 PASS。

**Step 2: 與 baseline 對比**

記錄：
- mismatch count parity（目標：與 baseline 相同或更好）。
- replay 事件完整度（`PlayerShoot`、`TurretFire`、monster removals）。
- 使用者接入步驟簡化（before/after）。

**Step 3: 發佈驗證筆記**

報告需包含：
- 指令結果摘要
- 已知差異
- 回退到 baseline tag 的操作說明

**Step 4: Commit**

```bash
git add Tools/CLI/src/reevaluation-replay-e2e-game.ts docs/plans/2026-02-19-replay-generic-baseline-checklist.md docs/plans/2026-02-19-replay-generic-baseline-checklist.zh-TW.md docs/plans/2026-02-19-replay-generic-session-mode-verification.md docs/plans/2026-02-19-replay-generic-session-mode-verification.zh-TW.md
git commit -m "docs: publish generic replay session mode verification report"
```

## 預期使用者 API 成果

### Server（before）

- 手動註冊 live land
- 手動註冊 replay land
- 手動注入 reevaluation service
- 手動 wiring monitor/replay

### Server（after）

- 單一宣告啟用某 land 的 reevaluation + replay 能力。

### Client（before）

- monitor 頁面手工呼叫 `/admin/reevaluation/replay/start`
- 手工組 replay ws URL + replay landID
- route/sessionStorage glue 維護 replay mode

### Client（after）

- SDK session-level API：
  - `connectLive(...)`
  - `switchToReplay({ recordFilePath })`
  - `switchToLive()`
- UI 只看單一 `mode` 真實來源（相機/輸入切換皆同）。

