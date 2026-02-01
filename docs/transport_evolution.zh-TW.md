[English](transport_evolution.md) | [中文版](transport_evolution.zh-TW.md)

# 傳輸層編碼演進歷程與最終成果 (Transport Evolution)

本文件紀錄了 `optimize/transport-opcode-json-array` 分支在傳輸層（Transport Layer）編碼上的主要演進歷程。目標是透過更高效的序列化方式，顯著降低網路頻寬消耗並提升傳輸效能。

以下範例皆基於 **GameDemo** 的 `HeroDefenseState` 與 `ClientEvents`。

---

## 演進歷程 (Evolution History)

### 第一階段：Opcode JSON Array 優化

- **背景**：原有的傳輸格式為標準 JSON Object，欄位名稱（Key）佔用了大量重複的字節。
- **改進**：引入 `OpcodeJsonArray` 格式。將原本的 `{ "kind": "action", "payload": ... }` 結構改為陣列結構 `[Opcode, Payload...]`。

#### 範例 (Example)

假設有一個 `MoveTo` 的 Action：

**原始 JSON Object:**

```json
{
  "kind": "action",
  "payload": {
    "requestID": "req-1",
    "action": {
      "type": "MoveTo",
      "payload": { "target": { "v": { "x": 100, "y": 200 } } }
    }
  }
}
```

**Opcode JSON Array:**

```json
[
  101, // Opcode for Action (假設 101 代表 Action)
  "req-1", // Request ID
  "MoveTo", // Action Type
  { "target": { "v": { "x": 100, "y": 200 } } } // Payload
]
```

> **差異**：移除了 "kind", "payload", "action", "type" 等重複 Key，大幅減少封包大小。

