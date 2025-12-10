# SwiftStateTree DSL 設計草案 v0.2

> 單一 StateTree + 同步規則 + Land DSL

## 模組簡寫

為了方便後續溝通，定義以下簡寫：

| 簡寫 | 完整名稱 | 說明 |
|------|---------|------|
| **core** | `swift-state-tree` | 核心模組（不相依網路） |
| **transport** | `swift-state-tree-transport` | 網路傳輸模組 |
| **app** | `swift-state-tree-server-app` | Server 應用啟動模組 |
| **codegen** | `swift-state-tree-codegen` | Schema 生成工具 |

詳見 [DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md) 的「模組拆分建議」章節。

## 目標

- 用**一棵權威狀態樹 StateTree**（包含一個 StateNode 作為根部）表示整個領域的狀態
- StateTree 可以長出多個 StateNode（支援巢狀結構）
- 用 **@Sync 規則** 控制伺服器要把哪些資料同步給誰
- 支援遞迴過濾：巢狀的 StateNode 可以獨立套用 @Sync 政策
- 用 **Land DSL** 定義領域、Action/Event 處理、Tick 設定
- **UI 計算全部交給客戶端**，伺服器只送「邏輯資料」

---

## 文檔結構

本文檔已切分為多個章節，方便閱讀和維護：

### 核心概念
- **[DESIGN_CORE.md](./DESIGN_CORE.md)**：整體理念、StateTree 結構、同步規則 DSL
- **[DESIGN_VERSIONING.md](./DESIGN_VERSIONING.md)**：Schema 版本控制機制、`@Since` 標記、自動補欄位、Persistence 處理

### 通訊模式
- **[DESIGN_COMMUNICATION.md](./DESIGN_COMMUNICATION.md)**：Action 與 Event 通訊模式、WebSocket 傳輸、路由機制

### Land DSL
- **[DESIGN_LAND_DSL.md](./DESIGN_LAND_DSL.md)**：Land DSL 語法、Action 處理、Event 處理、LandContext
- **[DESIGN_LAND-DSL-ROOM_LIFECYCLE.md](./DESIGN_LAND-DSL-ROOM_LIFECYCLE.md)**：房間生命週期、Hook 呼叫順序、async/await 支援

### Transport 層
- **[DESIGN_TRANSPORT.md](./DESIGN_TRANSPORT.md)**：網路傳輸抽象、Transport 協議、服務注入

### Runtime 結構
- **[DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md)**：LandKeeper、SyncEngine 的運行時結構

### Server 架構
- **[DESIGN_APP_CONTAINER_HOSTING.md](./DESIGN_APP_CONTAINER_HOSTING.md)**：AppContainer 與 Hosting 設計、服務組裝
- **[DESIGN_MULTI_ROOM_ARCHITECTURE.md](./DESIGN_MULTI_ROOM_ARCHITECTURE.md)**：多房間架構、配對服務、房間管理設計

### 客戶端 SDK 與程式碼生成
- **[TYPESCRIPT_SDK_ARCHITECTURE.md](../guides/TYPESCRIPT_SDK_ARCHITECTURE.md)**：TypeScript SDK 完整架構設計（整合了舊版 SDK 設計和 Code-gen 計劃）

### 範例與速查
- **[DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md)**：端到端範例、語法速查表、命名說明、設計決策、**專案目錄結構**

---

## 專案結構

### 模組架構

本專案採用模組化設計，分為四個核心模組：

| 模組 | 簡寫 | 完整名稱 | 說明 |
|------|------|---------|------|
| **core** | `SwiftStateTree` | `swift-state-tree` | 核心模組（不相依網路） |
| **transport** | `SwiftStateTreeTransport` | `swift-state-tree-transport` | 網路傳輸模組 |
| **app** | `SwiftStateTreeServerApp` | `swift-state-tree-server-app` | Server 應用啟動模組 |
| **codegen** | `SwiftStateTreeCodeGen` | `swift-state-tree-codegen` | Schema 生成工具 |

### 模組依賴關係

```
core (swift-state-tree)
    ↑
    ├── transport (swift-state-tree-transport)
    │       ↑
    │       └── app (swift-state-tree-server-app)
    │
    └── codegen (swift-state-tree-codegen)
```

### 專案目錄結構

詳見 [DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md) 的「專案目錄結構建議」章節。

**快速參考**：

```
swift-state-tree/
├── Sources/
│   ├── SwiftStateTree/              # core：核心模組
│   │   ├── Action/                  # ActionPayload protocol
│   │   ├── Event/                   # EventPayload protocols
│   │   ├── State/                   # StateProtocol
│   │   ├── StateTree/               # StateTree 定義
│   │   ├── Sync/                    # @Sync 同步規則
│   │   ├── Land/                   # Land DSL
│   │   ├── Runtime/                 # Runtime 執行器（LandKeeper）
│   │   ├── SchemaGen/              # Schema 生成器
│   │   └── Support/                # 工具類
│   ├── SwiftStateTreeTransport/     # transport：網路傳輸模組
│   ├── SwiftStateTreeServerApp/     # app：Server 應用模組
│   └── SwiftStateTreeCodeGen/      # codegen：Schema 生成工具
├── Tests/                           # 各模組的測試
└── Examples/                        # 範例專案
```

**詳細結構說明**：請參考 [DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md#專案目錄結構建議)

---

## 相關文檔

- **[APP_APPLICATION.md](./APP_APPLICATION.md)**：StateTree 在 App 開發中的應用
  - SNS App 完整範例
  - 與現有方案比較（Redux、MVVM、TCA）
  - 跨平台實現（Android/Kotlin、TypeScript）
  - 狀態同步方式詳解

---

## 快速導覽

### 新手入門
1. 閱讀 [DESIGN_CORE.md](./DESIGN_CORE.md) 了解核心概念
2. 閱讀 [DESIGN_COMMUNICATION.md](./DESIGN_COMMUNICATION.md) 了解通訊模式
3. 查看 [DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md) 中的範例

### 開發參考
- 定義 StateTree：參考 [DESIGN_CORE.md](./DESIGN_CORE.md) 的「StateTree：狀態樹結構」和「同步規則 DSL」
- 定義 Land：參考 [DESIGN_REALM_DSL.md](./DESIGN_REALM_DSL.md)
- 設定 Transport：參考 [DESIGN_TRANSPORT.md](./DESIGN_TRANSPORT.md)
- 生成客戶端 SDK：參考 [TYPESCRIPT_SDK_ARCHITECTURE.md](../guides/TYPESCRIPT_SDK_ARCHITECTURE.md)
- 語法速查：參考 [DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md) 的「語法速查表」

### 架構深入
- Runtime 運作：參考 [DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md)
- 多房間架構：參考 [DESIGN_MULTI_ROOM_ARCHITECTURE.md](./DESIGN_MULTI_ROOM_ARCHITECTURE.md)
- Server 組裝：參考 [DESIGN_APP_CONTAINER_HOSTING.md](./DESIGN_APP_CONTAINER_HOSTING.md)
- 多伺服器架構：參考 [DESIGN_TRANSPORT.md](./DESIGN_TRANSPORT.md) 的「多伺服器架構設計」章節
