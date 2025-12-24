# 🧭 Land DSL v1（優化版）總覽

**目標：**

* 用一個 `@Land` 標註的 struct

  清楚描述一座「世界樂園」的：

  * 大門規則（誰能進來）

  * 遊戲規則（Action / Event / OnJoin / OnLeave）

  * 營業時間 / 生命週期（Tick、關園、持久化）

* Action / Event 都是 **型別導向（type-driven）**

  不再強迫用單一 enum 寫死。

* Event handler 支援：

  * 泛用：`On(ClientEvents.self) { ... }`

  * 自動生成語義化版本：`OnReady { ... }`, `OnChat { ... }`

    透過 macro / codegen 自動對應到 `ClientEvents.ready / .chat`。

* 與現有 StateTree、SyncEngine 完整相容。

---

## 0️⃣ 快速導覽：從 DSL 到 Runtime

1. `@Land`（或 `Land(...)`）會把 `AccessControl / Rules / Lifetime` 區塊收集成 `[LandNode]`，交給 `LandBuilder` 組出 `LandDefinition`。
2. `LandDefinition` 持有 state 型別、事件型別與所有 handler，`LandKeeper` runtime 只需要這份定義就能處理 Action、Event 與 Tick。
3. Transport 端透過 `ActionEnvelope` 與泛型 `Event` 封包對應型別，詳見 `docs/design/DESIGN_EVENT_ACTION_GENERIC.md`。

> 這個流程確保 DSL 僅描述行為，runtime 與傳輸層實作可以獨立演進。

---

## 1️⃣ 核心 Protocol 與基礎型別

### 1.1 Action / Event 基底

```swift
public protocol ActionPayload: Codable, Sendable {}

public protocol ClientEventPayload: Codable, Sendable {}

public protocol ServerEventPayload: Codable, Sendable {}
```

* **ActionPayload**：Client → Server 的「意圖」
* **ClientEventPayload**：Client → Server 的「即時事件」
* **ServerEventPayload**：Server → Client 的廣播事件

---

### 1.2 LandNode（DSL 節點）

```swift
public protocol LandNode: Sendable {}
```

後面所有 DSL 元件（Config、Action handler、Event handler…）
都會包成 `LandNode`，讓 builder 收集。

---

### 1.3 LandDefinition

```swift
public struct LandDefinition<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
>: Sendable {
    public let id: String
    public let stateType: State.Type
    public let clientEventType: ClientE.Type
    public let serverEventType: ServerE.Type
    public let config: LandConfig
    public let actionHandlers: [AnyActionHandler<State>]
    public let eventHandlers: [AnyClientEventHandler<State, ClientE>]
    public let lifetimeHandlers: LifetimeHandlers<State>
}
```

> 實際欄位可以再細拆，這裡先給概念。

* `LandConfig`：大門 / Tick / Idle 等基本設定
* `AnyActionHandler`：型別抹除後的 Action 處理
* `AnyClientEventHandler`：型別抹除後的 Event 處理
* `LifetimeHandlers`：OnJoin / OnLeave / Tick / OnShutdown…

---

### 1.4 LandContext（請求級上下文）

（你之前已經有概念，這裡用 v1 写法收斂）

```swift
public struct LandContext: Sendable {
    public let landID: String
    public let playerID: PlayerID
    public let clientID: ClientID
    public let sessionID: SessionID
    public let services: LandServices
    public func sendEvent(_ event: any ServerEventPayload,
                          to target: EventTarget) async {
        await sendEventHandler(event, target)
    }
    public func syncNow() async {
        await syncHandler()
    }
    // 隱藏具體傳輸實作
    private let sendEventHandler: @Sendable (any ServerEventPayload, EventTarget) async -> Void
    private let syncHandler: @Sendable () async -> Void
}
```

```swift
public enum EventTarget {
    case all
    case player(PlayerID)
    case client(ClientID)
    case session(SessionID)
    case players([PlayerID])
}
```

---

## 2️⃣ Land DSL 類型與 Result Builder

