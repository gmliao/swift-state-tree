# SwiftStateTree — Protocol Schema v0

（Land / Node / Tree / Action / Event 型別 Schema）

> 本文件定義 SwiftStateTree Server 導出的 **Schema 格式**，
> 用於：
>
> * TypeScript SDK 產生器（codegen）
> * Playground / DevTool 自動產 UI
> * 測試 / 模擬器（mock server / mock client）
> * API 文件自動化生成

Schema 格式採 **JSON Schema + 自訂擴充欄位 `x-stateTree`**
以同時支援型別安全（TS）與 StateTree-specific metadata。

---

# 1. Schema 總覽（Server `/schema` Endpoint 回傳）

Server 提供一個 REST Endpoint：

```
GET /schema
```

回傳 JSON：

```jsonc
{
  "version": "0.1.0",
  "lands": {
    "MatchLand": {
      "stateType": "MatchLandState",
      "actions": {
        "match.join": { "$ref": "#/defs/MatchJoinPayload" },
        "match.ready": { "$ref": "#/defs/EmptyPayload" }
      },
      "events": {
        "match.start": { "$ref": "#/defs/MatchStartEvent" }
      },
      "sync": {
        "snapshot": { "$ref": "#/defs/MatchLandState" },
        "diff": { "$ref": "#/defs/MatchLandDiff" }
      }
    }
  },
  "defs": {
    "... 型別定義們 ...": {}
  }
}
```

## Schema 主體包含三大區塊

### 1. `lands`

描述每個 Land 的：

* 狀態樹 root 型別
* Action（client → server）
* Event  （server → client）
* Sync 相關 payload 型別

### 2. `defs`

所有型別（Node / State / Payload）的 JSON Schema 定義

### 3. `version`

schema 版本（給 TS SDK 與 Playground 測相容性用）

---

# 2. Land 區塊格式（lands）

每個 land 形如下：

```jsonc
"MatchLand": {
  "stateType": "MatchLandState",
  "actions": {
    "match.join": { "$ref": "#/defs/MatchJoinPayload" },
    "match.ready": { "$ref": "#/defs/EmptyPayload" }
  },
  "events": {
    "match.start": { "$ref": "#/defs/MatchStartEvent" }
  },
  "sync": {
    "snapshot": { "$ref": "#/defs/MatchLandState" },
    "diff": { "$ref": "#/defs/MatchLandDiff" }
  }
}
```

## 說明

### `stateType`

* Root 狀態樹的型別名稱
* 對應 `defs` 裡的某個型別

### `actions`

Action ID → Payload Schema

Action ID 全域唯一，建議命名：

```
<domain>.<action>
match.join
match.ready
lobby.createRoom
card.draw
```

### `events`

ServerEvent ID → Payload Schema

### `sync`

專門給 State Sync 使用：

* `snapshot`：完整樹（state = defs.MatchLandState）
* `diff`：差異 patch（格式你定義即可）

---

# 3. defs — 所有型別（Tree / Node / Payload）

每個型別是一個 JSON Schema，外加 SwiftStateTree 專用 metadata：

```jsonc
{
  "type": "object",
  "properties": { ... },
  "required": [ ... ],

  "x-stateTree": {
    "nodeKind": "object | map | array | leaf",
    "landRoot": true | false,
    "sync": "broadcast | perPlayer | serverOnly | custom",
    "keyType": "PlayerID | String | Int",       // map 專用
    "path": "players/*/pos"                     // optional，未來 debug/工具用
  }
}
```

### 自訂欄位說明（x-stateTree）

| 欄位         | 說明                                             |
| ---------- | ---------------------------------------------- |
| `nodeKind` | SwiftStateTree Node 類型：`object/map/array/leaf` |
| `landRoot` | 是否為 Land 的狀態樹根                                 |
| `sync`     | Sync policy（對應 Swift @Sync）                    |
| `keyType`  | Map 的 key 型別                                   |
| `path`     | 樹中位置（可選，用於 debug）                              |

這允許 Client 根據 tree metadata 做：

* 更好的 DevTool 顯示
* TS 型別生成時可加入 sync 訊息提示
* Debugger 可顯示樹狀 Navigation

---

# 4. 完整範例（MatchLandState）

以下是一個可實際用于 TS codegen 的完整例子。

