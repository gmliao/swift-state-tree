# Realm DSL

此目錄包含 Realm DSL 相關的實現。

## 預期內容

- `RealmDefinition.swift`：Realm DSL 定義（不含網路細節）
- `RealmContext.swift`：RealmContext 定義
- `RealmDSL.swift`：Realm DSL 語法（@resultBuilder 等）

## 設計原則

- Realm DSL 不應包含網路細節（WebSocket、HTTP 等）
- RealmContext 採用 Request-scoped Context 模式
- 詳見 [DESIGN_REALM_DSL.md](../../../DESIGN_REALM_DSL.md)

