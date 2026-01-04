# Documentation Index

歡迎來到 SwiftStateTree 文檔中心。本頁提供完整的文檔導覽與建議閱讀順序。

## 🚀 快速開始

如果你是第一次接觸 SwiftStateTree，建議按照以下順序閱讀：

1. **[概觀](overview.md)** - 了解系統架構與核心概念
2. **[架構概念總覽](conceptual-overview.md)** - 深入理解 StateTree 的設計理念與核心概念（可選但推薦）
3. **[快速開始](quickstart.md)** - 實作最小可行範例
4. **[Land DSL](core/land-dsl.md)** - 學習如何定義領域邏輯
5. **[同步規則](core/sync.md)** - 理解狀態同步機制

## 📚 完整文檔目錄

### 入門指南

- **[概觀](overview.md)** - 系統架構、模組組成、核心概念
- **[架構概念總覽](conceptual-overview.md)** - StateTree 架構的完整概念說明（狀態層、動作層、Resolver、語意模型等）
- **[架構分層](architecture.md)** - 組件分層架構與關係說明
- **[快速開始](quickstart.md)** - 從零開始建立第一個伺服器

### 核心概念

- **[核心模組](core/README.md)** - StateNode、Sync、Land DSL、Runtime 總覽
- **[Land DSL](core/land-dsl.md)** - 領域定義、AccessControl、Rules、Lifetime
- **[同步規則](core/sync.md)** - `@Sync` 策略、`@Internal`、同步引擎

### 整合與部署

- **[Transport 層](transport/README.md)** - WebSocket、連線管理、多房間支援
- **[Hummingbird 整合](hummingbird/README.md)** - 伺服器設定、單房間/多房間模式
- **[認證機制](hummingbird/auth.md)** - JWT、Guest 模式、Admin 路由

### 範例

- **[Cookie Clicker 範例](examples/cookie-clicker.md)** - 完整的多玩家遊戲範例，展示進階功能

### 參考文檔

- **[Schema 生成](schema/README.md)** - JSON Schema 自動生成
- **[Macros](macros/README.md)** - `@StateNodeBuilder`、`@Payload`、`@SnapshotConvertible`

## 🔍 依使用場景查找

### 我想建立一個遊戲伺服器

1. [快速開始](quickstart.md) - 基本設定
2. [Land DSL](core/land-dsl.md) - 定義遊戲邏輯
3. [Hummingbird 整合](hummingbird/README.md) - 部署伺服器

### 我想了解狀態同步機制

1. [同步規則](core/sync.md) - 同步策略詳解
2. [核心模組](core/README.md) - Runtime 與 SyncEngine

### 我想實作多房間架構

1. [架構分層](architecture.md) - 了解組件分層與關係
2. [Transport 層](transport/README.md) - 多房間管理
3. [Hummingbird 整合](hummingbird/README.md) - 多房間模式設定

### 我想優化效能

1. [Macros](macros/README.md) - 使用 `@SnapshotConvertible` 提升效能
2. [核心模組](core/README.md) - 了解 Runtime 運作機制

## 📝 設計與開發筆記

詳細的設計文檔與開發筆記請參考 [Notes/](../Notes/index.md) 目錄：

- `Notes/design/` - 系統設計文檔
- `Notes/guides/` - 開發指南
- `Notes/performance/` - 效能分析
- `Notes/protocol/` - 通訊協定規格

## 💡 文檔結構說明

- **`docs/`** - 正式發布的文檔，適合對外閱讀
- **`Notes/`** - 內部設計與開發筆記，可能包含未完成的內容

---

如有問題或建議，歡迎提交 [Issue](https://github.com/your-username/SwiftStateTree/issues)。
