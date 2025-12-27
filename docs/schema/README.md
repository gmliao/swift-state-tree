# Schema 生成

SchemaGen 用於從 LandDefinition 和 StateNode 自動產生 JSON Schema，提供 client SDK 生成的穩定輸入。

## 設計目的

- **Client SDK 生成**：提供穩定的 schema 輸入，用於生成 TypeScript、Kotlin 等客戶端 SDK
- **版本對齊**：支援 schema 版本管理，確保客戶端與伺服器版本一致
- **工具驗證**：可用於驗證訊息格式、測試工具等
- **自動生成**：由 macro metadata 驅動，避免手寫 schema

## 產生流程

Schema 生成流程如下：

```mermaid
graph LR
    A[LandDefinition] --> B[SchemaExtractor]
    B --> C[ProtocolSchema]
    C --> D[JSON Schema]
    D --> E[Client SDK 生成]
    
    A1[@StateNodeBuilder] --> B
    A2[@Payload] --> B
    
    style A fill:#e1f5ff
    style D fill:#c8e6c9
```

### 步驟說明

1. **Macro 生成 Metadata**：
   - `@StateNodeBuilder` 生成 `getSyncFields()` 方法
   - `@Payload` 生成 `getFieldMetadata()` 方法

2. **SchemaExtractor 提取**：
   - 從 `LandDefinition` 提取 State、Action、Event 資訊
   - 遞迴提取巢狀的 StateNode
   - 生成完整的 JSON Schema

3. **輸出 Schema**：
   - 使用 `SchemaGenCLI` 輸出 JSON 檔案
   - 或透過 Hummingbird `/schema` endpoint 取得

## 使用方式

### 方式 1：使用 SchemaGenCLI（推薦）

建立一個 executable target 來生成 schema：

```swift
// Sources/SchemaGen/main.swift
import Foundation
import SwiftStateTree

@main
struct SchemaGen {
    static func main() {
        // 收集所有 LandDefinition
        let landDefinitions = [
            AnyLandDefinition(gameLand),
            AnyLandDefinition(lobbyLand)
        ]
        
        // 從命令列參數生成
        try? SchemaGenCLI.generateFromArguments(landDefinitions: landDefinitions)
    }
}
```

在 `Package.swift` 中新增 executable target：

```swift
.executableTarget(
    name: "SchemaGen",
    dependencies: [
        .product(name: "SwiftStateTree", package: "SwiftStateTree")
    ],
    path: "Sources/SchemaGen"
)
```

使用方式：

```bash
# 輸出到 stdout
swift run SchemaGen

# 輸出到檔案
swift run SchemaGen --output schema.json

# 指定版本
swift run SchemaGen --output schema.json --version 1.0.0

# 查看幫助
swift run SchemaGen --help
```

### 方式 2：程式碼中使用

直接在程式碼中生成 schema：

```swift
import SwiftStateTree

// 從單一 LandDefinition 提取
let schema = SchemaExtractor.extract(
    from: gameLand,
    version: "1.0.0"
)

// 使用 SchemaGenCLI 生成並輸出
let landDefinitions = [AnyLandDefinition(gameLand)]
try SchemaGenCLI.generate(
    landDefinitions: landDefinitions,
    version: "1.0.0",
    outputPath: "schema.json"
)
```

### 方式 3：多個 Land 合併

生成包含多個 Land 的完整 schema：

```swift
let landDefinitions = [
    AnyLandDefinition(gameLand),
    AnyLandDefinition(lobbyLand),
    AnyLandDefinition(matchmakingLand)
]

try SchemaGenCLI.generate(
    landDefinitions: landDefinitions,
    version: "1.0.0",
    outputPath: "schema.json"
)
```

## Hummingbird Schema 端點

`LandServer` 會自動提供 `/schema` endpoint，輸出當前 Land 的 JSON schema。

### 使用方式

```bash
# 取得 schema
curl http://localhost:8080/schema

# 使用 jq 格式化輸出
curl http://localhost:8080/schema | jq
```

### 回應格式

```json
{
  "version": "1.0.0",
  "lands": {
    "game-room": {
      "stateType": "GameState",
      "actions": {
        "JoinAction": { "$ref": "#/defs/JoinAction" },
        "AttackAction": { "$ref": "#/defs/AttackAction" }
      },
      "events": {
        "PlayerJoinedEvent": { "$ref": "#/defs/PlayerJoinedEvent" },
        "DamageEvent": { "$ref": "#/defs/DamageEvent" }
      },
      "sync": {
        "snapshot": { "$ref": "#/defs/GameState" },
        "diff": { "$ref": "#/defs/StateDiff" }
      }
    }
  },
  "defs": {
    "GameState": {
      "type": "object",
      "properties": {
        "players": {
          "type": "object",
          "additionalProperties": { "$ref": "#/defs/PlayerState" }
        }
      }
    },
    "JoinAction": {
      "type": "object",
      "properties": {
        "playerID": { "type": "string" },
        "name": { "type": "string" }
      },
      "required": ["playerID", "name"]
    }
  }
}
```

### CORS 支援

Schema endpoint 自動支援 CORS，方便前端工具使用：

