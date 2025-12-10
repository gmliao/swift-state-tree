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

## 與 StateNodeResolver 的對應

`Resolve(StateType.self, ResolverType.self)` 要求 Resolver 實作下列介面：

```swift
public protocol StateNodeResolver<NodeState> {
    associatedtype NodeState: Codable & Sendable

    static func hydrate(
        _ state: inout NodeState,
        context: HydrateContext
    ) async throws

    static func resolveAction(
        _ action: AnyActionPayload,
        state: inout NodeState,
        context: ActionContext
    ) async throws -> Bool

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
  - 初始化時依 `fillPolicy` 決定是否呼叫 `hydrate`
  - 收到 action 時路由至對應 Resolver 的 `resolveAction`
  - 關閉或 checkpoint 時依 `persistPolicy` 決定是否呼叫 `persist`

- Passive（stateless / REST / Redis）：
  - 每次 HTTP/RPC 請求期間，依 `fillPolicy` 決定是否從 Redis/DB 載回該子樹
  - 執行 action 後依 `persistPolicy` 決定是否寫回儲存層

---

## 使用建議

為避免 Resolver 粒度過細造成複雜度上升，建議：

- **推薦掛 Resolver 的種類**：具備明確業務邏輯的 aggregate，例如 `RoomState`, `CartState`, `ProfileState`, `PlayerState`, `ChatState`。
- **不建議單獨掛 Resolver 的節點**：單純 value 或 leaf 欄位（`HP`, `Name`, `CreatedAt`, `Vector2`, `Color` 等），這類欄位應由所屬 aggregate 的 Resolver 一併處理。

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


