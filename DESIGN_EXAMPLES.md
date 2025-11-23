# 範例與速查表

> 本文檔包含 SwiftStateTree 的端到端範例、語法速查表、命名說明和設計決策


## 端到端範例

### 範例 1：玩家加入（RPC + Event，包含 late join）

#### 流程

1. **Client A 發送 RPC**：`.join(playerID: "A", name: "Alice")`

2. **Server 處理 RPC**：
   ```swift
   case .join(let id, let name):
       state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
       state.hands[id] = HandState(ownerID: id, cards: [])
       let snapshot = syncEngine.snapshot(for: id, from: state)
       await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
       return .success(.joinResult(JoinResponse(realmID: ctx.realmID, state: snapshot)))
   ```

3. **Client A 收到 RPC Response**：
   - 包含完整狀態快照（late join 使用）
   - Client A 立即更新本地狀態，無需等待 Event

4. **所有 Client 收到 Event**：
   - `.stateUpdate(snapshot)` 包含裁切後的狀態
   - 其他玩家看到 A 加入

5. **SyncEngine.snapshot(for: "A", from: state)** 的裁切邏輯：
   - `players`：broadcast → 全部輸出
   - `hands`：perPlayer(ownerID) → 只輸出 A 的
   - `hiddenDeck`：serverOnly → 不輸出

### 範例 2：攻擊操作（RPC 不包含狀態，透過 Event 推送）

#### 流程

1. **Client A 發送 RPC**：`.attack(attacker: "A", target: "B", damage: 10)`

2. **Server 處理 RPC**：
   ```swift
   case .attack(let attacker, let target, let damage):
       state.players[target]?.hpCurrent -= damage
       let snapshot = syncEngine.snapshot(for: attacker, from: state)
       await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
       await ctx.sendEvent(.gameEvent(.damage(from: attacker, to: target, amount: damage)), to: .all)
       return .success(.empty)  // 不包含狀態，透過 Event 取得
   ```

3. **Client A 收到 RPC Response**：
   - 只是 `.success(.empty)`
   - 知道操作成功，等待 Event 獲取狀態更新

4. **所有 Client 收到兩個 Event**：
   - `.stateUpdate(snapshot)`：更新狀態（B 的血量減少）
   - `.gameEvent(.damage(...))`：觸發傷害動畫、音效等

### 範例 3：玩家準備（Event 雙向）

#### 流程

1. **Client A 發送 Event**：`.playerReady(playerID: "A")`

2. **Server 處理 Event**：
   ```swift
   case .playerReady(let id):
       state.readyPlayers.insert(id)
       await ctx.sendEvent(.gameEvent(.playerReady(id)), to: .all)
       // 如果所有人都準備好，開始遊戲
       if state.readyPlayers.count == state.players.count {
           state.round = 1
           await ctx.sendEvent(.gameEvent(.gameStarted), to: .all)
       }
   ```

3. **所有 Client 收到 Event**：
   - `.gameEvent(.playerReady("A"))`：UI 顯示 A 已準備
   - 如果所有人都準備好：`.gameEvent(.gameStarted)`：開始遊戲

### 範例 4：Late Join 場景

#### 場景

玩家在遊戲進行中才加入，需要立即取得完整狀態。

#### 流程

1. **Client 發送 RPC**：`.join(playerID: "C", name: "Charlie")`

2. **Server 處理**：
   ```swift
   case .join(let id, let name):
       state.players[id] = PlayerState(...)
       // 生成完整的狀態快照（包含所有可見資料）
       let snapshot = syncEngine.snapshot(for: id, from: state)
       await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
       // Response 包含完整狀態，Client C 可以立即同步
       return .success(.joinResult(JoinResponse(realmID: ctx.realmID, state: snapshot)))
   ```

3. **Client C 收到 Response**：
   ```swift
   let response = try await client.rpc(.join(...))
   if case .success(.joinResult(let joinResponse)) = response,
      let snapshot = joinResponse.state {
       // 立即更新本地狀態（late join）
       updateLocalState(snapshot)
   }
   ```

### Client 端狀態管理範例

