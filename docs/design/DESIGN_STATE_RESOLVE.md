# StateResolve：為子樹指定 Resolver 與填充策略

## 目標

`StateResolve` 區塊用於宣告：

- 在該 Land 中，**哪些 State 子樹**由**哪個 Resolver 型別**負責；
- 該子樹在 runtime 的**填充（hydrate）策略**與**持久化（persist）策略**。

這些宣告僅定義關係與策略；實際的 IO、domain 邏輯由符合 `StateNodeResolver` 的 Resolver 實作。

---

## 語法概觀

在 Land DSL 的 `body` 中加入 `StateResolve`：

```swift
@Land(GameState.self, client: ClientEvents.self, server: ServerEvents.self)
struct GameLand {
    static var body: some LandDSL {
        AccessControl { ... }
        Rules { ... }
        Lifetime { ... }

        StateResolve {
            Resolve(ProfileState.self, ProfileResolver.self)

            Resolve(CartState.self, CartResolver.self)
                .fill(.onEnter)
                .persist(.onAction)

            Resolve(PlayerState.self, PlayerResolver.self)
                .fill(.onDemand)
        }
    }
}
```

### 基本語法

```swift
Resolve(StateType.self, ResolverType.self)
```

- `StateType`：要被管理的 State 子樹型別（例如 `CartState`、`ProfileState`）。
- `ResolverType`：該子樹對應的 Resolver（需符合 `StateNodeResolver<StateType>`）。

預設策略（可由實作覆寫）：

- `fill`: `.onEnter`
- `persist`: `.never`

### 進階：鏈式修飾

可以針對個別子樹覆寫 `fill` / `persist`：

```swift
Resolve(CartState.self, CartResolver.self)
    .fill(.onEnter)
    .persist(.onAction)

Resolve(PlayerState.self, PlayerResolver.self)
    .fill(.onDemand)
```

---

## FillPolicy / PersistPolicy

### FillPolicy（填充策略）

決定何時載入／填充該子樹狀態：

```swift
public enum FillPolicy {
    /// 進入 Land / Room / Page 時填充
    case onEnter

    /// 第一次被讀取時才填充（lazy）
    case onDemand

    /// 僅由 action 推動狀態變化，不主動從外部載入
    case actionDriven

    /// runtime 或 Resolver 自行定義的進階策略
    case custom(/* implementation-defined */)
}
```

範例：

- `ProfileState`：進入房間時需要 → `.fill(.onEnter)`
- `PlayerState`：人數多、可能不會被用到 → `.fill(.onDemand)`
- 計算型結果、僅在 action 時更新 → `.fill(.actionDriven)`

### PersistPolicy（持久化策略）

決定何時呼叫 `Resolver.persist`：

```swift
public enum PersistPolicy {
    /// 不主動持久化（完全 in-memory）
    case never

    /// 每次成功處理 action 後持久化
    case onAction

    /// runtime 在 checkpoint / 關閉時呼叫（例如房間結束）
    case onCheckpoint

    /// runtime 或 Resolver 自行定義的進階策略
    case custom(/* implementation-defined */)
}
```

範例：

- `CartState`（電商）：`.fill(.onEnter).persist(.onAction)` → 進頁面載入購物車，每次操作寫回 DB/Redis。
- `MatchResultState`（對戰結果）：`.fill(.actionDriven).persist(.onCheckpoint)` → 對戰結束時寫入最終結果。

---

## 優化項目：同步性分離原則

### 核心原則

**所有會改動 State 的操作必須是同步的，只有 Resolve（資料載入）操作可以是非同步的。**

這是為了確保狀態變更的可預測性、可追蹤性與可回放性。具體規則如下：

### 必須同步的操作（State Mutation）

以下操作**必須是同步的**，不能使用 `async`：

- **Action Handler**：`HandleAction` 內的所有邏輯
- **Event Handler**：`HandleEvent` 或 `On(ClientEvents)` 內的所有邏輯
- **Lifetime Handlers**：`OnJoin`、`OnLeave`、`OnTick`、`OnShutdown` 等
- **Resolver.resolveAction**：處理 action 並變更 state 的邏輯

