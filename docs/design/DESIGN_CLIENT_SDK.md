# 客戶端 SDK 與程式碼生成

> 本文檔說明**跨語言客戶端 SDK 的設計理念、自動生成機制，以及 Code-gen 架構**。
>
> **本文檔定位**：General 的 SDK 架構設計和生成理念（適用於 TypeScript、Kotlin、Swift 等所有語言）
>
> **相關文檔**：
> - **[DESIGN_TYPESCRIPT_SDK.md](./DESIGN_TYPESCRIPT_SDK.md)**：TypeScript SDK 的具體設計和實作方向
>   - TS SDK Core 現況（`StateTreeRuntime` + `StateTreeView`）
>   - TypeScript schema codegen 規劃
>   - 生成「每個 land 一個 `StateTree` 類別」：樹狀 state + function actions/events
>   - 框架無關設計（Vue/React 等）
>
> **注意**：本文檔只包含架構和概念，不包含具體實作細節。實作細節請參考各語言的 SDK 設計文檔。

---

## 設計理念

### 為什麼需要自動生成客戶端 SDK？

StateTree 的核心設計理念是**單一來源真相（Single Source of Truth）**：

1. **Server 定義是權威來源**：
   - Server 端定義 StateTree、Action、Event 的完整型別和結構
   - 這些定義包含所有業務邏輯和同步規則

2. **客戶端需要型別安全的介面**：
   - 客戶端必須知道如何呼叫 Action、處理 Event
   - 必須確保型別一致性，避免執行時錯誤

3. **手動維護容易出錯**：
   - 手動定義客戶端型別容易與 Server 不同步
   - 型別不匹配會在執行時才發現，難以維護

### 自動生成的優勢

- **型別安全**：從 Server 定義自動生成，確保型別完全一致
- **自動同步**：Server 定義變更時，客戶端 SDK 自動更新
- **減少錯誤**：避免手動定義導致的型別不匹配
- **開發體驗**：提供完整的型別提示和自動完成

## 設計決策

### 決策 1：採用自動生成

**決定**：客戶端 SDK **必須**從 Server 定義自動生成，不支援手動定義。

**原因**：
1. 確保型別一致性
2. 減少維護成本
3. 提供更好的開發體驗

### 決策 2：必須使用中間格式（JSON Schema）

**核心設計決策**：Code-gen 架構**必須**採用兩階段設計：

1. **第一階段**：Swift → JSON Schema（中間格式）
2. **第二階段**：JSON Schema → 各語言 SDK

**為什麼必須使用中間格式？**

#### ❌ 不推薦：Swift 直接生成所有語言

```
Swift 定義 → Swift Generator → TypeScript / Kotlin / ...
```

**缺點**：
- **耦合度高**：Swift 工具需要知道所有目標語言
- **難以擴充**：新增語言需要修改 Swift 工具
- **難以重用**：其他工具無法使用
- **維護成本高**：所有生成邏輯集中在一個工具

#### ✅ 推薦：使用 JSON Schema 作為中間格式

```
Swift 定義 → JSON Schema → 各語言生成器（可獨立實作）
```

**優點**：
- **解耦**：Swift 工具只需輸出一次 JSON，不需要知道目標語言
- **獨立開發**：各語言生成器可以用不同語言實作（TypeScript 生成器可用 Node.js）
- **可重用**：JSON Schema 可以被其他工具使用（文檔生成、API 測試等）
- **可驗證**：JSON Schema 可以獨立驗證和測試
- **易擴充**：新增語言只需新增一個生成器，不需要修改 Swift 工具
- **版本控制**：JSON Schema 可以版本化，追蹤變更

## 架構設計

### 整體架構