### 2.1 LandDSL Builder

```swift
@resultBuilder
public enum LandDSL {
    public static func buildBlock(_ components: LandNode...) -> [LandNode] {
        components
    }
}
```

### 2.2 Land 註冊入口（優化版）

```swift
/// 核心：註冊一個 Land 定義
public func Land<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
>(
    _ id: String,
    using stateType: State.Type,
    clientEvents: ClientE.Type,
    serverEvents: ServerE.Type,
    @LandDSL _ content: () -> [LandNode]
) -> LandDefinition<State, ClientE, ServerE> {
    LandBuilder.build(
        id: id,
        stateType: stateType,
        clientEvents: clientEvents,
        serverEvents: serverEvents,
        nodes: content()
    )
}
```

---

### 2.3 `@Land` Macro 版（語法糖）

「優化版」推薦你主要文件用這種語法：

```swift
@Land(GameState.self, client: ClientEvents.self, server: ServerEvents.self)
struct GameLand {
    static var body: some LandDSL {
        AccessControl { ... }
        Rules { ... }
        Lifetime { ... }
    }
}
```

使用規範：

* `struct` 內必須定義 `static var body: some LandDSL`，其中的內容就是 DSL 實體。
* `@Land` attribute 的參數為 `state`, `client`, `server`，可選填 `id:`。
  * 有填 `id:` 時，直接採用該值。
  * 沒填 `id:` 時，macro 會將 struct 名稱去掉尾巴 `Land` 後轉成 kebab-case，例如 `GameLand → game`、`BattleArenaLand → battle-arena`。

Macro 展開後會變成一個呼叫 `Land(...)` 的靜態成員，大致等價：

```swift
struct GameLand {
    static var definition: LandDefinition<GameState, ClientEvents, ServerEvents> {
        Land("game", using: GameState.self,
             clientEvents: ClientEvents.self,
             serverEvents: ServerEvents.self) {
            Self.body
        }
    }
}
```

> Macro 會在重複命名（例如多個 `OnReady` 定義）或缺少 enum case 時發出編譯錯誤，避免語義化 handler 與 `ClientEvents` 失去同步。

---

## 3️⃣ 三大區塊：AccessControl / Rules / Lifetime

### 3.1 AccessControl：大門規則

```swift
public struct AccessControlNode: LandNode {
    public let maxPlayers: Int?
    public let allowPublic: Bool
    // 未來可以加 role-based / auth check / custom policy
}
```

DSL：

```swift
public func AccessControl(@AccessControlBuilder _ content: (inout AccessControlConfig) -> Void)
-> AccessControlNode { ... }

public struct AccessControlConfig {
    public var maxPlayers: Int?
    public var allowPublic: Bool = true
}
```

語法：

```swift
AccessControl {
    $0.maxPlayers = 4
    $0.allowPublic = true
}
```

或提供 helper：

```swift
AccessControl {
    AllowPublic()
    MaxPlayers(4)
}
```

---

### 3.2 Rules：遊戲規則（Action + Event + 進出房）

```swift
public struct RulesNode: LandNode {
    public let nodes: [LandNode]
}

public func Rules(@LandDSL _ content: () -> [LandNode]) -> RulesNode {
    RulesNode(nodes: content())
}
```

Rules 裡面可以放：

* `OnJoin { ... }`
* `OnLeave { ... }`
* `Action(...) { ... }`
* `On(ClientEvents.self) { ... }`
* `OnXXX { ... }`（自動生成的語義版 Event handler）
* `AllowedClientEvents { ... }`

---

### 3.3 Lifetime：營業時間 / 生命週期

```swift
public struct LifetimeNode: LandNode {
    public let config: LifetimeConfig
}

public struct LifetimeConfig {
    public var tickInterval: Duration?
    public var destroyWhenEmptyAfter: Duration?
    public var persistInterval: Duration?
    public var onShutdown: (@Sendable (any StateNodeProtocol) async -> Void)?
}
```

DSL：

