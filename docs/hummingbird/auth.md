# JWT 與 Guest 模式

Hummingbird 版本的 WebSocket 連線支援 JWT 驗證與 Guest 模式。

## 設計說明

- WebSocket 在瀏覽器環境較容易透過 query 傳遞 token
- JWT 驗證在握手階段完成，避免未授權連線進入遊戲層
- Guest 模式允許沒有 token 的連線，用於 demo 或低門檻體驗

## 連線參數

JWT token 透過 query 參數傳遞：

```
ws://host:port/game?token=<jwt-token>
```

若未提供 token：

- `allowGuestMode = true`：允許連線，join 時使用 guest session
- `allowGuestMode = false`：直接拒絕連線

## JWTConfiguration

```swift
let jwtConfig = JWTConfiguration(
    secretKey: "your-secret-key",
    algorithm: .HS256,
    validateExpiration: true
)

// Create LandHost to manage HTTP server and game logic
let host = LandHost(configuration: LandHost.HostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with JWT configuration
try await host.register(
    landType: "demo",
    land: demoLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: LandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: true
    )
)

try await host.run()
```

也可以使用環境變數：

- `JWT_SECRET_KEY`
- `JWT_ALGORITHM`
- `JWT_ISSUER` (可選)
- `JWT_AUDIENCE` (可選)

## PlayerSession 優先序

join 時的 player/device/metadata 來源順序：

1. join request 內容
2. JWT payload
3. guest session

## 流程概觀

```
Client --(ws?token=...)--> Hummingbird Adapter
  -> JWT validate (if configured)
  -> TransportAdapter.onConnect(authInfo)
  -> join request
  -> CanJoin / OnJoin
```

## JWT Token 生成

### 伺服器端生成（範例）

在實際應用中，JWT token 通常由認證服務生成。以下是使用 SwiftJWT 的範例：

```swift
import SwiftJWT

struct MyClaims: Claims {
    let playerID: String
    let deviceID: String?
    let exp: Date
    let iat: Date
}

func generateJWT(playerID: String, deviceID: String?) throws -> String {
    let myHeader = Header(typ: "JWT")
    let expiration = Date().addingTimeInterval(3600 * 2) // 2 hours
    let myClaims = MyClaims(
        playerID: playerID,
        deviceID: deviceID,
        exp: expiration,
        iat: Date()
    )
    
    var myJWT = JWT(header: myHeader, claims: myClaims)
    let jwtSigner = JWTSigner.hs256(key: Data("your-secret-key".utf8))
    let signedJWT = try myJWT.sign(using: jwtSigner)
    
    return signedJWT
}
```

### 客戶端生成（TypeScript 範例）

在客戶端，可以使用 Web Crypto API 生成 JWT：

```typescript
async function generateJWT(
  secretKey: string,
  payload: { playerID: string; deviceID?: string },
  expiresInHours: number = 2
): Promise<string> {
  const header = { alg: 'HS256', typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const exp = now + (expiresInHours * 3600);
  
  const jwtPayload = {
    ...payload,
    iat: now,
    exp: exp
  };
  
  // Encode header and payload
  const encodedHeader = btoa(JSON.stringify(header))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  const encodedPayload = btoa(JSON.stringify(jwtPayload))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  // Create signature
  const message = `${encodedHeader}.${encodedPayload}`;
  const keyData = new TextEncoder().encode(secretKey);
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );
  
  const signature = await crypto.subtle.sign(
    'HMAC',
    cryptoKey,
    new TextEncoder().encode(message)
  );
  
  const encodedSignature = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
  
  return `${encodedHeader}.${encodedPayload}.${encodedSignature}`;
}

// 使用範例
const token = await generateJWT('your-secret-key', {
  playerID: 'player-123',
  deviceID: 'device-456'
});

// 連接到 WebSocket
const ws = new WebSocket(`ws://localhost:8080/game?token=${token}`);
```

## 完整設定範例

### 基本 JWT 設定

```swift
import SwiftStateTreeHummingbird

// 設定 JWT 配置
let jwtConfig = JWTConfiguration(
    secretKey: "your-secret-key-here",
    algorithm: .HS256,
    validateExpiration: true,
    validateIssuer: false,
    expectedIssuer: nil,
    validateAudience: false,
    expectedAudience: nil
)

