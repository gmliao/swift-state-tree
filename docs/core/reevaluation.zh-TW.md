[English](reevaluation.md) | [中文版](reevaluation.zh-TW.md)

# Deterministic Re-evaluation（決定性重評估）

> SwiftStateTree 的 Re-evaluation 能力讓你能夠錄製遊戲對局，並以決定性的方式重播，用於除錯、測試和分析。

## 概述

Re-evaluation（重評估）是**在固定的世界條件下重新執行狀態轉換邏輯**的能力。與傳統的 replay（只是重播錄製的資料）不同，Re-evaluation 會用相同的輸入重新執行 handlers。

### 核心概念

| 概念                     | 說明                                           |
| ------------------------ | ---------------------------------------------- |
| **Live Mode**            | 正常執行；`enableLiveStateHashRecording` 開啟時記錄輸入和 resolver outputs（預設關閉） |
| **Reevaluation Mode**    | 重播錄製的輸入，跳過 resolver，驗證 state hash |
| **Deterministic Output** | 事件和同步請求會排入佇列，在 tick 結尾 flush   |

## 運作原理

### 錄製（Live Mode）

在 Live 模式下，`LandKeeper` 只有在 `enableLiveStateHashRecording` 為 `true` 時才會錄製；它預設為 `false`，此時什麼都不錄。開啟後，keeper 會一起記錄：

1. **Actions** - `sequence`、`payload`、`resolverOutputs`、`resolvedAtTick`
2. **Client Events** - `sequence`、`payload`、`resolvedAtTick`
3. **Lifecycle Events** - `OnJoin`、`OnLeave`、`OnInitialize` 及其 resolver outputs，以及強制關閉（`"shutdown"`）
4. **Server Events** - 透過 `ctx.emitEvent()` 發送的事件
5. **State Hash** - 每 tick 的 hash，用於驗證

```swift
// 只有開啟 enableLiveStateHashRecording 才會錄製
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .live,
    enableLiveStateHashRecording: true  // 錄製 input、server event 與每 tick hash
)
```

### 重播（Reevaluation Mode）

在 Reevaluation 模式下，`LandKeeper`：

1. 從 `ReevaluationSource` 載入錄製的輸入
2. 跳過 resolver 執行，使用錄製的 `resolverOutputs`
3. 用相同的輸入執行 handlers
4. 每個 tick 後比對 state hash

手動建立的 replay keeper 要帶入錄製的 land ID 與 RNG seed，如下例；沒有帶的話，兩者都會使用 land type。`ReevaluationEngine.run` 與 `ConcreteReevaluationRunner` 會自動處理。keeper 只讀取所註冊 service 的 seed：用它啟動 land 的產生器，並從它建立的 context 中移除這個 service，因此 handler 透過 `ctx.random` 抽取，resolver 則碰不到它。