```swift
public func Lifetime(_ configure: (inout LifetimeConfig) -> Void) -> LifetimeNode {
    var cfg = LifetimeConfig()
    configure(&cfg)
    return LifetimeNode(config: cfg)
}
```

語法例：

```swift
Lifetime {
    $0.tickInterval = .milliseconds(50)
    $0.destroyWhenEmptyAfter = .minutes(5)
    $0.persistInterval = .seconds(30)
    $0.onShutdown = { state in
        await saveFinalState(state as! GameState)
    }
}
```

可選擇提供小 helper：

```swift
Lifetime {
    Tick(every: .milliseconds(50)) { state, ctx in
        await handleTick(&state, ctx)
    }
    DestroyWhenEmpty(after: .minutes(5))
    PersistSnapshot(every: .seconds(30))
    OnShutdown { state in ... }
}
```

> 實作上 `Tick(...)` / `DestroyWhenEmpty(...)` / `PersistSnapshot(...)`
> 都只是修改 `LifetimeConfig` 的 DSL helper。

---

## 4️⃣ Action DSL（類型導向，非 enum）

### 4.1 Action 型別

```swift
struct Move: ActionPayload {
    let x: Int
    let y: Int
}

struct Attack: ActionPayload {
    let target: PlayerID
    let damage: Int
}

struct GetInventory: ActionPayload {
    let id: PlayerID
}
```

不需要在一個 enum 裡包起來。
每個 Action 可以獨立檔案，模組化。

---

### 4.2 Handler API（型別推論回傳）

```swift
public struct AnyActionHandler<State: StateNodeProtocol>: LandNode {
    let type: Any.Type
    let handler: @Sendable (inout State, Any, LandContext) async throws -> AnyCodable
}
```

DSL：

```swift
public func Action<State, A>(
    _ type: A.Type,
    _ body: @escaping @Sendable (inout State, A, LandContext) async throws -> some Codable & Sendable
) -> AnyActionHandler<State> {
    AnyActionHandler<State>(
        type: A.self,
        handler: { state, anyAction, ctx in
            guard let action = anyAction as? A else {
                throw LandError.invalidActionType
            }
            let result = try await body(&state, action, ctx)
            return AnyCodable(result)
        }
    )
}
```

使用方式：

```swift
Rules {
    Action(Move.self) { state, action, ctx in
        state.players[ctx.playerID]?.position = Vec2(action.x, action.y)
        return VoidResponse.ok
    }

    Action(Attack.self) { state, action, ctx in
        state.players[action.target]?.hp -= action.damage
        return AttackResult(success: true)
    }

    Action(GetInventory.self) { state, action, ctx in
        return state.players[action.id]?.inventory ?? []
    }
}
```

**重點：**

* `some Codable & Sendable` 讓 Swift 自動推論回傳型別。
* runtime 統一包成 `AnyCodable` 往傳輸層送，Transport 端可根據 `ActionEnvelope.typeIdentifier` 反射或 codegen 來解包（詳見 `docs/design/DESIGN_EVENT_ACTION_GENERIC.md` 中的 Transport 章節）。

---

## 5️⃣ Event DSL：On + 自動生成 OnReady / OnChat

### 5.1 基本版：On(ClientEvents.self)

```swift
public struct AnyClientEventHandler<State: StateNodeProtocol, E: ClientEventPayload>: LandNode {
    let handler: @Sendable (inout State, E, LandContext) async -> Void
}

public func On<State, E: ClientEventPayload>(
    _ type: E.Type,
    _ body: @escaping @Sendable (inout State, E, LandContext) async -> Void
) -> AnyClientEventHandler<State, E> {
    AnyClientEventHandler(handler: body)
}
```

用法：

```swift
Rules {
    On(ClientEvents.self) { state, event, ctx in
        switch event {
        case .ready:
            ...
        case .move(let vec):
            ...
        case .chat(let msg):
            ...
        }
    }
}
```

---

### 5.2 AllowedClientEvents

