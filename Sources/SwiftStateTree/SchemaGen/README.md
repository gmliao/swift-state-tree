# Schema Generator

此目錄包含 Schema 生成器相關的實現。

## 預期內容

- `SchemaGenerator.swift`：從 StateTree 定義生成 JSON Schema
- `TypeExtractor.swift`：從 Swift 定義提取型別資訊（可能與 codegen 模組共享）

## 設計原則

- Schema Generator 應從 StateTree 定義自動生成 JSON Schema
- 不應依賴網路或 Transport 層
- 詳見 [DESIGN_CLIENT_SDK.md](../../../DESIGN_CLIENT_SDK.md)