```
┌─────────────────────────────────────────┐
│   Server Definition (Swift)             │
│   - StateTree                           │
│   - Action / Event                         │
│   - Land DSL                           │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│   Type Extractor (Swift)                │
│   - AST Analysis / Macro Output        │
│   - 提取型別資訊                        │
│   - 輸出：JSON Schema                   │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│   JSON Schema (中間格式)                │
│   - 語言無關的型別定義                  │
│   - Land / Action / Event 定義            │
│   - 可版本化、可驗證                    │
└─────────────────────────────────────────┘
              ↓
    ┌─────────┴─────────┐
    ↓                   ↓
┌──────────┐      ┌──────────┐
│ TypeScript│      │  Kotlin  │
│ Generator│      │ Generator│
│ (Node.js)│      │ (Kotlin) │
└──────────┘      └──────────┘
    ↓                   ↓
┌──────────┐      ┌──────────┐
│ TypeScript│      │  Kotlin  │
│   SDK    │      │   SDK    │
└──────────┘      └──────────┘
```

**關鍵設計要點**：
1. **JSON Schema 是必須的**：所有生成器都必須從 JSON Schema 讀取
2. **生成器可以獨立實作**：TypeScript 生成器可以用 Node.js 寫，Kotlin 生成器可以用 Kotlin 寫
3. **Swift 工具只負責提取**：不需要知道目標語言
4. **JSON Schema 可以重用**：文檔生成、API 測試等工具也可以使用

### 設計目標

Code-gen 架構必須滿足以下需求：

1. **可擴充**：容易新增新的目標語言（Kotlin、Swift、Rust 等）
2. **模組化**：每個語言生成器獨立，互不影響
3. **可測試**：每個生成器可以獨立測試
4. **可維護**：清晰的架構，容易理解和修改
5. **解耦**：Swift 工具與目標語言生成器完全解耦

## 核心組件

### 1. Type Extractor（型別提取器）

**職責**：從 Server 定義中提取型別資訊

**實作方式**（概念層面）：
- **Swift Macros**：在編譯時輸出型別資訊
- **AST Analysis**：分析 Swift AST，提取型別
- **Reflection**：執行時反射（不推薦，效能較差）

**輸出**：中間格式（JSON Schema）

**提取的資訊**：
- StateTree 結構和屬性
- Action 定義和參數
- Event 定義和參數
- 型別定義（struct、enum、alias 等）
- 同步規則（@Sync 政策）

### 2. Intermediate Format（中間格式）：JSON Schema

**職責**：語言無關的型別定義，**必須使用 JSON Schema**

**設計決策**：統一使用 JSON Schema 作為中間格式

**原因**：
- **標準化**：JSON Schema 是業界標準，工具支援豐富
- **易讀易寫**：人類可讀，容易除錯和驗證
- **語言無關**：任何語言都可以讀取和處理
- **可驗證**：可以使用 JSON Schema 驗證器驗證格式
- **可版本化**：可以追蹤變更歷史

**Schema 格式**：詳見 [SCHEMA_DEFINITION.md](../protocol/SCHEMA_DEFINITION.md)

**JSON Schema 的優勢**：
- **可驗證**：可以使用 JSON Schema 驗證器驗證格式正確性
- **可版本化**：可以追蹤變更歷史，比較不同版本
- **可重用**：文檔生成、API 測試等工具也可以使用
- **易除錯**：人類可讀，容易發現問題

### 3. Generator Interface（生成器介面）

**職責**：定義統一的生成器介面（**不限定實作語言**）

**重要設計決策**：生成器可以用任何語言實作，只需要：
1. 讀取 JSON Schema
2. 生成目標語言的 SDK
3. 遵循統一的介面規範

**介面規範（概念層面）**：

生成器需要提供以下功能：
- **輸入**：JSON Schema 檔案路徑
- **輸出**：生成的 SDK 檔案
- **配置**：輸出目錄、套件名稱等選項
- **驗證**：驗證生成的程式碼正確性

**各語言生成器可以獨立實作**：
- TypeScript Generator 可以用 Node.js 實作
- Kotlin Generator 可以用 Kotlin 實作
- Swift Client Generator 可以用 Swift 實作

**優勢**：
- **語言無關**：生成器可以用最適合的語言實作
- **獨立開發**：每個生成器可以獨立開發和測試
- **易擴充**：新增語言只需新增一個生成器實作

