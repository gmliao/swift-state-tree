# GameDemo Protocol 比較：State Update、Action、Event

本文檔使用 GameDemo 的實際 Schema 來比較不同編碼格式的 protocol 差異。

## Schema 資訊

- **Land Type**: `hero-defense`
- **PathHashes**: 54 個（已啟用）
- **Client Event Hashes**: 
  - `MoveTo`: 1
  - `PlaceTurret`: 2
  - `Shoot`: 3
  - `UpdateRotation`: 4
  - `UpgradeTurret`: 5
  - `UpgradeWeapon`: 6
- **Server Event Hashes**:
  - `PlayerShoot`: 1
  - `TurretFire`: 2

---

## 1. State Update（狀態更新）

### 場景：更新玩家位置和生命值

假設更新：
- 玩家 `guest-799195` 的位置：`position.v.x = 50000`, `position.v.y = 30000`
- 玩家 `guest-799195` 的生命值：`health = 85`

### 1.1 JSON Object 格式

```json
{
  "type": "diff",
  "patches": [
    {
      "op": "replace",
      "path": "/players/guest-799195/position/v/x",
      "value": 50000
    },
    {
      "op": "replace",
      "path": "/players/guest-799195/position/v/y",
      "value": 30000
    },
    {
      "op": "replace",
      "path": "/players/guest-799195/health",
      "value": 85
    }
  ]
}
```

**大小分析：**
- 結構開銷：`{"type":"diff","patches":[` = ~25 字符
- Patch 1: `{"op":"replace","path":"/players/guest-799195/position/v/x","value":50000}` = ~65 字符
- Patch 2: `{"op":"replace","path":"/players/guest-799195/position/v/y","value":30000}` = ~65 字符
- Patch 3: `{"op":"replace","path":"/players/guest-799195/health","value":85}` = ~60 字符
- **總計：約 215 字符**

### 1.2 PathHash 格式（Opcode JSON Array）

```json
[
  2,
  "guest-799195",
  [2079215419, [0, "guest-799195"], 1, 50000],
  [2079214216, [0, "guest-799195"], 1, 30000],
  [2520354134, [0, "guest-799195"], 1, 85]
]
```

**拆解：**
- `2`: diff opcode (1 字符)
- `"guest-799195"`: playerID (15 字符)
- `[2079215419, [0, "guest-799195"], 1, 50000]`: 
  - `2079215419`: pathHash for `players.*.position.v.x` (10 字符)
  - `[0, "guest-799195"]`: dynamicKey 第一次定義 (20 字符)
  - `1`: opcode set (1 字符)
  - `50000`: value (5 字符)
  - 陣列結構: ~10 字符
  - **小計：約 46 字符**
- `[2079214216, [0, "guest-799195"], 1, 30000]`: 約 46 字符
- `[2079214216, [0, "guest-799195"], 1, 85]`: 約 44 字符

**總計：約 152 字符**

**注意：** 如果 dynamicKey 已經定義過（後續更新），格式會變成：
```json
[
  2,
  "guest-799195",
  [2079215419, 0, 1, 50000],
  [2079214216, 0, 1, 30000],
  [2520354134, 0, 1, 85]
]
```
**總計：約 92 字符**（節省 40%）

### 1.3 比較總結

| 格式 | 第一次更新 | 後續更新 | 節省 |
|------|-----------|---------|------|
| JSON Object | 215 字符 | 215 字符 | - |
| PathHash (首次) | 152 字符 | - | ↓ 29% |
| PathHash (後續) | - | 92 字符 | ↓ 57% |

**PathHash 的優勢：**
- ✅ 後續更新時，dynamicKey 只需傳遞 slot (0)，而不是完整 key
- ✅ pathHash (10 字符) 比完整 path (35+ 字符) 短
- ⚠️ 但第一次定義時，`[slot, "key"]` 的開銷較大

---

## 2. Action（動作）

### 場景：執行 PlayAction（無參數）

### 2.1 JSON 格式

```json
{
  "kind": "action",
  "payload": {
    "action": {
      "typeIdentifier": "PlayAction",
      "payload": {}
    },
    "requestID": "req-1234567890"
  }
}
```

**大小分析：**
- 結構開銷：`{"kind":"action","payload":{"action":{"typeIdentifier":"PlayAction","payload":{},"requestID":"req-1234567890"}}` = ~95 字符
- **總計：約 95 字符**