```jsonc
{
  "version": "0.1.0",
  "lands": {
    "MatchLand": {
      "stateType": "MatchLandState",
      "actions": {
        "match.join": { "$ref": "#/defs/MatchJoinPayload" },
        "match.ready": { "$ref": "#/defs/EmptyPayload" }
      },
      "events": {
        "match.start": { "$ref": "#/defs/MatchStartEvent" }
      },
      "sync": {
        "snapshot": { "$ref": "#/defs/MatchLandState" },
        "diff": { "$ref": "#/defs/MatchLandDiff" }
      }
    }
  },

  "defs": {
    "EmptyPayload": {
      "type": "object",
      "properties": {},
      "x-stateTree": { "nodeKind": "leaf" }
    },

    "MatchJoinPayload": {
      "type": "object",
      "properties": {
        "playerId": { "type": "string" },
        "nickname": { "type": "string" }
      },
      "required": ["playerId"],
      "x-stateTree": { "nodeKind": "leaf" }
    },

    "MatchStartEvent": {
      "type": "object",
      "properties": {
        "startAt": { "type": "number" }
      },
      "required": ["startAt"],
      "x-stateTree": { "nodeKind": "leaf" }
    },

    "MatchLandState": {
      "type": "object",
      "properties": {
        "players": {
          "type": "object",
          "additionalProperties": { "$ref": "#/defs/PlayerState" },
          "x-stateTree": {
            "nodeKind": "map",
            "keyType": "PlayerID",
            "sync": "perPlayer"
          }
        },
        "round": { "type": "integer" }
      },
      "required": ["players"],
      "x-stateTree": {
        "nodeKind": "object",
        "landRoot": true
      }
    },

    "PlayerState": {
      "type": "object",
      "properties": {
        "id": { "type": "string" },
        "hp": { "type": "integer" },
        "pos": { "$ref": "#/defs/Vec2" }
      },
      "required": ["id", "hp"],
      "x-stateTree": {
        "nodeKind": "object"
      }
    },

    "Vec2": {
      "type": "object",
      "properties": {
        "x": { "type": "number" },
        "y": { "type": "number" }
      },
      "required": ["x", "y"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    },

    "MatchLandDiff": {
      "type": "object",
      "properties": {
        "patches": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "op": { "type": "string" },
              "path": { "type": "string" },
              "value": {}
            },
            "required": ["op", "path"]
          }
        }
      },
      "required": ["patches"],
      "x-stateTree": { "nodeKind": "leaf" }
    }
  }
}
```

---

# 5. Schema Source：如何從 Land DSL 產生

這份 schema 可以手寫，但最終會：

1. **從 Swift Land DSL AST 解析**
2. 自動產生：

   * `lands.<name>.actions`（從 @Action macro）
   * `lands.<name>.events`
   * `lands.<name>.stateType`
   * `defs.<State>`（從 @StateTreeBuilder / property wrapper 推導）
   * `x-stateTree.sync`（從 @Sync 推導）

這樣的 pipeline：

```
Land DSL → SwiftSyntax Macro AST → ProtocolSchema(JSON) → TS SDK + Playground
```

---

# 6. 用途：這份 Schema 能做到什麼？

### ✔ 1. TS SDK 產生型別安全 API

能產生：

```ts
client.action("match.join", { playerId: "A1", nickname: "Bob" });
client.on("sync.diff", (patch) => ...);
client.state.players["A1"].hp;
```

### ✔ 2. Playground（DevTool）

* 左側：自動從 schema 列出所有 Land / Actions
* 中間：依 payload schema 自動生成表單
* 右側：WebSocket 收送 JSON

### ✔ 3. 自動生成 API 文件（OpenAPI-like）

Schema 可以轉出：

* Action List
* Payload Structure
* 節點型別
* Sync 格式

### ✔ 4. 測試框架可以用 schema 驗證 patch 是否符合定義

---

# 7. 下一步建議


### 開始寫 Server Side 的 `SchemaBuilder.swift`

我會給你可編譯的版本：

```swift
struct ProtocolSchema: Codable { ... }
struct SchemaBuilder {
    static func build() -> ProtocolSchema
}
```

### TS Codegen（`statetree-codegen`）

我可以幫你生出第一版 codegen（Node.js / TS）

### Playground v0（schema-driven）

我可以幫你生 React/Vue UI 骨架

---