- **相關分析程式碼**:
  - Server 端編碼: [StateUpdateEncoder.swift:L140](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L140)
  - Client 端解碼: [protocol.ts:L388](../sdk/ts/src/core/protocol.ts#L388)

---

### 第二階段：路徑雜湊 (Path Hashing)

- **背景**：在狀態同步（State Sync）中，大量的字串路徑（String Path）佔據了大部分的流量。例如 `players.user-123.position.v.x`。
- **改進**：引入 `PathHasher` 與 `schema.json` 整合。傳輸時僅發送 4-byte 整數雜湊。

#### 範例 (Example)

參考 `schema.json` 中的定義：

```json
"pathHashes" : {
  "players.*.position" : 3358665268,
  "players.*.items" : 2159421276
}
```

> **註**：其中的 `*` 代表**動態片段** (Wildcard)，對應到 State 中的字典鍵值 (Dictionary Key) 或陣列索引。這些片段在傳輸時會由「第三階段」的動態鍵值機制進一步優化。

當伺服器要更新玩家位置時 (以 Diff 為例)：

**原始路徑 (String):**

```json
[
  2, // Opcode: Diff
  ["players/user-123/position", 1, { "v": { "x": 105, "y": 205 } }]
]
```

**Path Hash 優化後:**

```json
[
  2, // Opcode: Diff
  [3358665268, "user-123", 1, { "v": { "x": 105, "y": 205 } }]
]
```

- `2`: 代表 `StateUpdateOpcode.diff`。
- `3358665268`: 代表 `players.*.position` 的 Hash。
- `"user-123"`: 動態路徑部分（Dynamic Key）。
- `1`: 代表 `StatePatchOpcode.set`。

> **差異**：長字串 `players.*.position` 被 4-byte 整數取代。
> **註**：在 JSON 格式下，由於雜湊數字長度（如 `3358665268` 為 10 bytes）與原路徑相近，且為了分離動態鍵值引入了陣列結構，此階段的 **文字體積** 可能不會明顯下降。其核心價值在於建立「數值化」的結構，為後續的「第四階段」二進制壓縮提供物理基礎。

- **相關分析程式碼**:
  - 路徑雜湊邏輯: [PathHasher.swift](../Sources/SwiftStateTree/Core/PathHasher.swift)
  - Server 端應用: [StateUpdateEncoder.swift:L214](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L214)
  - Client 端路徑重建: [protocol.ts:L520](../sdk/ts/src/core/protocol.ts#L520)

---

### 第三階段：執行期壓縮優化 (Runtime Compression)

針對無法在編譯期預知的動態資料，引入了執行期壓縮機制 (Runtime Compression)，進一步壓榨傳輸極限。這依賴「首次同步」建立的 Snapshot 映射表。

#### 1. 核心概念：Slot Mapping

為了消除長字串 (Dynamic Path Keys) 帶來的 Overhead，伺服器維護了 `String <-> Int Slot` 的動態映射表。

- **Dynamic Key (Body Layer)**: 將 State Path 中的動態字串（例如 `players["user-123"]`、`inventory["item-abcdef"]`）映射為 `Int`。
- **Scope**：slot 表格 **不是全域共用**，而是以 `(landID, playerID)` 為單位各自維護，避免不同玩家互相污染。
- **Reset**：在 `firstSync` 時會重置表格並重新定義 keys，避免無限制成長，並確保解碼決定性。

#### 1.1 Dynamic Key 封包格式（Opcode Patch）

在 PathHash patch 中，patch 格式為：

`[pathHash, dynamicKeyOrKeys, op, value?]`

其中 `dynamicKeyOrKeys` 同時支援單層與多層 wildcard：

- **無 wildcard**：`null`
- **單層 wildcard**（schema pattern 只有一個 `*`）：一個 _DynamicKeyToken_
- **多層 wildcard**（schema pattern 有兩個以上 `*`）：依 wildcard 出現順序的一組 _DynamicKeyToken_ 陣列

**DynamicKeyToken** 可以是：

- `string`：原始 key（不壓縮）
- `number`：已定義過的 **slot id**（壓縮引用）
- `[number, string]`：**定義** slot id 對應原始 key（`[slot, "key"]`）
- `null`：無 key（僅在 schema pattern 沒有 `*` 時合理）

> **重要**：`number` 保留給 slot id 使用。若你的動態 key 本身是數字索引（例如 `7`），請以 **字串** `"7"` 傳輸，避免被誤判為 slot id。

> **歧義規則**：陣列形狀若為 `[number, string]`，一定視為「定義 token」。其他形狀的陣列一律視為多層 wildcard 的 `dynamicKeyOrKeys` 列表。

#### 2. 建立機制：首次同步 (First Sync)

當玩家剛連線時，伺服器發送 Opcode `1` (FirstSync)。

- **強制定義 (Body)**：Body 中的所有 Patch，凡涉及動態 Key (如 `players.user-123`)，皆強制使用 `[Slot, "KeyString"]` 格式，建立初始映射。

**首次同步範例 (First Sync):**

```json
[
  1,          // Opcode: FirstSync
  // Patches...
  [2159421276, [1, "user-123"], 3, { ... }]  // [Body] Define Slot 1 = "user-123" for this path
]
```

#### 3. 運行效益：增量更新 (Update)

一旦映射建立完成，後續的所有更新 (Diff) 僅需傳輸 Slot ID。

`[2, [3358665268, 1, 1, 100]]`

- **Opcode**: `2` (Diff)。
- **Body**: 使用 Slot `1` (1 byte) 代替 "user-123" (36 bytes)。

  > **註**：此機制可用於 **任何** 出現在 `*` 的動態片段（例如 `PlayerID`、`MonsterID`、`ItemKey`），不限於 `players` 字典。

- **相關分析程式碼**:
  - Server 端管理: [StateUpdateEncoder.swift:L221](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L221)
  - Client 端映射解析: [protocol.ts:L455](../sdk/ts/src/core/protocol.ts#L455)

---

### 第四階段：MessagePack 二進制整合 (MessagePack Integration)

- **背景**：前面的階段已經完成「數值化」與「結構化」。雖然 JSON Array 減少了欄位名稱，但數值 `1234567890` 在文字格式下仍需佔用 10 bytes，且解析效能仍受限於文字處理。
- **改進**：由於前置優化已將數據簡化為純數值陣列，這為 **MessagePack** 提供了完美的發揮空間。透過將 Opcode Array、PathHash 與 Dynamic Keys 直接轉為二進制編碼，徹底消除文字處理成本，達到效能與頻寬的雙重極限。

#### 範例 (Example)

同樣是位置更新 (Diff)：

**JSON Array:**
`[2, [3358665268, 1, 1, 100]]` (純文字，每個數位/逗點都是字元)

**MessagePack (二進制):**
`92 02 94 CE C8 31 2A 34 01 01 64`

> **註**：你若用某些線上工具（特別是以 JavaScript Number 為基礎的編碼器）去轉，可能會把 `3358665268` 編成 **float64**（`CB`）而不是 `UInt32`（`CE`），例如：
> `92 02 94 CB 41 E9 06 25 46 80 00 00 01 01 64`
>
> 這兩者代表的數值相同，但 **型別 tag 不同**；Swift 端的 `UInt32` PathHash 在 MessagePack 正常會走 `CE`（uint32）。

- `92`: Top-level Array of 2 elements (`[opcode, patches]`)。
- `02`: Opcode `2` (Diff)。
- `94`: Patch Array of 4 elements (`[pathHash, slot, op, val]`)。
- `CE C8 31 2A 34`: `UInt32` (PathHash) 僅佔 5 bytes。
  - 若看到 `CB 41 E9 06 25 46 80 00 00`：代表同一個 PathHash 被編成 `float64`（9 bytes）。
- `01`: `Int` (Dynamic Key Slot) 僅佔 1 byte。
- `01`: `Int` (Patch Opcode) 僅佔 1 byte。
- `64`: `Int` (Value 100) 僅佔 1 byte。

> **最終效益**：徹底移除文字解析成本，將封包大小壓縮至極限。

#### 平行編碼支援 (Parallel Encoding Support)

`OpcodeMessagePackStateUpdateEncoder` 和 `MessagePackSerializer` 都是 **`Sendable`** 類型，支援在多線程環境中安全地平行編碼：

```swift
// 在 TaskGroup 中安全地平行編碼
let results = await withTaskGroup(of: Data.self) { group in
    for update in updates {
        group.addTask {
            try! encoder.encode(update: update, landID: landID, playerID: playerID)
        }
    }
    // ...
}
```

**單元測試驗證**：平行編碼結果與串行編碼完全一致，且效能更佳。

- **相關分析程式碼**:
  - Server 端編碼 (MessagePack): [StateUpdateEncoder.swift:L329](../Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift#L329)
  - Client 端解碼: [protocol.ts:L304](../sdk/ts/src/core/protocol.ts#L304)
  - 平行編碼測試: [TransportAdapterParallelEncodingPerformanceTests.swift](../Tests/SwiftStateTreeTransportTests/TransportAdapterParallelEncodingPerformanceTests.swift)

---

## 最終成果 (Final Result)

目前的 `GameDemo` 採用以下配置達到最佳效能：

1.  **Transport Config**: `messagepack`
    - 全二進制傳輸。
2.  **State Encoding**: `opcodeMessagePack`
    - 結合 Path Hash (編譯期) + DynamicKey (執行期)。
3.  **Schema**: `schema.json`
    - 包含完整 `pathHashes` 表，確保客戶端與伺服器端同步解碼。

## 效能實測 (Performance Benchmarks)

基於 `2026-01-15` 的壓力測試結果 (GameServer: hero-defense, 時長: 60秒)，各階段優化成果如下：

| 訊息類型 (Message Type)     | JSON Format (原始) | Opcode Format (階段一) | MessagePack Format (最終) | 最終節省比例 (Savings) |
| :-------------------------- | :----------------- | :--------------------- | :------------------------ | :--------------------- |
| **StateUpdate (平均/封包)** | 533.60 bytes       | 255.14 bytes           | **142.30 bytes**          | **73.00%**             |
| **Event (平均/封包)**       | 185.00 bytes       | 97.00 bytes            | **48.74 bytes**           | **73.00%**             |
| **Transport Control**       | 312.00 bytes       | 110.00 bytes           | **90.00 bytes**           | **71.00%**             |

### 關鍵數據

- **73% 頻寬節省**: 從原始 JSON 到最終 MessagePack + PathHash，狀態更新封包大小縮減至原本的 1/4。
- **低於 150 bytes**: 平均每個狀態更新 **StateUpdate(diff) 訊息封包**（一次同步 flush 的 diff，可能包含多個 patches）約 **142 bytes/封包**。
  - **換算頻寬**：實際頻寬約為 \(142 \times \text{StateUpdate(diff) 每秒封包數}\) bytes/s。
  - 例如若每秒發送 10 次狀態更新，約為 \(142 \times 10 = 1420\) bytes/s（約 1.4 KB/s）。

## 技術問答 (Technical Q&A)

### Q1: 如果同一幀內同一 ID 發生多次更新，會合並嗎？ (Update Merging)

**A: 會的，會自動合併。**

- **機制**：`SyncEngine` 採用的是 **Snapshot Diff (快照比對)** 機制，而非 Operation Log (操作日誌)。
- **流程**：
  1.  每幀結束時，系統擷取當前狀態的 Snapshot。
  2.  將其與上一幀發送的 Snapshot 進行比對。
  3.  僅產生差異部分 (Diff)。
- **範例**：若某玩家在同一幀內位置由 `(0,0)` -> `(10,0)` -> `(20,0)`：
  - 系統僅會看見 `Old=(0,0)` 與 `New=(20,0)`。
  - 最終僅產生一個 Patch: `op: set, value: (20,0)`。
  - 這保證了在網路抖動或高頻運算下，傳輸量始終保持最小，不會因為中間運算過程而膨脹。

### Q2: Payload Macro (@Payload) 生成的 Array 順序是如何決定的？

**A: 嚴格依照 Struct 屬性的宣告順序 (Declaration Order)。**

- **實作**：`@Payload` Macro 在編譯期會解析 Struct 的語法樹 (AST)。
- **規則**：它會先將 `Stored Properties` 依照欄位名稱進行 **ASCII 排序 (Deterministic ASCII Sorting)**，再產生對應的序列化程式碼。這確保了即使重構原始碼（改變宣告行號），只要欄位名稱不變，協議就能保持穩定。
- **雙重保證 (同步性)**：
  1.  **Runtime (`encodeAsArray`)**: Macro 排序後生成此函數供 Server 序列化使用。
  2.  **Schema (`getFieldMetadata`)**: Macro 排序後生成此元數據供 `SchemaExtractor` 寫入 `schema.json`。
- **關鍵限制**：這兩個函數必須使用相同的排序邏輯。我們選擇 ASCII 排序是因為它以此確保了**跨平台、跨語言的決定性**，且不受開發者重構程式碼的習慣影響。
- **Schema 對應**：雖然 JSON Object 的 `properties` 是無序的，但在生成的 `schema.json` 中，`required` 陣列會嚴格保留此順序，作為客戶端解碼 Tuple Array 的依據。
- **相關程式碼**：[PayloadMacro.swift](../Sources/SwiftStateTreeMacros/PayloadMacro.swift)
- **範例**：
  ```swift
  @Payload
  struct MyEvent {
      let x: Int    // Index 0
      let y: Int    // Index 1
      let z: Int    // Index 2
  }
  ```
  序列化結果必為 `[x, y, z]`。
- **注意**：因此在修改 Protocol 時，若要保持向下相容，**新欄位必須加在最後面**，且舊欄位不可改變順序或刪除 (除非所有客戶端強制更新)。

### Q3: `player.rotate` 與 `player.position` 同時更新會變成兩筆資料嗎？

**A: 是的，會產生兩個獨立的 Patch，但會在同一個 Packet 中傳輸。**

- **結構**：在 `PlayerState` 中，`position` 與 `rotation` 是兩個獨立的 `@Sync` 屬性。
- **Patch 生成**：
  - `SyncEngine` 偵測到 `position` 變更 -> 生成 Patch 1。
  - `SyncEngine` 偵測到 `rotation` 變更 -> 生成 Patch 2。
- **傳輸合併**：這兩個 Patch 會被打包進同一個 `StateUpdate.diff([Patch1, Patch2])` 陣列中。
  - 這意味著雖然邏輯上是兩筆修改，但網路傳輸層面上**只有一個封包** (封包標頭 Overhead 只有一次)。
  - 接收端也會在同一個 Tick 內一次應用這兩個變更，不會有狀態不一致的問題。

### Q4: 客戶端的 Payload 目前是使用什麼格式？ (Future Optimizations)

**A: 目前各語言 SDK (TypeScript/C#) 的 Payload 仍使用 Object 格式。**

- **現況**：雖然 Server 端已全面優化為 Tuple Array (e.g. `[100, 200]`)，但目前的 Client SDK 在發送 Action 時，Payload 部分仍採用 Object 結構 (e.g. `{ "x": 100, "y": 200 }`)。
- **未來優化**：這是一個已知的優化點。後續可以讓 Client 端也實作類似 `@Payload` 的機制，將 Action Payload 也轉為 Array 傳輸，進一步節省上行流量。

### Q5: MessagePack 編碼器支援平行編碼嗎？ (Parallel Encoding)

**A: 支援！MessagePack 編碼器完全支援平行編碼。**

- **技術原因**：`OpcodeMessagePackStateUpdateEncoder` 和 `MessagePackSerializer` 都是 `Sendable` 類型，可以在 `TaskGroup` 中安全地並行執行。
- **測試驗證**：單元測試 `testOpcodeMessagePackParallelEncoding` 驗證了平行編碼結果與串行編碼完全一致。
- **效能比較**（50 updates × 3 patches）：

| 格式                          | 每個更新     | vs JSON   |
| ----------------------------- | ------------ | --------- |
| JSON Object                   | 280 bytes    | 100%      |
| Opcode JSON (Legacy)          | 172 bytes    | 61.5%     |
| Opcode JSON (PathHash)        | 99 bytes     | 35.4%     |
| Opcode MsgPack (Legacy)       | 135 bytes    | 48.2%     |
| **Opcode MsgPack (PathHash)** | **65 bytes** | **23.3%** |

> **最佳組合 (Opcode MessagePack + PathHash) 節省了 76.7% 的空間！**

---

### Q6: Opcode 107 如何合併廣播更新與事件？ (Broadcast Merge + Dynamic Keys)

**A: Opcode 107 只合併廣播狀態更新與廣播事件，每個房間只編碼一次。**

- **廣播只編碼一次**：伺服器將 broadcast diff 編碼一次後送給所有 session。
- **Per-player 仍然逐 session**：per-player diff 與 targeted event 仍是每個 session 各自編碼與送出（opcode 2/103）。
- **Dynamic key scope**：
  - broadcast 更新使用 **broadcast key table**（以 land 為範圍）
  - per-player 更新使用 **per-player key table**（以 land + player 為範圍）
- **Late-join 規則**：新加入的 client 若在 broadcast keys 已存在之後加入，必須先收到 **dynamic key 定義**，才能接收 slot-only broadcast 更新。可透過強制定義或 join 後傳一次 broadcast firstSync。

---

## 綜合演進範例 (Comprehensive Evolution Example)

以「更新某個玩家的生命值 (HP)」為例，觀察同一個語意在不同階段的表達方式與封包大小：

#### 階段 0：原始 JSON Object

```json
{
  "kind": "stateUpdate",
  "payload": {
    "type": "diff",
    "patches": [{ "path": "players/user-123456/hp", "op": "set", "value": 100 }]
  }
}
```

- **大小**：**117 bytes**
- **痛點**：大量的重複 Key (kind, payload, type, path...)。

#### 階段 1：Opcode JSON Array

```json
[2, [["players/user-123456/hp", 1, 100]]]
```

- **大小**：**38 bytes**
- **優化**：移除了屬性名稱，僅保留結構。

#### 階段 2：路徑雜湊 (Path Hashing)

```json
[2, [[3358665268, "user-123456", 1, 100]]]
```

- **大小**：**38 bytes**
- **優化**：長路徑 `players.*.hp` 被縮減為 4-byte 雜湊。
- **註**：此階段在 JSON 格式下大小未下降，是因為 `3358665268` 字串長度與原路徑相近，且為了分離動態鍵值引入了陣列結構。此優化的真正目標是為「第四階段」的二進制儲存提供定長（4-byte）的基礎。

#### 階段 3：執行期壓縮 (Dynamic Key)

```json
[2, [[3358665268, 1, 1, 100]]]
```

- **大小**：**26 bytes**
- **優化**：動態字串 `user-123456` 被縮減為 1-byte Slot ID。

#### 階段 4：MessagePack 二進制 (最終形態)

`92 02 91 94 CE C8 31 2A 34 01 01 64` (Hex)

- **大小**：**12 bytes**
- **終極優化**：數值與結構直接以二進制儲存，無需括號、逗點或引號。

### 總結

從 **117 bytes** 縮減至 **12 bytes**，在維持相同邏輯語意的情況下，我們實現了物理層面上 **89.74% 的頻寬節省**。這正是本分支優化的核心價值。
