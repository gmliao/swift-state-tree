# State Update - Opcode + JSON Array（保留 playerID 字串）

此文件記錄 WebSocket 傳輸的第一階段封包縮減目標：
使用「opcode + JSON array」取代原本的 JSON 物件格式，並保留 `playerID` 字串。

## 狀態

- 目標：作為 **階段一** 的封包優化
- 仍使用 JSON（不引入 MessagePack）
- `playerID` 維持字串（尚未改成 playerIndex）
- 暫不取代既有 `StateUpdate` 格式（需能力協商/版本切換）

## 目的

- 降低高頻 diff 同步的 payload 大小
- 保留可讀性與除錯友善度（Wireshark / console 仍可直接觀察）
- 最小化改動成本，先穩定協定與同步模型

## 封包結構（概觀）

```json
[MSG_DIFF, PLAYER_UPDATE, "guest-799195",
  [fieldId, OP_SET, 10000, 20000],
  [fieldId2, OP_REMOVE]
]
```

欄位說明：

- `MSG_DIFF`: 封包層級 opcode（diff 更新）
- `PLAYER_UPDATE`: 子類型/範圍 opcode（例如玩家視角更新）
- `playerID`: 玩家 ID 字串（保留）
- 後續項目：每筆變更的 patch 陣列

### 目前實作（v1）

第一版實作的實際輸出為：

```json
[updateOpcode, playerID,
  [path, op, value?],
  [path, op]
]
```

- `updateOpcode`: `StateUpdateOpcode`（`0 = noChange`, `1 = firstSync`, `2 = diff`）
- `op`: `StatePatchOpcode`（`1 = set`, `2 = remove`, `3 = add`）
- `path`: JSON Pointer 字串（暫代 `fieldId`）

### Patch 陣列格式

- `OP_SET`: 設值，後面依欄位型別附上參數
  - 例：`[fieldId, OP_SET, x, y]`
- `OP_REMOVE`: 移除
  - 例：`[fieldId, OP_REMOVE]`
- `OP_ADD`: 新增
  - 例：`[fieldId, OP_ADD, value]`

`fieldId` 與 `OP_*` 的實際數值由協議常數定義；
`OP_SET` 的參數個數由欄位型別決定（例如 position 使用 2 個整數）。

**第一版實作說明：**

- `fieldId` 尚未導入時，patch 會使用 `path` 字串作為第一欄位
- opcodes 以整數輸出，但 patch 語意仍與現有 JSON Patch 對應

## 與現有 JSON 物件格式的對照

現行 `StateUpdate`：

```json
{
  "type": "diff",
  "patches": [
    { "op": "replace", "path": "/players/guest-799195/position", "value": { "x": 10000, "y": 20000 } },
    { "op": "remove", "path": "/players/guest-799195/target" }
  ]
}
```

目標 opcode 陣列：

```json
[MSG_DIFF, PLAYER_UPDATE, "guest-799195",
  [fieldIdForPosition, OP_SET, 10000, 20000],
  [fieldIdForTarget, OP_REMOVE]
]
```

## 適用階段

- Prototype / 初期：先穩定 diff 結構與同步語意
- Beta / 壓測：再切換 MessagePack（結構不變）
- 上線 / 高頻同步：進一步改為 playerIndex

## 後續演進

1. **MessagePack**：保留結構、改編碼
2. **playerIndex**：join 時建立 `index ↔ playerID` 映射

此文件僅描述 **階段一** 的目標，不代表最終協定定稿。

## 設定方式（程式碼）

第一版以程式碼指定編碼組合，可選擇：

- `TransportEncoding.message`
- `StateUpdateEncoding.stateUpdate`

範例：

```swift
let config = TransportEncodingConfig(
    message: .json,
    stateUpdate: .opcodeJsonArray
)
```

啟動時 logger 會輸出目前使用的 `messageEncoding` 與 `stateUpdateEncoding`。

## 實測紀錄（Hero Defense / 1 玩家 / 180 秒 / 1 怪物生成）
**測試日期**: 2026-01-11
**測試環境**: GameDemo (localhost), 1 Player, 固定每次生成 1 隻怪物

### 測試結果比較

| 項目 | JSON Object (Baseline) | Opcode JSON Array (Legacy) | Opcode JSON Array (PathHash) |
|------|------------------------|----------------------------|------------------------------|
| **平均封包大小** | **1789.86 bytes** | **1208.84 bytes** | **955.89 bytes** |
| **vs Baseline** | - | **↓ 32.5%** | **↓ 46.6%** |
| **vs Legacy** | - | - | **↓ 20.9%** |

### 詳細數據

#### 1. JSON Object (Baseline)
- 平均大小: 1789.86 bytes/封包
- 每秒流量: ~17.89 KB/s

