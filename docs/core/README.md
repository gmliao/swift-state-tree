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

- `docs/core/land-dsl.md`
- `docs/core/sync.md`

## Runtime（LandKeeper）

- actor 序列化所有 state mutation
- 以 snapshot 模式進行同步，不阻塞 handler
- 同步具備 dedup，避免重複同步成本
- 每次請求建立 request-scoped 的 `LandContext`

## Resolver

- 多個 resolver 會並行執行
- 任一 resolver 失敗會中止 handler，錯誤回傳給 client
- Resolver output 透過 `ctx.<outputName>` 存取

## SchemaGen

- `@StateNodeBuilder` 與 `@Payload` 產生 metadata
- `SchemaExtractor` 由 `LandDefinition` 產生 JSON schema
- Hummingbird 會提供 `/schema` endpoint
