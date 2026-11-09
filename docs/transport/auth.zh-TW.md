[English](auth.md) | [中文版](auth.zh-TW.md)

# JWT 與 Guest 模式

`NIOLandHost`（模組 `SwiftStateTreeNIO`）可以在 WebSocket upgrade 時驗證 JWT，並讓沒有 token 的客戶端以 guest 身分加入。認證依註冊的 land type 個別設定，透過 `NIOLandServerConfiguration`。Admin 路由使用另一把 API key，見 [Admin 路由](#admin-路由)。

## 設計說明

- WebSocket 在瀏覽器環境較容易透過 query 傳遞 token
- JWT 驗證在握手階段完成，未授權連線不會進入遊戲層
- Guest 模式允許沒有 token 的連線，用於 demo 或低門檻體驗
- token 檢查位於 `TokenValidatorProtocol`（在 `SwiftStateTreeTransport`）之後，server 可以換上自己的 validator 而不必改動 transport

## 連線參數

JWT 放在 WebSocket URL 的 `token` query 參數：

```
ws://host:port/game?token=<jwt-token>
```

驗證前會先做 percent-decode。同樣的規則適用於 `webSocketPath` 以及其下的任何路徑（例如註冊在 `/game` 的 land 的 `/game/room-abc`）。

upgrade 時的行為取決於該 land 的設定：

| 設定 | 有 token | 沒有 token |
|---|---|---|
| 沒有 `jwtConfig` 也沒有 `jwtValidator` | 忽略 token，接受連線 | 接受連線 |
| 啟用 JWT，`allowGuestMode = false`（預設） | 驗證；無效則拒絕 | 拒絕 |
| 啟用 JWT，`allowGuestMode = true` | 驗證；無效則拒絕 | 接受，以 guest 加入 |

「啟用 JWT」指設定了 `jwtValidator` 或 `jwtConfig`。驗證在 HTTP upgrade 被接受後立刻執行；被拒絕的連線會在接上 land session 之前由 server 關閉。

## 設定

`NIOLandServerConfiguration` 欄位：

| 欄位 | 預設 | 說明 |
|---|---|---|
| `jwtConfig` | `nil` | 內建 `DefaultJWTAuthValidator` 使用的 `JWTConfiguration` |
| `jwtValidator` | `nil` | 自訂 validator（`JWTAuthValidator`）；優先於 `jwtConfig` |
| `allowGuestMode` | `false` | 啟用 JWT 時，接受沒有送 token 的連線 |
| `createGuestSession` | `nil` | guest session 的 factory `(SessionID, ClientID) -> PlayerSession`；`nil` 時使用下方的預設值 |

```swift
import SwiftStateTree
import SwiftStateTreeNIO

let jwtConfig = JWTConfiguration(
    secretKey: "your-secret-key",
    algorithm: .HS256,
    validateExpiration: true
)

// Create NIOLandHost to manage the HTTP/WebSocket server and game logic
let host = NIOLandHost(configuration: NIOLandHostConfiguration(
    host: "localhost",
    port: 8080
))

// Register land type with JWT configuration
try await host.register(
    landType: "demo",
    land: demoLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: NIOLandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: true
    )
)

try await host.run()
```

### JWTConfiguration

| 參數 | 預設 | 說明 |
|---|---|---|
| `secretKey` | `nil` | HMAC secret；預設 validator 必須要有 |
| `publicKey` | `nil` | 保留欄位；預設 validator 不使用 |
| `algorithm` | `.HS256` | 必須與 token header 的 `alg` 相同 |
| `validateExpiration` | `true` | 拒絕超過 `exp` 或早於 `nbf` 的 token |
| `validateIssuer` / `expectedIssuer` | `false` / `nil` | 要求 `iss` 等於 `expectedIssuer` |
| `validateAudience` / `expectedAudience` | `false` / `nil` | 要求 `aud`（單一字串）等於 `expectedAudience` |

`DefaultJWTAuthValidator` 支援 `HS256`、`HS384` 與 `HS512`。`JWTAlgorithm` 雖有 `RS*` 與 `ES*`，但預設 validator 會拒絕所有使用它們的 token；非對稱金鑰請使用自訂 `jwtValidator`。

### Token Payload

預設 validator 把 payload 解碼成 `JWTPayload`，再轉成 `AuthenticatedInfo`：

- `playerID` claim；沒有 `playerID` 時使用標準的 `sub` claim；兩者之一必須是非空字串
- `deviceID`（選填）
- `metadata`（選填）：所有值都是字串的物件
- 其他非標準的頂層 claim（例如 `username`）會以字串複製到 metadata；數字與布林值會轉換，巢狀值存成 JSON 文字

### 自訂 Validator

實作 `JWTAuthValidator`（一種 `TokenValidatorProtocol`）的 `validate(token:)`。拋出錯誤即拒絕 upgrade：

```swift
struct MyValidator: JWTAuthValidator {
    func validate(token: String) async throws -> AuthenticatedInfo {
        // Verify the token with your own keys or auth service
        AuthenticatedInfo(playerID: "player-123", deviceID: nil, metadata: [:])
    }
}

let configuration = NIOLandServerConfiguration(jwtValidator: MyValidator())
```

### 環境變數

`JWTConfiguration.fromEnvironment()`（也可經由 `NIOEnvConfig.fromEnvironment().jwtConfiguration` 取得）讀取：

| Key | 預設 | 說明 |
|---|---|---|
| `JWT_SECRET_KEY` | （無） | 未設定或為空：回傳 `nil` |
| `JWT_ALGORITHM` | `HS256` | 未知的名稱回傳 `nil` |
| `JWT_ISSUER` | （無） | 有設定時驗證 issuer |
| `JWT_AUDIENCE` | （無） | 有設定時驗證 audience |

過期時間一律驗證。host 不會自行讀取這些變數；請把結果傳給 `jwtConfig`：

```swift
// nil when JWT_SECRET_KEY is not set: JWT stays disabled for this land
let jwtConfig = JWTConfiguration.fromEnvironment()

try await host.register(
    landType: "game",
    land: gameLand,
    initialState: GameState(),
    webSocketPath: "/game",
    configuration: NIOLandServerConfiguration(
        jwtConfig: jwtConfig,
        allowGuestMode: false  // Don't allow Guest mode
    )
)
```

```bash
export JWT_SECRET_KEY="your-secret-key-here"
export JWT_ALGORITHM="HS256"
export JWT_ISSUER="my-game-server"    # Optional
export JWT_AUDIENCE="my-game-client"  # Optional
```

## PlayerSession 優先序

**playerID。** 有 JWT 時，token 的 `playerID` 就是玩家身分：
- join request 沒帶 `playerID`，或帶的就是 token 的 `playerID`，就以 token 的玩家身分加入。
- join request 帶了不同的 `playerID`，會在查找或建立任何 land 之前以 `JOIN_PLAYER_MISMATCH` 拒絕，server 也會以 warning 等級記錄這次不符。
- 在設定了 JWT validator 或 JWT 設定的 land 上，沒有 token 的連線（guest mode）就是 guest：帶了 `playerID` 的 join request 會以 `JOIN_PLAYER_MISMATCH` 拒絕，沒帶的則以 guest session 的玩家身分加入。
- 在沒有 JWT 的 land 上，使用 join request 的 `playerID`，沒有的話使用 guest session 的。

有 JWT 的 join 一定不是 guest。沒有 JWT 的 join，沒帶 `playerID` 時就是 guest。

**device ID 與 metadata** 維持以下優先序：

1. join request 內容
2. JWT payload
3. guest session

metadata 會合併：先放 JWT metadata，join request metadata 中相同的 key 會覆蓋它。

## 流程概觀

```
Client --(ws?token=...)--> NIOWebSocketServer (upgrade)
  -> NIOLandHost auth resolver: JWT validate (if configured)
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

validator 把 `exp`、`iat` 與 `nbf` 當成整數 Unix 時間戳讀取；請將簽章函式庫設定成以這種方式編碼日期。

### 客戶端生成（TypeScript 範例）

本機測試時，可以在客戶端用 Web Crypto API 生成 JWT。不要把 secret 發給真正的客戶端：

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

// Usage example
const token = await generateJWT('your-secret-key', {
  playerID: 'player-123',
  deviceID: 'device-456'
});

// Connect to WebSocket
const ws = new WebSocket(`ws://localhost:8080/game?token=${token}`);
```

## Guest 模式

### 使用場景

Guest 模式適合以下場景：

- **Demo 或測試環境**：不需要完整認證流程
- **快速體驗**：降低用戶進入門檻
- **開發階段**：簡化開發和測試流程

### Guest Session

join 沒有帶 `playerID`、且連線沒有認證資訊時，就會成為 guest session。完全沒有設定 JWT 時也是如此。預設的 guest session 使用：

- `playerID`：session ID（每條連線產生的 UUID）
- `deviceID`：client ID
- `isGuest: true`，以及 `metadata["isGuest"] = "true"`

傳入 `createGuestSession` 可改用其他值：

```swift
let configuration = NIOLandServerConfiguration(
    jwtConfig: jwtConfig,
    allowGuestMode: true,
    createGuestSession: { sessionID, clientID in
        PlayerSession(
            playerID: "guest-\(sessionID.rawValue)",
            deviceID: clientID.rawValue,
            isGuest: true
        )
    }
)
```

### Guest Session 處理

handler 在 `CanJoin` 中以 `session.isGuest`、在 `OnJoin` 中以 `ctx.isGuest` 取得這個旗標：

```swift
Rules {
    OnJoin { state, ctx in
        state.players[ctx.playerID] = PlayerState(
            name: ctx.isGuest
                ? "Guest \(ctx.playerID.rawValue.suffix(8))"
                : (ctx.metadata["displayName"] ?? ctx.playerID.rawValue),
            isGuest: ctx.isGuest
        )
    }
}
```

### Guest 模式限制

建議在 Guest 模式下實施一些限制：

```swift
struct GuestNotAllowed: Error {}

Rules {
    CanJoin { state, session, ctx in
        // Limit Guest player count
        let guestCount = state.players.values.filter { $0.isGuest }.count
        if session.isGuest && guestCount >= 10 {
            return .deny(reason: "Too many guest players")
        }
        return .allow(playerID: PlayerID(session.playerID))
    }
    
    HandleAction(PremiumAction.self) { state, action, ctx in
        // Guest players cannot perform certain actions
        if state.players[ctx.playerID]?.isGuest == true {
            throw GuestNotAllowed()
        }
        // Normal processing...
    }
}
```

## Admin 路由

Admin 路由不使用 JWT。設定 `NIOLandHostConfiguration.adminAPIKey` 時，由 `NIOLandHost.run()` 註冊；未設定則停用：

```swift
let host = NIOLandHost(configuration: NIOLandHostConfiguration(
    host: "localhost",
    port: 8080,
    adminAPIKey: "your-admin-api-key"
))
```

key 由 `NIOAdminAuth` 檢查，可透過以下方式傳遞：

1. **HTTP Header**：`X-API-Key: your-secure-api-key`
2. **Query 參數**：`?apiKey=your-secure-api-key`

相符的 key 會得到 `admin` 角色。`AdminRole` 也定義了 `operator` 與 `viewer`（層級 `admin` > `operator` > `viewer`）；讀取類路由需要 `viewer`，其他需要 `admin`，但 API key 是唯一的憑證，所以每個通過認證的請求都是 `admin`。

### Admin 路由端點

回應是 JSON 外層 `{ "success": ..., "data": ..., "error": ... }`。

| 路由 | 角色 | 作用 |
|---|---|---|
| `GET /admin/lands` | viewer | 列出 land ID |
| `GET /admin/lands/:landID` | viewer | 單一 land 的統計 |
| `GET /admin/lands/:landID/stats` | viewer | 同上 |
| `GET /admin/stats` | viewer | `totalLands` 與 `totalPlayers` |
| `DELETE /admin/lands/:landID` | admin | 移除 land |
| `POST /admin/lands` | admin | 尚未實作（501） |
| `GET /admin/lands/:landID/reevaluation-record` | admin | 下載 re-evaluation record |
| `GET /admin/reevaluation/records` | viewer | 列出 re-evaluation record |
| `POST /admin/reevaluation/start` | admin | 為某個 record 啟動 re-evaluation monitor land |
| `POST /admin/reevaluation/replay/start` | admin | 為某個 record 啟動 replay land |

兩個 reevaluation start 都接受 JSON body `{ landType, recordFilePath, expectedLandDefinitionID?, expectedRecordVersion? }`（monitor 對應 `ReevaluationMonitorStartRequest`）。路由會檢查 record 位於 records 目錄內、存在且相容，再回傳 land 的 ID（`monitorLandID` 或 `replayLandID`）。這個 ID 是伺服器為該 record 簽發的 ticket：只有路由簽發的 ID 能建立 land，且須在簽發後五分鐘內；一種 land 的 ticket 不能開啟另一種 land。monitor land 建立時即開始驗證 ticket 綁定的 record；`StartVerification` action 只會在前一次執行結束後以同一個 record 重新開始，其 `landType` 與 `recordFilePath` 欄位會被忽略。

```bash
curl -H "X-API-Key: your-secure-api-key" http://localhost:8080/admin/lands
```

回應：
```json
{
  "success": true,
  "data": ["game-room-1", "game-room-2"]
}
```

### 除錯狀態路由（僅限測試）

供 E2E 狀態收斂檢查使用。只有在設定 admin API key **且** `ENABLE_DEBUG_STATE_ROUTES=true` 時才會註冊，並需要 `admin` 角色。這些路由會回傳完整的 land 狀態，而 freeze 會暫停 land，因此一旦啟用，任何持有 key 的人都能造成服務中斷。**切勿在正式環境啟用。**

| 路由 | 作用 |
|---|---|
| `POST /admin/lands/:landID/debug/freeze` | 暫停 land（不再開始 tick 或 sync，無 tick 的 land 會暫扣輸入），等進行中的工作結束，再送出一次 settle sync。回傳 `{ freezeToken, tickId, freezeCount, reused }`。freeze 有參照計數；已凍結時再 freeze 會回傳同一個 token，不會再 settle。若進行中的工作或執行中的 sync 讓 drain 與 settle 超過期限（10 秒），freeze 會被釋放並回 503；若 freeze 在 settle 完成前就被釋放，回 409。 |
| `GET /admin/lands/:landID/debug/projection?playerID=...` | settle sync 描述給該玩家的狀態（broadcast 加上該玩家的 per-player 欄位）；不帶 `playerID` 時只回 broadcast 欄位。值的形狀與 state wire 相同（例如 `Position2` 是原始定點整數）。freeze 期間若有人加入或離開，`membershipChanged` 為 true。land 未凍結時回 409。 |
| `POST /admin/lands/:landID/debug/resume?freezeToken=...` | 釋放回傳該 `freezeToken` 的 freeze 的一個參照（放在 query 或 JSON body `{ "freezeToken": ... }`；缺少時回 400）。最後一個釋放時 land 恢復執行，並補跑凍結期間被延後的 sync。已被釋放（例如自動恢復）的 freeze 的 token 不做任何事（`resumed: false`），因此不會釋放較新的 freeze。 |

凍結的 land 會在 `DEBUG_FREEZE_TIMEOUT_SECONDS`（預設 30）秒後自動恢復；每次 freeze 都會重新計時。

## 錯誤處理

### 被拒絕的連線

JWT 驗證失敗，或啟用 JWT、關閉 guest 模式且沒有送 token 時，server 會在 upgrade 之後立刻關閉連線，不送 WebSocket close frame。客戶端可能先看到 `open`，接著收到 code 1006、沒有原因的 `close`；server 會記錄 `JWT/auth validation failed, rejecting upgrade` 與錯誤內容。

```typescript
ws.onclose = (event) => {
  if (!event.wasClean) {
    // Could be an invalid or expired token: refresh it and reconnect
    handleAuthError();
  }
};
```

### Admin 路由錯誤

Admin 路由回傳標準 HTTP 狀態碼：

- `401 Unauthorized`：缺少或錯誤的 API key
- `404 Not Found`：land 或 record 不存在
- `400 Bad Request`：缺少參數

## 安全性建議

### 1. Secret Key 管理

- **不要將 secret key 寫死在程式碼中**：使用環境變數或密鑰管理服務
- **使用強密鑰**：至少 32 字元的隨機字串
- **定期輪換**：定期更換 secret key

```swift
// ✅ Correct: Read from environment variable
let jwtConfig = JWTConfiguration.fromEnvironment()

// ❌ Wrong: Hardcoded in code
let jwtConfig = JWTConfiguration(secretKey: "my-secret-key")
```

### 2. Token 過期時間

設定合理的 token 過期時間。token 放在 URL 中，可能出現在 proxy 或 access log，因此有效期要短：

```swift
// Set expiration time when generating token
let expiration = Date().addingTimeInterval(3600 * 2) // 2 hours
```

### 3. HTTPS/WSS

在生產環境中，務必使用 HTTPS 和 WSS（通常在 NIO server 前方的 load balancer 或 ingress 終止 TLS）：

```swift
// Production should use WSS
let wsURL = "wss://your-domain.com/game?token=\(token)"
```

### 4. Admin API Key

- **使用強隨機字串**：至少 32 字元
- **優先使用 header**：放在 `?apiKey=` 的 key 和 token 一樣會進到 log
- **限制存取來源**：使用 IP 白名單或 VPN
- **記錄所有 Admin 操作**：用於審計

### 5. Guest 模式限制

在生產環境中，建議對 Guest 模式實施限制：

```swift
// Limit Guest player count
// Limit Guest player actions
// Regularly clean up inactive Guest players
```

## 相關文檔

- [Transport 層](README.zh-TW.md) - 了解連線管理機制
- [Server 整合指南](server-integration.zh-TW.md) - 其他框架使用的 `TokenValidatorProtocol` 與 auth resolver
- [FAQ](../FAQ.zh-TW.md) - 常見問題解答
