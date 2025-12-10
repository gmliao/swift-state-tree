# Schema 定義文件

本文檔定義了 SwiftStateTree 的 Protocol Schema 格式，用於描述 Land、State、Action、Event 的型別結構。

## 目錄

1. [Schema 總覽](#schema-總覽)
2. [TypeScript 類型定義](#typescript-類型定義)
3. [Swift 類型定義](#swift-類型定義)
4. [JSON Schema 格式](#json-schema-格式)
5. [x-stateTree 擴充欄位](#x-statetree-擴充欄位)
6. [完整範例](#完整範例)

## Schema 總覽

Protocol Schema 是一個 JSON 物件，包含以下主要區塊：

```json
{
  "version": "0.1.0",
  "lands": {
    "LandName": {
      "stateType": "StateTypeName",
      "actions": { ... },
      "clientEvents": { ... },
      "events": { ... },
      "sync": { ... }
    }
  },
  "defs": {
    "TypeName": { ... }
  }
}
```

### 主要欄位

- **`version`**: Schema 版本字串（例如 "0.1.0"）
- **`lands`**: 所有 Land 定義的字典，key 為 Land ID
- **`defs`**: 所有型別定義的字典，key 為型別名稱

## TypeScript 類型定義

### Schema 根結構

```typescript
export interface Schema {
  version: string
  defs: Record<string, SchemaDef>
  lands: Record<string, LandDefinition>
}
```

### Land 定義

```typescript
export interface LandDefinition {
  stateType: string
  actions?: Record<string, { $ref: string }>
  clientEvents?: Record<string, { $ref: string }>
  events?: Record<string, { $ref: string }>
  sync?: {
    snapshot?: { $ref: string }
    diff?: { $ref: string }
  }
}
```

**欄位說明：**

- `stateType`: 根狀態樹的型別名稱（對應 `defs` 中的某個型別）
- `actions`: Action ID → Schema 引用（客戶端 → 伺服器）
- `clientEvents`: Client Event ID → Schema 引用（客戶端 → 伺服器）
- `events`: Server Event ID → Schema 引用（伺服器 → 客戶端）
- `sync`: 同步相關的 Schema 引用
  - `snapshot`: 完整狀態快照的 Schema
  - `diff`: 差異補丁的 Schema

### Schema 定義

```typescript
export interface SchemaDef {
  type?: string
  properties?: Record<string, SchemaProperty>
  required?: string[]
  items?: SchemaDef
  additionalProperties?: SchemaDef | boolean
  '$ref'?: string
  'x-stateTree'?: {
    nodeKind?: string
    sync?: {
      policy?: string
    }
  }
}

export interface SchemaProperty {
  type?: string
  properties?: Record<string, SchemaProperty>
  items?: SchemaDef
  additionalProperties?: SchemaDef | boolean
  '$ref'?: string
  'x-stateTree'?: {
    nodeKind?: string
    sync?: {
      policy?: string
    }
  }
}
```

## Swift 類型定義

### ProtocolSchema

```swift
public struct ProtocolSchema: Codable, Sendable {
    public let version: String
    public let lands: [String: LandSchema]
    public let defs: [String: JSONSchema]
    
    public init(
        version: String = "0.1.0",
        lands: [String: LandSchema] = [:],
        defs: [String: JSONSchema] = [:]
    )
}
```

### LandSchema

```swift
public struct LandSchema: Codable, Sendable {
    /// The root state tree type name (e.g., "MatchLandState").
    public let stateType: String
    
    /// Action ID → Payload Schema reference.
    public let actions: [String: JSONSchema]
    
    /// Client Event ID → Payload Schema reference (Client → Server).
    public let clientEvents: [String: JSONSchema]
    
    /// Server Event ID → Payload Schema reference (Server → Client).
    public let events: [String: JSONSchema]
    
    /// Sync-related payload types.
    public let sync: SyncSchema
}

public struct SyncSchema: Codable, Sendable {
    /// Schema reference for the full state snapshot.
    public let snapshot: JSONSchema
    
    /// Schema reference for the diff/patch format.
    public let diff: JSONSchema
}
```

### JSONSchema

```swift
public struct JSONSchema: Codable, Sendable {
    public var type: SchemaType?
    public var properties: [String: JSONSchema]?
    public var items: Box<JSONSchema>?
    public var required: [String]?
    public var enumValues: [String]?
    public var ref: String?  // Encoded as "$ref"
    public var description: String?
    public var additionalProperties: Box<JSONSchema>?
    public var defaultValue: SnapshotValue?
    public var xStateTree: StateTreeMetadata?  // Encoded as "x-stateTree"
}

public enum SchemaType: String, Codable, Sendable {
    case object
    case array
    case string
    case integer
    case number
    case boolean
    case null
}
```

### StateTreeMetadata

```swift
public struct StateTreeMetadata: Codable, Sendable {
    public let nodeKind: NodeKind
    public let sync: SyncMetadata?
}

public enum NodeKind: String, Codable, Sendable {
    case object
    case array
    case map
    case leaf
}

public struct SyncMetadata: Codable, Sendable {
    public let policy: String
}
```

## JSON Schema 格式

### 基本型別

#### 字串 (string)

```json
{
  "type": "string"
}
```

#### 整數 (integer)

```json
{
  "type": "integer"
}
```

#### 數字 (number)

```json
{
  "type": "number"
}
```

#### 布林值 (boolean)

```json
{
  "type": "boolean"
}
```

#### 空值 (null)

```json
{
  "type": "null"
}
```

### 物件 (object)

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string"
    },
    "age": {
      "type": "integer"
    }
  },
  "required": ["name", "age"]
}
```

### 陣列 (array)

```json
{
  "type": "array",
  "items": {
    "type": "string"
  }
}
```

### 字典/映射 (map)

使用 `additionalProperties` 表示字典：

```json
{
  "type": "object",
  "additionalProperties": {
    "type": "string"
  }
}
```

或引用其他型別：

```json
{
  "type": "object",
  "additionalProperties": {
    "$ref": "#/defs/PlayerState"
  }
}
```

### 引用 ($ref)

使用 `$ref` 引用 `defs` 中的型別定義：

```json
{
  "$ref": "#/defs/PlayerState"
}
```

**引用格式：** `#/defs/TypeName`

## x-stateTree 擴充欄位

`x-stateTree` 是 SwiftStateTree 專用的擴充欄位，用於描述 StateTree 特定的 metadata。

### 結構

```json
{
  "x-stateTree": {
    "nodeKind": "object | array | map | leaf",
    "sync": {
      "policy": "broadcast | perPlayer | serverOnly | custom"
    }
  }
}
```

### nodeKind

描述節點的種類：

- **`object`**: 結構化物件（struct/class）
- **`array`**: 陣列
- **`map`**: 字典/映射（`[String: Value]` 或 `[PlayerID: Value]`）
- **`leaf`**: 葉節點（基本型別或不可再分解的型別）

### sync.policy

描述同步策略（對應 Swift 的 `@Sync`）：

- **`broadcast`**: 廣播給所有玩家（`.broadcast`）
- **`perPlayer`**: 每個玩家看到不同的值（`.perPlayer`）
- **`serverOnly`**: 僅伺服器可見（`.serverOnly`）
- **`custom`**: 自訂同步策略（`.custom`）

### 範例

#### 廣播欄位

```json
{
  "type": "object",
  "properties": {
    "round": {
      "type": "integer",
      "x-stateTree": {
        "nodeKind": "leaf",
        "sync": {
          "policy": "broadcast"
        }
      }
    }
  }
}
```

#### 每個玩家不同的欄位

```json
{
  "type": "object",
  "additionalProperties": {
    "$ref": "#/defs/PlayerState",
    "x-stateTree": {
      "nodeKind": "map",
      "sync": {
        "policy": "perPlayer"
      }
    }
  }
}
```

#### 伺服器專用欄位

```json
{
  "type": "object",
  "properties": {
    "hiddenDeck": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "x-stateTree": {
        "nodeKind": "array",
        "sync": {
          "policy": "serverOnly"
        }
      }
    }
  }
}
```

## 完整範例

### 範例 1: 簡單的 Action 和 Response

```json
{
  "version": "0.1.0",
  "lands": {
    "DemoGame": {
      "stateType": "DemoGameState",
      "actions": {
        "AddGold": {
          "$ref": "#/defs/AddGoldAction"
        }
      },
      "sync": {
        "snapshot": {
          "$ref": "#/defs/DemoGameState"
        },
        "diff": {
          "$ref": "#/defs/StatePatch"
        }
      }
    }
  },
  "defs": {
    "AddGoldAction": {
      "type": "object",
      "properties": {
        "amount": {
          "type": "integer"
        }
      },
      "required": ["amount"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    },
    "AddGoldResponse": {
      "type": "object",
      "properties": {
        "success": {
          "type": "boolean"
        },
        "newGold": {
          "type": "integer"
        }
      },
      "required": ["success", "newGold"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    },
    "DemoGameState": {
      "type": "object",
      "properties": {
        "gold": {
          "type": "integer",
          "default": {
            "type": "int",
            "value": 0
          },
          "x-stateTree": {
            "nodeKind": "leaf",
            "sync": {
              "policy": "broadcast"
            }
          }
        },
        "players": {
          "type": "object",
          "additionalProperties": {
            "$ref": "#/defs/PlayerState"
          },
          "x-stateTree": {
            "nodeKind": "map",
            "sync": {
              "policy": "broadcast"
            }
          }
        }
      },
      "required": ["gold", "players"],
      "x-stateTree": {
        "nodeKind": "object"
      }
    },
    "PlayerState": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string"
        },
        "hp": {
          "type": "integer"
        }
      },
      "required": ["name", "hp"],
      "x-stateTree": {
        "nodeKind": "object"
      }
    },
    "StatePatch": {
      "type": "object",
      "properties": {
        "patches": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "op": {
                "type": "string"
              },
              "path": {
                "type": "string"
              },
              "value": {}
            },
            "required": ["op", "path"]
          }
        }
      },
      "required": ["patches"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    }
  }
}
```

### 範例 2: 包含 Event 的完整 Land

```json
{
  "version": "0.1.0",
  "lands": {
    "ChatRoom": {
      "stateType": "ChatRoomState",
      "actions": {
        "SendMessage": {
          "$ref": "#/defs/SendMessageAction"
        }
      },
      "clientEvents": {
        "ChatEvent": {
          "$ref": "#/defs/ChatEvent"
        }
      },
      "events": {
        "MessageReceived": {
          "$ref": "#/defs/MessageReceivedEvent"
        }
      },
      "sync": {
        "snapshot": {
          "$ref": "#/defs/ChatRoomState"
        },
        "diff": {
          "$ref": "#/defs/StatePatch"
        }
      }
    }
  },
  "defs": {
    "SendMessageAction": {
      "type": "object",
      "properties": {
        "message": {
          "type": "string"
        }
      },
      "required": ["message"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    },
    "SendMessageResponse": {
      "type": "object",
      "properties": {
        "success": {
          "type": "boolean"
        },
        "messageID": {
          "type": "string"
        }
      },
      "required": ["success", "messageID"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    },
    "ChatEvent": {
      "type": "object",
      "properties": {
        "message": {
          "type": "string"
        }
      },
      "required": ["message"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    },
    "MessageReceivedEvent": {
      "type": "object",
      "properties": {
        "from": {
          "type": "string"
        },
        "message": {
          "type": "string"
        },
        "timestamp": {
          "type": "number"
        }
      },
      "required": ["from", "message", "timestamp"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    },
    "ChatRoomState": {
      "type": "object",
      "properties": {
        "messages": {
          "type": "array",
          "items": {
            "$ref": "#/defs/ChatMessage"
          },
          "x-stateTree": {
            "nodeKind": "array",
            "sync": {
              "policy": "broadcast"
            }
          }
        },
        "participants": {
          "type": "object",
          "additionalProperties": {
            "$ref": "#/defs/ParticipantInfo"
          },
          "x-stateTree": {
            "nodeKind": "map",
            "sync": {
              "policy": "broadcast"
            }
          }
        }
      },
      "required": ["messages", "participants"],
      "x-stateTree": {
        "nodeKind": "object"
      }
    },
    "ChatMessage": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string"
        },
        "from": {
          "type": "string"
        },
        "content": {
          "type": "string"
        },
        "timestamp": {
          "type": "number"
        }
      },
      "required": ["id", "from", "content", "timestamp"],
      "x-stateTree": {
        "nodeKind": "object"
      }
    },
    "ParticipantInfo": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string"
        },
        "joinedAt": {
          "type": "number"
        }
      },
      "required": ["name", "joinedAt"],
      "x-stateTree": {
        "nodeKind": "object"
      }
    },
    "StatePatch": {
      "type": "object",
      "properties": {
        "patches": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "op": {
                "type": "string",
                "enum": ["replace", "remove", "add"]
              },
              "path": {
                "type": "string"
              },
              "value": {}
            },
            "required": ["op", "path"]
          }
        }
      },
      "required": ["patches"],
      "x-stateTree": {
        "nodeKind": "leaf"
      }
    }
  }
}
```

## 預設值格式

預設值使用 `SnapshotValue` 格式編碼，採用 `type + value` 結構：

```json
{
  "type": "integer",
  "default": {
    "type": "int",
    "value": 0
  }
}
```

### SnapshotValue 編碼格式

預設值遵循 `SnapshotValue` 的自定義編碼格式（`type + value`）：

- **null**: `{ "type": "null" }`（沒有 value 欄位）
- **bool**: `{ "type": "bool", "value": true }`
- **int**: `{ "type": "int", "value": 100 }`
- **double**: `{ "type": "double", "value": 3.14 }`
- **string**: `{ "type": "string", "value": "hello" }`
- **array**: `{ "type": "array", "value": [...] }`
- **object**: `{ "type": "object", "value": {...} }`

**範例：**

```json
{
  "type": "object",
  "properties": {
    "gold": {
      "type": "integer",
      "default": {
        "type": "int",
        "value": 0
      }
    },
    "name": {
      "type": "string",
      "default": {
        "type": "string",
        "value": "Player"
      }
    },
    "items": {
      "type": "array",
      "items": {
        "type": "string"
      },
      "default": {
        "type": "array",
        "value": []
      }
    }
  }
}
```

## Action/Event ID 命名規範

### Action ID

建議使用 `<domain>.<action>` 格式：

- `match.join`
- `match.ready`
- `lobby.createRoom`
- `card.draw`
- `player.move`

### Event ID

建議使用 `<domain>.<event>` 格式：

- `match.start`
- `match.end`
- `lobby.roomCreated`
- `player.joined`
- `player.left`

**注意：** Action ID 和 Event ID 在整個 schema 中必須唯一。

## Schema 生成流程

### 1. 從 Swift 定義生成

使用 `SchemaGenCLI` 從 LandDefinitions 生成 schema：

```swift
let landDefinitions: [AnyLandDefinition] = [...]
try SchemaGenCLI.generate(
    landDefinitions: landDefinitions,
    version: "0.1.0",
    outputPath: "schema.json"
)
```

### 2. 從 Server 端點獲取

Server 提供 REST 端點：

```
GET /schema
```

返回完整的 Protocol Schema JSON。

### 3. 用於 Codegen

TypeScript SDK 生成器可以讀取 schema 並生成型別安全的 API：

```typescript
// 讀取 schema
const schema: Schema = await fetch('/schema').then(r => r.json())

// 生成型別定義
const types = generateTypes(schema.defs)
const actions = generateActions(schema.lands)
const events = generateEvents(schema.lands)
```

## 參考資料

- [JSON Schema Specification](https://json-schema.org/)
- [SwiftStateTree Protocol Schema 設計](./DESIGN_PROTOCOL_SCHEMA.md)
- [Transport Protocol](./TRANSPORT_PROTOCOL.md)