### 2.2 Opcode JSON Array 格式

```json
[
  101,
  "req-1234567890",
  "PlayAction",
  {}
]
```

**拆解：**
- `101`: action opcode (3 字符)
- `"req-1234567890"`: requestID (15 字符)
- `"PlayAction"`: typeIdentifier (11 字符)
- `{}`: payload (2 字符)
- 陣列結構: ~5 字符

**總計：約 36 字符**

### 2.3 比較總結

| 格式 | 大小 | 節省 |
|------|------|------|
| JSON Object | 95 字符 | - |
| Opcode JSON Array | 36 字符 | ↓ 62% |

**Opcode 格式的優勢：**
- ✅ 大幅減少結構開銷
- ✅ 使用數字 opcode 而非字串 `"kind"`
- ✅ 陣列格式更緊湊

---

## 3. Event（事件）

### 3.1 Client Event：MoveToEvent

#### JSON 格式

```json
{
  "kind": "event",
  "payload": {
    "event": {
      "type": "MoveToEvent",
      "payload": {
        "target": {
          "v": {
            "x": 50000,
            "y": 30000
          }
        }
      }
    }
  }
}
```

**大小分析：**
- 結構開銷：`{"kind":"event","payload":{"event":{"type":"MoveToEvent","payload":{"target":{"v":{"x":50000,"y":30000}}}}}}` = ~95 字符
- **總計：約 95 字符**

#### Opcode JSON Array 格式（無 Hash）

```json
[
  103,
  0,
  "MoveToEvent",
  {
    "target": {
      "v": {
        "x": 50000,
        "y": 30000
      }
    }
  }
]
```

**拆解：**
- `103`: event opcode (3 字符)
- `0`: direction (0 = fromClient) (1 字符)
- `"MoveToEvent"`: type (12 字符)
- payload object: ~45 字符
- 陣列結構: ~5 字符

**總計：約 66 字符**

#### Opcode JSON Array 格式（使用 Hash）

```json
[
  103,
  0,
  1,
  {
    "target": {
      "v": {
        "x": 50000,
        "y": 30000
      }
    }
  }
]
```

**拆解：**
- `103`: event opcode (3 字符)
- `0`: direction (1 字符)
- `1`: type hash (MoveTo = 1) (1 字符)
- payload object: ~45 字符
- 陣列結構: ~5 字符

**總計：約 55 字符**

### 3.2 Client Event：ShootEvent（無參數）

#### JSON 格式

```json
{
  "kind": "event",
  "payload": {
    "event": {
      "type": "ShootEvent",
      "payload": {}
    }
  }
}
```

**總計：約 70 字符**

#### Opcode JSON Array 格式（使用 Hash）

```json
[
  103,
  0,
  3,
  {}
]
```

**總計：約 12 字符**（節省 83%）

### 3.3 Server Event：PlayerShootEvent

#### JSON 格式

```json
{
  "kind": "event",
  "payload": {
    "event": {
      "type": "PlayerShootEvent",
      "payload": {
        "playerID": "guest-799195",
        "from": {
          "v": {
            "x": 50000,
            "y": 30000
          }
        },
        "to": {
          "v": {
            "x": 60000,
            "y": 40000
          }
        }
      }
    }
  }
}
```

**總計：約 180 字符**

#### Opcode JSON Array 格式（使用 Hash）

```json
[
  103,
  1,
  1,
  {
    "playerID": "guest-799195",
    "from": {
      "v": {
        "x": 50000,
        "y": 30000
      }
    },
    "to": {
      "v": {
        "x": 60000,
        "y": 40000
      }
    }
  }
]
```

**總計：約 140 字符**（節省 22%）

### 3.4 比較總結

| Event 類型 | JSON 格式 | Opcode (無 Hash) | Opcode (Hash) | 節省 |
|-----------|-----------|------------------|---------------|------|
| MoveToEvent | 95 字符 | 66 字符 | 55 字符 | ↓ 42% |
| ShootEvent | 70 字符 | 25 字符 | 12 字符 | ↓ 83% |
| PlayerShootEvent | 180 字符 | 150 字符 | 140 字符 | ↓ 22% |