這些操作的共同特點是**會直接修改 State**，因此必須在單一同步執行緒中完成，確保狀態變更是原子性且可預測的。

### 允許非同步的操作（Data Resolution）

只有以下操作**允許使用 `async`**：

- **Resolver.hydrate**：從外部資料來源（DB、Redis、API）載入資料
- **Resolver.persist**：將 state 寫回外部儲存層
- **Context.resolved.xxx**：透過 lazy resolver 存取外部資料時

這些操作屬於**資料 IO**，不直接修改 state，因此可以非同步執行。

### 資料流設計

正確的模式是：

1. **非同步載入資料**（`hydrate` / `ctx.resolved.xxx`）→ 將結果放入 context
2. **同步處理邏輯**（`HandleAction` / `OnJoin` / `resolveAction`）→ 基於已載入的資料修改 state
3. **非同步持久化**（`persist`）→ 將變更寫回儲存層

這樣設計的好處：

- **可預測性**：state mutation 是同步的，不會有競態條件
- **可回放性**：同步的 state mutation 易於重現與除錯
- **效能**：resolver 可以並行執行（透過 `.needs()`），但 state mutation 保證順序

### 實作範例

```swift
// ✅ 正確：hydrate 可以 async（資料載入）
static func hydrate(
    _ state: inout NodeState,
    context: HydrateContext
) async throws {
    let data = try await fetchFromDatabase()
    state.value = data
}

// ✅ 正確：resolveAction 必須 sync（會改動 state）
static func resolveAction(
    _ action: AnyActionPayload,
    state: inout NodeState,
    context: ActionContext
) throws -> Bool {
    // 同步處理邏輯並修改 state
    state.counter += 1
    return true
}

// ✅ 正確：persist 可以 async（資料寫出）
static func persist(
    _ state: NodeState,
    context: PersistContext
) async throws {
    try await saveToDatabase(state)
}
```

```swift
// ✅ 正確：HandleAction 必須 sync
HandleAction(UpdateCart.self) { state, action, ctx in
    // 同步處理邏輯
    state.items.append(action.item)
}

// ❌ 錯誤：HandleAction 不能 async
HandleAction(UpdateCart.self) { state, action, ctx async in
    // 這會破壞同步性原則
}
```

---

## 與 StateNodeResolver 的對應

`Resolve(StateType.self, ResolverType.self)` 要求 Resolver 實作下列介面：

```swift
public protocol StateNodeResolver<NodeState> {
    associatedtype NodeState: Codable & Sendable

    // ✅ 允許 async：資料載入操作
    static func hydrate(
        _ state: inout NodeState,
        context: HydrateContext
    ) async throws

    // ✅ 必須 sync：會直接改動 state 的操作
    static func resolveAction(
        _ action: AnyActionPayload,
        state: inout NodeState,
        context: ActionContext
    ) throws -> Bool  // 注意：已移除 async

    // ✅ 允許 async：資料持久化操作
    static func persist(
        _ state: NodeState,
        context: PersistContext
    ) async throws
}
```

每條 `Resolve` 宣告在 macro 展開後會產生 metadata：

```swift
struct ResolvedNodeConfig {
    let stateType: Any.Type
    let resolverType: Any.Type
    let fillPolicy: FillPolicy
    let persistPolicy: PersistPolicy
}
```

Active / Passive runtime 會依據這些設定運作：

- Active（房間 / realtime）：
  - 初始化時依 `fillPolicy` 決定是否呼叫 `hydrate`（async）
  - 收到 action 時路由至對應 Resolver 的 `resolveAction`（sync，若需外部資料會先透過 resolver hydrate）
  - 關閉或 checkpoint 時依 `persistPolicy` 決定是否呼叫 `persist`（async）

- Passive（stateless / REST / Redis）：
  - 每次 HTTP/RPC 請求期間，依 `fillPolicy` 決定是否從 Redis/DB 載回該子樹（async，透過 `hydrate`）
  - 執行 action 時，若需外部資料會先透過 resolver 載入，然後同步執行 state mutation
  - 執行 action 後依 `persistPolicy` 決定是否寫回儲存層（async，透過 `persist`）

