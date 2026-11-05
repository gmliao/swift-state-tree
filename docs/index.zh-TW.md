[English](index.md) | [中文版](index.zh-TW.md)

# Documentation Index

歡迎來到 SwiftStateTree 文檔中心。本頁提供完整的文檔導覽與建議閱讀順序。

## 🚀 快速開始

如果你是第一次接觸 SwiftStateTree，建議按照以下順序閱讀：

1. **[概觀](overview.zh-TW.md)** - 了解系統架構與核心概念
2. **[架構概念總覽](programming-model.zh-TW.md)** - 深入理解 StateTree 的設計理念與核心概念（可選但推薦）
3. **[快速開始](quickstart.zh-TW.md)** - 實作最小可行範例
4. **[Land DSL](core/land-dsl.zh-TW.md)** - 學習如何定義領域邏輯
5. **[同步規則](core/sync.zh-TW.md)** - 理解狀態同步機制

## 📚 完整文檔目錄

### 入門指南

- **[概觀](overview.zh-TW.md)** - 系統架構、模組組成、核心概念
- **[架構概念總覽](programming-model.zh-TW.md)** - StateTree 架構的完整概念說明（狀態層、動作層、Resolver、語意模型等）
- **[架構分層](architecture.zh-TW.md)** - 組件分層架構與關係說明
- **[快速開始](quickstart.zh-TW.md)** - 從零開始建立第一個伺服器

### 核心概念

- **[核心模組](core/README.zh-TW.md)** - StateNode、Sync、Land DSL、Runtime 總覽
- **[Land DSL](core/land-dsl.zh-TW.md)** - 領域定義、AccessControl、Rules、Lifetime
- **[同步規則](core/sync.zh-TW.md)** - `@Sync` 策略、`@Internal`、同步引擎

### 整合與部署

- **[配對雙層架構](matchmaking-two-plane.zh-TW.md)** - Control Plane（NestJS）與 Runtime Plane（Swift）關係、客戶端流程、connectUrl
- **[Transport 層](transport/README.zh-TW.md)** - WebSocket、連線管理、多房間支援
- **[傳輸層演進](transport_evolution.zh-TW.md)** - 從 JSON 到 MessagePack 二進位編碼的演進歷程
- **[認證機制](transport/auth.zh-TW.md)** - JWT、Guest 模式、Admin 路由
- **[部署與負載平衡](deploy/README.md)** - 以 nginx/K8s 依路徑把連線導到房間

### 範例

- **[Cookie Clicker 範例](examples/cookie-clicker.zh-TW.md)** - 完整的多玩家遊戲範例，展示進階功能

### 遊戲開發

- **[確定性數學運算](deterministic-math/README.zh-TW.md)** - 固定點運算、碰撞檢測和向量運算，用於伺服器權威遊戲

### 客戶端 SDK

- **[TypeScript SDK](sdk/README.zh-TW.md)** - 客戶端 SDK 架構、分層設計與框架整合

### 參考文檔

- **[Schema 生成](schema/README.zh-TW.md)** - JSON Schema 自動生成
- **[Macros](macros/README.zh-TW.md)** - `@StateNodeBuilder`、`@Payload`、`@SnapshotConvertible`

## 🔍 依使用場景查找

### 我想建立一個遊戲伺服器

1. [快速開始](quickstart.zh-TW.md) - 基本設定
2. [Land DSL](core/land-dsl.zh-TW.md) - 定義遊戲邏輯
3. [部署與負載平衡](deploy/README.md) - 部署伺服器

### 我想了解狀態同步機制

1. [同步規則](core/sync.zh-TW.md) - 同步策略詳解
2. [核心模組](core/README.zh-TW.md) - Runtime 與 SyncEngine

### 我想實作配對系統

1. [配對雙層架構](matchmaking-two-plane.zh-TW.md) - Control Plane 與 Runtime Plane、客戶端流程
2. [Matchmaking Control Plane MVP Runbook](operations/matchmaking-control-plane-mvp.md) - 本地執行說明

### 我想實作多房間架構

1. [架構分層](architecture.zh-TW.md) - 了解組件分層與關係
2. [Transport 層](transport/README.zh-TW.md) - 多房間管理
3. [部署與負載平衡](deploy/README.md) - 把客戶端導到房間

### 我想優化效能

1. [Macros](macros/README.zh-TW.md) - 使用 `@SnapshotConvertible` 提升效能
2. [核心模組](core/README.zh-TW.md) - 了解 Runtime 運作機制
3. [傳輸層演進](transport_evolution.zh-TW.md) - 了解傳輸層編碼優化

### 我想建立確定性遊戲

1. [確定性數學運算](deterministic-math/README.zh-TW.md) - 固定點運算與碰撞檢測
2. [核心模組](core/README.zh-TW.md) - StateNode 與同步機制

## 📝 設計與開發筆記

詳細的設計文檔與開發筆記請參考 [Notes/](../Notes/index.md) 目錄：

- `Notes/design/` - 系統設計文檔
- `Notes/guides/` - 開發指南
- `Notes/performance/` - 效能分析
- `Notes/protocol/` - 通訊協定規格
- `Notes/plans/` - 設計與實作計劃，附[狀態索引](../Notes/plans/README.md)

實驗資料（每個實驗一份 README，並有 `regenerate.py` 可以重建表格）在 [deep-research/](../deep-research/README.md)。

## 💡 文檔結構說明

- **`docs/`** - 正式發布的文檔，適合對外閱讀
- **`Notes/`** - 內部設計與開發筆記，可能包含未完成的內容

---

如有問題或建議，歡迎提交 [Issue](https://github.com/your-username/SwiftStateTree/issues)。