#### 2. Opcode JSON Array (Legacy)
- 格式: `[path, op, value]`
- 平均大小: 1208.84 bytes/封包
- 每秒流量: ~12.08 KB/s
- 改善: 比 Baseline 減少 32.5%

#### 3. Opcode JSON Array (PathHash)
- 格式: `[pathHash, dynamicKey, op, value]`
- 平均大小: 955.89 bytes/封包
- 每秒流量: ~9.55 KB/s
- 改善: 比 Baseline 減少 46.6%，比 Legacy 減少 20.9%

### 結論

PathHash 優化成功將封包大小進一步壓縮。在不改變 JSON 傳輸格式的前提下，僅透過將 path string 替換為 hash (UInt32)，就獲得了額外 20% 的頻寬節省。

整體而言，相較於原始的 JSON Object 格式，新的 **Opcode + PathHash 格式減少了近一半 (46.6%) 的流量**。

### 下一步
- 考慮導入 MessagePack 進一步壓縮 (binary encoding)。
- 考慮將 playerID 優化為 playerIndex。

---

### 測試 2（Hero Defense / 1 玩家 / 180 秒 / 動態怪物生成）
**測試日期**: 2026-01-14
**測試環境**: GameDemo (localhost), 1 Player, 動態怪物生成
**PathHash 狀態**: ✅ 已啟用 (54 個 pathHashes)

#### 測試結果比較

| 項目 | JSON Object (Baseline) | Opcode JSON Array (PathHash) |
|------|------------------------|------------------------------|
| **平均封包大小** | **1773.70 bytes** | **1790.29 bytes** |
| **vs Baseline** | - | **↑ 0.94%** |
| **累計封包數** | 1798 個 | 1800 個 |
| **每秒封包數** | 9.99 個/s | 10.00 個/s |

#### 詳細數據

##### 1. JSON Object (Baseline)
- 平均大小: 1773.70 bytes/封包
- 累計流量: 3.04 MB (17717.24 B/s)
- 累計封包: 1798 個 (9.99 個/s)

##### 2. Opcode JSON Array (PathHash)
- 格式: `[pathHash, dynamicKey, op, value]`
- 平均大小: 1790.29 bytes/封包
- 累計流量: 3.07 MB (17902.89 B/s)
- 累計封包: 1800 個 (10.00 個/s)
- 相對 Baseline: 增加 0.94%

#### 觀察與分析

本次測試中，Opcode JSON Array (PathHash) 模式的封包大小略大於 JSON Object 模式。可能原因：

1. **遊戲狀態複雜度**: 動態怪物生成可能導致狀態更新更頻繁，PathHash 格式的額外結構開銷（pathHash + dynamicKey）在某些情況下可能超過 path string 的長度
2. **測試環境差異**: 與測試 1 相比，本次測試使用動態怪物生成，遊戲狀態變化模式可能不同
3. **編碼優化**: PathHash 的優勢在 path string 較長時更明顯，當 path 較短時，hash (UInt32) + dynamicKey 的組合可能不如直接使用 path string 節省空間

#### 結論

PathHash 優化在測試 1 中顯示出顯著的頻寬節省（46.6%），但在測試 2 中表現略遜於 Baseline。這表明：

- PathHash 的壓縮效果與遊戲狀態的具體模式相關
- 當 path string 較短或狀態更新模式不同時，PathHash 的優勢可能不明顯
- 需要進一步優化編碼策略，根據實際 path 長度動態選擇使用 pathHash 或 path string

### 下一步（更新）
- 考慮導入 MessagePack 進一步壓縮 (binary encoding)。
- 考慮將 playerID 優化為 playerIndex。
- 優化 PathHash 編碼策略，根據 path 長度動態選擇編碼方式。

---

## 封包結構分析：PathHash 在 JSON 中變大的原因

### 問題拆解

#### 1. PathHash 格式的實際編碼開銷

**PathHash 格式：** `[pathHash, dynamicKey, op, value?]`

實際 JSON 編碼範例：
```json
[2, "guest-799195", [2558331159, [0, "guest-799195"], 1, 100]]
```

拆解分析：
- `2`: diff opcode (1 字符)
- `"guest-799195"`: playerID (15 字符)
- `[2558331159, [0, "guest-799195"], 1, 100]`: patch 陣列
  - `2558331159`: pathHash (10 字符) - **問題：UInt32 在 JSON 中是 10 字符，而不是 4 bytes**
  - `[0, "guest-799195"]`: dynamicKey 第一次定義 (20+ 字符) - **問題：第一次定義時需要包含完整 key**
  - `1`: opcode (1 字符)
  - `100`: value (3 字符)
  - 陣列結構符號: `[`, `]`, `,`, 空格等 (~10 字符)