Input 在其 handler 執行前就被錄製，因此 `validate` 拋出錯誤的 input 也會依序出現在錄製中，並列為 rejected（[被拒絕的 input](#被拒絕的-input35)）。Replay 會再執行它的 `validate`，因此 `validate` 必須具決定性，並檢查拒絕的是相同的 input。

> **沒有 tick 的 land。** 沒有 tick handler 的 land 把所有 input 都錄在 tick 0，replay 會在該 tick 依序套用它們（#167、#268），因此會比對其 server event。從錄製格式 3.1 起，它的 frame 也記錄 live 的每一次處理：處理前的序號計數器，以及依序套用的 input（`passes`）。Replay 把每一次處理當成一個 input turn 執行，執行前先還原它的計數器，因此即使某個 input 超前另一個（等待 resolver 的 action，#325），input 仍依 live 的順序套用，event 序號也與 live 相同（#321）；結果是 `passed` 或 `failed`。若 passes 沒有恰好一次列出 frame 的每個 input、列出不是該 frame input 的序號，或計數器遞減，該 tick 失敗：發現不相符之後，該 tick 不再套用任何 input（檢查在任何一次處理之前執行，因此未通過檢查的錄製一個 input 都不套用）。Hosted replay（`ReevaluationStepResult.recordedPassMismatch`）會把這樣的 tick 回報為不相符，replay land 也不會改送錄到的 event。3.0 或 2.x 的 tickless record 沒有 passes：replay 依序號套用 input，該 tick 的結果是 `passedIgnoringSequence`：比對型別、payload、對象與順序，但不比對序號。沒有 tick 的 land 不錄製每個 tick 的 state hash，因此只驗證它的 event。錄到的空清單也會比對：replay 在 live 沒有送出 event 的地方送出 event，就會失敗。2.5 或 2.6 的 record 每個 tick 只保留最後錄到的那份 server event 清單，所以舊的 tickless record 若有多次處理都送出 event，replay 會失敗；請用目前的 server 重新錄製。

```swift
let source = try JSONReevaluationSource(filePath: "recording.jsonl")
let metadata = try await source.getMetadata()
var services = LandServices()
services.register(DeterministicRngService(seed: metadata.replayRngSeed), as: DeterministicRngService.self)
let keeper = LandKeeper(
    definition: myLand,
    initialState: MyState(),
    mode: .reevaluation,
    reevaluationSource: source,
    services: services,
    landID: metadata.landID
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
| `ReevaluationTickFrame`  | `tickId`、`stateHash`、`actions`、`clientEvents`、`lifecycleEvents`、`serverEvents`、選填的 `sequenceBeforeInputs` / `sequenceBeforeTickHandler`、選填的 `landFailure`（3.4）、選填的 `rejected`（3.5） |
| `ReevaluationRecordedPass` | `sequenceBefore`、`inputs`（依套用順序的序號）、選填的 `ordinal`（3.4）、選填的 `rejected`（3.5）；位於沒有 tick 的 frame 的選填 `passes`（3.1） |
| `ReevaluationRecordedServerInput` | `sequence`、`typeIdentifier`、`payload`、`resolvedAtTick`；位於 frame 的選填 `serverInputs`（3.2） |

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

每 tick 的 `stateHash` 是完整 server state（`fullStateSnapshot()`，錄製格式 2.4 起）以 sorted-keys JSON 編碼後的決定性 FNV-1a64 hash：涵蓋每一層的每個 `@Sync` 欄位，不論其 policy。server-only、per-player 與 masked 欄位都以實際值納入 hash，巢狀 state node 也會納入其所有 `@Sync` 欄位，即使它位於 `@SnapshotConvertible` 值（透過其產生的 `toFullSnapshotValue()`）或 enum 的 payload 中亦同。只有手寫 `toSnapshotValue()` 的值（例如 DeterministicMath 型別）則依該轉換的結果納入 hash。`@Internal` property 不納入 hash：其文件中的用法是 wall-clock timestamp 之類的值，納入會讓每次 replay 都不符；而會影響 state 的 internal 值本來就會反映在 `@Sync` 欄位上。當 live 與 replay 在每個 tick 都產生相同 hash 時，即證明 state 轉換邏輯是決定性的。Server event 由相同的 handler 與輸入產生；記錄它們可提供額外的一致性檢查。此保證只對同一個程式 build 成立：只有錄製它的那個 build 重播時，才保證得到相同的 hash；handler 或其相依不同的 build，可能由相同輸入算出不同的 state。

此 hash 永遠不會送給 client，也沒有任何 sync 路徑會計算它：client 輸出不受影響。map 的 key 與送給 client 時一樣轉成字串（同一個 map 中若有兩個 key 轉成同一字串，hash 即無法計算），set 的元素依其標準編碼排序，因此插入順序不會影響 hash。

### 可讀取的最舊錄製（2.5）

錄製格式 2.5（#154）將 `PlayerID`、`ClientID`、`SessionID` 與 `LandID` 寫成字串，並將以它們為 key 的 dictionary 寫成以該字串為 key 的 object，與所有 encoder 現在送出的形狀一致。因此含有 `ClientID`、`SessionID` 或 `LandID` 的 state，其 hash 與 2.4 不同（`PlayerID` 在 2.4 已是字串）。較舊的錄製把它們存成 object（`{"rawValue": ...}`），已無法 decode，也不會被轉換：讀取端在 replay 之前就把早於 2.5 的錄製視為不支援而拒絕（`ReevaluationRecordVersionError.unsupported`）。`ReevaluationRunner --verify` 會印出「unsupported record version ...; re-record with the current server」並以 exit code 10 結束（無法比對，絕不視為 replay 差異），admin 的 replay start route 則回應 409 `RECORD_VERSION_UNSUPPORTED`。請用目前版本的 server 重新錄製這類 session。下方關於較舊格式的段落說明的是這些錄製當時如何驗證。

### Broadcast 父欄位下的 masked 欄位（2.6）

錄製格式 2.6（#179）標記 client 收到內容的一項改變：位於 `.broadcast` 欄位之下的 `.masked` 欄位，現在會以 mask 後的值出現在 broadcast snapshot 與 diff 中；之前會被略去。State hash 不變，因此 2.5 錄製仍可讀取與驗證。具有此形狀的 state（任一層級中由 `.broadcast` 欄位持有、且帶有 `.masked` 欄位的 state node）的 2.5 錄製，replay 時會出現 sync-output 不符（exit 8），且不會被標為無法比對：請用目前版本的 server 重新錄製這類 session。範例 Land 都沒有此形狀。

### 沒有 tick 的 land 的 passes（3.1）

錄製格式 3.1（#325、#321）為沒有 tick 的 land 的 frame 加上選填的 `passes`，說明見〈運作原理〉。這個欄位是附加的：3.1 讀取端可讀 3.0 錄製，replay 照舊。3.0 版本讀取 3.1 錄製時會忽略此欄位，照以往依序號 replay 沒有 tick 的 land。有 tick 的 land 不錄 passes，因此其 frame 不變。

### Server input（3.2）

錄製格式 3.2（#387）為 frame 加上選填的 `serverInputs`：land 的 server 端程式送出的 input（`submitServerInput`，由 `HandleServerInput` 套用），以 handler 收到的錄製形式保存。它們與其他 input 共用 `sequence` 計數器，沒有 tick 的 land 的 passes 也像其他 input 一樣列出它們。Replay 從錄製套用它們，因此 replay 中的 land 不接受自己送出的 server input。3.1 錄製沒有 server input，replay 照舊。

強制關閉（`LandKeeper.forceShutdown()`，#382）同樣錄在 3.2 中，是一筆 kind 為 `"shutdown"`、不帶玩家的 lifecycle event。它是一個 keeper turn：清除仍在 land 中的玩家（不執行 OnLeave）、丟棄尚未套用的 input，並關閉 intake。在沒有 tick 的 land 上，它是所屬 pass 的一筆 input，排在比它先進佇列的 input 之後。在有 tick 的 land 上，它是最後一個 tick 之後自成一格的 frame，state hash 與該 tick 相同：這個 turn 不執行 tick handler，也不改變狀態。Replay 把它當成 replay 的結束：之後的 input 不再套用，之後的 tick 也不再執行；但 replay land 的觀看者會留著，land 也保持開啟，直到它自己的空房 destroy。Replay 端的 build 不認得的 lifecycle event kind 會讓該 tick 失敗（`recordedPassMismatches`），而不是被當成別的事件 replay。

從 3.2 起，讀取端遇到 minor 比自己新的 3.x 錄製會拒絕，並列出兩個版本（`ReevaluationRecordLogError.newerMinor`、`ReevaluationRecordVersion.isReadable`）：請用不早於錄製版本的 build 來 replay。3.1 版本早於這項檢查：它會讀取 3.2 錄製並在沒有 server input 的情況下 replay，因此在套用過 server input 之處無法與 live 一致。請用 3.2 或更新的版本 replay 3.2 錄製。

### NFC 的 key 與 player ID（3.3）

從錄製格式 3.3（#446）起，凡是轉換 state 的地方，map 的 key 與 `PlayerID` 都是 Unicode 正規化形式 C：wire 上、state hash 與 sync-output hash 皆然。檔案的結構不變。本來就是 NFC 的文字（包含所有 ASCII）轉換結果與先前相同，因此這類執行的 3.2 錄製 replay 時 hash 不變。

早於 3.3 的錄製若含有其他形式（例如 NFD）的字串或 key，replay 時 hash 可能不同，因為這個版本讀入 ID、寫出 key 時都用 NFC。讀取端在載入錄製時檢查其中的文字（`ReevaluationSource.getHoldsNonNFCText()`）；這類錄製的 state hash 不一致會回報為無法比較（`RunResult.hashIncomparability`），而不是失敗。Sync-output 的 digest 對 path 字串與值做 hash，其中含有同樣的 key，因此這類錄製的 sync-output 不一致會以該原因回報為 skipped。相符的錄製照常驗證。若要驗證，請用目前的 server 重新錄製。3.2 版本會拒絕 3.3 錄製（minor 較新）。

### Pass 序號與 land 失敗（3.4）

錄製格式 3.4（#563、#535）新增三個選填 key。沒有 tick 的 land 從 1 開始為 pass 編號（`ReevaluationRecordedPass.ordinal`），每個 sync output 與 sync marker 錄製它是在哪個 pass 之後讀取的（`afterPass`；0 表示在任何 pass 之前）。序號在套用該 pass 的 turn 片段中取得，早於 sync phase 讀取，因此在 turn 外 commit 的 seed（加入者獨立的 firstSync）也會標出它讀到的是哪個 pass 的 state。讀取時的 sequence 無法定位 output：一個沒有送出 event 的 pass，其 output 讀到的 sequence 就是該 pass 開始時的值，同一個值同時代表該 pass 之前與之後。Replay 檢查序號是否無缺口地接續它自己的計數（不符時該 tick 失敗，與其他 pass 不符相同），並依 `afterPass` 定位每個沒有 tick 的 output 與 seed，因此沒有 tick 的 land 的 sync output 也會被驗證。早於 3.4 的沒有 tick 的錄製沒有序號：其 sync-output 判定為 `skipped`，並附上原因。有 tick 的 land 一如既往依 tick 定位 output。

因失敗而結束的 land（#535）會把失敗錄在其 tick 的 frame 中（`ReevaluationTickFrame.landFailure`，型別為 `LandFailure`：kind、field、detail，以及位置：tick、pass、sequence 與 stage）。它只錄一次，就在結束 land 的同一個 turn 片段中。Sync stream 也在此結束：失敗之後不再錄製任何 sync output、seed 或 clear，包括失敗的拆除所關閉的 session 的 clear，以及讀取 state 期間 land 已失敗的 firstSync。失敗的 turn 在失敗之前的條目照常保留。transport 回報的失敗會當作輸入套用，並在該處結束其 turn 的批次；它的位置會標明這點（`LandFailurePosition.endsInputs`），replay 也以同樣方式結束該 tick：不執行 tick handler，也不送出該 turn 的任何 event（沒有 tick 的 land 則是該 pass 的 event）。有 tick 的 land 若在第一個 tick 之前失敗，不論失敗在哪裡發生，都會以同樣方式把失敗錄在 frame 0：live 沒有跑過任何 tick，所以 replay 也不執行 tick handler（#901）。Replay 與 live 執行一樣停在該 tick，並回報該失敗（`RunResult.liveFailure`、`ReevaluationSource.getLandFailure()`）；在它之前的部分照常驗證。3.3 版本會拒絕 3.4 錄製（minor 較新）。

### 被拒絕的 input（3.5）

錄製格式 3.5（#586）把 `validate` 拋出錯誤的 input 列為 `rejected`：沒有 tick 的 land 記在 `ReevaluationRecordedPass.rejected`，有 tick 的 land 記在 `ReevaluationTickFrame.rejected`，為空時省略。從 3.5 起，沒有這份清單表示沒有 input 被拒絕。Replay 會再執行 `validate`，因此它必須具決定性（[Land DSL：編譯器擋不住的事](land-dsl.zh-TW.md#編譯器擋不住的事)）。Replay 比對它拒絕的序號與錄製的序號，不同時回報為該 tick 的 pass mismatch：「input <seq> was rejected live and applied in replay」或「applied live and rejected in replay」。格式錯誤的清單（列出不是其 pass 或 tick 之 input 的序號，或重複列出同一個序號）也是 mismatch。3.4 錄製沒有這份清單；3.5 版本 replay 它時不做此比對，從 3.6 起 replay 會拒絕它（見下方）。3.4 版本會拒絕 3.5 錄製（minor 較新）。

### Schema fingerprint（3.6）

錄製格式 3.6（#521）記錄 land 的 schema fingerprint（`ReevaluationRecordMetadata.schemaFingerprint`）：16 位 hex，雜湊錄製中 payload 與 snapshot 解碼時所依據的形狀。它涵蓋 state tree（欄位、型別、同步 policy，以及欄位是否有預設值）、action 與各自回傳的 response、client 與 server event、server input、`Set` 的元素型別，以及 `CaseIterable` raw-value enum 的 raw value。它不涵蓋行為（handler、tick 邏輯、tick 間隔、service、設定），也不涵蓋預設值本身的值：macro 在 process 執行時才計算它（`UUID()`、`Date()`）。`ReevaluationEngine.run` 與 monitor 的 runner 以每個 tick 的 state hash 比對檢查這些。payload 欄位的預設值不屬於形狀：synthesized `Decodable` 不論有無預設值都會讀取 `var` 的 key。它是嚴格的：新增 action、event 或欄位也會改變它；文件說明、欄位順序，以及在同一個 wire key 下改名的 property 則不會（`ReevaluationSchemaFingerprint.compute(for:)`）。

它看不到的：經 `Codable` sample fallback 讀取的型別，或 `CodingKeys` 宣告在 extension 中、或自訂 `encode(to:)` 的 `@Payload` 型別，其欄位以 Swift property 名稱命名。這時 property 改名會改變 fingerprint，只改 wire key 則看不出來。非 `CaseIterable` 的 raw-value enum 的 case 也看不到。`@Payload` 型別中有初始值的 `let` 也一樣：synthesized `Decodable` 不解碼它，所以 action replay 時用的是初始值而不是錄製的值，改變初始值就會改變錄製 replay 出來的結果（#611）。

fingerprint 缺少或與目前定義的不同時，replay 在第一步之前就拒絕該錄製（`ReevaluationSchemaFingerprint.checkRecord`）。除了直接建構的 `LandKeeper(mode: .reevaluation, reevaluationSource:)`，每個進入點皆然：

- `ReevaluationEngine.run` 拋出 `ReevaluationRecordFingerprintError`。
- monitor 的 runner 回報 `ReevaluationReplayCompatibilityError` 代碼 2004（`RECORD_SCHEMA_FINGERPRINT_MISMATCH`）或 2005（`RECORD_SCHEMA_FINGERPRINT_MISSING`）。
- admin replay start 以 409 回傳相同的代碼字串並附上相關值（錄製與目前的 fingerprint，或錄製版本與最低版本）。land type 沒有可比對的 fingerprint 時，它也一律拒絕，回 409 `RECORD_SCHEMA_FINGERPRINT_UNAVAILABLE`（details 為 `landType` 與 `reason`）：其 land server 不回報（protocol 的預設）或未註冊，或其定義含 fingerprint 無法列出的型別。
- `ReevaluationRunner --verify` 對沒有 fingerprint 的錄製以 10 結束，對不同 schema 的錄製以 13 結束。

3.6 之前的錄製都沒有 fingerprint，因此 replay 會拒絕（`ReevaluationRecordVersion.minimumReplayable`）；不做 replay 的讀取端仍讀取 2.5 起的錄製（`minimumSupported`）。請用目前版本的 server 重新錄製這類 run。

fingerprint 必須能列出每個欄位。會錄製（`enableLiveStateHashRecording`）或為 reevaluation 註冊的 land，若做不到就在註冊時被拒絕：有欄位但沒有 `@Payload` 的 payload 或 server input，或無法建出 sample 的巢狀值（有必填欄位且沒有 `@SnapshotConvertible`），名稱列在 `LandRegistrationError.schemaFingerprint`（`SchemaFingerprintError.unbuildableType`）。兩個欄位共用一個 wire key 的 `@Payload` 型別（`.wireKeyCollision`），以及元素無法列出的 `Set`，也同樣被拒絕。沒有欄位的型別、集合、raw-value 型別、Foundation 純量、有自己 snapshot 轉換的值與 `AnyCodable` 照原樣雜湊。fingerprint 對每個定義值計算一次並快取在其上，不在 tick 路徑上：對所有 land 共用同一個值的 host（`NIOLandHost`）在註冊時計算；對每個 land 建一個定義的 `LandManager` factory，則在錄製時於建立 land 時計算（admin start 的檢查也會呼叫該 factory）。

### Replay 中的 server event

replay land 以有型別的方式顯示每個錄製的 server event（#521、#538）。runner 在每個 tick 排入佇列前先解析：每個錄製的 event，以及 replay 自己送出的 event，都依名稱在 base land 的 registry 查找，payload 用錄製檔自己的 codec（`CanonicalMessagePack`，也就是 recorder 寫入時用的 codec）解碼。`Date` 從 ISO 字串讀回，`Data` 與 `URL` 從它們自己的 `Codable` 形式讀回。儲存的錄製檔以嚴格模式解碼。JSON 檢視失去了浮點數與整數的區別，所以在那裡整數可以精確轉換時，會解碼成 `Double` 或 `Float`。replay land 會註冊 base land 的 server event，並用 `emitEvent` 送出每個 event。

在錄製檔的值域內，重送的 event 編碼後與 live frame 位元組相同：`Bool`、`String`、`Int.min` 到 `Int.max` 的整數、整秒的 `Date`、有限的 `Float` 與 `Double`、`Data`、`URL`，以及由這些組成的 optional、array、以字串為 key 的 map，和巢狀的 `@Payload` 型別。值域外：

- 帶小數秒的 `Date`：錄製檔只保留整秒，所以 replay 時往負無限大方向截斷；
- 大於 `Int.max` 的無號整數：含有這種值的儲存錄製檔無法讀取（#628）；在 JSON 檢視中這個值是 `Double`，解碼會失敗；
- JSON 檢視中的 `-0.0` 讀回為 `+0.0`（儲存的錄製檔會保留）；
- 含有兩個正規等價 key（同一段文字的 NFC 與 NFD 寫法）的 map：錄製檔的 encoder 會把它當成重複 key 拒絕，含有這種 map 的錄製檔也無法讀取（#805）。

無法解析的 tick 會讓 replay run 以 `ReevaluationReplayResolutionError` 失敗。錯誤會指出該 tick、event 的來源（錄製或 replay 送出）、序號與名稱，以及原因。以下情況的 tick 無法解析：名稱未註冊、payload 無法解碼，或錄製的 target 不是 live run 會寫出的形式（未知的 kind、player、client、session target 的 ID 不是剛好一個，或帶有 ID 的 `all` target；#641）的 server event、讀取錄製檔失敗、state snapshot 無法編碼、以及無法從 snapshot 重建 state。run 在 admin 狀態中變成 `failed`。之前的 tick 仍留在佇列中並會顯示；replay land 保持運作，之後不會再收到任何內容。

live run 不可能寫出的錄製檔，會在開啟時、run 的第一個 tick 之前被拒絕：同一個 tick 有兩個 frame，tick 不在 `0 ..< Int64.max` 之內，輸出序號不在 `0 ..< Int64.max` 之內（initialize record 的序號、序號計數器 watermark，或某個 pass 的 `sequenceBefore`），或 sync output、seed marker 的 `afterPass` 小於 0（`ReevaluationRecordContentError`，#639、#640、#729）。live run 不可能寫出這些值。但落在這些範圍內的錄製檔，仍可能讓 replay 用完序號：re-evaluation keeper 上的 replay 以檢查溢位的加法取得輸出序號，land 送出的 event 多於錄製的計數器所剩空間時，run 會以 `ReevaluationRecordContentError.sequenceExhausted` 結束，而不是 trap。run 變成 `failed`，錯誤會指出該值或原因，伺服器照常運作。檢查針對組裝後的錄製內容：3.x 來源檢查的是 reader 合併並修剪該 turn 的記錄之後的每個 frame，JSON 來源檢查的是寫入的 frame。獨立引擎（`ReevaluationEngine.run`）與 hosted runner 的 OnInitialize 檢查，也會把 live run 不會寫出的錄製 event target 回報為這個錯誤，而不是與 replay 送出的 event 不相符。自訂 runner 若回報 `Int64.max` 為最後一個 tick，它的 run 也會以同樣方式、在第一步之前失敗。

Replay 會從 tick 0 逐一走到錄製檔的最後一個 tick，沒有 frame 的 tick 也算，所以 run 的長度是最後一個 tick + 1，而不是 frame 的數量。這個上限計算的是外層步驟（tick）；它不限制一個步驟內的工作量，所以沒有 tick 的 land 把它的 pass 記在很少的 frame 裡，並不會因此受 pass 數量限制。錄製檔本身的大小在讀取時另有上限。最後一個 tick + 1 超過上限的錄製檔，會在開啟時、run 的第一步之前，以 `ReevaluationRecordContentError.replayTooLong(lastTick:limit:)` 被拒絕（#728）；只有 tick 0 與 tick 10^12 兩個 frame 的錄製檔，否則永遠跑不完。預設上限是 `ReevaluationRecordFile.defaultMaxReplayTicks`，1,000,000 個 tick，50 ms 的 tick 下約 13.9 小時。它對一般的 session 有很大的餘裕，但連續存活數天的 land 會錄下每個 tick，所以合法的長壽錄製檔也可能超過預設值：有這種 land 的 host 要調高上限。每一種開啟錄製檔的方式都接受 `maxReplayTicks:`（`JSONReevaluationSource`、`ReevaluationRecordLogSource`、`ReevaluationRecordFile.openSource`、`ReevaluationEngine.run`、`ConcreteReevaluationRunner`），每個公開入口對小於 1 的上限都會讓 process 停止。`ReevaluationRunnerService(factory:maxReplayTicks:)` 會讓 runner 回報的長度超過上限的 run 在第一步之前失敗（不論 factory 建立的是哪種 runner），也會讓實際步數超過上限的 run 失敗（即使它的 runner 回報的較少）；步數只能在走完一步之後檢查，所以這樣的 runner 最多會多走一步才失敗，失敗訊息會說明 runner 產生的結果數超過上限（這是步數的計數，不是錄製檔的 tick）。自己開啟錄製檔的 runner 在開啟時套用它自己的上限，所以要允許更長的錄製檔，兩邊都要調高。Admin 的 replay 啟動（`/admin/reevaluation/start` 與 `/admin/reevaluation/replay/start`）以 `ReevaluationFeatureConfiguration.maxReplayTicks` 檢查錄製檔，host 要把它設成與 service 相同的值，超過時回傳 400，訊息會指出最後一個 tick 與上限；這個值是 `NIOLandHost.registerWithGenericReplay` 為該 land type 記下的上限，與 service 的上限不一致也是安全的（admin 啟動提早拒絕，或 run 以 `replayTooLong` 失敗）。另有兩點來自 host 註冊 land 的方式。Reevaluation monitor land 只註冊一次，由第一次啟用 re-evaluation 的 `registerWithGenericReplay` 呼叫（停用的呼叫不會註冊 monitor）以該次的 service 與上限註冊，而 `/admin/reevaluation/start` 以請求中 land type 的上限檢查錄製檔：各 land 的上限不同時，對上限較高的 land 通過檢查的錄製檔，仍可能在 monitor 失敗，狀態為 `phase == .failed`，`errorMessage` 帶有 `replayTooLong` 的描述（會被回報、不會無聲失敗），所以共用 monitor 的 land 若要讓 monitor 路由生效，應使用相同的上限。另外 `NIOAdminRoutes` 在 `registerAdminRoutes()` 執行時取得各 land type 上限的快照（`NIOLandHost.run` 會在註冊之後才呼叫它）：之後才用 `registerWithGenericReplay` 註冊的 land，admin 啟動仍使用預設上限。Demo 與 GameDemo 範例的 `ReevaluationRunner` 命令列工具接受 `--max-replay-ticks <n>`。記憶體內的 `JSONReevaluationSource(metadata:frames:)`，以及直接以 `.reevaluation` 模式、搭配自訂 `ReevaluationSource` 建立的 `LandKeeper`，都沒有上限：兩者都是 host 的程式碼，所以 host 若傳入外部提供的 frame，應該用有檢查的來源（例如 `ReevaluationRecordFile.openSource`）讀取。

供給 replay land 的 run，遇到 land 無法顯示的結果也會失敗：沒有 frame 的結果（`unresolvedResult`，自訂 runner 沒有呼叫 `ReevaluationReplayFrame.resolve`）、其他 state 型別的 frame（`stateTypeMismatch`）、或沒有 state 的 frame（`stateUnavailable`）。無法計算 state hash 的 tick（§ 無法計算的 State Hash）沒有 state，其原因就是 hash 的錯誤。不供給 replay land 的 run（monitor 的驗證）會把這種 tick 回報為無法驗證，並繼續執行。`registerWithGenericReplay` 會在排入佇列前拒絕這些結果。只用 `GenericReplayLand.makeLand` 建立的 land 會在讀取每個結果時檢查，並讓 run 失敗，所以結果不會被默默丟掉。

錄製內容會被 replay 的 land，若有 server event 型別沒有 decoder，註冊時會被拒絕（`LandRegistrationError.serverEventsWithoutDecoder`）。DSL 註冊的每個型別都有 decoder。這項檢查在內建 runner 的 init 與 engine 中、錄製檔自身的檢查之後執行。自訂 runner（`ReevaluationTargetFactory`）會略過它，並在 `resolve` 中遇到同樣的情況。

內建 runner 的每一步都會重建 state 並解碼該 tick 的每個 server event，monitor 的驗證也一樣：monitor run 每個 tick 要付出一次 state 重建與 event 解碼的成本。

### Replay 中的 resolver output

replay 時，handler 收到錄製的 resolver output（它的 `productInfo` 參數）的方式，和 replay land 讀取錄製的 server event 相同：用錄製檔自己的 codec（#707）。action 的 resolver、`OnJoin` 與 `OnLeave`、`OnInitialize` 都是如此。`Date`、`Data`、`URL` 或 `Decimal` 欄位讀回的值與 live handler 看到的相同，`Decimal` NaN 也一樣。儲存的錄製檔嚴格解碼。在 JSON 檢視中，整數若能精確轉換，會解碼成 `Double` 或 `Float`。上面的值域限制同樣適用：帶小數秒的 `Date` replay 時會被截斷。無法解碼成所要型別的 output 讀成 `nil`，land 的 logger 會記一則警告，指出該 output、錄製的型別與要求的型別，以及錯誤。

限制：錄製的 action 本身的 payload 仍以 JSON 來回轉換解碼，所以 payload 含 `Date`、`Data` 或 `URL` 欄位的 action 在 replay 時會被丟棄（#709）。

### Replay 中的 OnInitialize

Replay 以錄製的 resolver output 再次執行 OnInitialize：不會拋出錯誤的 body，或先 `validate` 再 `apply`（#593）。只有 live 的 `validate` 通過時，錄製才會有 initialize 項目，因為 live 的拒絕會在記錄任何內容之前結束 land。因此重播的 `validate` 若拋出錯誤，表示 `validate` 不是確定性的：它讀取了 state 與 context 以外的東西，例如時鐘或可變的全域變數。

此時 replay 什麼都不寫入，和 live 執行相同，initialize 檢查失敗，原因會指出 OnInitialize 與錯誤（`InitializeVerification.failed`）。沒有 initialize record 的錄製也一樣，它的 OnInitialize 在 tick 0 內重播。Replay 會繼續進行，之後的 state hash 會回報後續的狀況。

託管的 replay（reevaluation monitor 與 replay land）在 initialize 檢查失敗時，即使每個 tick 的 hash 都相符，也會讓該次執行失敗。被拒絕的初始化可能讓 tick hash 保持相同，例如 `apply` 什麼都不寫入，或只寫入之後的 tick 會覆寫的內容。執行的錯誤訊息會指出 OnInitialize 與錯誤。只有 `.failed` 會讓執行失敗：`.unverifiable` 或 `.notComparable` 的檢查仍會讓它完成。自訂的 runner 透過 `ReevaluationRunnerProtocol.initializeVerification()` 回報它的檢查，這個方法沒有預設實作。不檢查 OnInitialize 的 runner 回傳 `.notRecorded`，不會讓執行失敗；包裝另一個 runner 的 runner 則轉傳該 runner 的回答。

### 錄製所含的 Hash

| 錄製格式 | State 與 initialize hash | 驗證方式 |
|---|---|---|
| 2.4 以後 | 完整 state（`ReevaluationHashDefinition.fullState`） | 以完整 state 精確比對 |
| 2.3 | broadcast view，`snapshot(for: nil)` | 以 broadcast view 精確比對 |
| 早於 2.3 | broadcast view，#175 之前 | 以 broadcast view 比對，並套用下方的 #175 規則 |

讀取端依錄製版本選擇定義（`ReevaluationRecordVersion.hashDefinition`），並由 `RunResult.hashDefinition` 回報，因此較舊的錄製照舊驗證，不會被整批豁免。Sync-output hash 是對 client 實際收到內容的 hash，2.4 不改變它。

### 無法計算的 State Hash

若 state 無法為 hash 轉換（map 的 key 轉成字串後衝突、值的型別不受支援、JSON 無法編碼的 NaN 或無限大浮點數），live tick 不會因此停止：該 tick 的 hash 會記錄為 `unavailable: <reason>`，keeper 會記錄 error log 並計數（`LandKeeper.stateHashUnavailableCount`）。Replay 會把這類 tick 回報為無法驗證，絕不視為相符（`RunResult.unverifiableStateHashes`；較舊版本記錄的 `"error"` 也同樣處理），initialize 檢查則回報 `unverifiable`。replay land 對這種 tick 沒有 state 可顯示，所以供給 replay land 的 run 會在此失敗（`stateUnavailable`，帶上 hash 的錯誤；§ Replay 中的 server event）。若錄製的 hash 有效、但 replay 時無法計算，則屬於分歧，會回報為不符。`ReevaluationRunner --verify` 只有在沒有任何確定失敗時，才會因無法驗證的 hash 以 exit code 11 結束：state hash 不符（5）、server event（6）、sync output（8）與 OnInitialize（9）優先。

大於 `Int.max` 的無號整數（`UInt`、`UInt64`）在所有路徑上都會轉成十進位數字字串：以前會 trap。可放入 `Int` 的值在傳輸上不變。

### 早於 2.3 的錄製（#175）

在錄製格式 2.3 之前，位於 `[String: X]` 或 `[PlayerID: X]` map 中的 `@SnapshotConvertible` state node 會連同所有欄位（包含 server-only 欄位，例如 Hero Defense 的 `players.*.lastFireTick`）一起轉換。它的 state hash、initialize hash 與 sync-output hash 都涵蓋了這些欄位。現在的版本會排除它們，因此這類錄製無法再重現原本的 hash。

所有錄製仍會比對 hash。Land 是否受影響由其 state 型別判定，而非由錄製內容判定（`ReevaluationRecordVersion.hashChangedByNestedNodePolicies`）：在任一層級中，`[String: X]` 或 `[PlayerID: X]` map 的值是 `@SnapshotConvertible` state node，且只沿 `.broadcast` 欄位追蹤，因為 hash 涵蓋的是 broadcast view。Hero Defense 受影響；visibility-test 不受影響（其 `entities` map 為 `.perPlayer`）。受影響 Land 早於 2.3 的錄製若 state hash 或 initialize hash 不符，讀取端會回報為無法比對（「recorded before #175, hash not comparable」），而不是 replay 差異：`RunResult.hashIncomparability` 帶有原因，initialize 檢查回報 `notComparable`，`ReevaluationRunner --verify` 以 exit code 10 結束。請用目前版本重新錄製這類 session。其他所有不符仍照舊視為失敗：未受影響 Land 的任何不符（不論錄製版本），以及所有 sync-output 失敗（exit 8）。有兩個偏向安全的後果：早於 2.3 的 visibility-test 錄製，其 state hash 會驗證通過，但 sync output 會失敗（exit 8），因為它的 per-player patch 已改變；而位於非 node 的 `@SnapshotConvertible` 值中的 map 不會被偵測到，因此這類 Land 的不符會視為失敗（exit 5）。任何 Land 的 2.3 錄製，以及所有 2.4 錄製，都會精確比對。

### Server Event 驗證

當 `enableLiveStateHashRecording: true` 時，伺服器也會記錄每 tick 的 server events（`ctx.emitEvent()`）。在帶 `--verify` 的 reevaluation 中，runner 會比對錄製與發送的 server events。若 mismatch 表示 event 發送有非決定性（例如順序或 payload 差異）。

錄製的 payload 是錄製檔的形式，發送的 payload 則是 replay 的有型別值，所以 verifier 會先把發送的 payload 轉成錄製檔的形式（`CanonicalMessagePack`，與 recorder 寫入的方式相同），再比對兩者（#633）。`Date`、`Data`、`URL` 或 `Float` 欄位在兩種錄製形式都會相符；帶小數秒的 `Date` 也會相符，因為兩邊都只保留整秒。限制：JSON 檢視已失去 `-0.0` 的正負號（[Replay 中的 server event](#replay-中的-server-event)），所以在 JSON 檢視中，event payload 裡的 `-0.0` 會讓該 tick 被回報；儲存的錄製檔則相符。

Action、client event、lifecycle event 與 server event 共用同一個 `sequence` 計數器。有 tick 的 Land 在 live 模式下，每個 tick 會在 tick frame 記下該計數器的兩個 watermark（`sequenceBeforeInputs`、`sequenceBeforeTickHandler`）；reevaluation 時把計數器往前推到這兩個值，因此重播的 server event 會拿到與錄製相同的 `sequence`。從錄製格式 3.1 起，沒有 tick 的 land 的 frame 若帶有錄到的 passes，也算帶有 watermark（`watermarkedTicks`）：replay 會在每一次處理前還原計數器。比對以 tick 為單位判定：frame 帶有 watermark 的 tick 必須完全一致（包含 `sequence`），且即使錄製的事件清單為空也會比對，因此重播多出的 event 會被回報。沒有 watermark 的舊格式錄製維持原規則：只有錄到事件時才比對，僅 `sequence` 不同時回報為警告而非失敗（`ReevaluationEngine.RunResult.serverEventVerification`）。

### Sync Output 驗證

每個 commit 的 sync plan 會依 scope（broadcast scope 與每位玩家的 scope）錄製其 canonical patch list 的 hash，以及隨之送出的 event。不比對編碼後的位元組：dynamic-key slot、frame 順序與 wire encoding 都不是 canonical 的。Replay 以餵入 replay 狀態的 shadow sync engine 重新規劃每個錄製的 sync output，並比對 hash（不符時 `ReevaluationRunner --verify` 以 exit code 8 結束）。有 tick 的 land 的 output 與它讀取的那個 tick 的 state 比對；沒有 tick 的 land 從 3.4 起，與它讀取時最後套用的那個 pass 之後的 state 比對（見「Pass 序號與 land 失敗」）。Replay 檢查的是 server 實際產生的內容：一筆 output 沒有送給的玩家會列在它的 `perPlayerUnverified`，在那筆 output 既不比對也不 stage。這也包括在那一輪所有 session 都因 sync lag 暫停（`resyncPending`）的玩家；暫停以 resync 的 clear 與 seed 結束，或以離開的 clear 結束（#572）。以這種方式略過的每個 scope 都計入結果的 `perPlayer.unverifiable`，所以含有暫停的錄製判定為 `partial`：這個計數會指出涵蓋範圍在哪裡減少，而不是默默略過。在 #572 修正之前錄製的檔案沒有這一項，遇到暫停仍會回報不符。沒有 tick 的 land 上，玩家離開的那個 turn 會在該玩家的 clear 之前 sync，而這時該玩家的 session 已經結束，所以那筆 output 會列出離開的玩家，含有這種離開的錄製判定為 `partial`。

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
