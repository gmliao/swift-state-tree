# StateTree: A Reactive Server State Programming Model

> **關於本文件**：本文件整理並定義一套名為 **StateTree** 的 reactive server state programming model。此模型由作者在實務開發與架構設計過程中整理而成，用於描述一種以「單一權威狀態樹」為核心的伺服器端狀態管理與同步思維。
>
> 本文件描述的是一個 **programming model（語意模型）**，而非特定框架或語言實作；文中提及的 Swift 實作僅作為參考，並非此模型的唯一或必要實現方式。為避免語意混淆，本文中對 State / Action / Resolver 的定義，皆以本文件為準。

StateTree 是一套以 **狀態機核心（State Machine Core）** 為基礎的 reactive server state programming model。此架構將「狀態（State）」、「動作（Action）」、「資料來源（Resolver）」明確分層，提供一個清晰的伺服器端狀態管理模型。

> 本 programming model 主要是根據 Vue 的 reactive 模式與後端資料過濾實務，發展出的伺服器端 reactive 狀態管理模型。透過狀態樹的方式表達伺服器狀態，可以直接將資料以 reactive 的方式同步給客戶端，實現自動化的狀態同步與更新。在整理過程中，也發現某些設計理念與 Redux 的單一狀態樹（single state tree）概念有相似之處。

目前實作採用 **有房間（room-based）** 的即時模式（Active StateTree），狀態持續存在並透過 WebSocket 同步給客戶端。

本文件將以完整架構觀點敘述其核心語意模型與設計理念，並在最後根據設計內容推論出此模型所具備的特性。

---

## 1. 狀態層（State Layer）—— StateTree = 唯一真實來源（Single Source of Truth）

StateTree 代表伺服器端的「真實狀態」，以樹狀結構組織狀態資料。

**核心特性**：

* **值類型、快照式（Snapshot-based）**：狀態是值類型，可以產生快照
* **不可變性原則**：狀態不可直接被外部修改
* **同步策略標記**：每個狀態屬性需要標記同步策略（哪些資料同步給哪些客戶端）
* **單一修改入口**：狀態只能透過 Action 修改
* **自動同步機制**：所有修改會自動產生差異（diff）並同步給客戶端

狀態的完整演化軌跡僅由 Action 控制，這使 StateTree 的可推論性非常高。

---

## 2. 動作層（Action Layer）—— 唯一修改狀態的入口

Action 是唯一能修改 StateTree 的地方。

**核心設計**：

* **單一修改入口**：所有狀態變更都必須透過 Action handler
* **同步執行**：Action handler 本身是同步的，不包含非同步操作
* **輸入與輸出**：Action handler 接收當下狀態、Action payload、以及 Resolver 提供的上下文，返回 Response
* **狀態修改方式**：透過引用傳遞（pass by reference）修改狀態

**設計建議：Deterministic Action（目前未強制）**

雖然目前實作未強制，但建議 Action handler 保持 deterministic：

* 避免呼叫 random/time/uuid 等非決定性 API（或使用 seed）
* Action 依賴：
  * 當下 State
  * Action Payload
  * Resolver 提供的 Context
* 相同的輸入 → 產生相同的輸出

這讓 StateTree 更具可推論性，對除錯、回放、同步、複製具有極大優勢。

Action 的責任非常單純：

> **依照業務邏輯，決定要將哪些資料寫入 StateTree。**

Resolver 只是提供輔助資訊（參考資料），不會、也不能直接寫入 StateTree。

---

## 3. 資料來源層（Resolver Layer）—— Action 的上下文提供者

Resolver 是 StateTree 架構的核心創新之一。

Resolver 的定位如下：

* 提供 Action/Event handler 所需要的「外部來源資料」
* 僅能讀取外部系統，不得修改 StateTree
* **並行執行**：所有宣告的 resolver 在 handler 執行前並行執行
* **執行完成後填入上下文**：Resolver 結果會填充到 handler 的上下文中
* **不進狀態樹**：Resolver 的輸出資料不會進入 StateTree，也不會被同步或持久化

Resolver 的本質角色：

> **提供 Action/Event handler 需要的上下文（Context Provider），而非狀態的一部分。**

StateNode vs ResolverOutput 的差異：

| 類別 | 來源 | 會進 StateTree？ | 可改變同步行為？ |
|------|------|----------------|----------------|
| **StateNode** | server 狀態 | ✔ | ✔（可定義同步策略） |
| **ResolverOutput** | 外部資料來源 | ✘ | ✘ |

---

## 4. 語意層（Semantic Model）—— StateTree 的核心概念整合