---

## 使用建議

為避免 Resolver 粒度過細造成複雜度上升，建議：

- **推薦掛 Resolver 的種類**：具備明確業務邏輯的 aggregate，例如 `RoomState`, `CartState`, `ProfileState`, `PlayerState`, `ChatState`。
- **不建議單獨掛 Resolver 的節點**：單純 value 或 leaf 欄位（`HP`, `Name`, `CreatedAt`, `Vector2`, `Color` 等），這類欄位應由所屬 aggregate 的 Resolver 一併處理。

---

## Action 層級的 Resolver 控制：`.needs()` 與 Eager / Lazy Resolve

### 概念

Resolver 執行有兩種模式：

- **Lazy Resolve（預設）**：resolver 在第一次使用時才執行。
- **Eager Resolve（`.needs()`）**：resolver 在 Action 執行前提前執行。

這不是為了「能不能取得資料」，而是為了「什麼時機點取得資料」。

### Lazy Resolve（預設行為）

不指定 `.needs()` 時：

```swift
HandleAction(UpdateCart.self)
```

- `ctx.resolved.carItem` 是一個 lazy slot。
- Action 邏輯真正讀取該值時才執行 resolver 的 `hydrate`（async，但會在存取點 await）。
- 若 Action 未使用該值 → 完全不呼叫 resolver，零成本。
- 最適合不確定是否需要某資料的情況。
- 注意：第一次存取 lazy resolver 時會觸發 async hydrate，之後的值會被快取供 Action 使用。

### Eager Resolve（`.needs()` 修飾器）

指定 `.needs()` 時：

```swift
HandleAction(UpdateCart.self)
    .needs(CarItemInfo.self)
    .needs(ProfileInfo.self)
    .needs(ShopConfigInfo.self)
```

- Action 執行前就已經完成所有指定的 resolver 的 `hydrate`（async 操作）。
- `ctx.resolved.carItemInfo`、`ctx.resolved.profileInfo` 等已有值（資料已準備好）。
- Action 執行時直接使用已載入的資料，不會卡在查資料（因為 Action 本身是 sync）。
- **Runtime 可以並行執行這些 resolvers**，提升吞吐量。

### Lazy vs Eager 比較

| 行為            | Lazy（預設）        | Eager（`.needs()`）  |
| ------------- | --------------- | ------------------ |
| 何時呼叫 resolver | 第一次存取時          | Action 執行前         |
| 效能模式          | 按需、快            | 高吞吐、預先準備           |
| 未使用資料時        | 不呼叫、零成本         | 仍會呼叫（有成本）          |
| 是否允許並行        | 部分（視 Action 使用） | ✔ 全部 resolvers 可並行 |
| 適合場景          | 不確定是否會用到        | 一定會用到、且希望提前準備      |
| DSL 表達語意      | 自動依需求           | 明確宣告依賴關係           |

### `.needs()` 的定義

```swift
.needs(T.self)
```

表示該 Action 在執行前一定需要 `T` 的 resolver 的 `hydrate` 被完整執行並完成（async 操作會在 Action 執行前完成）。若未宣告 `.needs()`，`T` 的 resolver 會以 lazy 方式在 `ctx.resolved.T` 第一次被讀取時才執行（此時會在存取點 await async hydrate）。無論是 eager 或 lazy，Action 本身的執行都是同步的。

### 實踐場景

- **一個 Action 需要多個資料來源**時，宣告 `.needs()` 讓 runtime 並行準備，避免串行延遲。
- **某個 resolver 成本很高或必須提前準備**時，用 `.needs()` 強制執行。
- **大部分場景下 lazy 就足夠**，除非有性能或邏輯需求才加 `.needs()`。

---

## 完整數據流：Resolver → Action → StateTree → Client

下列圖示展示 Resolver、Action、State 與 Client 的完整互動流程：

```
 +----------------+
 |  Resolver(s)   |  --->  外部資料（lazy/eager，由 .needs() 控制）
 +----------------+
          |
          | ctx.resolved.xxx
          v
 +----------------+
 |    Action      |  ---> 根據 resolver + payload 計算 → 決策
 +----------------+
          |
          | state mutation (inout)
          v
 +----------------+
 |   StateTree    |  ---> authoritative state
 +----------------+
          |
          | diff
          v
 +----------------+
 |     Client     |  ---> reactive UI 更新
 +----------------+
```

