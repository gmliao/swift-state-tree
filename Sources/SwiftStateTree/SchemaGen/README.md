# Schema Generator

此目錄包含 Schema 生成器相關的實現，用於從 LandDefinition 自動生成 JSON Schema。

## 檔案結構

- `ProtocolSchema.swift`：定義 ProtocolSchema、LandSchema、JSONSchema 等資料結構
- `SchemaExtractor.swift`：主要的 Schema 提取器，從 LandDefinition 生成完整 schema
- `TypeToSchemaConverter.swift`：將 Swift 型別轉換為 JSON Schema
- `StateTreeSchemaExtractor.swift`：遞迴提取 State Tree schema
- `ActionEventExtractor.swift`：提取 Action 和 Event 的 schema
- `AnyLandDefinition.swift`：Type-erased wrapper，用於在 CLI 中處理多個 LandDefinition
- `SchemaGenCLI.swift`：CLI 工具函數，提供命令列介面
- `FieldMetadata.swift`：定義欄位 metadata 結構
- `SchemaMetadataProvider.swift`：Protocol 定義，用於提供型別 metadata
- `SchemaHelper.swift`：輔助函數，判斷 nodeKind 等

## 使用方式

### 方式 1：使用 CLI 工具（推薦）

在您的專案中建立一個簡單的 executable target：

```swift
// Sources/SchemaGen/main.swift
import Foundation
import SwiftStateTree
import YourContentModule  // 包含 LandDefinition 的 module

@main
struct SchemaGen {
    static func main() {
        let landDefinitions = [
            AnyLandDefinition(YourGame.makeLand()),
            AnyLandDefinition(AnotherGame.makeLand())
        ]
        
        try? SchemaGenCLI.generateFromArguments(landDefinitions: landDefinitions)
    }
}
```

然後在 `Package.swift` 中新增 executable target：

```swift
.executableTarget(
    name: "SchemaGen",
    dependencies: [
        "YourContentModule",
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
swift run SchemaGen --output schema.json --version 0.2.0

# 查看幫助
swift run SchemaGen --help
```

### 方式 2：程式碼中使用

```swift
// 從 LandDefinition 提取 schema
let landDefinition = DemoGame.makeLand()
let schema = SchemaExtractor.extract(from: landDefinition, version: "0.1.0")

// 使用 SchemaGenCLI 生成並輸出
let landDefinitions = [AnyLandDefinition(landDefinition)]
try SchemaGenCLI.generate(
    landDefinitions: landDefinitions,
    version: "0.1.0",
    outputPath: "schema.json"
)
```

## 設計原則

- Schema Generator 應從 StateTree 定義自動生成 JSON Schema
- 不應依賴網路或 Transport 層
- 利用 `@StateNodeBuilder` 和 `@Payload` macro 生成的 `getFieldMetadata()` 方法
- 支援遞迴提取巢狀的 StateNode
- 符合 [DESIGN_PROTOCOL_SCHEMA.md](../../../docs/design/DESIGN_PROTOCOL_SCHEMA.md) 定義的格式

## Schema 格式

生成的 schema 符合 DESIGN_PROTOCOL_SCHEMA.md 定義的格式：

```jsonc
{
  "version": "0.1.0",
  "lands": {
    "LandID": {
      "stateType": "StateTypeName",
      "actions": {
        "action.id": { "$ref": "#/defs/ActionType" }
      },
      "events": {
        "EventType": { "$ref": "#/defs/EventType" }
      },
      "sync": {
        "snapshot": { "$ref": "#/defs/StateTypeName" },
        "diff": { "$ref": "#/defs/StateDiff" }
      }
    }
  },
  "defs": {
    "StateTypeName": { ... },
    "ActionType": { ... },
    "EventType": { ... }
  }
}
```

## 注意事項

- Action 和 Event 型別需要標記 `@Payload` macro 以提供 metadata
- StateNode 型別需要標記 `@StateNodeBuilder` macro（已自動提供 `getFieldMetadata()`）
- 目前 Action ID 的生成是基於型別名稱的簡化轉換，未來可以改進為更結構化的方式
