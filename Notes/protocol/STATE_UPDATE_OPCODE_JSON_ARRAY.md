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

## 實測紀錄（Hero Defense / 1 玩家 / 60 秒）

使用 `GameDemo` 的 `hero-defense` Land，單一玩家連線，讓伺服器 tick 1 分鐘後統計收到的 payload bytes。

測試指令：

```bash
# JSON object
cd Examples/GameDemo && PORT=8020 STATE_UPDATE_ENCODING=jsonObject swift run GameServer
cd Tools/CLI && npx tsx scripts/measure-state-updates.ts --url ws://localhost:8020/game/hero-defense --land hero-defense --duration 60

# opcodeJsonArray
cd Examples/GameDemo && PORT=8021 STATE_UPDATE_ENCODING=opcodeJsonArray swift run GameServer
cd Tools/CLI && npx tsx scripts/measure-state-updates.ts --url ws://localhost:8021/game/hero-defense --land hero-defense --duration 60
```

結果摘要：

- JSON object
  - Total: 214,706 bytes
  - StateUpdate: 209,909 bytes / 599 msgs / avg 350.43 bytes
- opcodeJsonArray
  - Total: 137,205 bytes
  - StateUpdate: 132,408 bytes / 598 msgs / avg 221.42 bytes

差異：

- Total 減少約 **36.1%**
- StateUpdate 減少約 **36.9%**（opcode 約為 JSON 的 63.1%）
