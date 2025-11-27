# Transport 層：網路傳輸抽象

> 本文檔說明 SwiftStateTree 的 Transport 層設計


## Transport 層：網路傳輸抽象

### 設計理念

**Transport 層負責處理所有網路細節**，StateTree/Land 層不應該知道 HTTP 路徑或 WebSocket URL 等細節。

### 架構分層

**關鍵設計原則**：WebSocket 細節不應該暴露到 StateTree 層。

```
┌─────────────────────────────────────┐
│   StateTree / Land DSL (領域層)     │
│   - 不知道 HTTP/WebSocket 細節      │
│   - LandContext 不包含 Transport    │
│   - 只使用邏輯路徑和服務抽象         │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│   Runtime Layer (LandKeeper)        │
│   - 持有 Transport                   │
│   - 建立 LandContext（不暴露 Transport）│
│   - 處理 Transport 細節              │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│   Transport Layer (傳輸層)           │
│   - 處理 WebSocket/HTTP 細節        │
│   - 連接管理（三層識別）             │
│   - 路由 landID 到對應的 Land      │
│   - 訊息序列化/反序列化              │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│   Server App (應用層)                │
│   - 設定 Transport 和路由            │
│   - 註冊 Land                       │
│   - 配置 WebSocket endpoint          │
└─────────────────────────────────────┘
```

### 三層識別系統

**設計決策**：使用三層識別系統來管理連接。

| 識別 | 層級 | 誰生成 | 持久化 | 用途 |
|------|------|--------|--------|------|
| `playerID` | 業務層（帳號） | 應用端（認證系統） | Server | 用戶身份、遊戲邏輯 |
| `clientID` | 裝置層（客戶端） | **應用端** | **應用端本地** | 裝置識別、多裝置追蹤 |
| `sessionID` | 連接層（會話） | Server（自動生成） | 不持久化 | 連接追蹤、除錯 |

**關鍵點**：
- `playerID` = 誰（帳號）
- `clientID` = 哪個裝置（應用端生成並持久化）
- `sessionID` = 哪個連接（Server 自動生成）

**應用端生成 clientID 範例**：

```typescript
// Web：使用 localStorage
function generateOrGetClientID(): string {
    const STORAGE_KEY = 'myapp_client_id';
    let clientID = localStorage.getItem(STORAGE_KEY);
    
    if (!clientID) {
        clientID = `client-${crypto.randomUUID()}`;
        localStorage.setItem(STORAGE_KEY, clientID);
    }
    
    return clientID;
}

// 使用
const clientID = generateOrGetClientID();
const client = new StateTreeClient({
    websocketURL: 'wss://api.example.com/ws',
    playerID: 'user-123',
    clientID: clientID  // 應用端提供
});
```

### Transport 協議

**設計原則**：Transport 層處理所有 WebSocket 細節，包括連接管理和三層識別系統。

```swift
// Transport 抽象協議
protocol GameTransport {
    // 註冊 Land
    func register(_ land: LandDefinition<some StateTree>) async
    
    // 處理 WebSocket 連接（三層識別）
    func handleConnection(
        playerID: PlayerID,      // 帳號識別（應用端提供）
        clientID: ClientID,      // 裝置識別（應用端提供）
        sessionID: SessionID,    // 會話識別（Server 自動生成）
        websocket: WebSocket
    ) async
    
    // 發送 Event（支援多種目標）
    func send(_ event: GameEvent, to playerID: PlayerID, in landID: String) async
    func send(_ event: GameEvent, to clientID: ClientID, in landID: String) async
    func send(_ event: GameEvent, to sessionID: SessionID, in landID: String) async
    func broadcast(_ event: GameEvent, in landID: String) async
    
    // 發送 Action 回應
    func sendActionResult(
        requestID: String,
        response: AnyCodable,
        to sessionID: SessionID
    ) async
}

### 訊息結構

```swift
public struct ActionEnvelope: Codable, Sendable {
    public let typeIdentifier: String
    public let payload: Data
}

