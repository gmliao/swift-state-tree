# Deterministic Replay 規格

**Goal**: 建立可重播且可驗證的 Deterministic Replay 機制，確保 Action 與 ClientEvent 在 Tick-based 執行模型下能被完整記錄並重現。

## 範圍

- Action、ClientEvent 與 Lifecycle Event（OnJoin/OnLeave/OnInitialize）統一進 queue，於 Tick 中執行。
- 記錄 Action/ClientEvent/Lifecycle Event 的輸入與 resolver outputs，供 replay 使用。
- 記錄 ServerEvent（server -> client），供 client replay 使用。
- 記錄 RecordingMetadata（land 創建資訊、配置等），供 replay 初始化使用。
- 移除 `handleAction<A>`，以 `handleActionEnvelope` 作為唯一入口。
- 無 resolver 的 action 走快速路徑（不建立 resolver task group）。

## 非範圍

- 不新增 `LandContext` 欄位（僅注入 resolver outputs）。

## 功能需求

1. **Queue 機制**
   - Action + ClientEvent 皆進 `pending queue`。
   - 在 Tick 開始時處理 queue，執行 handler。
   - 排序規則：`resolvedAtTick` 為主，`sequence`（接收順序）為次。

2. **序號規則**
   - Action 與 ClientEvent 共用同一個全域遞增 `sequence`。
   - 需記錄在 replay 檔案中。

3. **API 行為**
   - `handleActionEnvelope`：在 `.live` 模式下加入 queue，立即回 ACK。
   - `handleClientEvent`：在 `.live` 模式下加入 queue，立即回 ACK。
   - `.replay` 模式下不執行上述入口，改由 `ActionSource` 提供資料。

4. **Resolver 行為**
   - 有 resolver：執行 resolver 並將 outputs 注入 context。
   - 無 resolver：直接建立 PendingItem（快速路徑）。

5. **Replay 資料**
   - 記錄 Action/ClientEvent/Lifecycle Event 的 payload、`sequence`、`resolvedAtTick`、`resolverOutputs`。
   - 記錄 ServerEvent 的 payload 與 target，保留 `sequence` 與 `tickId`。
   - 記錄 RecordingMetadata（land 創建資訊、配置等）。
   - Resolver outputs 保存類型資訊（`RecordedResolverOutput`）用於類型驗證。
   - Replay 時跳過 resolver，直接注入 recorded outputs。

## 資料模型

### PendingItem

- `kind`: `.action` / `.clientEvent` / `.lifecycle`
- `sequence: Int64`
- `payload: AnyCodable`（action/clientEvent）或 `LifecycleKind`（lifecycle）
- `payloadType`: `ActionPayload.Type` / ClientEvent descriptor / `LifecycleKind`
- `playerID`, `clientID`, `sessionID`（lifecycle event 可能為 nil）
- `resolverOutputs: [String: any ResolverOutput]`（client event 為空，lifecycle event 可能有）
- `resolvedAtTick: Int64`

### RecordingFile

- `metadata: RecordingMetadata`
- `frames: [RecordingFrame]`

### RecordingMetadata

- `landID: String`
- `landType: String`
- `createdAt: Date`
- `metadata: [String: String]`（land 創建參數）
- `landDefinitionID: String?`
- `initialStateHash: String?`
- `landConfig: [String: AnyCodable]?`
- `version: String?`
- `extensions: [String: AnyCodable]?`

### RecordingFrame

- `tickId: Int64`
- `actions: [RecordedAction]`
- `clientEvents: [RecordedClientEvent]`
- `serverEvents: [RecordedServerEvent]`
- `lifecycleEvents: [RecordedLifecycleEvent]`

### RecordedAction

- `kind: String` (`action`)
- `sequence: Int64`
- `typeIdentifier: String`
- `payload: AnyCodable`
- `playerID`, `clientID`, `sessionID`
- `resolverOutputs: [String: RecordedResolverOutput]`
- `resolvedAtTick: Int64`

### RecordedClientEvent

- `kind: String` (`clientEvent`)
- `sequence: Int64`
- `typeIdentifier: String`
- `payload: AnyCodable`
- `playerID`, `clientID`, `sessionID`
- `resolvedAtTick: Int64`

### RecordedLifecycleEvent

- `kind: String` (`initialize` / `join` / `leave`)
- `sequence: Int64`
- `tickId: Int64`
- `playerID`, `clientID`, `sessionID`（可能為 nil）
- `deviceID: String?`
- `isGuest: Bool?`
- `metadata: [String: String]`
- `resolverOutputs: [String: RecordedResolverOutput]`
- `resolvedAtTick: Int64`

### RecordedResolverOutput

- `typeIdentifier: String`（resolver output 類型名稱，用於類型驗證）
- `value: AnyCodable`（resolver output 的值）

### RecordedServerEvent

- `kind: String` (`serverEvent`)
- `sequence: Int64`
- `tickId: Int64`
- `typeIdentifier: String`
- `payload: AnyCodable`
- `target: EventTargetRecord`

### EventTargetRecord

- `case`: `all` / `player` / `client` / `session` / `players`
- `ids`: `[String]`（依 target 類型填入）

## 錯誤處理

- Resolver 執行失敗：維持目前錯誤傳遞策略。
- Replay JSON 解析失敗：回報錯誤並中止 replay。

## 效能考量

- 無 resolver 的 action 應避開 TaskGroup 建立成本。
- Pending queue 只處理 `resolvedAtTick < nextTickId` 的項目。

## 測試需求

- Action 被 queue，非立即執行。
- Action/ClientEvent 在 tick 中執行。
- `sequence` 排序可重現。
- Replay 與 Live 結果一致。

## Clarifications

### Replay 輸入來源

**Q:** Replay 輸入的錄製檔案來源要怎麼指定？  
**A:** 由各應用程式實作的 ReevaluationRunner CLI 參數指定輸入檔路徑。

### Replay 驗證層級

**Q:** Replay 驗證要做到哪個層級？  
**A:** 每個 tick 都驗證 state hash。

### 錄製檔案寫入時機

**Q:** 錄製檔案的寫入時機？  
**A:** 定期 flush（例如每 N tick）。

### Flush 間隔

**Q:** 定期 flush 的 tick 間隔要多少？  
**A:** 可配置（預設 60 tick）。

### State Hash 來源

**Q:** tick 驗證用的 state hash 要用哪個來源？  
**A:** 使用既有的 state hash/快照機制（若有）。
