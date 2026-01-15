# 傳輸層編碼演進歷程與最終成果 (Transport Evolution)

本文件紀錄了 `optimize/transport-opcode-json-array` 分支在傳輸層（Transport Layer）編碼上的主要演進歷程。目標是透過更高效的序列化方式，顯著降低網路頻寬消耗並提升傳輸效能。

以下範例皆基於 **GameDemo** 的 `HeroDefenseState` 與 `ClientEvents`。

---

## 演進歷程 (Evolution History)

### 第一階段：Opcode JSON Array 優化
*   **背景**：原有的傳輸格式為標準 JSON Object，欄位名稱（Key）佔用了大量重複的字節。
*   **改進**：引入 `OpcodeJsonArray` 格式。將原本的 `{ "kind": "action", "payload": ... }` 結構改為陣列結構 `[Opcode, Payload...]`。

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
  101,       // Opcode for Action (假設 101 代表 Action)
  "req-1",   // Request ID
  "MoveTo",  // Action Type
  { "target": { "v": { "x": 100, "y": 200 } } } // Payload
]
```
> **差異**：移除了 "kind", "payload", "action", "type" 等重複 Key，大幅減少封包大小。

---

### 第二階段：路徑雜湊 (Path Hashing)
*   **背景**：在狀態同步（State Sync）中，大量的字串路徑（String Path）佔據了大部分的流量。例如 `players.user-123.position.v.x`。
*   **改進**：引入 `PathHasher` 與 `schema.json` 整合。傳輸時僅發送 4-byte 整數雜湊。

#### 範例 (Example)
參考 `schema.json` 中的定義：

```json
"pathHashes" : {
  "players.*.position" : 3358665268,
  "players.*.items" : 2159421276
}
```

當伺服器要更新玩家位置時：

**原始路徑 (String):**
`["players", "user-123", "position", "set", { "v": { "x": 105, "y": 205 } }]`

**Path Hash 優化後:**
`[3358665268, "user-123", nil, 1, { "v": { "x": 105, "y": 205 } }]`
*   `3358665268`: 代表 `players.*.position` 的 Hash。
*   `"user-123"`: 動態路徑部分（Dynamic Key）。
*   `1`: Opcode for Set Operation.

> **差異**：長字串 `players.*.position` 被 4-byte 整數取代。

---

### 第三階段：執行期壓縮優化 (Runtime Compression)

針對無法在編譯期預知的動態資料，引入了執行期壓縮機制 (Runtime Compression)，進一步壓榨傳輸極限。這包含兩個層面：**Header 優化 (PlayerSlot)** 與 **Body 優化 (Dynamic Key)**，兩者皆依賴「首次同步」建立的 Snapshot 映射表。

#### 1. 核心概念：Slot Mapping
為了消除長字串 (UUID, Dynamic Path Keys) 帶來的 Overhead，伺服器維護了 `String <-> Int Slot` 的動態映射表。

*   **PlayerSlot (Header Layer)**: 將連線的 PlayerID 映射為 `Int32`。
*   **Dynamic Key (Body Layer)**: 將 State Path 中的動態字串 (e.g. `players["user-123"]`) 映射為 `Int`。

#### 2. 建立機制：首次同步 (First Sync)
當玩家剛連線時，伺服器發送 Opcode `1` (FirstSync)。在此之前，客戶端已透過 **JoinResponse (Opcode 105)** 獲知了自己的 `PlayerID` 與分配到的 `PlayerSlot`。

*   **告知身分 (Header)**：Payload Header 攜帶分配給該玩家的 **PlayerSlot** (e.g. `5`)。客戶端依據 JoinResponse 的資訊識別此封包屬於自己。
*   **強制定義 (Body)**：Body 中的所有 Patch，凡涉及動態 Key (如 `players.user-123`)，皆強制使用 `[Slot, "KeyString"]` 格式，建立初始映射。

**首次同步範例 (First Sync):**
```json
[
  1,          // Opcode: FirstSync
  5,          // [Header] Player Slot = 5 (Client knowns this from JoinResponse)
  // Patches...
  [2159421276, [1, "user-123"], 3, { ... }]  // [Body] Define Slot 1 = "user-123" for this path
]
```

#### 3. 運行效益：增量更新 (Update)
一旦映射建立完成，後續的所有更新 (Diff) 僅需傳輸 Slot ID。

**後續傳輸範例 (Diff):**
`[3358665268, 5, 1, 1, ...]`
*   **Header**: 使用 Slot `5` (1 byte) 代替 UUID (36 bytes)。
*   **Body**: 使用 Slot `1` (1 byte) 代替 "user-123" (36 bytes)。
> **註**：目前 Dynamic Key 機制主要用於優化 `players` 字典中的 `PlayerID`。

---

### 第四階段：MessagePack 二進制整合 (MessagePack Integration)
*   **背景**：JSON 即使轉為 Array，數值 `1234567890` 仍需佔用 10 bytes 文字。此外，字串處理與 Base64 編碼（針對 binary barrier）也存在效能瓶頸。
*   **改進**：全面整合 **MessagePack**，將上述所有優化結構（Opcode Array, PathHash, Slots）改為二進制編碼。

#### 範例 (Example)
同樣是位置更新：

**JSON Array:**
`"[3358665268, 5, ...]"` (純文字，每個數字都是字元)

**MessagePack (Hex):**
`95 CE C8 31 12 34 05 ...`
*   `95`: Array of 5 elements.
*   `CE C8 31 12 34`: `UInt32` (PathHash) 僅佔 5 bytes。
*   `05`: `Int` (PlayerSlot) 僅佔 1 byte。

> **最終效益**：徹底移除文字解析成本，並將數值資料壓縮至極限。

---


## 最終成果 (Final Result)

目前的 `GameDemo` 採用以下配置達到最佳效能：

1.  **Transport Config**: `messagepack`
    *   全二進制傳輸。
2.  **State Encoding**: `opcodeMessagePack`
    *   結合 Path Hash (編譯期) + PlayerSlot (執行期) + DynamicKey (執行期)。
3.  **Schema**: `schema.json`
    *   包含完整 `pathHashes` 表，確保客戶端與伺服器端同步解碼。

此架構使得 `HeroDefenseState` 中高頻更新的 `position` (60Hz) 與 `rotation` 能夠以極低的頻寬消耗進行廣播，支撐多人即時戰鬥的需求。

## 效能實測 (Performance Benchmarks)

基於 `2026-01-15` 的壓力測試結果 (GameServer: hero-defense, 時長: 60秒)，各階段優化成果如下：

| 訊息類型 (Message Type) | JSON Format (原始) | Opcode Format (階段一) | MessagePack Format (最終) | 最終節省比例 (Savings) |
| :--- | :--- | :--- | :--- | :--- |
| **StateUpdate (平均/封包)** | 533.60 bytes | 255.14 bytes | **142.30 bytes** | **73.00%** |
| **Event (平均/封包)** | 185.00 bytes | 97.00 bytes | **48.74 bytes** | **73.00%** |
| **Transport Control** | 312.00 bytes | 110.00 bytes | **90.00 bytes** | **71.00%** |

### 關鍵數據
*   **73% 頻寬節省**: 從原始 JSON 到最終 MessagePack + PathHash，狀態更新封包大小縮減至原本的 1/4。
*   **低於 150 bytes**: 平均每個狀態更新封包 (含 60Hz 位移同步) 僅需 142 bytes，極大降低了行動網路下的延遲風險。

## 技術問答 (Technical Q&A)

### Q1: 如果同一幀內同一 ID 發生多次更新，會合並嗎？ (Update Merging)
**A: 會的，會自動合併。**

*   **機制**：`SyncEngine` 採用的是 **Snapshot Diff (快照比對)** 機制，而非 Operation Log (操作日誌)。
*   **流程**：
    1.  每幀結束時，系統擷取當前狀態的 Snapshot。
    2.  將其與上一幀發送的 Snapshot 進行比對。
    3.  僅產生差異部分 (Diff)。
*   **範例**：若某玩家在同一幀內位置由 `(0,0)` -> `(10,0)` -> `(20,0)`：
    *   系統僅會看見 `Old=(0,0)` 與 `New=(20,0)`。
    *   最終僅產生一個 Patch: `op: set, value: (20,0)`。
    *   這保證了在網路抖動或高頻運算下，傳輸量始終保持最小，不會因為中間運算過程而膨脹。

### Q2: Payload Macro (@Payload) 生成的 Array 順序是如何決定的？
**A: 嚴格依照 Struct 屬性的宣告順序 (Declaration Order)。**

*   **實作**：`@Payload` Macro 在編譯期會解析 Struct 的語法樹 (AST)。
*   **規則**：它會依序讀取 `Stored Properties` 的宣告，並生成對應的序列化程式碼。
*   **範例**：
    ```swift
    @Payload
    struct MyEvent {
        let x: Int    // Index 0
        let y: Int    // Index 1
        let z: Int    // Index 2
    }
    ```
    序列化結果必為 `[x, y, z]`。
*   **注意**：因此在修改 Protocol 時，若要保持向下相容，**新欄位必須加在最後面**，且舊欄位不可改變順序或刪除 (除非所有客戶端強制更新)。

### Q3: `player.rotate` 與 `player.position` 同時更新會變成兩筆資料嗎？
**A: 是的，會產生兩個獨立的 Patch，但會在同一個 Packet 中傳輸。**

*   **結構**：在 `PlayerState` 中，`position` 與 `rotation` 是兩個獨立的 `@Sync` 屬性。
*   **Patch 生成**：
    *   `SyncEngine` 偵測到 `position` 變更 -> 生成 Patch 1。
    *   `SyncEngine` 偵測到 `rotation` 變更 -> 生成 Patch 2。
*   **傳輸合併**：這兩個 Patch 會被打包進同一個 `StateUpdate.diff([Patch1, Patch2])` 陣列中。
    *   這意味著雖然邏輯上是兩筆修改，但網路傳輸層面上**只有一個封包** (封包標頭 Overhead 只有一次)。
    *   接收端也會在同一個 Tick 內一次應用這兩個變更，不會有狀態不一致的問題。

### Q4: 客戶端的 Payload 目前是使用什麼格式？ (Future Optimizations)
**A: 目前各語言 SDK (TypeScript/C#) 的 Payload 仍使用 Object 格式。**

*   **現況**：雖然 Server 端已全面優化為 Tuple Array (e.g. `[100, 200]`)，但目前的 Client SDK 在發送 Action 時，Payload 部分仍採用 Object 結構 (e.g. `{ "x": 100, "y": 200 }`)。
*   **未來優化**：這是一個已知的優化點。後續可以讓 Client 端也實作類似 `@Payload` 的機制，將 Action Payload 也轉為 Array 傳輸，進一步節省上行流量。

### Q5: 既然 JoinResponse 已經告訴 Client 它的 Slot，為什麼 FirstSync 封包裡面還要再送一次 PlayerID 字串？
**A: 這是為了確保 Client 端的解碼器能建立正確的對照表 (Table Synchronization)。**

雖然 `JoinResponse` 讓 Client 知道「我是 Slot 5」，但 Client 內部的解碼器 (Decoder) 初始狀態是**空的**。
1.  **Transport 層 (Header)**：負責標記「這個封包來自 Slot 5」。
2.  **Encoder 層 (Body)**：負責壓縮內容。當它要壓縮 `players["user-123"]` 時，它必須告訴 Client 的解碼器：**「Body Slot 1 代表字串 "user-123"」**。

如果 FirstSync 封包裡不送這個定義 (`[1, "user-123"]`)，Client 收到 Body Slot 1 時會因為**查無此號**而報錯 (如 `protocol.ts` 中的 `Dynamic key slot used before definition` 錯誤)。
所以，這個看似冗餘的傳輸，其實是 **Server 將內部記憶同步給 Client** 的必要過程，也確保了 Encoder 可以通用於任何動態 Key (不只是 PlayerID)。
    *   Encoder 也不知道這個 Key 是 PlayerID 還是 MonsterID。
    *   因此，Encoder 必須嚴謹地遵守 "Define-on-First-Use"，發送 `[1, "user-123"]` 來定義 Body 專用的映射表。

**結論**：是的，對於「玩家自己的 ID」來說，這確實有一次性的冗餘傳輸。但這換來了 Encoder 的**通用性**——它能用同一套邏輯壓縮任何動態 Key (如別人的 ID、道具 ID)，而不需要依賴外部 Transport 層的狀態。