**總計：** 約 60+ 字符

#### 2. JSON Object 格式的實際編碼

**JSON Object 格式：**
```json
{"type":"diff","patches":[{"op":"replace","path":"/players/guest-799195/hp","value":100}]}
```

拆解分析：
- `{"type":"diff","patches":[`: 結構開銷 (~25 字符)
- `{"op":"replace","path":"/players/guest-799195/hp","value":100}`: patch 物件
  - `"op":"replace"`: 13 字符
  - `"path":"/players/guest-799195/hp"`: 35 字符
  - `"value":100`: 10 字符
  - 結構符號: `{`, `}`, `,`, `:` (~5 字符)

**總計：** 約 88 字符

### 關鍵問題分析

#### 問題 1：dynamicKey 第一次定義的開銷
- **PathHash**: `[0, "guest-799195"]` = 20+ 字符（需要包含 slot 和完整 key）
- **JSON Object**: 直接使用 path string，雖然長但結構簡單

#### 問題 2：pathHash 在 JSON 中的大小（**主要問題**）
- **UInt32** (例如 2558331159) 在 JSON 中是 **10 個字符**
- 在二進制格式中只需要 **4 bytes**
- **損失：** 60% 的空間效率

#### 問題 3：陣列 vs 物件的 JSON 開銷
- JSON 陣列需要 `[`, `]`, `,` 等符號
- JSON 物件需要 `{`, `}`, `:`, `,` 等符號
- PathHash 格式有 4 個元素，JSON Object 只有 3 個欄位

### MessagePack 的預期影響

#### MessagePack 的優勢

1. **數字編碼**
   - UInt32 (2558331159) 在 JSON: 10 字符
   - UInt32 在 MessagePack: 4 bytes (uint32)
   - **節省：** 60%

2. **字串編碼**
   - 字串在 JSON: `"guest-799195"` = 15 字符
   - 字串在 MessagePack: 1 byte (str8 header) + 13 bytes (內容) = 14 bytes
   - **節省：** 約 7%

3. **陣列編碼**
   - JSON 陣列: `[2558331159, [0, "guest-799195"], 1, 100]` = ~50 字符
   - MessagePack 陣列: 1 byte (array header) + 內容 = ~25 bytes
   - **節省：** 約 50%

4. **結構開銷**
   - JSON 需要 `[`, `]`, `,`, `:`, `"` 等符號
   - MessagePack 使用類型標記，開銷更小

#### 預估改善

**PathHash + MessagePack vs PathHash + JSON:**
- pathHash: 10 字符 → 4 bytes (**60% 節省**)
- dynamicKey 陣列: ~20 字符 → ~12 bytes (**40% 節省**)
- 整體封包: 預估 **40-50% 節省**

**PathHash + MessagePack vs JSON Object + JSON:**
- 預估 **50-60% 節省**

### 結論

1. **PathHash 在 JSON 中變大的主要原因：**
   - ✅ dynamicKey 第一次定義時使用 `[slot, "key"]` 格式，開銷較大
   - ✅ **pathHash (UInt32) 在 JSON 中是 10 字符，而不是 4 bytes（這是主要問題）**
   - ✅ JSON 陣列的結構開銷

2. **MessagePack 的影響：**
   - ✅ 會大幅改善 PathHash 格式的表現
   - ✅ 預估可以達到 **40-50% 的額外節省**
   - ✅ 特別是在數字和陣列編碼上，MessagePack 的優勢非常明顯

3. **建議：**
   - 🎯 **優先導入 MessagePack**：PathHash 格式在 MessagePack 中的優勢會非常明顯
   - 🎯 考慮優化 dynamicKey 的編碼策略（例如使用更短的 key 或更好的壓縮）
   - 🎯 MessagePack 導入後，預期 PathHash 格式可以達到比 JSON Object 更好的壓縮效果

---

## 為什麼實際測試結果和理論分析有差異？

### 問題：理論分析顯示 PathHash 應該更小，但實際測試結果卻差不多

**測試數據：**
- JSON Object: 1773.70 bytes/封包
- PathHash: 1790.29 bytes/封包（反而大了 0.94%）

### 實際封包分析

#### 1. 實際封包中的 Patches 數量

**估算每個封包的 patches 數量：**
- 平均每個 patch 大小：
  - JSON Object: 約 60-80 bytes（包含完整 path）
  - PathHash (首次定義): 約 50-60 bytes（包含 dynamicKey 定義）
  - PathHash (後續更新): 約 30-40 bytes（只有 slot）

**估算結果：**
- JSON Object: 1773 / 70 ≈ **25 個 patches/封包**
- PathHash: 1790 / 45 ≈ **40 個 patches/封包**（如果都是首次定義）