```javascript
// 在瀏覽器中取得 schema
fetch('http://localhost:8080/schema')
  .then(response => response.json())
  .then(schema => {
    // 使用 schema 生成客戶端程式碼
    generateClientSDK(schema)
  })
```

## Schema 格式

生成的 schema 符合 ProtocolSchema 格式：

### 頂層結構

```json
{
  "version": "1.0.0",        // Schema 版本
  "lands": { ... },           // Land 定義
  "defs": { ... }             // 型別定義
}
```

### Land Schema

每個 Land 包含：

- `stateType`：StateNode 型別名稱
- `actions`：Action ID → Schema 參考
- `clientEvents`：Client Event ID → Schema 參考
- `events`：Server Event ID → Schema 參考
- `sync`：同步相關的 schema（snapshot、diff）

### 型別定義

`defs` 包含所有使用的型別定義，使用 JSON Schema 格式：

- 基本型別：`string`、`number`、`boolean`、`integer`
- 物件：`object` with `properties`
- 陣列：`array` with `items`
- 參考：`$ref` 指向其他定義

## Schema 版本對齊

### 版本管理

Schema 版本用於確保客戶端與伺服器版本一致：

```swift
// 生成時指定版本
let schema = SchemaExtractor.extract(
    from: gameLand,
    version: "1.2.3"  // 使用語義化版本
)
```

### 版本檢查

客戶端可以檢查 schema 版本：

```typescript
// 客戶端檢查版本
const schema = await fetch('/schema').then(r => r.json())
if (schema.version !== expectedVersion) {
  console.warn(`Schema version mismatch: expected ${expectedVersion}, got ${schema.version}`)
}
```

### 版本相容性

- **主版本號變更**：可能包含不兼容的變更
- **次版本號變更**：新增功能，向後兼容
- **修訂版本號變更**：錯誤修復，向後兼容

## 實作細節

### SchemaExtractor

`SchemaExtractor` 是主要的提取器：

```swift
// 提取單一 Land 的 schema
let schema = SchemaExtractor.extract(
    from: landDefinition,
    version: "1.0.0"
)
```

**提取流程**：

1. 提取 StateTree schema（遞迴處理巢狀結構）
2. 提取 Action schemas（從 action handlers）
3. 提取 Event schemas（從 event handlers）
4. 生成 sync schemas（snapshot 和 diff）

### StateTreeSchemaExtractor

遞迴提取 StateNode 的 schema：

```swift
// 提取 StateNode 的 schema
let stateSchema = StateTreeSchemaExtractor.extract(
    GameState.self,
    definitions: &definitions,
    visitedTypes: &visitedTypes
)
```

**處理邏輯**：

- 使用 `getSyncFields()` 取得欄位 metadata
- 遞迴處理巢狀的 StateNode
- 避免循環引用（使用 `visitedTypes`）

### ActionEventExtractor

提取 Action 和 Event 的 schema：

```swift
// 提取 Action schema
let actionSchema = ActionEventExtractor.extractAction(
    JoinAction.self,
    definitions: &definitions
)
```

**處理邏輯**：

- 使用 `getFieldMetadata()` 取得欄位資訊
- 處理巢狀型別（遞迴提取）
- 生成 JSON Schema 格式

## 最佳實踐

### 1. 定期生成 Schema

在 CI/CD 流程中自動生成 schema：

```yaml
# .github/workflows/generate-schema.yml
- name: Generate Schema
  run: swift run SchemaGen --output schema.json --version ${{ github.ref_name }}
```

### 2. 版本管理

使用語義化版本管理 schema：

```swift
let version = "1.2.3"  // major.minor.patch
```

### 3. Schema 驗證

在客戶端驗證 schema 版本：

```typescript
// 客戶端驗證
const serverSchema = await fetch('/schema').then(r => r.json())
if (!isCompatible(serverSchema.version, clientSchemaVersion)) {
  throw new Error('Schema version incompatible')
}
```

### 4. 文檔化

將生成的 schema 加入版本控制，方便追蹤變更：

```bash
# 生成並提交 schema
swift run SchemaGen --output schema.json --version 1.0.0
git add schema.json
git commit -m "Update schema to v1.0.0"
```

## 常見問題

### Q: 為什麼某些型別沒有出現在 schema 中？

A: 確保所有型別都標記了對應的 macro：
- StateNode：標記 `@StateNodeBuilder`
- Payload：標記 `@Payload`
- 巢狀結構：標記 `@SnapshotConvertible`

### Q: 如何處理自定義型別？

A: 確保自定義型別實作了必要的 protocol：
- `Codable`：用於序列化
- `Sendable`：用於並發安全
- 標記 `@Payload` 或 `@SnapshotConvertible` 以提供 metadata

### Q: Schema 檔案很大怎麼辦？

A: 可以考慮：
- 分離不同 Land 的 schema
- 使用 `$ref` 減少重複定義
- 壓縮 schema 檔案

## 相關文檔

- [Macros](macros/README.md) - 了解 macro 的使用
- [核心概念](../core/README.md) - 了解 StateNode 和 Land DSL
- [設計文檔](../../Notes/protocol/SCHEMA_DEFINITION.md) - Schema 格式詳細說明
