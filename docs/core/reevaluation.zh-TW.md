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

Input 在其 handler 執行前就被錄製，因此 handler 拋出錯誤的 input 也會依序出現在錄製中；replay 會再執行它，並以相同方式失敗。

> **沒有 tick 的 land。** 沒有 tick handler 的 land 把所有 input 都錄在 tick 0，replay 會在該 tick 依序套用它們（#167、#268），因此會比對其 server event。它的 frame 沒有序號 watermark，replay 無法還原 event 的序號，所以該 tick 的結果是 `passedIgnoringSequence`：比對型別、payload、對象與順序，但不比對序號（#321）。沒有 tick 的 land 不錄製每個 tick 的 state hash，因此只驗證它的 event，而且只在 record 有 event 時才驗證：沒有 watermark 的 frame 只在錄到 event 時才比對，所以沒有任何 event 的 tickless record 什麼都驗證不到，replay 在 live 沒有 event 的地方送出 event 也照樣通過（#321）。

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
| `ReevaluationTickFrame`  | `tickId`、`stateHash`、`actions`、`clientEvents`、`lifecycleEvents`、`serverEvents`、選填的 `sequenceBeforeInputs` / `sequenceBeforeTickHandler` |

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

每 tick 的 `stateHash` 是完整 server state（`fullStateSnapshot()`，錄製格式 2.4 起）以 sorted-keys JSON 編碼後的決定性 FNV-1a64 hash：涵蓋每一層的每個 `@Sync` 欄位，不論其 policy。server-only、per-player 與 masked 欄位都以實際值納入 hash，巢狀 state node 也會納入其所有 `@Sync` 欄位，即使它位於 `@SnapshotConvertible` 值（透過其產生的 `toFullSnapshotValue()`）或 enum 的 payload 中亦同。只有手寫 `toSnapshotValue()` 的值（例如 DeterministicMath 型別）則依該轉換的結果納入 hash。`@Internal` property 不納入 hash：其文件中的用法是 wall-clock timestamp 之類的值，納入會讓每次 replay 都不符；而會影響 state 的 internal 值本來就會反映在 `@Sync` 欄位上。當 live 與 replay 在每個 tick 都產生相同 hash 時，即證明 state 轉換邏輯是決定性的。Server event 由相同的 handler 與輸入產生；記錄它們可提供額外的一致性檢查。

此 hash 永遠不會送給 client，也沒有任何 sync 路徑會計算它：client 輸出不受影響。map 的 key 與送給 client 時一樣轉成字串（同一個 map 中若有兩個 key 轉成同一字串，hash 即無法計算），set 的元素依其標準編碼排序，因此插入順序不會影響 hash。

### 可讀取的最舊錄製（2.5）

錄製格式 2.5（#154）將 `PlayerID`、`ClientID`、`SessionID` 與 `LandID` 寫成字串，並將以它們為 key 的 dictionary 寫成以該字串為 key 的 object，與所有 encoder 現在送出的形狀一致。因此含有 `ClientID`、`SessionID` 或 `LandID` 的 state，其 hash 與 2.4 不同（`PlayerID` 在 2.4 已是字串）。較舊的錄製把它們存成 object（`{"rawValue": ...}`），已無法 decode，也不會被轉換：讀取端在 replay 之前就把早於 2.5 的錄製視為不支援而拒絕（`ReevaluationRecordVersionError.unsupported`）。`ReevaluationRunner --verify` 會印出「unsupported record version ...; re-record with the current server」並以 exit code 10 結束（無法比對，絕不視為 replay 差異），admin 的 replay start route 則回應 409 `RECORD_VERSION_UNSUPPORTED`。請用目前版本的 server 重新錄製這類 session。下方關於較舊格式的段落說明的是這些錄製當時如何驗證。

### Broadcast 父欄位下的 masked 欄位（2.6）