```swift
// Client (SwiftUI 例)
class GameClient: ObservableObject {
    @Published var localState: StateSnapshot?
    
    func handleEvent(_ event: GameEvent) {
        switch event {
        case .stateUpdate(let snapshot):
            localState = snapshot  // 更新本地狀態
        case .gameEvent(let detail):
            handleGameEvent(detail)  // 觸發動畫、音效
        }
    }
    
    // UI 計算
    var playerViewStates: [PlayerViewState] {
        localState?.players.map { PlayerViewState(from: $0) } ?? []
    }
}

struct PlayerViewState {
    let name: String
    let hpText: String
    let hpProgress: Double
    let isLowHP: Bool
    
    init(from state: PlayerState) {
        let percent = Double(state.hpCurrent) / Double(state.hpMax)
        self.name = state.name
        self.hpText = "\(state.hpCurrent) / \(state.hpMax)"
        self.hpProgress = percent
        self.isLowHP = percent < 0.3
    }
}
```

---

## 命名說明

### Realm vs App vs Feature

**核心概念**：`Realm`（領域/土地）是 StateTree 生長的地方

- **Realm**：核心名稱，通用於所有場景
- **App**：`Realm` 的別名，適合 App 場景
- **Feature**：`Realm` 的別名，適合功能模組場景

**使用建議**：
- 遊戲場景：使用 `Realm`
- App 場景：使用 `App` 或 `Realm`
- 功能模組：使用 `Feature` 或 `Realm`
- 通用場景：使用 `Realm`

**內部實作**：所有別名都指向 `Realm`，實作完全相同。

## 相關文檔

- **[APP_APPLICATION.md](./APP_APPLICATION.md)**：StateTree 在 App 開發中的應用
  - SNS App 完整範例
  - 與現有方案比較（Redux、MVVM、TCA）
  - 跨平台實現（Android/Kotlin、TypeScript）
  - 狀態同步方式詳解

---

## 語法速查表

### 1. StateTree + Sync

```swift
@StateTree
struct GameStateTree {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState]
    
    @Sync(.perPlayer(\.ownerID))
    var hands: [PlayerID: HandState]
    
    @Sync(.serverOnly)
    var hiddenDeck: [Card]
}
```

### 2. Realm 定義（混合模式）

```swift
// 使用 Realm（核心名稱）
let realm = Realm("match-3", using: GameStateTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
    }
    
    // RPC 處理：混合模式
    // 簡單的查詢：用獨立 handler
    RPC(GameRPC.getPlayerHand) { state, id, ctx -> RPCResponse in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    // 複雜的狀態修改：用統一 handler
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        switch rpc {
        case .join(let id, let name):
            return await handleJoin(&state, id, name, ctx)
        // ...
        }
    }
    
    // Event 處理：混合模式
    // 簡單的 Event：用獨立 handler
    On(ClientEvent.heartbeat) { state, timestamp, ctx in
        state.playerLastActivity[ctx.playerID] = timestamp
    }
    
    // 複雜的 Event：用統一 handler
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromClient(.playerReady(let id)):
            await handlePlayerReady(&state, id, ctx)
        // ...
        }
    }
}
```

### 3. RPC 例子

```swift
enum GameRPC: Codable {
    case join(playerID: PlayerID, name: String)
    case drawCard(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
    case getPlayerHand(PlayerID)
}
```

### 4. Event 例子

```swift
// Client -> Server Event（需要在 AllowedClientEvents 中定義）
enum ClientEvent: Codable {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
    case uiInteraction(PlayerID, action: String)
}

// Server -> Client Event（不受限制）
enum ServerEvent: Codable {
    case stateUpdate(StateSnapshot)
    case gameEvent(GameEventDetail)
    case systemMessage(String)
}

// 統一的 Event 包裝
enum GameEvent: Codable {
    case fromClient(ClientEvent)   // Client -> Server
    case fromServer(ServerEvent)   // Server -> Client
}
```

### 5. Context 介面（伺服端）

```swift
// 推送 Event
await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
await ctx.sendEvent(.gameEvent(.damage(...)), to: .all)
await ctx.sendEvent(.systemMessage("xxx"), to: .player(playerID))
```

---

## Event 範圍限制設計決策

### 設計決策：採用選項 C（Realm DSL 中定義）

**決定**：使用 Realm DSL 中的 `AllowedClientEvents` 來限制 Client->Server Event。

**重要限制**：
- `AllowedClientEvents` **只限制 Client->Server 的 Event**（`ClientEvent`）
- **Server->Client 的 Event 不受限制**（因為是 Server 自己控制的）
- 需要在 Event 型別定義中明確區分 `ClientEvent` 和 `ServerEvent`

### Event 型別定義