### 4. Template Engine（模板引擎）

**職責**：使用模板生成程式碼（可選）

**選擇**（概念層面）：
- **Stencil**：Swift 模板引擎，語法簡單
- **Mustache**：語言無關，但功能較少
- **自定義模板**：完全控制，但需要自己實作
- **直接生成**：不使用模板，直接生成程式碼字串

**建議**：各語言生成器可以自行決定是否使用模板引擎，以及使用哪種模板引擎

## 生成內容（概念）

從 Server 定義自動生成以下內容：

1. **型別定義**：
   - StateTree 型別（對應 Server 的 StateTree）
   - Action 型別（對應 Server 的 Action）
   - Event 型別（對應 Server 的 ClientEvent / ServerEvent）
   - Response 型別（對應 Server 的 ActionResult）
   - 所有相關的型別定義

2. **客戶端 SDK 類別**：
   - 連接管理（WebSocket 或其他傳輸層）
   - Action 方法：型別安全的 Action 呼叫
   - Event 處理：型別安全的 Event 訂閱
   - State 同步：狀態樹的同步和更新

3. **型別輔助**：
   - 型別定義檔案
   - 自動完成提示
   - 編譯時型別檢查

**注意**：具體的 API 設計和實作方式由各語言的 SDK 設計文檔決定（例如 [DESIGN_TYPESCRIPT_SDK.md](./DESIGN_TYPESCRIPT_SDK.md)）

## 擴充新語言

新增新語言生成器**完全獨立**，不需要修改 Swift 工具：

### 概念流程

1. **建立生成器專案**：可以用任何語言實作（Node.js、Kotlin、Python 等）
2. **實作生成器**：讀取 JSON Schema，生成目標語言的 SDK
3. **建立模板檔案**（可選）：如果使用模板引擎
4. **整合到工作流程**：在 CI/CD 或開發流程中呼叫生成器

### 關鍵優勢

- ✅ **完全獨立**：不需要修改 Swift 工具
- ✅ **語言自由**：可以用最適合的語言實作
- ✅ **易於測試**：可以獨立測試和驗證
- ✅ **版本獨立**：每個生成器可以獨立版本化

## JSON Schema 的額外用途

JSON Schema 不僅用於生成 SDK，還可以用於：

1. **API 文檔生成**：從 Schema 自動生成 API 文檔
2. **API 測試生成**：從 Schema 自動生成測試案例
3. **OpenAPI/Swagger 轉換**：轉換為其他 API 文檔格式
4. **型別驗證**：在執行時驗證資料格式

## 開發順序（概念）

### Phase 1：TypeScript 支援（優先）

1. **實作 Type Extractor**：從 Swift 定義提取型別資訊，輸出 JSON Schema
2. **實作 TypeScript Generator**：從 JSON Schema 生成 TypeScript SDK
3. **建立 CLI 工具**：提供命令列介面
4. **測試和驗證**：生成程式碼測試、型別一致性測試

### Phase 2：架構優化

1. **優化 Intermediate Format**：評估和優化 JSON Schema 格式
2. **改進 Template Engine**：更好的錯誤處理、更豐富的模板功能
3. **文件生成**：自動生成 API 文檔、使用範例

### Phase 3：擴充其他語言

1. **Kotlin Generator**
2. **Swift Client Generator**
3. **其他語言（根據需求）**

## 相關文檔

- **[DESIGN_TYPESCRIPT_SDK.md](./DESIGN_TYPESCRIPT_SDK.md)**：TypeScript SDK 的具體設計和實作方向
- **[SCHEMA_DEFINITION.md](../protocol/SCHEMA_DEFINITION.md)**：Schema 格式定義
- **[DESIGN_CORE.md](./DESIGN_CORE.md)**：StateTree 核心概念
- **[DESIGN_COMMUNICATION.md](./DESIGN_COMMUNICATION.md)**：Action 與 Event 通訊模式
- **[DESIGN_LAND_DSL.md](./DESIGN_LAND_DSL.md)**：Land DSL 定義
