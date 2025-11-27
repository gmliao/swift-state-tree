# Land DSL

此目錄包含 Land DSL 相關的實現。

## 預期內容

- `LandDefinition.swift`：Land DSL 定義（不含網路細節）
- `LandContext.swift`：LandContext 定義
- `LandDSL.swift`：Land DSL 語法（@resultBuilder 等）

## 設計原則

- Land DSL 不應包含網路細節（WebSocket、HTTP 等）
- LandContext 採用 Request-scoped Context 模式
- 詳見 [DESIGN_REALM_DSL.md](../../../DESIGN_REALM_DSL.md)