首先需要將 Event 明確區分為兩種：

### Event 型別設計

```swift
// Client -> Server Event（需要限制）
enum ClientEvent: Codable {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
    case uiInteraction(PlayerID, action: String)
    // 更多 Client Event...
}

// Server -> Client Event（不受限制，Server 自己控制）
enum ServerEvent: Codable {
    case stateUpdate(StateSnapshot)
    case gameEvent(GameEventDetail)
    case systemMessage(String)
    // Server 可以自由定義和發送
}

// 統一的 Event 包裝（用於傳輸層）
enum GameEvent: Codable {
    case fromClient(ClientEvent)   // Client -> Server
    case fromServer(ServerEvent)   // Server -> Client
}
```

### Realm DSL 定義（選項 C）

**範例：採用選項 C**

```swift
// Realm DSL 中定義允許的 Client Event（只限制 Client->Server）
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    // 定義這個領域允許的 Client Event（只能指定 ClientEvent 類型）
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
        // 只有這些 ClientEvent 可以被 Client 發送到這個領域
        // ServerEvent 不受此限制（Server 可以自由發送）
    }
    
    // Event 處理（處理允許的 ClientEvent）
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromClient(let clientEvent):
            // 只會收到 AllowedClientEvents 中定義的 ClientEvent
            switch clientEvent {
            case .playerReady(let id):
                state.readyPlayers.insert(id)
                // Server 可以自由發送 ServerEvent
                await ctx.sendEvent(.fromServer(.gameEvent(.playerReady(id))), to: .all)
                
            case .heartbeat(let timestamp):
                // 更新心跳時間
                state.playerLastActivity[id] = timestamp
                
            case .uiInteraction(let id, let action):
                // 記錄 UI 事件
                analytics.track(id, action: action)
            }
            
        case .fromServer:
            // ServerEvent 不應該從 Client 收到（應該被傳輸層過濾）
            break
        }
    }
    
    // RPC 處理
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        // ...
    }
}

### DSL 實作概念

```swift
// DSL 實作：AllowedClientEvents 只接受 ClientEvent
protocol RealmNode {}

struct AllowedClientEventsNode: RealmNode {
    let allowedClientEvents: Set<ClientEventType>
    
    init(@AllowedClientEventsBuilder _ builder: () -> Set<ClientEventType>) {
        self.allowedClientEvents = builder()
    }
}

@resultBuilder
enum AllowedClientEventsBuilder {
    static func buildBlock(_ events: ClientEventType...) -> Set<ClientEventType> {
        Set(events)
    }
    
    // 只接受 ClientEvent 類型
    static func buildExpression(_ eventType: ClientEvent.Type) -> ClientEventType {
        ClientEventType(eventType)
    }
}

