# StateResolve：為子樹指定 Resolver 與填充策略

## 目標

`StateResolve` 區塊用來宣告：

- 在這個 Land 裡，**哪一段 State 子樹** 要由 **哪一個 Resolver 型別** 負責。
- 該子樹在 runtime 中應採用的 **填充（fill / hydration）策略** 與 **持久化（persist）策略**。

這些宣告只負責「**關係與策略**」，實際邏輯由 Swift 端的 `StateNodeResolver` 實作。

---

## 語法概觀

在 Land DSL 中，可以在 `body` 內新增一個 `StateResolve` 區塊：

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

- `StateType`: 要被管理的子樹 State 型別（例如 `CartState`、`ProfileState`）。
- `ResolverType`: 負責該子樹邏輯的 Resolver 型別（必須符合 `StateNodeResolver<StateType>`）。

此寫法會套用預設策略（建議預設值，可依實作調整）：

- `fill`: `.onEnter`
- `persist`: `.never`

### 進階：鏈式修飾子

可以針對個別子樹覆寫 fill / persist 策略：

```swift
Resolve(CartState.self, CartResolver.self)
    .fill(.onEnter)
    .persist(.onAction)

Resolve(PlayerState.self, PlayerResolver.self)
    .fill(.onDemand)
```

---

## FillPolicy / PersistPolicy 說明

### FillPolicy（填充策略）

對應子樹在 runtime 中「何時載入 / 填充狀態」：

```swift
public enum FillPolicy {
    /// 進入 Land / Room / Page 時填充
    case onEnter
    
    /// 第一次被讀取時才填充（lazy）
    case onDemand
    
    /// 僅由 action 推動狀態變化，不主動從外部載入
    case actionDriven
    
    /// 由 runtime 或 Resolver 自行定義的進階策略
    case custom(/* implementation-defined */)
}
```

範例：

- `ProfileState`：進入房間時就需要 → `.fill(.onEnter)`
- `PlayerState`：人數多、可能不會全部用到 → `.fill(.onDemand)`
- 純 Session 計算結果、完全由 action 決定 → `.fill(.actionDriven)`

### PersistPolicy（持久化策略）

決定何時對該子樹呼叫 `Resolver.persist`：

```swift
public enum PersistPolicy {
    /// 不主動持久化（完全 in-memory）
    case never
    
    /// 每次成功處理 action 後持久化
    case onAction
    
    /// 由 runtime 在 checkpoint / 關閉時呼叫（例如房間結束）
    case onCheckpoint
    
    /// 由 runtime 或 Resolver 自行定義的進階策略
    case custom(/* implementation-defined */)
}
```

範例：

- `CartState`（電商）：
  `.fill(.onEnter).persist(.onAction)`
  → 進頁面就載入購物車，每次操作都寫回 DB / Redis。
- `MatchResultState`（遊戲對戰結果）：
  `.fill(.actionDriven).persist(.onCheckpoint)`
  → 只在對戰結束時寫入一筆最終記錄。

---

## 與 StateNodeResolver 的對應

`Resolve(StateType.self, ResolverType.self)` 要求：

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

Land DSL 中的每一行 Resolve 宣告，在 compile-time/macro 展開後，會生成對應的 metadata：

```swift
struct ResolvedNodeConfig {
    let stateType: Any.Type
    let resolverType: Any.Type
    let fillPolicy: FillPolicy
    let persistPolicy: PersistPolicy
}
```

Active / Passive runtime 都會依這個設定：

- Active（房間 / realtime）：
  - 初始化：依 `fillPolicy` 決定是否呼叫 `hydrate`
  - 收到 action：route 到對應 Resolver 的 `resolveAction`
  - 關閉 / checkpoint：依 `persistPolicy` 決定是否呼叫 `persist`
- Passive（stateless / REST / Redis）：
  - HTTP / RPC 請求時：依 `fillPolicy` 決定是否從 Redis/DB 填充子樹
  - 完成 action 後：依 `persistPolicy` 決定是否寫回 Redis/DB

---

## 建議使用準則

為避免 Resolver 粒度過細造成複雜度上升，建議：

- **適合掛 Resolver 的子樹**：
  - 具有清楚業務語意的 aggregate：
    - `RoomState`, `CartState`, `ProfileState`, `PlayerState`, `ChatState`…

- **不建議單獨掛 Resolver 的節點**：
  - 單純 value 型別或 leaf 欄位：
    - `HP`, `Name`, `CreatedAt`, `Vector2`, `Color`…
    - 這些欄位應由所屬 aggregate 的 Resolver 一併處理。