錄製格式 2.6（#179）標記 client 收到內容的一項改變：位於 `.broadcast` 欄位之下的 `.masked` 欄位，現在會以 mask 後的值出現在 broadcast snapshot 與 diff 中；之前會被略去。State hash 不變，因此 2.5 錄製仍可讀取與驗證。具有此形狀的 state（任一層級中由 `.broadcast` 欄位持有、且帶有 `.masked` 欄位的 state node）的 2.5 錄製，replay 時會出現 sync-output 不符（exit 8），且不會被標為無法比對：請用目前版本的 server 重新錄製這類 session。範例 Land 都沒有此形狀。

### 錄製所含的 Hash

| 錄製格式 | State 與 initialize hash | 驗證方式 |
|---|---|---|
| 2.4 以後 | 完整 state（`ReevaluationHashDefinition.fullState`） | 以完整 state 精確比對 |
| 2.3 | broadcast view，`snapshot(for: nil)` | 以 broadcast view 精確比對 |
| 早於 2.3 | broadcast view，#175 之前 | 以 broadcast view 比對，並套用下方的 #175 規則 |

讀取端依錄製版本選擇定義（`ReevaluationRecordVersion.hashDefinition`），並由 `RunResult.hashDefinition` 回報，因此較舊的錄製照舊驗證，不會被整批豁免。Sync-output hash 是對 client 實際收到內容的 hash，2.4 不改變它。

### 無法計算的 State Hash

若 state 無法為 hash 轉換（map 的 key 轉成字串後衝突、值的型別不受支援、JSON 無法編碼的 NaN 或無限大浮點數），live tick 不會因此停止：該 tick 的 hash 會記錄為 `unavailable: <reason>`，keeper 會記錄 error log 並計數（`LandKeeper.stateHashUnavailableCount`）。Replay 會把這類 tick 回報為無法驗證，絕不視為相符（`RunResult.unverifiableStateHashes`；較舊版本記錄的 `"error"` 也同樣處理），initialize 檢查則回報 `unverifiable`。若錄製的 hash 有效、但 replay 時無法計算，則屬於分歧，會回報為不符。`ReevaluationRunner --verify` 只有在沒有任何確定失敗時，才會因無法驗證的 hash 以 exit code 11 結束：state hash 不符（5）、server event（6）、sync output（8）與 OnInitialize（9）優先。

大於 `Int.max` 的無號整數（`UInt`、`UInt64`）在所有路徑上都會轉成十進位數字字串：以前會 trap。可放入 `Int` 的值在傳輸上不變。

### 早於 2.3 的錄製（#175）

在錄製格式 2.3 之前，位於 `[String: X]` 或 `[PlayerID: X]` map 中的 `@SnapshotConvertible` state node 會連同所有欄位（包含 server-only 欄位，例如 Hero Defense 的 `players.*.lastFireTick`）一起轉換。它的 state hash、initialize hash 與 sync-output hash 都涵蓋了這些欄位。現在的版本會排除它們，因此這類錄製無法再重現原本的 hash。

所有錄製仍會比對 hash。Land 是否受影響由其 state 型別判定，而非由錄製內容判定（`ReevaluationRecordVersion.hashChangedByNestedNodePolicies`）：在任一層級中，`[String: X]` 或 `[PlayerID: X]` map 的值是 `@SnapshotConvertible` state node，且只沿 `.broadcast` 欄位追蹤，因為 hash 涵蓋的是 broadcast view。Hero Defense 受影響；visibility-test 不受影響（其 `entities` map 為 `.perPlayer`）。受影響 Land 早於 2.3 的錄製若 state hash 或 initialize hash 不符，讀取端會回報為無法比對（「recorded before #175, hash not comparable」），而不是 replay 差異：`RunResult.hashIncomparability` 帶有原因，initialize 檢查回報 `notComparable`，`ReevaluationRunner --verify` 以 exit code 10 結束。請用目前版本重新錄製這類 session。其他所有不符仍照舊視為失敗：未受影響 Land 的任何不符（不論錄製版本），以及所有 sync-output 失敗（exit 8）。有兩個偏向安全的後果：早於 2.3 的 visibility-test 錄製，其 state hash 會驗證通過，但 sync output 會失敗（exit 8），因為它的 per-player patch 已改變；而位於非 node 的 `@SnapshotConvertible` 值中的 map 不會被偵測到，因此這類 Land 的不符會視為失敗（exit 5）。任何 Land 的 2.3 錄製，以及所有 2.4 錄製，都會精確比對。