public enum TransportMessage<ClientE, ServerE>: Codable
where ClientE: ClientEventPayload, ServerE: ServerEventPayload {
    case action(requestID: String, landID: String, action: ActionEnvelope)
    case actionResponse(requestID: String, response: AnyCodable)
    case event(landID: String, event: Event<ClientE, ServerE>)
}
```

* `typeIdentifier`：用於對應實際 Action 型別（可由 codegen 產出常數）。
* `payload`：ActionPayload 經 JSON/MsgPack 編碼後的原始資料。
* Action 回應以 `AnyCodable` 傳回，客戶端可自行轉型或使用 schema。

// WebSocket Transport 實作
actor WebSocketTransport: GameTransport {
    private var landActors: [String: LandKeeper] = [:]
    
    // ✅ 三層連接管理：playerID -> clientID -> sessionID -> WebSocket
    private var connections: [PlayerID: [ClientID: [SessionID: WebSocket]]] = [:]
    private var clientSessions: [SessionID: ClientSession] = [:]
    
    struct ClientSession {
        let playerID: PlayerID
        let clientID: ClientID
        let sessionID: SessionID
        let connectedAt: Date
    }
    
    private let services: LandServices
    
    init(services: LandServices) {
        self.services = services
    }
    
    func register(_ land: LandDefinition<some StateTree>) async {
        // 創建 LandKeeper 並註冊（注入 Transport 和 Services）
        let actor = LandKeeper(
            definition: land,
            transport: self,
            services: services
        )
        landActors[land.id] = actor
    }
    
    func handleConnection(
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        websocket: WebSocket
    ) async {
        // 記錄連接
        if connections[playerID] == nil {
            connections[playerID] = [:]
        }
        if connections[playerID]?[clientID] == nil {
            connections[playerID]?[clientID] = [:]
        }
        connections[playerID]?[clientID]?[sessionID] = websocket
        
        // 記錄會話資訊
        clientSessions[sessionID] = ClientSession(
            playerID: playerID,
            clientID: clientID,
            sessionID: sessionID,
            connectedAt: Date()
        )
        
        // 設定 WebSocket 處理
        websocket.onText { [weak self] _, text in
            guard let self = self,
                  let message = try? JSONDecoder().decode(TransportMessage.self, from: text.data(using: .utf8)!) else {
                return
            }
            
            Task {
                await self.handleMessage(message, sessionID: sessionID)
            }
        }
        
        websocket.onClose { [weak self] _ in
            Task {
                await self?.removeConnection(sessionID: sessionID)
            }
        }
    }
    
    private func handleMessage(_ message: TransportMessage, sessionID: SessionID) async {
        guard let session = clientSessions[sessionID] else { return }
        
        switch message {
        case .action(let requestID, let landID, let envelope):
            guard let actor = landActors[landID] else { return }
            do {
                let action = try actionDecoder.decode(from: envelope)
                let response = try await actor.handleAction(
                    action,
                    from: session.playerID,
                    clientID: session.clientID,
                    sessionID: session.sessionID
                )
                await sendActionResult(requestID: requestID, response: AnyCodable(response), to: sessionID)
            } catch {
                await sendActionResult(
                    requestID: requestID,
                    response: AnyCodable(["error": "\(error)"]),
                    to: sessionID
                )
            }
            
        case .event(let landID, let event):
            guard let actor = landActors[landID] else { return }
            await actor.handleEvent(
                event,
                from: session.playerID,
                clientID: session.clientID,
                sessionID: session.sessionID
            )
            
        case .actionResponse:
            // Server 不應該收到 Action Response
            break
        }
    }
    
    // 發送 Event 給特定 playerID 的所有連接（所有裝置/標籤頁）
    func send(_ event: GameEvent, to playerID: PlayerID, in landID: String) async {
        guard let clientConnections = connections[playerID] else { return }
        
        for (clientID, sessions) in clientConnections {
            for (sessionID, websocket) in sessions {
                await sendEvent(event, to: websocket)
            }
        }
    }
    
    // 發送 Event 給特定 clientID（單一裝置的所有標籤頁）
    func send(_ event: GameEvent, to clientID: ClientID, in landID: String) async {
        for (playerID, clients) in connections {
            if let sessions = clients[clientID] {
                for (sessionID, websocket) in sessions {
                    await sendEvent(event, to: websocket)
                }
            }
        }
    }
    
    // 發送 Event 給特定 sessionID（單一連接）
    func send(_ event: GameEvent, to sessionID: SessionID, in landID: String) async {
        guard let session = clientSessions[sessionID],
              let websocket = connections[session.playerID]?[session.clientID]?[sessionID] else {
            return
        }
        await sendEvent(event, to: websocket)
    }
    
    func broadcast(_ event: GameEvent, in landID: String) async {
        // 發送給該 land 的所有連接
        for (playerID, clients) in connections {
            for (clientID, sessions) in clients {
                for (sessionID, websocket) in sessions {
                    await sendEvent(event, to: websocket)
                }
            }
        }
    }
    
    func sendActionResult(
        requestID: String,
        response: ActionResult,
        to sessionID: SessionID
    ) async {
        guard let session = clientSessions[sessionID],
              let websocket = connections[session.playerID]?[session.clientID]?[sessionID] else {
            return
        }
        
        let message = TransportMessage.actionResponse(
            requestID: requestID,
            response: response
        )
        await websocket.send(JSONEncoder().encode(message))
    }
    
    private func sendEvent(_ event: GameEvent, to websocket: WebSocket) async {
        let message = TransportMessage.event(
            landID: "",  // 會在發送時設定
            event: event
        )
        await websocket.send(JSONEncoder().encode(message))
    }
    
    private func removeConnection(sessionID: SessionID) async {
        guard let session = clientSessions[sessionID] else { return }
        
        connections[session.playerID]?[session.clientID]?.removeValue(forKey: sessionID)
        
        // 清理空的 clientID
        if connections[session.playerID]?[session.clientID]?.isEmpty == true {
            connections[session.playerID]?.removeValue(forKey: session.clientID)
        }
        
        // 清理空的 playerID
        if connections[session.playerID]?.isEmpty == true {
            connections.removeValue(forKey: session.playerID)
        }
        
        clientSessions.removeValue(forKey: sessionID)
    }
}
```

### 服務注入

服務實作可以在 Transport 層注入，而不是在 Land 定義中：

```swift
// Server App 啟動時注入服務
func configure(_ app: Application) throws {
    // 創建服務實作（可以選擇 HTTP、gRPC 等）
    let timelineService = HTTPTimelineService(baseURL: "https://api.example.com")
    let userService = HTTPUserService(baseURL: "https://api.example.com")
    
    // 創建服務容器
    let services = LandServices(
        timelineService: timelineService,
        userService: userService
    )
    
    // 設定 Transport（注入服務）
    let transport = WebSocketTransport(
        baseURL: "wss://api.example.com",
        routing: [...],
        services: services  // 注入服務
    )
    
    // 註冊 Land
    transport.register(matchLand)
}
```

---

