[English](land-dsl.md) | [中文版](land-dsl.zh-TW.md)

# Land DSL

Land 是伺服器邏輯的最小可運行單位，負責定義加入規則、行為規則與生命周期。
`Land(...)` 會收集 DSL 節點並產生 `LandDefinition<State>`，交由 Runtime 執行。

## 設計說明

- Land DSL 只描述行為，不暴露 Transport 細節
- handlers 以同步方式定義；輸出請用 `ctx.emitEvent(...)` / `ctx.requestSync*()`，非同步 I/O 請在 handler 之外處理（例如 Resolver）。
- 事件型別註冊（Client/ServerEvents）用於 schema 與驗證
- Handler closure 不必寫出型別：state 型別來自 `Land(_:using:)`，每個 input 型別來自它的 handler 的 `.self` 參數

## 基本結構

```swift
Land("demo", using: GameState.self) {
    AccessControl { ... }
    ClientEvents { ... }
    ServerEvents { ... }
    Rules { ... }
    Lifetime { ... }
}
```

## AccessControl

控制房間可見性與人數上限：

- `AllowPublic(true|false)`
- `MaxPlayers(Int)`

## ClientEvents / ServerEvents

註冊事件型別（schema/驗證/工具會用到）：

```swift
ClientEvents {
    Register(ClickCookieEvent.self)
}

ServerEvents {
    Register(PongEvent.self)
}
```

land 處理的每個 client event 都要註冊，註冊的每個 client event 都要處理。兩份清單不一致的 land 會在註冊時被拒絕：註冊了卻沒有 `HandleEvent` 的 event，或處理了卻沒有 `Register` 的 event。錯誤 `LandRegistrationError.clientEventMismatches` 會列出每個這樣的 event 與它缺少的那一邊。沒經過註冊就建立的 keeper，會在初始化時拒絕這個 land。

