# StateTree Vue Integration Tests

這些測試展示了 **StateTree 架構如何讓 Vue 組件測試變得簡單**。

## 測試結構

### 1. `utils/` - 業務邏輯單元測試 ⭐ **重點**
- **gameLogic.test.ts** - 展示如何測試業務邏輯
  - 展示如何提取邏輯從組件中獨立測試
  - 展示如何使用 `createMockState()` 測試邏輯函數
  - 展示單元測試的最佳實踐
  - **這是實際專案中最有價值的測試**

### 2. `components/` - 組件整合測試
- **CookieGamePage.test.ts** - 簡化的組件測試
  - 展示如何測試組件與 StateTree 的整合
  - 展示如何測試用戶交互和響應式更新
  - 只保留必要的範例（邏輯測試在 `utils/` 中）

- **HomeView.test.ts** - 測試連線頁面組件
  - 展示如何測試連線邏輯
  - 展示自動跳轉功能

### 3. Codegen 生成的測試工具 ✅
- **`generated/demo-game/testHelpers.ts`** - 自動生成的測試工具
  - `createMockState()` - **最有用**，用於測試業務邏輯
  - `createMockDemoGame()` - 用於組件測試
  - `testWithDemoGamePlayer()` - 快速設置常見場景
  - 查看 `CODEGEN_TEST_HELPERS.md` 了解詳細使用方法

## Codegen 生成的測試工具

**✅ 已啟用！** Codegen 現在會自動生成測試工具（`testHelpers.ts`），包含：
- `createMockState()` - 自動生成默認值的 mock state
- `createMockDemoGame()` - 完整的 mock composable
- `testWithDemoGamePlayer()` - 高級測試 helper

查看 `CODEGEN_TEST_HELPERS.md` 了解詳細使用方法。

## 測試策略

### ⚠️ 不應該測試的內容

**SDK 核心功能應該在 SDK 層面測試，而不是在應用層：**
- ❌ TypeScript 類型安全（編譯器功能）
- ❌ Vue 響應式系統（Vue 核心功能）
- ❌ StateTree 的 sync policies、snapshot generation 等（SDK 已測試）
- ❌ 架構設計概念（關注點分離等）

這些功能在 `Tests/SwiftStateTreeTests/` 和 `Tests/SwiftStateTreeTransportTests/` 中已經有完整的測試覆蓋。

### ✅ 應該測試的內容

**應用層應該專注於：**
- ✅ 業務邏輯（`utils/gameLogic.test.ts`）
- ✅ 組件與 StateTree 的整合（`components/`）
- ✅ 應用特定的狀態轉換和用戶交互

## 運行測試

```bash
# 運行所有測試
npm test

# 運行特定測試
npm test CookieGamePage

# 查看測試覆蓋率
npm run test:coverage

# 使用 UI 模式
npm run test:ui
```

## 測試重點

### 單元測試 vs 組件測試

**單元測試（`utils/gameLogic.test.ts`）** - 最有價值 ⭐
- 測試業務邏輯函數
- 使用 `createMockState()` 創建測試數據
- 快速、獨立、易於維護
- **這是實際專案中應該重點關注的測試**

**組件測試（`components/`）** - 展示整合
- 測試組件與 StateTree 的整合
- 測試用戶交互和響應式更新
- 作為範例展示測試便利性

### 測試原則

1. **邏輯應該提取並單獨測試** - 見 `utils/gameLogic.ts` 和 `utils/gameLogic.test.ts`
2. **組件測試專注於整合** - 測試組件如何與 StateTree 協作
3. **使用 codegen 生成的 helper** - `createMockState()` 是最有用的工具
4. **不要重複測試 SDK 核心功能** - 類型安全、響應式等已在 SDK 層面測試
5. **專注於應用層價值** - 測試業務邏輯和應用特定的行為

### SDK 測試覆蓋

StateTree SDK 的核心功能在以下位置有完整測試：
- `Tests/SwiftStateTreeTests/` - StateNode、SyncEngine、Dirty Tracking 等
- `Tests/SwiftStateTreeTransportTests/` - Transport、WebSocket、JWT 等
- `Tests/SwiftStateTreeMacrosTests/` - Macro 生成功能

應用層測試應該專注於**如何使用**這些功能，而不是**測試這些功能本身**。