### Server Event 驗證

當 `enableLiveStateHashRecording: true` 時，伺服器也會記錄每 tick 的 server events（`ctx.emitEvent()`）。在帶 `--verify` 的 reevaluation 中，runner 會比對錄製與發送的 server events。若 mismatch 表示 event 發送有非決定性（例如順序或 payload 差異）。

Action、client event、lifecycle event 與 server event 共用同一個 `sequence` 計數器。有 tick 的 Land 在 live 模式下，每個 tick 會在 tick frame 記下該計數器的兩個 watermark（`sequenceBeforeInputs`、`sequenceBeforeTickHandler`）；reevaluation 時把計數器往前推到這兩個值，因此重播的 server event 會拿到與錄製相同的 `sequence`。比對以 tick 為單位判定：frame 帶有 watermark 的 tick 必須完全一致（包含 `sequence`），且即使錄製的事件清單為空也會比對，因此重播多出的 event 會被回報。沒有 watermark 的舊格式錄製維持原規則：只有錄到事件時才比對，僅 `sequence` 不同時回報為警告而非失敗（`ReevaluationEngine.RunResult.serverEventVerification`）。

### Sync Output 驗證

每個 commit 的 sync plan 會依 scope（broadcast scope 與每位玩家的 scope）錄製其 canonical patch list 的 hash，以及隨之送出的 event。不比對編碼後的位元組：dynamic-key slot、frame 順序與 wire encoding 都不是 canonical 的。Replay 以餵入 replay 狀態的 shadow sync engine 重新規劃每個錄製的 sync output，並比對 hash（不符時 `ReevaluationRunner --verify` 以 exit code 8 結束）。

它能抓到：

- dirty tracking 漏標：live plan 只擷取 dirty 欄位，shadow 擷取全部，因此 live 沒標記到的變更欄位會顯示為缺少的 patch；
- 進入 sync phase 的內容（狀態、成員、event 佇列）不具決定性；
- cache 管理：live 執行 stage、unstage 或重設 cache 的方式與其 plan commit 的內容不同（key-scope 重設、recovery plan）；
- event 消耗：event 被消耗兩次、略過或順序錯亂（opcode 107 模式）。

另有 patch-apply oracle：把每個 scope 的 patch 套用到參考 client view，與 replay 狀態中該 scope 的 view 比對，可抓到 diff 在 snapshot 正確時仍產生錯誤、缺少或多餘 patch 的情況。

它無法證明的：live 與 shadow 執行相同的 `SyncEngine` 擷取與相同的 policy filter，因此 filter 錯誤顯示或隱藏的欄位，兩邊與預期 view 都一樣是錯的。它驗證的是 sync phase 具決定性、且與自身的 projection 一致，而不是 projection 本身正確。

診斷用：`REEVALUATION_RECORD_SYNC_DETAILS=true` 會錄製每位 commit 玩家的 hash，讓 per-player 不符時能指出是哪位玩家；`REEVALUATION_RECORD_SYNC_PATCHES=true` 會錄製每個 scope 的 canonical patch list，讓不符時能指出第一個不同的 path。兩者預設關閉；patch list 與 state update 一樣大，只適合短時間執行。

### 欄位級 State Diff（Debug 用）

當 hash mismatch 需要深入除錯時，可錄製完整的逐 tick state snapshot，並在 reevaluation 時用 `--diff-with` 產生欄位級 diff。錄製的 snapshot 就是 hash 所涵蓋的內容（2.4 起為完整 state），因此 diff 指出的就是 hash 看到的欄位。

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