```swift
public struct AllowedClientEventsNode: LandNode {
    public let allowed: Set<AnyHashable>
}

public func AllowedClientEvents(_ builder: () -> [AnyHashable]) -> AllowedClientEventsNode {
    AllowedClientEventsNode(allowed: Set(builder()))
}
```

使用：

```swift
Rules {
    AllowedClientEvents {
        ClientEvents.ready
        ClientEvents.move
        ClientEvents.chat
    }
    // ...
}
```

Transport 層只允許這些 ClientEvents 過來。

---

### 5.3 自動生成 OnReady / OnChat（優化版重點）

你想要的：

```swift
Rules {
    OnReady { state, ctx in ... }
    OnMove  { state, vec, ctx in ... }
    OnChat  { state, msg, ctx in ... }
}
```

設計方式：

1. Event enum：

   ```swift
   @GenerateLandEventHandlers   // macro / codegen 標記
   enum ClientEvents: ClientEventPayload {
       case ready
       case move(Vec2)
       case chat(String)
   }
   ```

2. macro 展開後自動生成：

   ```swift
   // 自動生成：不需人工維護
   func OnReady<State: StateNodeProtocol>(
       _ body: @escaping @Sendable (inout State, LandContext) async -> Void
   ) -> AnyClientEventHandler<State, ClientEvents> {
       On(ClientEvents.self) { state, event, ctx in
           if case .ready = event {
               await body(&state, ctx)
           }
       }
   }

   func OnMove<State: StateNodeProtocol>(
       _ body: @escaping @Sendable (inout State, Vec2, LandContext) async -> Void
   ) -> AnyClientEventHandler<State, ClientEvents> {
       On(ClientEvents.self) { state, event, ctx in
           if case .move(let vec) = event {
               await body(&state, vec, ctx)
           }
       }
   }

   func OnChat<State: StateNodeProtocol>(
       _ body: @escaping @Sendable (inout State, String, LandContext) async -> Void
   ) -> AnyClientEventHandler<State, ClientEvents> {
       On(ClientEvents.self) { state, event, ctx in
           if case .chat(let msg) = event {
               await body(&state, msg, ctx)
           }
       }
   }
   ```

3. 所以你寫的 DSL：

   ```swift
   Rules {
       OnReady { state, ctx in
           state.readyPlayers.insert(ctx.playerID)
       }

       OnMove { state, vec, ctx in
           state.players[ctx.playerID]?.position = vec
       }

       OnChat { state, msg, ctx in
           broadcastChat(msg, from: ctx.playerID)
       }
   }
   ```

其實在編譯後等價於一堆 `On(ClientEvents.self) { switch event ... }`。

> ✅ 「自動配對到 event」不是 builder 猜的，
> 是 macro 事先幫你把 `OnReady` 寫好，
> builder 只負責收集這些 `LandNode`。

`@GenerateLandEventHandlers` 作用重點：

- 只能套在 `ClientEventPayload` enum 上。
- 每個 enum case 會對應到一個 `OnXxx` 函式，case 有 payload 時函式簽名會自動帶型別。
- DSL 內的 `Rules { ... }` 只要 `import SwiftStateTree` 就能直接呼叫這些 `OnXxx`。

---

## 6️⃣ Lifetime / Tick Handler

`Lifetime` 區塊中可以有 Tick handler。

做法一（簡單版）：Tick handler 放在 `LifetimeConfig` 裡。

```swift
public struct LifetimeConfig {
    public var tickInterval: Duration?
    public var tickHandler: (@Sendable (inout any StateNodeProtocol, LandContext) async -> Void)?
    // ...
}
```

DSL helper：

```swift
public func Tick<State: StateNodeProtocol>(
    every interval: Duration,
    _ body: @escaping @Sendable (inout State, LandContext) async -> Void
) -> (inout LifetimeConfig) -> Void {
    return { cfg in
        cfg.tickInterval = interval
        cfg.tickHandler = { anyState, ctx in
            guard var state = anyState as? State else { return }
            await body(&state, ctx)
            anyState = state
        }
    }
}
```

使用：