#### 2. 關鍵問題：dynamicKey 定義的累積開銷

**PathHash 格式的問題：**
- 每次遇到新的 dynamicKey（如新的 playerID、monsterID、turretID），都需要定義一次
- 定義格式：`[slot, "key"]` = 約 20 字符
- 在實際遊戲中，可能有很多不同的 key：
  - 玩家 ID: `guest-799195`
  - 怪物 ID: `1`, `2`, `3`, ...（動態生成）
  - 砲塔 ID: `1`, `2`, `3`, ...（動態生成）

**實際場景分析：**
假設一個封包包含：
- 1 個玩家更新（5 個 patches：position.x, position.y, health, resources, rotation）
- 5 個怪物更新（每個怪物 3 個 patches：position.x, position.y, health）
- 2 個砲塔更新（每個砲塔 2 個 patches：position.x, rotation）
- 1 個 base 更新（2 個 patches：health, position.x）

**總計：約 23 個 patches**

**dynamicKey 定義開銷：**
- 如果這些都是第一次出現：
  - 1 個玩家 ID 定義
  - 5 個怪物 ID 定義（新怪物不斷生成）
  - 2 個砲塔 ID 定義
  - **總計：8 個 dynamicKey 定義**
  - 每個定義約 20 字符，總計約 **160 字符的額外開銷**

#### 3. 為什麼理論分析顯示 PathHash 更小？

**理論分析的假設：**
- ✅ 只考慮單個 patch 的比較
- ✅ 假設 dynamicKey 已經定義過（後續更新）
- ✅ 假設 path 較長（如 `players.*.position.v.x` = 35 字符）

**實際情況：**
- ❌ 封包包含多個 patches（平均 25-40 個）
- ❌ 很多 dynamicKey 是第一次定義（新實體不斷出現）
- ❌ 有些 path 較短（如 `players.*.health` = 20 字符）

#### 4. 實際遊戲狀態更新的特點

**GameDemo 的實際更新模式：**
1. **玩家更新**：位置、旋轉、生命值等（每個玩家多個欄位）
2. **怪物更新**：位置、生命值、進度等（每個怪物多個欄位）
   - ⚠️ **關鍵**：在動態怪物生成場景中，新怪物不斷出現
   - 每個新怪物都需要定義 dynamicKey
3. **砲塔更新**：位置、旋轉、等級等（每個砲塔多個欄位）
4. **Base 更新**：生命值、位置等

**關鍵觀察：**
- 在動態遊戲中，新實體（怪物、砲塔）不斷出現
- 每個新實體都需要定義 dynamicKey
- 定義開銷累積：`[slot, "key"]` 比直接使用 path string 在某些情況下更大

### 結論：為什麼實際測試結果和理論分析有差異

**主要原因：**

1. ✅ **dynamicKey 定義開銷累積**
   - 在動態遊戲中，新實體（怪物、砲塔）不斷出現
   - 每個新實體都需要定義 dynamicKey
   - 定義開銷：`[slot, "key"]` 累積後可能超過 path string 的開銷

2. ✅ **PathHash 在 JSON 中的開銷**
   - UInt32 hash (10 字符) 在 JSON 中比預期大
   - 陣列格式的結構開銷（`[`, `]`, `,`）累積

3. ✅ **實際更新模式**
   - 可能有很多短 path（如 `players.*.health` = 20 字符）
   - 短 path 時，PathHash 的優勢不明顯
   - 長 path 時（如 `players.*.position.v.x` = 35 字符），PathHash 才有明顯優勢

4. ✅ **JSON 編碼的實際行為**
   - JSON 編碼器可能有優化
   - 物件格式和陣列格式的實際編碼開銷可能相近

### MessagePack 的影響

**MessagePack 可以解決這些問題：**

1. **數字編碼改善**
   - UInt32: 10 字符 → 4 bytes（**60% 節省**）
   - 這會大幅減少 pathHash 的開銷

2. **dynamicKey 定義改善**
   - `[slot, "key"]`: 20 字符 → 12 bytes（**40% 節省**）
   - 這會減少定義開銷的累積影響

3. **陣列編碼改善**
   - JSON 陣列結構開銷 → MessagePack 類型標記（**約 50% 節省**）

**預期改善：**
- PathHash + MessagePack vs PathHash + JSON: **40-50% 節省**
- PathHash + MessagePack vs JSON Object + JSON: **50-60% 節省**

**結論：**
- PathHash 在 JSON 中表現不佳的主要原因是 JSON 編碼的開銷（特別是數字和陣列）
- MessagePack 導入後，PathHash 的優勢會非常明顯
- 這也解釋了為什麼測試 1（固定怪物生成）中 PathHash 表現更好，而測試 2（動態怪物生成）中表現較差
