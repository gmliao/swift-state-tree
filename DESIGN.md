# SwiftStateTree DSL 設計草案 v0.2

> 單一 StateTree + 同步規則 + Realm DSL

## 目標

- 用**一棵權威狀態樹 StateTree** 表示整個領域的狀態
- 用 **@Sync 規則** 控制伺服器要把哪些資料同步給誰
- 用 **Realm DSL** 定義領域、RPC/Event 處理、Tick 設定
- **UI 計算全部交給客戶端**，伺服器只送「邏輯資料」

---

## 文檔結構

本文檔已切分為多個章節，方便閱讀和維護：

### 核心概念
- **[DESIGN_CORE.md](./DESIGN_CORE.md)**：整體理念、StateTree 結構、同步規則 DSL

### 通訊模式
- **[DESIGN_COMMUNICATION.md](./DESIGN_COMMUNICATION.md)**：RPC 與 Event 通訊模式、WebSocket 傳輸、路由機制

### Realm DSL
- **[DESIGN_REALM_DSL.md](./DESIGN_REALM_DSL.md)**：領域宣告語法、RPC 處理、Event 處理、RealmContext

### Transport 層
- **[DESIGN_TRANSPORT.md](./DESIGN_TRANSPORT.md)**：網路傳輸抽象、Transport 協議、服務注入

### Runtime 結構
- **[DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md)**：RealmActor、SyncEngine 的運行時結構

### 範例與速查
- **[DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md)**：端到端範例、語法速查表、命名說明、設計決策

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
- 定義 Realm：參考 [DESIGN_REALM_DSL.md](./DESIGN_REALM_DSL.md)
- 設定 Transport：參考 [DESIGN_TRANSPORT.md](./DESIGN_TRANSPORT.md)
- 語法速查：參考 [DESIGN_EXAMPLES.md](./DESIGN_EXAMPLES.md) 的「語法速查表」

### 架構深入
- Runtime 運作：參考 [DESIGN_RUNTIME.md](./DESIGN_RUNTIME.md)
- 多伺服器架構：參考 [DESIGN_TRANSPORT.md](./DESIGN_TRANSPORT.md) 的「多伺服器架構設計」章節