以下是 StateTree 成為「完整 reactive server 架構」的語意基礎。

---

### 4.1 Resolver 執行模式

Resolver 採用 **eager 並行執行** 模式：

* 在 Action/Event handler 執行前，所有宣告的 resolver 並行執行
* Resolver 執行完成後，結果會填充到 handler 的上下文中
* Handler 可以同步存取 resolver 結果
* Handler 本身是同步的，不需要處理 async 操作

**並行執行優勢**：

* 多個 resolver 同時執行，減少總執行時間
* Handler 保持同步，邏輯更清晰
* 錯誤處理統一：任何 resolver 失敗會中止整個處理流程

---

### 4.2 Resolver 與 State 的資料歸屬規則

* **同步要用的資料** → 一定要寫入 StateTree
* **Action 需要但不需同步的資料** → 放在 ResolverOutput
* **大量、頻繁變動資料（如股票）** → 不應進入 Tree（會爆 diff），用 Resolver 供應
* **永續或邏輯核心資料** → 一律進 Tree（需進 sync）

ResolverOutput 是上下文，StateNode 是權威狀態。兩者關係不可混淆。

---

## 5. Runtime Layer——StateTree 的執行流程

完整流程如下：

```
Client → Action(payload)
           |
           v
   [建立上下文]
           |
           v
   [並行執行 Resolvers]
       • 所有宣告的 resolver 並行執行
       • 載入外部資料（DB、API 等）
       • 結果填充到上下文
           |
           v
   [Action Handler Execution]
       • 讀取 state
       • 讀取 payload
       • 讀取 resolver 結果（同步存取）
       • 修改 state
       • 返回 Response
           |
           v
       [StateTree Updated → diff]
           |
           v
        [Sync Engine]
           |
           v
       相關 Client 自動收到更新
```

此流程確保狀態變更能自動同步給所有相關客戶端，實現 reactive 的伺服器狀態管理。

---

## 6. 未來擴展方向

### 6.1 Replay-Friendly 設計

StateTree 的設計使其具備重播（replay）能力：

**設計理念**：

由於 Action handler 建議保持 deterministic（相同輸入產生相同輸出），StateTree 可以：

* 記錄狀態變更的完整軌跡
* 透過 Action 序列重建任意時間點的狀態
* 支援狀態重播與除錯
* 未來可實現基於狀態的日誌系統（state-based logging）

**後續規劃**：

* 添加狀態為主的日誌系統，記錄狀態快照與 Action 序列
* 支援狀態重播功能，可以從任意快照點重新執行 Action 序列
* 實現完整的除錯與審計能力

**注意**：日誌系統與重播功能目前尚未實作，屬於未來規劃方向。

### 6.2 Passive StateTree（Stateless API 模式）

StateTree 架構理論上也可以支援 passive 模式：

1. 每個請求建立一棵臨時 Tree
2. 透過 Resolver 初始化資料
3. 執行一個或多個 Action
4. 回傳結果
5. 丟棄 Tree（server 保持 stateless）

**注意**：此功能目前尚未實作，屬於未來規劃方向。目前所有 StateTree 都是 Active 模式（房間模式，狀態持續存在）。

---

## 7. 設計特性推論

基於前述的設計內容，StateTree programming model 的核心設計屬性與限制如下：

### 核心設計屬性/限制

1. **單一狀態樹（Single Source of Truth）**：所有狀態集中在 StateTree，沒有分散的狀態來源
2. **Action 作為唯一修改入口**：狀態只能透過 Action handler 修改，沒有其他修改路徑
3. **狀態可序列化**：狀態可以 snapshot 形式保存與恢復
4. **同步策略分離**：同步邏輯（哪些資料同步給誰）與業務邏輯（如何修改狀態）分離
5. **Resolver 並行執行**：多個 Resolver 可在 handler 執行前並行載入資料
6. **建議 deterministic Action**：Action handler 建議保持 deterministic（相同輸入產生相同輸出）

### 從設計屬性/限制推論特性