// Runtime 驗證（只驗證 ClientEvent）
actor RealmActor {
    private let allowedClientEvents: Set<ClientEventType>
    
    func handleEvent(_ event: GameEvent, from player: PlayerID) async throws {
        switch event {
        case .fromClient(let clientEvent):
            // 檢查 ClientEvent 是否在允許列表中
            guard allowedClientEvents.contains(ClientEventType(type(of: clientEvent))) else {
                throw EventError.notAllowed("ClientEvent type not allowed in this realm")
            }
            // 處理允許的 ClientEvent
            await processClientEvent(clientEvent, from: player)
            
        case .fromServer:
            // ServerEvent 不應該從 Client 收到
            // 如果收到，可能是傳輸層錯誤
            throw EventError.invalidSource("ServerEvent should not come from client")
        }
    }
}
```

### 設計要點

1. **AllowedClientEvents 只限制 ClientEvent**
   - 只能列舉 `ClientEvent` 的類型
   - `ServerEvent` 不受限制（Server 自己控制）

2. **不同領域可以有不同的 ClientEvent 規則**
   ```swift
   // 卡牌遊戲領域
   let cardRealm = Realm("card-game", using: CardGameStateTree.self) {
       AllowedClientEvents {
           ClientEvent.playerReady
           ClientEvent.playCard
           ClientEvent.discardCard
       }
   }
   
   // 即時對戰領域
   let battleRealm = Realm("realtime-battle", using: BattleStateTree.self) {
       AllowedClientEvents {
           ClientEvent.playerReady
           ClientEvent.movementUpdate
           ClientEvent.skillCast
       }
   }
   ```

3. **Server 可以自由發送 ServerEvent**
   ```swift
   // 在任何 RPC 或 Event handler 中
   await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
   await ctx.sendEvent(.fromServer(.gameEvent(.damage(...))), to: .all)
   // 不需要在 AllowedClientEvents 中定義
   ```

### RPC Response 是否總是包含狀態？

**當前設計**：可選包含狀態（用於 late join 等場景）

**考慮**：
- 總是包含狀態：一致性高，但可能浪費頻寬
- 可選包含狀態：靈活，但需要明確的設計決策
- 永遠不包含狀態：統一透過 Event 推送，但 late join 需要額外處理

## 後續實作建議

### 模組拆分建議

#### 模組命名與簡寫

為了方便後續溝通，定義以下簡寫：

| 簡寫 | 完整名稱 | 說明 |
|------|---------|------|
| **core** | `swift-state-tree` | 核心模組（不相依網路） |
| **transport** | `swift-state-tree-transport` | 網路傳輸模組 |
| **app** | `swift-state-tree-server-app` | Server 應用啟動模組 |
| **codegen** | `swift-state-tree-codegen` | Schema 生成工具 |

#### Swift 版本模組劃分

##### 1. **core** (`swift-state-tree`)

**職責**：核心定義，不相依任何網路

**包含**：
- `@StateTree`：StateTree 定義
- `@Sync`：同步規則 DSL
- `SyncPolicy`：同步策略定義
- `StateTree`：狀態樹結構
- **Schema Generator**：從 StateTree 定義生成 JSON Schema
- `RealmDefinition`：Realm DSL 定義（不含網路細節）
- `RealmContext`：RealmContext 定義
- `RealmActor`：RealmActor 定義（不含 Transport）
- `SyncEngine`：同步引擎（不含 Transport）

**不包含**：
- ❌ WebSocket 相關
- ❌ HTTP 相關
- ❌ Transport 相關
- ❌ Server 啟動相關

**依賴**：無外部依賴（純 Swift）

##### 2. **transport** (`swift-state-tree-transport`)

**職責**：網路傳輸抽象和實作

**包含**：
- `GameTransport`：Transport 協議定義
- `WebSocketTransport`：WebSocket 實作
- `TransportMessage`：傳輸訊息格式
- 連接管理（三層識別：playerID、clientID、sessionID）
- 訊息序列化/反序列化
- 路由機制（realmID 路由）

**依賴**：`core`

##### 3. **app** (`swift-state-tree-server-app`)

**職責**：Server 應用啟動和配置

**包含**：
- Server 應用啟動設定
- WebSocket 路由配置
- Realm 註冊和配置
- Transport 初始化
- 服務注入（Services）
- 應用端類別定義（例如：Vapor、Kestrel 等）

**範例**：
```swift
// Vapor 應用端
import SwiftStateTreeServerApp
import Vapor

func configure(_ app: Application) throws {
    // 設定 Transport
    let transport = WebSocketTransport(...)
    
    // 註冊 Realm
    await transport.register(gameRealm)
    
    // 設定 WebSocket 路由
    app.webSocket("ws", ":playerID", ":clientID") { req, ws in
        await transport.handleConnection(...)
    }
}
```

**依賴**：`core`、`transport`、應用框架（Vapor、Kestrel 等）

##### 4. **codegen** (`swift-state-tree-codegen`)

**職責**：從 StateTree 定義生成 JSON Schema

**包含**：
- Type Extractor：從 Swift 定義提取型別資訊
- Schema Generator：生成 JSON Schema
- CLI 工具：命令列介面

**依賴**：`core`

#### 模組依賴關係

```
core (swift-state-tree)
    ↑
    ├── transport (swift-state-tree-transport)
    │       ↑
    │       └── app (swift-state-tree-server-app)
    │
    └── codegen (swift-state-tree-codegen)