// Create LandHost
let host = LandHost(configuration: LandHost.HostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with JWT configuration (no guest mode)
try await host.register(
    landType: "game",
    land: gameLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: LandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: false  // 不允許 Guest 模式
    )
)

try await host.run()
```

### 使用環境變數

```swift
// 從環境變數載入配置
let jwtConfig = JWTConfiguration.fromEnvironment() ?? JWTConfiguration(
    secretKey: "default-secret-key",
    algorithm: .HS256
)

// Create LandHost
let host = LandHost(configuration: LandHost.HostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with JWT configuration (allow guest mode as fallback)
try await host.register(
    landType: "game",
    land: gameLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: LandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: true  // 允許 Guest 模式作為後備
    )
)

try await host.run()
```

### 環境變數設定

```bash
# .env 檔案或環境變數
export JWT_SECRET_KEY="your-secret-key-here"
export JWT_ALGORITHM="HS256"
export JWT_ISSUER="my-game-server"  # 可選
export JWT_AUDIENCE="my-game-client"  # 可選
```

## Guest 模式

### 使用場景

Guest 模式適用於以下場景：

- **Demo 或測試環境**：不需要完整認證流程
- **快速體驗**：降低用戶進入門檻
- **開發階段**：簡化開發和測試流程

### Guest 模式設定

```swift
// Create LandHost
let host = LandHost(configuration: LandHost.HostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with guest mode enabled
try await host.register(
    landType: "game",
    land: gameLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: LandServerConfiguration(
        jwtConfig: jwtConfig,  // JWT 配置（可選）
        allowGuestMode: true   // 允許 Guest 模式
    )
)

try await host.run()
```

### Guest Session 處理

在 Land 的 `OnJoin` handler 中處理 Guest 玩家：

```swift
Rules {
    OnJoin { state, ctx in
        // 檢查是否為 Guest
        if ctx.playerID.rawValue.hasPrefix("guest-") {
            // Guest 玩家的特殊處理
            state.players[ctx.playerID] = PlayerState(
                name: "Guest \(ctx.playerID.rawValue.suffix(8))",
                isGuest: true
            )
        } else {
            // 正常玩家的處理
            state.players[ctx.playerID] = PlayerState(
                name: ctx.metadata["displayName"] ?? ctx.playerID.rawValue,
                isGuest: false
            )
        }
    }
}
```

### Guest 模式限制

建議在 Guest 模式下實施一些限制：

```swift
Rules {
    CanJoin { state, session, ctx in
        // 限制 Guest 玩家數量
        let guestCount = state.players.values.filter { $0.isGuest }.count
        if session.playerID.rawValue.hasPrefix("guest-") && guestCount >= 10 {
            return .deny(reason: "Too many guest players")
        }
        return .allow(playerID: PlayerID(session.playerID))
    }
    
    HandleAction(PremiumAction.self) { state, action, ctx in
        // Guest 玩家不能執行某些操作
        let player = state.players[ctx.playerID]
        if player?.isGuest == true {
            throw LandError.actionDenied("Guest players cannot perform this action")
        }
        // 正常處理...
    }
}
```

## Admin 路由

### 啟用 Admin 路由

```swift
import SwiftStateTreeHummingbird

// 建立 Admin 認證中間件
let adminAuth = AdminAuthMiddleware(
    jwtValidator: jwtValidator,  // 可選：使用 JWT 驗證
    apiKey: "your-admin-api-key"  // 可選：使用 API Key
)

// Create LandHost
let host = LandHost(configuration: LandHost.HostConfiguration(
    host: "localhost",
    port: 8080
))

// Register admin routes
try await host.registerAdminRoutes(
    adminAuth: adminAuth,
    enableAdminRoutes: true
)

// Register land types as usual
try await host.register(
    landType: "game",
    land: gameLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: serverConfig
)

try await host.run()
```

### Admin 角色

Admin 路由支援三種角色：

- **`admin`**：完整管理權限（最高權限）
- **`operator`**：操作權限（中等權限）
- **`viewer`**：查看權限（最低權限）

角色層級：`admin` > `operator` > `viewer`

### Admin JWT Token

Admin JWT token 需要在 metadata 中包含 `adminRole`：

```swift
// 生成 Admin JWT token
let adminPayload = JWTPayload(
    playerID: "admin-user",
    deviceID: nil,
    metadata: [
        "adminRole": "admin"  // 或 "operator", "viewer"
    ]
)
```

### Admin API Key

也可以使用 API Key 進行認證：

```swift
let adminAuth = AdminAuthMiddleware(
    apiKey: "your-secure-api-key"
)
```

API Key 可以透過以下方式傳遞：

1. **HTTP Header**：`X-API-Key: your-secure-api-key`
2. **Query Parameter**：`?apiKey=your-secure-api-key`

### Admin 路由端點

啟用 Admin 路由後，會自動提供以下端點：

#### GET /admin/lands

列出所有房間：

```bash
curl -H "X-API-Key: your-secure-api-key" http://localhost:8080/admin/lands
```

回應：
```json
[
  "game-room-1",
  "game-room-2",
  "lobby-main"
]
```

#### GET /admin/lands/:landID

取得特定房間的統計資訊：

```bash
curl -H "X-API-Key: your-secure-api-key" http://localhost:8080/admin/lands/game-room-1
```

回應：
```json
{
  "playerCount": 3,
  "createdAt": "2024-01-01T00:00:00Z",
  "lastActivity": "2024-01-01T01:00:00Z"
}
```

#### GET /admin/stats

取得系統統計資訊：

```bash
curl -H "X-API-Key: your-secure-api-key" http://localhost:8080/admin/stats
```

回應：
```json
{
  "totalLands": 5,
  "totalPlayers": 12
}
```

#### DELETE /admin/lands/:landID

刪除特定房間（需要 admin 權限）：

```bash
curl -X DELETE -H "X-API-Key: your-secure-api-key" http://localhost:8080/admin/lands/game-room-1
```

## 錯誤處理

### JWT 驗證錯誤

當 JWT 驗證失敗時，連線會被拒絕：

```swift
// 在客戶端處理連線錯誤
ws.onerror = { error in
    if error.localizedDescription.contains("JWT") {
        // JWT 驗證失敗，需要重新登入
        handleAuthError()
    }
}
```

### Guest 模式錯誤

當 Guest 模式被禁用且沒有提供 JWT token 時：

```swift
// 伺服器端會拒絕連線
// 客戶端會收到連線錯誤
```

### Admin 路由錯誤

Admin 路由會返回標準 HTTP 狀態碼：

- `401 Unauthorized`：未提供認證資訊或認證失敗
- `403 Forbidden`：權限不足
- `404 Not Found`：資源不存在

```swift
// 處理 Admin API 錯誤
let response = try await fetchAdminAPI(endpoint: "/admin/lands")
if response.status == 401 {
    // 需要重新認證
} else if response.status == 403 {
    // 權限不足
}
```

## 安全性建議

### 1. Secret Key 管理

- **不要將 secret key 寫死在程式碼中**：使用環境變數或密鑰管理服務
- **使用強密鑰**：至少 32 字元的隨機字串
- **定期輪換**：定期更換 secret key

```swift
// ✅ 正確：從環境變數讀取
let secretKey = ProcessInfo.processInfo.environment["JWT_SECRET_KEY"] ?? ""

// ❌ 錯誤：寫死在程式碼中
let secretKey = "my-secret-key"
```

### 2. Token 過期時間

設定合理的 token 過期時間：

```swift
// 在生成 token 時設定過期時間
let expiration = Date().addingTimeInterval(3600 * 2) // 2 小時
```

### 3. HTTPS/WSS

在生產環境中，務必使用 HTTPS 和 WSS：

```swift
// 生產環境應該使用 WSS
let wsURL = "wss://your-domain.com/game?token=\(token)"
```

### 4. Admin API Key

- **使用強隨機字串**：至少 32 字元
- **限制存取來源**：使用 IP 白名單或 VPN
- **記錄所有 Admin 操作**：用於審計

### 5. Guest 模式限制

在生產環境中，建議對 Guest 模式實施限制：

```swift
// 限制 Guest 玩家數量
// 限制 Guest 玩家的操作
// 定期清理不活躍的 Guest 玩家
```

## 相關文檔

- [Hummingbird 整合](README.md) - 了解完整的伺服器設定
- [Transport 層](../transport/README.md) - 了解連線管理機制
- [FAQ](../FAQ.md) - 常見問題解答