| 設計屬性/限制 | → | 推論出的特性 |
|-------------|---|------------|
| 單一狀態樹<br/>+ Action 作為唯一修改入口<br/>+ 建議 deterministic Action | → | **可預測性（Determinism）**<br/><br/>因為單一狀態樹，所以狀態來源明確，沒有分散狀態造成的歧義；因為 Action 作為唯一修改入口，所以變更路徑單一易於追蹤；因為建議 deterministic Action，所以狀態演化過程可預測。因此有可預測性。 |
| Action 作為唯一修改入口<br/>+ 狀態可序列化<br/>+ 建議 deterministic Action | → | **可驗證性（Verifiability）**<br/><br/>因為 Action 作為唯一修改入口，所以所有狀態變更都有明確來源，變更軌跡完整；因為狀態可序列化，所以狀態可以 snapshot 形式保存，便於驗證與測試；因為建議 deterministic Action，所以狀態變更可重現。因此有可驗證性。 |
| 單一狀態樹<br/>+ 同步策略分離 | → | **易同步（Sync-friendly）**<br/><br/>因為單一狀態樹，所以 StateTree 是唯一真實來源，同步邏輯清晰，不需要協調多個狀態來源；因為同步策略分離，所以可以明確定義哪些資料同步給哪些客戶端，同步行為可配置。因此有易同步性。 |
| Resolver 並行執行<br/>+ 狀態可序列化<br/>+ 單一狀態樹 + Action 唯一修改入口 | → | **高可並行度（Parallelism）**<br/><br/>因為 Resolver 並行執行，所以多個 Resolver 可同時載入資料，減少總執行時間；因為狀態可序列化，所以同步可以 snapshot 模式進行，不阻塞狀態變更；因為單一狀態樹 + Action 唯一修改入口，所以不同房間的 StateTree 可以並行執行（房間隔離）。因此有高可並行度。 |
| 單一狀態樹 + Action 唯一修改入口<br/>+ 同步策略分離<br/>+ State/Action/Resolver 明確分層 | → | **高可維護性（Maintainability）**<br/><br/>因為單一狀態樹 + Action 唯一修改入口，所以狀態變更集中且路徑明確，易於理解；因為同步策略分離，所以同步邏輯與業務邏輯解耦，職責清晰；因為 State/Action/Resolver 明確分層，所以各層職責清晰，結構清楚。因此有高可維護性。 |

---

## 8. 架構核心總結（最重要的五句話）

1. **Resolver 提供資料，不提供狀態。**
2. **Action handler 決定哪些資料要寫入 StateTree。**
3. **StateTree 是唯一真實來源，所有 sync 來自於它。**
4. **Resolver 在 handler 執行前並行執行，handler 同步存取結果。**
5. **建議 Action handler 保持 deterministic，有利於除錯、回放和未來擴展。**

---

## 附錄：Swift 實作參考

> 以下章節說明如何在 Swift 中實作 StateTree programming model 的相關概念，供 Swift 開發者參考。概念部分（上述章節）是語言無關的，可獨立閱讀。

### A.1 StateNode 的 Swift 實作

StateTree 中的狀態在 Swift 中實作為實作 `StateNodeProtocol` 的 `struct` 類型，並使用 `@StateNodeBuilder` macro 標記：

* `StateNodeProtocol`：定義狀態節點的協議
* `@StateNodeBuilder` macro：在編譯期生成必要的同步 metadata
* `@Sync`：標記同步策略（如 `.broadcast`、`.perPlayer` 等）
* `@Internal`：標記內部使用、不同步的欄位

狀態透過 `inout` 參數在 Action handler 中修改。

### A.2 Action Handler 的 Swift 實作

Action handler 在 Swift 中的簽名為：

```swift
(inout State, ActionPayload, LandContext) throws -> Response
```

* Action handler 在 `LandKeeper` actor 的隔離上下文中執行
* Handler 是同步的，但 Resolver 會在執行前並行完成
* State 透過 `inout` 參數直接修改

### A.3 Resolver 的 Swift 實作

Resolver 在 Swift 中實作為實作 `ContextResolver` protocol 的類型：

* Resolver 的輸出必須實作 `ResolverOutput` protocol
* 在 handler 中透過 `LandContext` 的 `@dynamicMemberLookup` 特性存取 resolver 結果
* Resolver 在 handler 執行前並行執行

**使用範例**：

```swift
Rules {
    HandleAction(UpdateCartAction.self, resolvers: (ProductInfoResolver.self, UserBalanceResolver.self)) { state, action, ctx in
        // Resolver 已經並行執行完成，結果可直接使用
        let productInfo = ctx.productInfo  // ProductInfo?
        let userBalance = ctx.userBalance  // UserBalance?
        // ...
    }
}
```

### A.4 Runtime 的 Swift 實作

* `LandKeeper`：作為 actor，管理狀態並執行 handlers
* `LandContext`：提供 handler 所需的上下文資訊
* `SyncEngine`：負責生成狀態快照和差異，實現同步機制

---

**完整的 Swift 實作說明請參考**：
- [Land DSL 指南](core/land-dsl.md)
- [同步規則詳解](core/sync.md)
- [Runtime 運作機制](core/runtime.md)
- [Resolver 使用指南](core/resolver.md)
