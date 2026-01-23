# Deterministic Replay - Technical Plan

## Architecture Overview

- **核心思路**: 將 Action 與 ClientEvent 統一進入 queue，於 tick 內按 `resolvedAtTick + sequence` 執行；在 live 模式記錄所有輸入、resolver outputs 以及 ServerEvent；在 replay 模式重建相同序列並重播 ServerEvent。
- **資料流**:
  1. Live: `handleActionEnvelope` / `handleClientEvent` / `join()` / `leave()` → 產生 `PendingItem` → `processPendingActions` → handler 執行 → `ActionRecorder` 記錄
  2. Live: `LandContext.sendEvent` → 記錄 `RecordedServerEvent`（含 target）
  3. Live: `OnInitialize` / `OnJoin` / `OnLeave` → 記錄 `RecordedLifecycleEvent`（含 resolver outputs）
  4. Live: `LandManager.getOrCreateLand()` → 設置 `RecordingMetadata`
  5. Replay: `ActionSource.getMetadata()` → 讀取 `RecordingMetadata` 用於初始化
  6. Replay: `ActionSource` 讀取 `RecordedAction` / `RecordedClientEvent` / `RecordedLifecycleEvent` → 轉換 `PendingItem` → `processPendingActions` → handler 執行 → 每 tick 驗證 state hash
  7. Replay: `RecordedServerEvent` 依序重播給 client（或輸出到 replay sink）
- **技術選型**: Swift + Codable (JSON) + 既有 StateTree / Resolver 機制

## Data Model

- **PendingItem**: unified queue item for action/client event/lifecycle event
  - `kind` (`.action` / `.clientEvent` / `.lifecycle`), `sequence`, `payload`, `payloadType`, `playerID/clientID/sessionID`, `resolverOutputs`, `resolvedAtTick`
- **RecordingFile**: `{ metadata: RecordingMetadata, frames: [RecordingFrame] }`
- **RecordingMetadata**: `{ landID, landType, createdAt, metadata, landDefinitionID, initialStateHash, landConfig, version, extensions }`
- **RecordingFrame**: `{ tickId, actions, clientEvents, serverEvents, lifecycleEvents }`
- **RecordedAction**: `{ kind, sequence, typeIdentifier, payload, playerID, clientID, sessionID, resolverOutputs: [String: RecordedResolverOutput], resolvedAtTick }`
- **RecordedClientEvent**: `{ kind, sequence, typeIdentifier, payload, playerID, clientID, sessionID, resolvedAtTick }`
- **RecordedLifecycleEvent**: `{ kind, sequence, tickId, playerID, clientID, sessionID, deviceID, isGuest, metadata, resolverOutputs: [String: RecordedResolverOutput], resolvedAtTick }`
- **RecordedResolverOutput**: `{ typeIdentifier, value }`（保存類型資訊用於驗證）
- **RecordedServerEvent**: `{ kind, sequence, tickId, typeIdentifier, payload, target }`
- **EventTargetRecord**: `{ case, ids[] }`

## API Design

- **handleActionEnvelope**: live 模式入隊並立即 ACK；replay 模式不執行
- **handleClientEvent**: live 模式入隊並立即 ACK；replay 模式不執行
- **ActionSource**: `getMetadata()`, `getActions(for:)`, `getClientEvents(for:)`, `getLifecycleEvents(for:)`, `getServerEvents(for:)`, `getMaxTickId()` 提供 replay 來源
- **ActionRecorder**: `setMetadata()`, `record(tick:actions:clientEvents:lifecycleEvents:)`, `recordLifecycleEvent()`, `save(to:)`，支援定期 flush（可配置，預設 60 tick）

## Component Design

1. **LandKeeper (Runtime)**
   - Pending queue 改為 `PendingItem`
   - `sequence` 全域遞增
   - `processPendingActions` 以 `resolvedAtTick + sequence` 排序
   - `runTick` 呼叫 `processPendingActions` 再執行 tick handler
   - 移除 `handleAction<A>`，保留 `handleActionEnvelope` 作唯一入口
   - `sendEventHandler` 攔截 ServerEvent，記錄 `RecordedServerEvent`

2. **ActionRecorder**
   - 收集 `RecordingFrame`（包含 actions, clientEvents, serverEvents, lifecycleEvents）
   - 保存 `RecordingMetadata`（land 創建資訊、配置等）
   - 定期 flush 機制（配置化）
   - 存檔格式為 JSON（`RecordingFile` 包含 metadata + frames）

3. **ActionSource**
   - 讀取 JSON 錄製檔案（`RecordingFile` 格式）
   - 提供 `getMetadata()` 用於 replay 初始化
   - 依 tickId 返回對應的 actions, clientEvents, lifecycleEvents, serverEvents

