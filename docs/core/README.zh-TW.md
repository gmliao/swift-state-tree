[English](README.md) | [中文版](README.zh-TW.md)

# Core

本區整理 SwiftStateTree 的核心概念與 API：StateNode、Sync、Land DSL、Runtime、Resolver、SchemaGen。

## 核心設計目標

- 單一權威狀態（StateNode）作為 server 的單一真相
- 同步邏輯與業務邏輯分離（SyncPolicy + Land DSL）
- 編譯期產生 metadata（macro）降低 runtime 反射成本
- Land DSL 不依賴 Transport，維持可移植性

## 主要組件

- StateNode + `@StateNodeBuilder`
- SyncPolicy + `@Sync` / `@Internal`
- Land DSL（AccessControl / Rules / Lifetime）
- Runtime：`LandKeeper`
- Resolver：handler 前置資料取得
- SchemaGen：輸出 JSON Schema

## 建議閱讀順序

1. **[Land DSL](land-dsl.zh-TW.md)** - 了解如何定義領域邏輯
2. **[同步規則](sync.zh-TW.md)** - 理解狀態同步機制
3. **[Runtime 運作機制](runtime.zh-TW.md)** - 深入了解 LandKeeper 的運作方式
4. **[Resolver 使用指南](resolver.zh-TW.md)** - 學習如何使用 Resolver 載入資料
5. **[Deterministic Re-evaluation](reevaluation.zh-TW.md)** - 錄製與重播機制
6. **[失敗處理](failure-handling.zh-TW.md)** - 失敗會結束什麼，以及程式碼目前的狀態

## Runtime（LandKeeper）

`LandKeeper` 是 SwiftStateTree 的核心運行時執行器，負責管理狀態和執行 handlers。

### 核心特性

- **Actor 序列化**：所有狀態變更通過 actor 序列化，確保線程安全
- **在 Turn 內同步**：每次 sync phase 都在 keeper 的 turn 內執行，因此狀態變更與同步不會交錯
- **Request-Scoped Context**：每次請求建立新的 `LandContext`，處理完成後釋放

### 主要功能

- **玩家生命週期管理**：處理 join/leave，執行 `CanJoin`/`OnJoin`/`OnLeave` handlers
- **Action/Event 處理**：執行對應的 handler，管理狀態變更
- **Tick 機制**：管理定時任務，執行 `OnTick` handler
- **狀態同步**：協調 SyncEngine 進行狀態同步
- **自動銷毀**：根據條件自動銷毀空房間

### 詳細說明

詳細的運作機制請參考 [Runtime 運作機制](runtime.zh-TW.md)。

## Resolver

Resolver 機制允許在 action、join、leave 或生命週期 handler 執行前並行載入外部資料，讓 handler 保持同步。Client event handler 不帶 resolver。

### 核心特性

- **並行執行**：多個 resolver 並行執行，提升效能
- **錯誤處理**：任何 resolver 失敗會中止整個處理流程
- **具型別的輸出**：handler 以具型別的參數收到每個 resolver 的輸出
- **資料載入**：從資料庫、Redis、API 等外部來源載入資料

### 使用方式

在 Land DSL 中宣告 resolver：

```swift
Rules {
    HandleAction(UpdateCartAction.self, resolvers: { _, action, _ in
        ProductInfo(productID: action.productID)
    }) { state, action, productInfo, ctx in
        // Resolver 已經執行完成；productInfo 是它的輸出（ProductInfoOutput?）
        // ...
    }
}
```

### 詳細說明

詳細的使用指南請參考 [Resolver 使用指南](resolver.zh-TW.md)。

## SchemaGen

SchemaGen 用於從 LandDefinition 和 StateNode 產生 JSON Schema，供客戶端 SDK 生成使用。

### 核心功能

- **Metadata 生成**：`@StateNodeBuilder` 與 `@Payload` 產生欄位 metadata
- **Schema 提取**：`SchemaExtractor` 由 `LandDefinition` 產生完整 JSON schema
- **Schema 端點**：設定 `NIOLandHostConfiguration.schemaProvider` 時，`NIOLandHost` 會在 `/schema` 提供 schema

### 使用場景

- 客戶端 SDK 生成（TypeScript、Kotlin 等）
- 版本對齊與工具驗證
- API 文檔生成

詳細說明請參考 [Schema 生成](../schema/README.zh-TW.md)。
