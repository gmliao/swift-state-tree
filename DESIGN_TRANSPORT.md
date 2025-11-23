# Transport 層：網路傳輸抽象

> 本文檔說明 SwiftStateTree 的 Transport 層設計


## Transport 層：網路傳輸抽象

### 設計理念

**Transport 層負責處理所有網路細節**，StateTree/Realm 層不應該知道 HTTP 路徑或 WebSocket URL 等細節。

### 架構分層

```
┌─────────────────────────────────────┐
│   StateTree / Realm DSL (領域層)     │
│   - 不知道 HTTP/WebSocket 細節      │
│   - 只使用邏輯路徑和服務抽象         │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│   Transport Layer (傳輸層)           │
│   - 處理 WebSocket/HTTP 細節        │
│   - 路由 realmID 到對應的 Realm      │
│   - 訊息序列化/反序列化              │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│   Server App (應用層)                │
│   - 設定 Transport 和路由            │
│   - 註冊 Realm                       │
│   - 配置 WebSocket endpoint          │
└─────────────────────────────────────┘
```

### Transport 協議

```swift
// Transport 抽象協議
protocol GameTransport {
    // 註冊 Realm
    func register(_ realm: RealmDefinition<some StateTree>) async
    
    // 處理 WebSocket 連接
    func handleConnection(
        realmID: String,
        playerID: PlayerID,
        websocket: WebSocket
    ) async
    
    // 發送 Event
    func send(_ event: GameEvent, to playerID: PlayerID, in realmID: String) async
    func broadcast(_ event: GameEvent, in realmID: String) async
    
    // 發送 RPC 回應
    func sendRPCResponse(
        requestID: String,
        response: RPCResponse,
        to playerID: PlayerID
    ) async
}

// WebSocket Transport 實作
actor WebSocketTransport: GameTransport {
    private var realmActors: [String: RealmActor] = [:]
    private var connections: [PlayerID: WebSocket] = [:]
    private let routing: [String: String]  // realmID -> WebSocket path
    
    init(baseURL: String, routing: [String: String]) {
        self.routing = routing
    }
    
    func register(_ realm: RealmDefinition<some StateTree>) async {
        // 創建 RealmActor 並註冊
        let actor = RealmActor(definition: realm, context: ...)
        realmActors[realm.id] = actor
    }
    
    func handleConnection(
        realmID: String,
        playerID: PlayerID,
        websocket: WebSocket
    ) async {
        connections[playerID] = websocket
        
        websocket.onText { [weak self] _, text in
            guard let self = self,
                  let message = try? JSONDecoder().decode(TransportMessage.self, from: text.data(using: .utf8)!) else {
                return
            }
            
            Task {
                await self.handleMessage(message, from: playerID)
            }
        }
    }
    
    private func handleMessage(_ message: TransportMessage, from playerID: PlayerID) async {
        switch message {
        case .rpc(let requestID, let realmID, let rpc):
            guard let actor = realmActors[realmID] else { return }
            let response = await actor.handleRPC(rpc, from: playerID)
            await sendRPCResponse(requestID: requestID, response: response, to: playerID)
            
        case .event(let realmID, let event):
            guard let actor = realmActors[realmID] else { return }
            await actor.handleEvent(event, from: playerID)
            
        case .rpcResponse:
            // Server 不應該收到 RPC Response
            break
        }
    }
}
```

### 服務注入

服務實作可以在 Transport 層注入，而不是在 Realm 定義中：

```swift
// Server App 啟動時注入服務
func configure(_ app: Application) throws {
    // 創建服務實作（可以選擇 HTTP、gRPC 等）
    let timelineService = HTTPTimelineService(baseURL: "https://api.example.com")
    let userService = HTTPUserService(baseURL: "https://api.example.com")
    
    // 創建服務容器
    let services = RealmServices(
        timelineService: timelineService,
        userService: userService
    )
    
    // 設定 Transport（注入服務）
    let transport = WebSocketTransport(
        baseURL: "wss://api.example.com",
        routing: [...],
        services: services  // 注入服務
    )
    
    // 註冊 Realm
    transport.register(matchRealm)
}
```

---