4. **ReevaluationRunner (Application-Specific CLI)**
   - 位於各應用程式（如 `Examples/GameDemo` 或 `Examples/HummingbirdDemo`）中，作為獨立 target
   - 由 `--input` 指定錄製檔案
   - 每 tick 驗證 state hash（使用既有 hash/快照機制）
   - 可設定 replay sink（例如輸出 event log 或傳送到 client）
   - **注意**：`Tools/ReplayRunner` 中的通用 CLI 已移除，改由各應用程式自行實作 ReevaluationRunner 以支援特定 Land 類型載入。

5. **SwiftStateTreeReevaluationMonitor (新增模組)**
   - **ReevaluationMonitorLand**: 一個專用的 Land 定義，用於即時視覺化 Reevaluation 過程
     - 使用 `Tick(every: .milliseconds(100))` 定期輪詢 ReevaluationRunnerService 狀態
     - 支援 `StartVerificationAction`、`PauseVerificationAction`、`ResumeVerificationAction`
     - 發送 `TickSummaryEvent`、`VerificationProgressEvent`、`VerificationCompleteEvent` 等 ServerEvent 到 Client
   - **ReevaluationRunnerService**: 可注入的 Service，封裝 ReevaluationRunner 執行邏輯
     - `startVerification(landType:recordFilePath:)`: 啟動驗證任務
     - `pause()` / `resume()` / `stop()`: 控制執行流程
     - `getStatus()`: 取得當前驗證狀態（phase、currentTick、correctTicks、mismatchedTicks 等）
     - `consumeResults()`: 消費並返回累積的 tick 驗證結果（供 Land Tick handler 發送 event）
   - **ReevaluationRunnerImpl**: 實作 `ReevaluationRunnerProtocol`
     - 封裝 `LandKeeper` 在 `.reevaluation` 模式下的 step-by-step 執行
     - 提供 `step()` 方法，每次呼叫執行一個 tick 並返回驗證結果
     - 計算 state hash 並與錄製的 hash 比對
   - **ReevaluationTargetFactory Protocol**: 應用程式實作此 protocol 以建立特定 Land 類型的 Runner
   - **WebClient 整合**:
     - 新增 `ReevaluationMonitorView.vue`: 提供即時驗證進度視覺化 UI
     - 新增 `StateTreeDiffView.vue` / `StateNode.vue`: 狀態樹差異視覺化元件
     - 新增 `useReevaluationMonitor.ts`: Vue composable for Monitor Land 連線管理

## Implementation Details

- **排序規則**: `resolvedAtTick` 為主、`sequence` 為次
- **Resolver fast path**: 無 resolver 時不建立 task group
- **Lifecycle Events**: `OnInitialize`, `OnJoin`, `OnLeave` 統一進 queue，支援 resolver outputs
- **ClientEvent**: 無 resolverOutputs，context 注入空字典
- **ServerEvent**: 攔截 `sendEvent`，記錄 `target` 與 `sequence`
- **Resolver Outputs**: 保存類型資訊（`RecordedResolverOutput`）用於 replay 時的類型驗證
- **RecordingMetadata**: 在 `LandManager.getOrCreateLand()` 時設置，包含 land 創建資訊和配置
- **Flush**: interval 可配置，預設 60 tick

## Testing Strategy

- Unit tests: queue 行為、tick 執行順序、sequence 排序
- Unit tests: ServerEvent recording order 與 target 序列化
- Replay tests: Live vs Replay 同步一致性（每 tick hash 驗證）
- 既有測試修正：`LandKeeperActionQueueTests.swift`

## Deployment & Operations

- ReevaluationRunner 以 CLI 方式執行，不影響 runtime server
- 錄製檔案由 CLI 參數指定輸入路徑
- 定期 flush 可調整以平衡效能與資料安全

## Reference

- 規格文件：`Notes/plans/specs/001-deterministic-replay/spec.md`
- 實作已完成，詳細實作見程式碼：
  - `Sources/SwiftStateTree/Runtime/ActionRecorder.swift`
  - `Sources/SwiftStateTree/Runtime/ActionSource.swift`
  - `Examples/GameDemo/Sources/ReevaluationRunner/` (Application-specific runner)
  - **SwiftStateTreeReevaluationMonitor 模組**:
    - `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationMonitorLand.swift`
    - `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationMonitorState.swift`
    - `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationMonitorActions.swift`
    - `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationMonitorEvents.swift`
    - `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerService.swift`
    - `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationRunnerImpl.swift`
    - `Sources/SwiftStateTreeReevaluationMonitor/ReevaluationInterfaces.swift`
  - **WebClient 整合**:
    - `Examples/GameDemo/WebClient/src/views/ReevaluationMonitorView.vue`
    - `Examples/GameDemo/WebClient/src/components/StateTreeDiffView.vue`
    - `Examples/GameDemo/WebClient/src/components/StateNode.vue`
    - `Examples/GameDemo/WebClient/src/generated/reevaluation-monitor/`
