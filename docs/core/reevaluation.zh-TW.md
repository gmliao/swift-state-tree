[English](reevaluation.md) | [中文版](reevaluation.zh-TW.md)

# Deterministic Re-evaluation（決定性重評估）

> SwiftStateTree 的 Re-evaluation 能力讓你能夠錄製遊戲對局，並以決定性的方式重播，用於除錯、測試和分析。

## 概述

Re-evaluation（重評估）是**在固定的世界條件下重新執行狀態轉換邏輯**的能力。與傳統的 replay（只是重播錄製的資料）不同，Re-evaluation 會用相同的輸入重新執行 handlers。

### 核心概念

| 概念                     | 說明                                           |
| ------------------------ | ---------------------------------------------- |
| **Live Mode**            | 正常執行，記錄所有輸入和 resolver outputs      |
| **Reevaluation Mode**    | 重播錄製的輸入，跳過 resolver，驗證 state hash |
| **Deterministic Output** | 事件和同步請求會排入佇列，在 tick 結尾 flush   |

## 運作原理

### 錄製（Live Mode）

在 Live 模式下，`LandKeeper` 會自動記錄：

1. **Actions** - `sequence`、`payload`、`resolverOutputs`、`resolvedAtTick`
2. **Client Events** - `sequence`、`payload`、`resolvedAtTick`
3. **Lifecycle Events** - `OnJoin`、`OnLeave`、`OnInitialize` 及其 resolver outputs
4. **Server Events** - 透過 `ctx.emitEvent()` 發送的事件
5. **State Hash** - 可選的每 tick hash 用於驗證

```swift
// 在 Live 模式下會自動錄製
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .live,  // 啟用錄製
    enableLiveStateHashRecording: true  // 啟用每 tick hash
)
```

### 重播（Reevaluation Mode）

在 Reevaluation 模式下，`LandKeeper`：

1. 從 `ReevaluationSource` 載入錄製的輸入
2. 跳過 resolver 執行，使用錄製的 `resolverOutputs`
3. 用相同的輸入執行 handlers
4. 每個 tick 後比對 state hash

```swift
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .reevaluation,
    reevaluationSource: JSONReevaluationSource(filePath: "recording.jsonl")
)

// 手動逐 tick 執行
await keeper.stepTickOnce()
```

## 錄製格式

錄製以 JSONL（JSON Lines）格式儲存：

```jsonl
{"kind":"metadata","landID":"game:abc123","landType":"game","createdAt":"2024-01-01T00:00:00Z"}
{"kind":"frame","tickId":0,"actions":[],"clientEvents":[],"lifecycleEvents":[{"kind":"initialize",...}]}
{"kind":"frame","tickId":1,"actions":[{"sequence":1,"typeIdentifier":"MoveAction",...}],...}
```

### 資料結構

| 結構                     | 欄位                                                                                                              |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `RecordedAction`         | `sequence`、`typeIdentifier`、`payload`、`playerID`、`clientID`、`sessionID`、`resolverOutputs`、`resolvedAtTick` |
| `RecordedClientEvent`    | `sequence`、`typeIdentifier`、`payload`、`playerID`、`clientID`、`sessionID`、`resolvedAtTick`                    |
| `RecordedLifecycleEvent` | `kind`、`sequence`、`tickId`、`playerID`、`resolverOutputs`、`resolvedAtTick`                                     |
| `RecordedServerEvent`    | `sequence`、`tickId`、`typeIdentifier`、`payload`、`target`                                                       |

## 使用 ReevaluationMonitor

`SwiftStateTreeReevaluationMonitor` 模組提供 web-based UI 用於視覺化重播：

### Server 設定

```swift
import SwiftStateTreeReevaluationMonitor

// 為你的 Land 類型建立 factory
struct MyReevaluationFactory: ReevaluationTargetFactory {
    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        switch landType {
        case "game":
            return try await ReevaluationRunnerImpl(
                definition: GameLand.definition,
                recordFilePath: recordFilePath
            )
        default:
            throw ReevaluationError.unknownLandType(landType)
        }
    }
}

// 註冊 monitor land
let monitorService = ReevaluationRunnerService(factory: MyReevaluationFactory())
server.registerLand(ReevaluationMonitor.makeLand(), services: [monitorService])
```

### WebClient

連接到 monitor land 並發送 actions：

```typescript
// 開始驗證
await client.sendAction("startVerification", {
  landType: "game",
  recordFilePath: "/path/to/recording.jsonl",
});

// 暫停/繼續
await client.sendAction("pauseVerification", {});
await client.sendAction("resumeVerification", {});
```

## 驗證

### State Hash 證明 Reevaluation

每 tick 的 `stateHash` 是完整 state snapshot 的決定性 FNV-1a64 hash。當 live 與 replay 對每個 tick 產生相同 hash 時，表示狀態轉換邏輯具決定性。Server events 來自相同的 handlers 與輸入；錄製它們可進行額外的一致性檢查。

### Server Event 驗證

當 `enableLiveStateHashRecording: true` 時，伺服器也會記錄每 tick 的 server events（`ctx.emitEvent()`）。在帶 `--verify` 的 reevaluation 中，runner 會比對錄製與發送的 server events。若 mismatch 表示 event 發送有非決定性（例如順序或 payload 差異）。

### 欄位級 State Diff（Debug 用）

當 hash mismatch 需要深入除錯時，可錄製完整的逐 tick state snapshot，並在 reevaluation 時用 `--diff-with` 產生欄位級 diff。

**步驟 1 – 在伺服器端啟用 state snapshot 錄製：**

```bash
ENABLE_STATE_SNAPSHOT_RECORDING=true ./YourServer
```

設定此 env var 後，recorder 會在主 `.json` 錄製檔旁寫出 `*-state.jsonl`，每行格式為：

```json
{"tickId": 42, "stateSnapshot": { ... }}
```

**步驟 2 – 以 `--diff-with` 執行 reevaluation：**

```bash
swift run ReevaluationRunner \
  --input path/to/recording.json \
  --diff-with path/to/recording-state.jsonl
```

錄製與計算 state 的欄位差異會輸出至 stderr：

```
[tick 42] DIFF at players.p1.position.v.x: recorded=98100 computed=0
[tick 42] DIFF at players.p1.position.v.y: recorded=35689 computed=0
```

> **注意：** `ENABLE_STATE_SNAPSHOT_RECORDING` 僅供 debug 使用，會增加每 tick 的記憶體與 I/O 用量。

## 最佳實踐

1. **保持 handlers 決定性** - 避免在 handlers 中直接使用 `Date()`、`random()`、外部 API 呼叫
2. **用 Resolvers 處理非決定性資料** - 將 async/非決定性操作移到 Resolvers
3. **啟用 state hash 錄製** - 設定 `enableLiveStateHashRecording: true` 用於驗證
4. **使用 `emitEvent` 而非 `spawn + sendEvent`** - 確保決定性的事件順序

## 相關文件

- [Runtime 運作機制](runtime.zh-TW.md) - Event Queue 和 Tick 執行模型
- [Resolver 機制](resolver.zh-TW.md) - 如何處理非決定性操作
- [設計：Re-evaluation vs 傳統 Replay](../../Notes/design/DESIGN_REEVALUATION_REPLAY.md) - 概念深入探討