**Opcode 格式的優勢：**
- ✅ 使用數字 opcode 和 hash，減少字串開銷
- ✅ 陣列格式比物件格式更緊湊
- ✅ 無參數事件（如 ShootEvent）節省最多

---

## 4. 完整 Protocol 比較表

### 4.1 編碼格式對照

| 類型 | JSON Object | Opcode JSON Array | Opcode + Hash |
|------|-------------|-------------------|---------------|
| **State Update** | ✅ | ✅ (PathHash) | ✅ (PathHash) |
| **Action** | ✅ | ✅ | - |
| **Event** | ✅ | ✅ | ✅ (Event Hash) |

### 4.2 大小比較（典型場景）

| 場景 | JSON Object | Opcode JSON Array | 節省 |
|------|-------------|-------------------|------|
| State Update (3 patches, 首次) | 215 字符 | 152 字符 | ↓ 29% |
| State Update (3 patches, 後續) | 215 字符 | 92 字符 | ↓ 57% |
| Action (PlayAction) | 95 字符 | 36 字符 | ↓ 62% |
| Event (MoveToEvent) | 95 字符 | 55 字符 | ↓ 42% |
| Event (ShootEvent) | 70 字符 | 12 字符 | ↓ 83% |
| Event (PlayerShootEvent) | 180 字符 | 140 字符 | ↓ 22% |

### 4.3 關鍵差異點

#### State Update
- **JSON Object**: 使用完整 JSON Pointer path，結構清晰但較大
- **PathHash**: 使用 hash + dynamicKey，首次定義時開銷較大，後續更新時優勢明顯

#### Action
- **JSON Object**: 完整的物件結構，包含 `kind`、`payload` 等欄位
- **Opcode Array**: 緊湊的陣列格式，`[opcode, requestID, typeIdentifier, payload]`

#### Event
- **JSON Object**: 完整的物件結構
- **Opcode Array**: `[opcode, direction, type/hash, payload]`
- **使用 Hash**: 將事件類型從字串（如 `"MoveToEvent"`）改為數字（如 `1`）

---

## 5. MessagePack 預期影響

### 5.1 數字編碼改善

| 項目 | JSON | MessagePack | 改善 |
|------|------|-------------|------|
| pathHash (UInt32) | 10 字符 | 4 bytes | ↓ 60% |
| Event Hash (Int) | 1-2 字符 | 1 byte | ↓ 50% |
| Opcode (Int) | 3 字符 | 1 byte | ↓ 67% |

### 5.2 預估整體改善

| 格式 | JSON 大小 | MessagePack 預估 | 改善 |
|------|-----------|------------------|------|
| State Update (PathHash, 後續) | 92 字符 | ~50 bytes | ↓ 46% |
| Action (PlayAction) | 36 字符 | ~20 bytes | ↓ 44% |
| Event (ShootEvent) | 12 字符 | ~8 bytes | ↓ 33% |

**結論：** MessagePack 導入後，PathHash 和 Opcode 格式的優勢會更加明顯。

---

## 6. 實際使用建議

### 6.1 推薦配置

**生產環境：**
- State Update: `opcodeJsonArray` + PathHash ✅
- Action/Event: `opcodeJsonArray` + Event Hash ✅
- 未來：MessagePack 編碼 ✅

**開發/調試環境：**
- State Update: `jsonObject`（可讀性高）
- Action/Event: `json`（可讀性高）

### 6.2 性能優化重點

1. **State Update**: PathHash 在後續更新時優勢明顯（57% 節省）
2. **Action**: Opcode 格式節省 62%
3. **Event**: 無參數事件節省最多（83%），有參數事件也有 20-40% 節省
4. **MessagePack**: 預期可再節省 30-50%

---

## 附錄：實際 PathHash 對照表（GameDemo）

| Path Pattern | Hash | 範例完整 Path |
|-------------|------|--------------|
| `players.*.position.v.x` | 2079215419 | `/players/guest-799195/position/v/x` |
| `players.*.position.v.y` | 2079214216 | `/players/guest-799195/position/v/y` |
| `players.*.health` | 2520354134 | `/players/guest-799195/health` |
| `players.*.resources` | 4001719203 | `/players/guest-799195/resources` |
| `monsters.*.position.v.x` | 447229454 | `/monsters/1/position/v/x` |
| `turrets.*.position.v.x` | 2678658541 | `/turrets/1/position/v/x` |