### 流程說明

1. **Resolver（資料來源層）**
   - 負責從外部系統（DB、Redis、API、檔案等）取得資料。
   - 由 `.needs()` 決定何時執行（eager）或何時執行（lazy）。
   - 結果放入 `ctx.resolved.*` 供 Action 使用。

2. **Action（決策層）**
   - 讀取 `ctx.resolved.xxx` 和 payload 資訊（資料已在 Action 執行前由 resolver 準備好）。
   - 執行業務邏輯，決定如何變更 State（**同步執行**）。
   - 直接變更 `state` parameter（`inout`）。

3. **StateTree（權威狀態層）**
   - Action 完成後，StateTree 包含最新狀態。
   - 這是「單一信源」(source of truth)。
   - 會計算與舊狀態的 diff。

4. **Client（UI 層）**
   - 接收 diff 推送，更新本地狀態。
   - 重新渲染 reactive UI。

### 關鍵設計特點

- **Resolver 與 Action 分離**：Action 不直接查資料，透過 Resolver 機制取得；支援 lazy 與 eager 兩種模式。
- **同步性分離**：Resolver（資料載入）可以是 async，但 Action（狀態變更）必須是 sync，確保狀態變更的可預測性。
- **Inout Mutation**：Action 直接修改 State，簡潔且高效。
- **Diff 推播**：只把變化傳給 client，節省頻寬。
- **並行化**：多個 `.needs()` resolver 可並行執行，提升吞吐；但 Action 執行本身是同步且順序的。

---

## 三個關鍵點一次收斂

下列為可直接摘錄到設計文件或 README 的精簡說明，整合了 Resolver、Lazy/onDemand 與 Active/Passive 的設計要點。

1. Resolver

   - **定義**：Resolver 是某一個 State 子樹的「解決者」，負責 hydrate、resolveAction 與 persist。
   - **宣告方式**：透過 `StateResolve { Resolve(State, Resolver) ... }` 指定哪個 State 由哪個 Resolver 處理，並可設定 fill/persist 策略。

2. Lazy + `.fill(.onDemand)`

   - **語意**：`.onDemand` 表示不會在進入時自動載入，只有當程式第一次讀取該子樹時才觸發 `hydrate`。對 domain 程式碼而言，存取仍像一般屬性讀取。實作上通常以 `LazyNode<T>` + async getter 實現。

   - **範例**：

     ```swift
     var cart: CartState {
         mutating get async throws {
             if !storage.cart.isLoaded {
                 let hydrated = try await runtime.hydrate(
                     CartState.self,
                     resolver: CartResolver.self,
                     path: ["cart"]
                 )
                 storage.cart.set(hydrated)
             }
             return storage.cart.value
         }
         set { storage.cart.set(newValue) }
     }
     ```

3. Active / Passive 與 Resolver/Lazy 的對照

   - **Active**：State 常駐記憶體（例如每個房間一顆），actor 保護資料一致性；`.onDemand` 在房間內首次存取時做記憶體載入，變更會由 Diff Engine 推送給 client。
   - **Passive**：State 存於外部儲存（Redis/DB），每次請求期間在第一次存取該子樹時由 Resolver 從儲存層載回；請求結束後依 persist 策略寫回。

   - **要點**：`Resolver + Lazy + fillPolicy` 用於定義子樹的生命週期；`Active / Passive` 決定 StateTree 的置放與存取方式。

---

### 精要（可直接引用）

- **Resolver**：每個有業務語意的 State 子樹可以綁定一個 Resolver，負責 hydrate、resolveAction 與 persist。
- **Lazy `.fill(.onDemand)`**：只有第一次存取時由 Resolver.hydrate 自動載入；對使用者透明且像一般屬性讀取。
- **Active / Passive 共用語意**：`Resolve(...).fill(...).persist(...)` 在兩種模式下語意一致，差別在於 State 的實體位置（記憶體 vs 外部儲存）。