server event 是通知，同步的狀態才是真實來源。仍在加入中的 session，會在它的 firstSync 之後依送出順序收到送給它的 targeted event，而這些 event 的效果已經包含在該 firstSync 裡（見 [Transport](../transport/README.zh-TW.md#join-與-session-流程)）。

## Rules

規則區塊定義 Join/Leave 與 Action/Event 行為：

- `CanJoin`：加入前驗證，回傳 `JoinDecision`
- `OnJoin` / `OnLeave`：加入或離開後處理
- `HandleAction`：處理 Action（回傳 action 宣告的 `Response`）
- `HandleEvent`：處理 Client Event（無回應）

Handler body 不會拋出錯誤；可被拒絕的 input 使用 `validate` 與 `apply`（[兩段式 Handler](#兩段式-handler)）。

```swift
Rules {
    CanJoin { state, session, ctx in
        .allow(playerID: PlayerID(session.playerID))
    }

    OnJoin { state, ctx in
        // mutate state
    }

    HandleAction(JoinAction.self) { state, action, ctx in
        return JoinResponse(status: "ok")
    }

    HandleEvent(ClickCookieEvent.self) { state, event, ctx in
        // mutate state
    }
}
```

### 兩段式 Handler

Input handler 寫入後不能再拋出錯誤（#586）。單一 closure 的 `HandleAction`、`HandleEvent`、`HandleServerInput`、`OnJoin` 與 `OnLeave` 接受的 body 都不會拋出錯誤。可被拒絕的 input 分兩段宣告，`validate` 與 `apply`：

```swift
HandleAction(BuyAction.self,
    validate: { state, action, ctx in
        guard let item = state.shop[action.itemID] else { throw ShopError.notFound }
        guard (state.players[ctx.playerID]?.gold ?? 0) >= item.price else { throw ShopError.noGold }
        return BuyPlan(item: item)
    },
    apply: { state, action, plan, ctx in
        state.players[ctx.playerID]?.gold -= plan.item.price
        state.players[ctx.playerID]?.items.append(plan.item)
        return BuyResponse(ok: true)
    })
```

| 步驟 | 何時 | 做什麼 | 不能做 |
|---|---|---|---|
| resolve（`resolvers:`） | 非同步，在 turn 之外、之前 | 載入資料（資料庫、遠端呼叫、時鐘）；其輸出會被錄製 | 碰狀態 |
| `validate` | 同步，在 turn 內 | 讀取狀態（常數）與 context；拋出錯誤表示拒絕；回傳 plan | 寫入狀態、發出 event、要求同步 |
| `apply` | 同步，在同一個 turn 內、緊接在 `validate` 之後 | 寫入狀態、發出 event、回傳 response | 拋出錯誤 |

- 沒有東西要傳時，`validate` 回傳 `Void`，`apply` 接受 `(inout State, Action, LandContext)`。
- `HandleEvent(_:validate:apply:)` 與 `HandleServerInput(_:validate:apply:)` 有相同的兩種形式；它們的 `apply` 回傳 `Void`。`HandleAction` 的兩種形式都可加 `resolvers:`；加了之後，兩段都在 action 之後收到其輸出：`validate: { state, action, outputs, ctx in … }`、`apply: { state, action, outputs, plan, ctx in … }`。
- `validate` 借用狀態：不會複製。它在同一個 turn 內緊接在 `apply` 之前執行，因此它檢查過的條件在 `apply` 寫入時仍然成立。
- `validate` 拋出錯誤時只有該 input 失敗，什麼都不寫入、什麼都不發出。Action 的呼叫者收到錯誤（`ACTION_HANDLER_ERROR`；在 tick land 上呼叫者在收件時已收到 ACK），event 的錯誤以 error payload 送給 client（限於 tickless land，event 會在那裡等待自己的 input turn；在 tick land 上 event 於下一個 tick 套用，因此在那裡拒絕只記錄在 log），server input 的錯誤記錄在 log（[Runtime：Input 與 Turn](runtime.zh-TW.md#input-與-turn)）。
- Action body 與 `apply` 回傳 action 宣告的 `Response`（#561）。回傳其他型別無法編譯。

#### ValidateContext

`validate` 收到的是 `ValidateContext`，不是 `LandContext`：

- **可用：** `landID`、`playerID`、`clientID`、`sessionID`、`deviceID`、`isGuest`、`metadata`、`tickId`、`playerSlot`、`logger`，以及只限 `ReadOnlyLandService` 型別的 `services`。
- **不可用：** `emitEvent`、`requestSyncNow()` / `requestSyncBroadcastOnly()`、server input、亂數、排程。

`ReadOnlyLandService` 是 marker protocol，也是編譯器無法檢查的約定：該 service 只讀取，且相同輸入給出相同答案，因為 replay 會再執行一次 `validate`。不具決定性的資料（時鐘、遠端呼叫、亂數來源）應放在 resolver，其輸出會被錄製。以 existential 型別註冊的 service（`register(x, as: (any P).self)`）無法透過 marker 取得；請以其具體型別註冊。

#### 每種型別一個 Handler

一個 land 對每種 action 型別只宣告一個 `HandleAction`，對每種 client event 型別只宣告一個 `HandleEvent`，對每種 server input 型別只宣告一個 `HandleServerInput`。第二個宣告會在註冊時以 `LandRegistrationError.duplicateHandlers` 拒絕，錯誤中標明型別與兩處宣告的 `fileID:line`。未經註冊直接建立的 keeper 也會在初始化時拒絕。輸入依名稱派送，所以共用同一個名稱的兩種不同型別也會以同樣方式拒絕（#599）：名稱、最後一段或 schema 名稱重疊的兩種 action 型別（`Ping` 與 `PingAction`，或 `A.Move` 與 `B.Move`）、同名的兩種 server input 型別，以及 event 名稱相同的兩種已註冊 client／server event 型別（`Hit` 與 `HitEvent`）。

#### 編譯器擋不住的事

- 不具決定性的 `validate`：讀取全域可變狀態或時鐘，或呼叫遵循 `ReadOnlyLandService` 卻不守約定的 service。Replay 再執行 `validate` 時可能做出不同決定。
- 透過狀態中持有的 class 參照寫入。state 不能放 class：state 欄位的值是 `PlainData`，在編譯期檢查（#464，[Sync](sync.zh-TW.md#同步狀態只能由-value-type-組成)）。
- `validate` 中的副作用，例如寫 log：replay 會重複它們。

### Join 檢查

`OnJoin` 不會失敗：玩家能否加入由 `CanJoin` 在 join 收件時決定。`OnJoin` 在之後的 turn 才套用，因此 `CanJoin` 對其他 input 會改變的狀態所做的檢查，到那時可能已經過時（turn 內的 join 檢查由 #588 追蹤）。不要把這類依賴狀態的檢查放在 `CanJoin`，改在 `OnJoin` 處理已經不適合加入的 joiner：讓他成為旁觀者，或發出 event 請他離開。`MaxPlayers` 不受影響：它在插入玩家時檢查，並計入仍在等待中的 joiner。`OnLeave` 也不會失敗：離開一定會發生。

`CanJoin` 的事件與同步請求會被丟棄：它送出的事件與發出的同步請求都不會有作用。它只決定能否加入，replay 也不會再執行它，因此它送出的任何東西都無從核對。請改在 `OnJoin` 送出事件。

### 必須至多套用一次的 action

transport 至多傳遞一次 action，且不會對重送去重（見 SDK 的[傳遞語意](../sdk/README.zh-TW.md#傳遞語意至多一次at-most-once)）：
- **連線關閉後，結果未知。** 因 `ConnectionClosedError` 而被 reject 的等待中 action，可能已套用，也可能沒有。
- **SDK 不會重送。** 是否重送由 app 決定，伺服器會把重送當成一個新的請求來套用。
- **重新加入後，以 firstSync 的狀態為準**，判斷 action 是否生效。
- **在有 tick 的 land 上，回應只是 ACK，代表「已排入佇列」，不代表「已套用」。** handler 在之後的 tick 執行，它的回傳值不會送到 client。請從狀態讀取結果。

不能套用兩次的 action（例如購買），請在 land 的狀態裡去重：
- client 在 payload 裡放一個 ID，每次操作選一次，重送時原封不動再送；
- handler 把已套用過的 ID 記在狀態裡，遇到看過的 ID 就忽略。

放在狀態裡，這個檢查就是 land 決定性 turn 的一部分，錄製、replay 與 reevaluation 都會重現它；放在狀態以外的表則看不到。歷史的長度由 app 決定上限：比上限更舊的重送會再套用一次。

```swift
@StateNodeBuilder
struct ShopState: StateNodeProtocol {
    @Sync(.perPlayerSlice())
    var coins: [PlayerID: Int] = [:]

    /// Purchase IDs this land has applied, per player, newest last. Server-only: clients
    /// don't need it. Bounded by the app (see `maxAppliedPurchases`).
    @Sync(.serverOnly)
    var appliedPurchases: [PlayerID: [String]] = [:]

    init() {}
}

@Payload
struct BuyItemAction: ActionPayload {
    typealias Response = BuyItemResponse

    /// Chosen by the client once per purchase, and sent again unchanged if it resends.
    let purchaseID: String
    let itemID: String
    let price: Int
}

@Payload
struct BuyItemResponse: ResponsePayload {
    let applied: Bool
    let coins: Int
}

/// How many purchase IDs a player's history keeps; a resend older than that applies again.
let maxAppliedPurchases = 64

// In the land's Rules:
HandleAction(BuyItemAction.self) { state, action, ctx in
    let player = ctx.playerID
    let coins = state.coins[player] ?? 0
    var applied = state.appliedPurchases[player] ?? []
    // Already applied: change nothing.
    guard !applied.contains(action.purchaseID) else {
        return BuyItemResponse(applied: false, coins: coins)
    }
    guard coins >= action.price else {
        return BuyItemResponse(applied: false, coins: coins)
    }
    state.coins[player] = coins - action.price
    applied.append(action.purchaseID)
    if applied.count > maxAppliedPurchases {
        applied.removeFirst(applied.count - maxAppliedPurchases)
    }
    state.appliedPurchases[player] = applied
    return BuyItemResponse(applied: true, coins: coins - action.price)
}
```

- `appliedPurchases` 是 `.serverOnly`：client 不需要它，也不佔傳輸量。
- 歷史以玩家為單位。上限要遠大於「重送仍可能發生的期間內，一個玩家能送出的這類 action 數量」。
- 在有 tick 的 land 上，client 收到的 `BuyItemResponse` 只是 ACK，`coins` 要從狀態讀。
- 這裡的檢查不拒絕 action，而是回答它（`applied: false`），所以一個不會拋出錯誤的 body 就夠了。應以錯誤失敗的 action 改由 `validate` 拋出，它什麼都不寫入（[兩段式 Handler](#兩段式-handler)）。

## Helper 與 `@Land`

land 的 rules 就是遊戲規則：誰可以加入、input 怎麼改變狀態、時間怎麼推進、有哪些事件。helper 是一個函式，回傳其中一部分，例如 `chatRules()` 就是聊天的規則。在它上面加上 land 的 builder 並寫出 land 的 state 型別，回傳同樣型別的 `LandRules`。它的 closure 會像在 `Land(_:using:)` 裡一樣推斷型別：

```swift
@LandDSL<GameState, NoServices>
func joinRules() -> LandRules<GameState, NoServices> {
    OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
}

let land = Land("game", using: GameState.self) {
    joinRules()
    Rules { joinRules() }
}
```

`NoServices` 是沒有 services 的 land 的 services 型別。typealias 可以讓同一個 helper 寫得短一些：`typealias GameDSL = LandDSL<GameState, NoServices>` 與 `typealias GameRules = LandRules<GameState, NoServices>`，然後寫 `@GameDSL func joinRules() -> GameRules`。

helper 只能放進 state 型別與 services 型別都相同的 land。為別的 state 或別的 services 寫的 helper，在放進 land 的地方就無法編譯。給多個 land 用的 helper 寫成泛型：對這些 state 共有的 protocol 泛型，也對 services 型別泛型，任何 services 的 land 都能用它：

```swift
protocol HasPlayers: StateNodeProtocol {
    var players: [PlayerID: Int] { get set }
}

@LandDSL<S, Svc>
func leaveRules<S: HasPlayers, Svc: Sendable>() -> LandRules<S, Svc> {
    OnLeave { state, ctx in state.players[ctx.playerID] = nil }
}

let game = Land("game", using: GameState.self) { leaveRules() }
let lobby = Land("lobby", using: LobbyState.self, services: LobbyServices.self) { leaveRules() }
```

有些 node 一個 land 只宣告一次：`AccessControl`、`CanJoin`、`OnJoin`、`OnLeave`，以及 `Lifetime` 裡的每一項設定（`Tick`、`StateSync`、`DestroyWhenEmpty`、`PersistSnapshot`、`OnInitialize`、`OnFinalize`、`AfterFinalize`）。同一個 land 裡的兩個 helper 可能宣告同一個 node。這時 land 會在註冊時被拒絕，錯誤訊息會指出兩處宣告的位置。設定不同項目的兩個 `Lifetime` 區塊可以組合，`AllowedClientEvents` 清單與 `ServerEvents` 的註冊也可以。

`@Land` 把 land 宣告成一個型別。它的 `body` 在 builder 之下，並和 helper 一樣回傳 `LandRules`：

```swift
@Land(GameState.self)
struct GameLand {
    static var body: LandRules<GameState, NoServices> {
        Rules {
            OnJoin { state, ctx in state.players[ctx.playerID] = 0 }
        }
    }
}

let definition = GameLand.definition
```

`@Land(GameState.self)` 建立沒有 services 的 land。`@Land(GameState.self, services: AppServices.self)` 建立有 services 的 land：它的 `definition` 是 `TypedLand<GameState, AppServices>`，`body` 回傳 `LandRules<GameState, AppServices>`，並以 `register(landType:land:services:…)` 註冊（[Resolver：服務](resolver.zh-TW.md#服務)）。

## LandContext

Handler 會取得 `LandContext`，包含：

- `landID`, `playerID`, `clientID`, `sessionID`, `deviceID`
- `metadata`（來自 join/JWT/guest）
- `services`（注入外部服務）
- `emitEvent(...)`, `requestSyncNow()`, `requestSyncBroadcastOnly()`

LandContext 是 request-scoped，請避免保存引用。

## Resolver

`HandleAction`、`CanJoin`、`OnJoin`、`OnLeave`、`OnInitialize` 與 `OnFinalize` 可宣告 resolver。Resolver 在 handler 之前並行執行，handler 以參數收到其輸出：

```swift
HandleAction(AddToCartAction.self, resolvers: { _, action, _ in ProductInfo(productID: action.productID) }) {
    state, action, product, ctx in
    ...
}
```

`resolvers:` closure 在接納 input 的那個 turn 中，依 State 與 input 建出 resolver 值。見 [Resolver](resolver.zh-TW.md)。

## Lifetime

- `Tick(every:)`：遊戲邏輯更新（可修改 state）
- `StateSync(every:)`：狀態同步（只讀 callback，會被調用）
- `DestroyWhenEmpty(after:)`：空房間自動關閉
- `PersistSnapshot(every:)`：快照週期
- `OnInitialize` / `OnFinalize` / `AfterFinalize`。與 input handler 相同，它們寫入後都不會再拋出錯誤（#593）：
  - `OnFinalize` 與 `DestroyWhenEmpty(after:_:)` 的 handler 接受不會拋出錯誤的 body。Land 正在結束，沒有人會處理拒絕：body 若呼叫會拋出錯誤的程式碼，要自己處理錯誤。
  - `OnInitialize` 接受不會拋出錯誤的 body，或像 input 一樣分成 `validate` 與 `apply` 兩段（[兩段式 Handler](#兩段式-handler)）。`validate` 拋出錯誤時，land 的初始化失敗，和 resolver 失敗時相同，什麼都不寫入（見下方範例）。
  - 重新評估（replay）keeper 不會執行任何銷毀 handler：記錄中沒有 finalize 事件，replay 無法對其進行核對。
  - `StateSync` 的 callback 的事件與同步請求同樣會被丟棄：它送出的事件與發出的同步請求都不會有作用。Replay 不會再執行它，因此它送出的任何東西都無從核對。`ctx.random` 照常可用。
  - 銷毀 handler（`OnFinalize`、`AfterFinalize` 與 `DestroyWhenEmpty(after:_:)` 的 handler）沒有輸出：它們送出的事件與同步請求都會被丟棄。Land 正在結束，之後不會再有 tick 或同步把它們送出去。它們送出的 server input（`ctx.serverInputs.submit`）會以 drain 中為由被拒絕（`.refused(.draining)`）。`ctx.random` 照常可用。
- `OnInitialize(resolvers:onResolverFailure:)`：resolver 丟錯時預設會讓 land 初始化失敗（`.failLand`）；`.continue` 則在沒有 resolver 輸出的情況下執行 OnInitialize。見 [Resolver 期限](resolver.zh-TW.md#期限)

```swift
Lifetime {
    // 遊戲邏輯更新（20Hz）
    Tick(every: .milliseconds(50)) { state, ctx in
        // 使用 ctx.tickId (Int64) 進行確定性、重播相容的邏輯
        if let tickId = ctx.tickId {
            let tickIntervalSeconds = 0.05  // 50ms = 0.05s
            let gameTime = Double(tickId) * tickIntervalSeconds
            state.position += state.velocity * tickIntervalSeconds
        }
    }
    
    // 網路同步（10Hz）
    // Callback 是唯讀的，會在 sync 時被調用 - 請勿修改 state
    StateSync(every: .milliseconds(100)) { state, ctx in
        // 唯讀 callback - 會在 sync 時被調用
        // 用於日誌記錄、指標收集或其他唯讀操作
        // Network sync 機制會在 callback 之後觸發網路同步
    }
    // 如果未設定 StateSync，會自動配置為與 tick interval 相同
}
```

**注意**：`Tick` 是重播功能中唯一可修改 state 的來源。`StateSync` 僅觸發狀態同步，不會修改 state。可選的 callback 是唯讀的，會在 sync 操作時被調用，用於日誌記錄、指標收集或其他唯讀操作。

### 可被拒絕的初始化

Land 可能需要某些資料才能開始：例如由 resolver 載入的房間設定。`validate` 檢查資料是否存在，並把它當作 plan 回傳。`apply` 把它寫入。

```swift
Lifetime {
    OnInitialize(
        resolvers: { _, ctx in RoomConfig(roomID: ctx.landID) },
        onResolverFailure: .continue,
        validate: { _, roomConfig, _ in
            guard let roomConfig else { throw RoomSetupError.noConfig }
            return roomConfig
        },
        apply: { state, _, config, _ in
            state.maxPlayers = config.maxPlayers
        }
    )
}
```

使用 `.continue` 時，resolver 拋出錯誤會讓 `roomConfig` 為 `nil`，`validate` 便會拒絕。拒絕會讓初始化失敗，和 resolver 使用 `.failLand` 時相同：land 被拆除且不執行 destroy handler，正在等待的 join 收到可重試的 `JOIN_DENIED`。重試的 join 會建立新的 land。