```swift
Lifetime {
    Tick(every: .milliseconds(50)) { state, ctx in
        await handleTick(&state, ctx)
    }
    DestroyWhenEmpty(after: .minutes(5))
    PersistSnapshot(every: .seconds(30))
}
```

LandKeeper 會依 `tickInterval` 建立一個計時 loop，
每次取 `state` 出來跑 `tickHandler`。
Tick helper 中以 `guard var state = anyState as? State` 取出具體型別、執行 handler 後再寫回 `anyState`，確保 mutation 會持久化到 LandKeeper 內部 state。

---

## 7️⃣ Runtime：LandKeeper 如何用 LandDefinition

概念流程（簡化）

```swift
actor LandKeeper<State, ClientE, ServerE>
where State: StateNodeProtocol,
      ClientE: ClientEventPayload,
      ServerE: ServerEventPayload {

    let definition: LandDefinition<State, ClientE, ServerE>
    private var state: State
    private var players: [PlayerID: PlayerSessionInfo] = [:]

    init(definition: LandDefinition<State, ClientE, ServerE>) {
        self.definition = definition
        self.state = State()
    }

    // 處理 Action
    func handleAction<A: ActionPayload>(
        _ action: A,
        from ctx: LandContext
    ) async throws -> AnyCodable {
        guard let handler = definition.actionHandlers
            .first(where: { $0.canHandle(A.self) }) else {
            throw LandError.actionNotRegistered
        }
        return try await handler.invoke(&state, action, ctx)
    }

    // 處理 Event
    func handleClientEvent(
        _ event: ClientE,
        from ctx: LandContext
    ) async {
        for h in definition.eventHandlers {
            await h.invoke(&state, event, ctx)
        }
    }

    // Tick loop / lifetime 控制略…
}
```

---

## 8️⃣ Land DSL v1 使用示例（整體）

最後給你一個完整例子，
可以當「官方優化版示範」。

```swift
// 1. StateTree
@StateTreeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    @Sync(.broadcast)
    var readyPlayers: Set<PlayerID> = []
    @Sync(.serverOnly)
    var lastTick: Date = .init()
}

// 2. Events
@GenerateLandEventHandlers
enum ClientEvents: ClientEventPayload {
    case ready
    case move(Vec2)
    case chat(String)
}

enum ServerEvents: ServerEventPayload {
    case systemMessage(String)
}

// 3. Actions
struct Join: ActionPayload { let name: String }
struct Move: ActionPayload { let x: Int; let y: Int }

// 4. Land
@Land(GameState.self, client: ClientEvents.self, server: ServerEvents.self)
struct GameLand {
    AccessControl {
        AllowPublic()
        MaxPlayers(4)
    }

    Rules {
        OnJoin { state, ctx in
            state.players[ctx.playerID] = PlayerState(name: "Guest")
        }

        OnLeave { state, ctx in
            state.players.removeValue(forKey: ctx.playerID)
        }

        AllowedClientEvents {
            ClientEvents.ready
            ClientEvents.move
            ClientEvents.chat
        }

        // 語義化 event handlers（由 macro 自動產生 API）
        OnReady { state, ctx in
            state.readyPlayers.insert(ctx.playerID)
        }

        OnMove { state, vec, ctx in
            state.players[ctx.playerID]?.position = vec
        }

        OnChat { state, msg, ctx in
            await ctx.sendEvent(
                ServerEvents.systemMessage("[\(ctx.playerID.rawValue)] \(msg)"),
                to: .all
            )
        }

        // Action handlers
        Action(Join.self) { state, action, ctx in
            state.players[ctx.playerID] = PlayerState(name: action.name)
            return VoidResponse.ok
        }

        Action(Move.self) { state, action, ctx in
            state.players[ctx.playerID]?.position = Vec2(action.x, action.y)
            return VoidResponse.ok
        }
    }

    Lifetime {
        Tick(every: .milliseconds(50)) { state, ctx in
            await handleTick(&state, ctx)
        }
        DestroyWhenEmpty(after: .minutes(5))
        PersistSnapshot(every: .seconds(30))
    }
}
```

---
