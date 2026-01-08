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
[MSG_DIFF, land, PLAYER_UPDATE, "guest-799195",
  [fieldId, OP_SET, 10000, 20000],
  [fieldId2, OP_CLEAR]
]
```

欄位說明：

- `MSG_DIFF`: 封包層級 opcode（diff 更新）
- `land`: Land 識別（沿用現行傳輸語意）
- `PLAYER_UPDATE`: 子類型/範圍 opcode（例如玩家視角更新）
- `playerID`: 玩家 ID 字串（保留）
- 後續項目：每筆變更的 patch 陣列

### Patch 陣列格式

- `OP_SET`: 設值，後面依欄位型別附上參數
  - 例：`[fieldId, OP_SET, x, y]`
- `OP_CLEAR`: 清除
  - 例：`[fieldId, OP_CLEAR]`

`fieldId` 與 `OP_*` 的實際數值由協議常數定義；
`OP_SET` 的參數個數由欄位型別決定（例如 position 使用 2 個整數）。

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
[MSG_DIFF, land, PLAYER_UPDATE, "guest-799195",
  [fieldIdForPosition, OP_SET, 10000, 20000],
  [fieldIdForTarget, OP_CLEAR]
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