```

#### 模組職責對照表

| 模組 | 簡寫 | 職責 | 包含內容 | 不包含 |
|------|------|------|---------|--------|
| `swift-state-tree` | **core** | 核心定義 | StateTree、@Sync、Realm DSL、SyncEngine、Schema Gen | WebSocket、HTTP、Transport |
| `swift-state-tree-transport` | **transport** | 網路傳輸 | Transport 協議、WebSocket 實作、連接管理 | Server 啟動、應用框架 |
| `swift-state-tree-server-app` | **app** | Server 應用 | WebSocket 路由、Realm 註冊、應用啟動 | 核心邏輯、Transport 實作 |
| `swift-state-tree-codegen` | **codegen** | Schema 生成 | Type Extractor、Schema Generator、CLI | 運行時邏輯 |

#### 跨平台版本

- **StateTree Protocol**（語言無關）：協議定義、JSON Schema、Protobuf 定義
- **StateTree Swift**：Swift 實現（使用 Macros、Property Wrappers）
- **StateTree Kotlin**：Kotlin 實現（使用 DSL、Annotations）
- **StateTree TypeScript**：TypeScript 實現（使用 Decorators，**自動生成**）

#### Code Generation

- **StateTreeCodeGen**：程式碼生成工具
  - Type Extractor：從 Server 定義提取型別資訊
  - Generator Interface：統一的生成器介面
  - TypeScript Generator：生成 TypeScript 客戶端 SDK（優先實作）
  - Kotlin Generator：生成 Kotlin 客戶端 SDK（後續擴充）
  - 其他語言生成器（根據需求擴充）

> **注意**：客戶端 SDK **必須**從 Server 定義自動生成，不支援手動定義。詳見 [DESIGN_CLIENT_SDK.md](./DESIGN_CLIENT_SDK.md)。

### 專案目錄結構建議

```
swift-state-tree/
├── Sources/
│   ├── SwiftStateTree/              # core：核心模組
│   │   ├── StateTree/               # StateTree 定義（StateNode、StateTreeEngine）
│   │   ├── Sync/                    # @Sync 同步規則（SyncPolicy、SyncEngine）
│   │   ├── Realm/                   # Realm DSL（RealmDefinition、RealmContext）
│   │   ├── Runtime/                 # RealmActor（不含 Transport）
│   │   └── SchemaGen/              # Schema 生成器（JSON Schema）
│   │
│   ├── SwiftStateTreeTransport/     # transport：網路傳輸模組
│   │   ├── Transport/              # Transport 協議（GameTransport）
│   │   ├── WebSocket/              # WebSocket 實作（WebSocketTransport）
│   │   └── Connection/             # 連接管理（三層識別）
│   │
│   ├── SwiftStateTreeServerApp/     # app：Server 應用模組
│   │   ├── Vapor/                  # Vapor 應用端
│   │   ├── Kestrel/                # Kestrel 應用端（未來）
│   │   └── Common/                 # 共用應用邏輯
│   │
│   └── SwiftStateTreeCodeGen/      # codegen：Schema 生成工具
│       ├── Extractor/              # Type Extractor（從 Swift 提取型別）
│       ├── Generator/              # Generator Interface（TypeScript、Kotlin 等）
│       └── CLI/                    # CLI 工具
│
├── Tests/
│   ├── SwiftStateTreeTests/        # core 測試
│   ├── SwiftStateTreeTransportTests/ # transport 測試
│   └── SwiftStateTreeServerAppTests/ # app 測試
│
└── Examples/                        # 範例專案
    ├── GameServer/                  # 遊戲伺服器範例
    └── SNSApp/                      # SNS App 範例
```

**模組簡寫對照**：
- `SwiftStateTree` = **core**
- `SwiftStateTreeTransport` = **transport**
- `SwiftStateTreeServerApp` = **app**
- `SwiftStateTreeCodeGen` = **codegen**

### 開發順序建議

1. **Phase 1：核心設計**
   - 定義協議格式（JSON Schema / Protobuf）
   - 實作 Swift 版本的核心功能
   - 建立遊戲伺服器範例

2. **Phase 2：App 開發支援**
   - 實作 App 版本的同步策略（Local、Cloud、Cache）
   - 建立 SNS App 範例
   - 優化離線支援

3. **Phase 3：跨平台實現**
   - 實作 Kotlin 版本
   - 實作 TypeScript 版本
   - 確保協議層一致性

4. **Phase 4：客戶端 SDK 與 Code Generation**
   - 實作 Type Extractor（從 Swift 定義提取型別）
   - 實作 TypeScript Generator（優先）
   - 建立 Code-gen 架構（可擴充設計）
   - CLI 工具和 Build Phase 整合
   - 詳見 [DESIGN_CLIENT_SDK.md](./DESIGN_CLIENT_SDK.md)

5. **Phase 5：優化和擴展**
   - 性能優化
   - 擴充其他語言生成器（Kotlin、Swift Client 等）
   - 工具鏈完善（Linting、格式化）
   - 文檔和測試覆蓋率

