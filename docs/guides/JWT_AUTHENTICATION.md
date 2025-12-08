# JWT 認證指南

本指南說明如何在 SwiftStateTree 中使用 JWT (JSON Web Token) 進行身份驗證。

## 目錄

- [概述](#概述)
- [伺服器端設置](#伺服器端設置)
- [JWT Payload 結構](#jwt-payload-結構)
- [登入流程](#登入流程)
- [客戶端實現](#客戶端實現)
- [範例](#範例)

## 概述

SwiftStateTree 支援在 WebSocket 握手階段進行 JWT 驗證。當客戶端建立 WebSocket 連接時，伺服器會：

1. 從 `Authorization: Bearer <token>` header 中提取 JWT token
2. 驗證 token 的簽名和有效性
3. 提取 payload 中的玩家資訊（`playerID`, `deviceID`, `metadata`）
4. 將這些資訊傳遞到 Land 層的 `OnJoin` handler

## 伺服器端設置

### 1. 配置 JWT Secret Key

#### 方法 1: 環境變數（推薦）

```bash
export JWT_SECRET_KEY="your-secret-key-here"
export JWT_ALGORITHM="HS256"  # 可選，預設為 HS256
export JWT_ISSUER="your-app-name"  # 可選
export JWT_AUDIENCE="your-audience"  # 可選
```

#### 方法 2: 程式碼配置

```swift
import SwiftStateTreeHummingbird

let jwtConfig = JWTConfiguration(
    secretKey: "your-secret-key-here",
    algorithm: .HS256,
    validateExpiration: true,
    validateIssuer: false,
    expectedIssuer: nil,
    validateAudience: false,
    expectedAudience: nil
)

let appContainer = AppContainer(
    land: myLand,
    initialState: MyState(),
    configuration: AppContainer.Configuration(
        jwtConfig: jwtConfig
    )
)
```

### 2. 啟動伺服器

```swift
// 從環境變數載入配置
let config = AppContainer.Configuration(
    jwtConfig: JWTConfiguration.fromEnvironment()
)

let appContainer = AppContainer(
    land: myLand,
    initialState: MyState(),
    configuration: config
)

try await appContainer.start()
```

## JWT Payload 結構

JWT Payload 必須包含以下字段：

### 必需字段

- `playerID` (String): 玩家唯一識別碼

### 可選字段

- `deviceID` (String?): 裝置識別碼
- `metadata` (Dictionary<String, String>?): 額外的元資料字典
- `iss` (String?): Issuer（發行者）
- `sub` (String?): Subject（通常也是 playerID）
- `aud` (String?): Audience（目標受眾）
- `exp` (Int64?): Expiration Time（過期時間，Unix timestamp）
- `iat` (Int64?): Issued At（發行時間，Unix timestamp）
- `nbf` (Int64?): Not Before（生效時間，Unix timestamp）

### 自定義字段

除了上述標準字段外，您可以在 JWT payload 中添加任意自定義字段（如 `username`, `schoolid`, `level` 等）。這些字段會自動被捕獲並放入 `metadata` 字典中，最終傳遞到 Land 層的 `OnJoin` handler。

**範例 JWT Payload：**

```json
{
  "playerID": "player-123",
  "deviceID": "device-456",
  "username": "alice",
  "schoolid": "school-789",
  "level": "10",
  "exp": 1735689600,
  "iat": 1735603200
}
```

## 登入流程

### 完整流程圖

```
客戶端                          伺服器
  |                               |
  |  1. WebSocket 連接請求          |
  |  (Authorization: Bearer <token>) |
  |------------------------------->|
  |                               |
  |                               | 2. 驗證 JWT token
  |                               |    - 檢查簽名
  |                               |    - 檢查過期時間
  |                               |    - 提取 payload
  |                               |
  |  3a. 驗證失敗 -> 關閉連接       |
  |<-------------------------------|
  |                               |
  |  3b. 驗證成功 -> 建立連接        |
  |<-------------------------------|
  |                               |
  |  4. 發送 join 請求              |
  |------------------------------->|
  |                               |
  |                               | 5. 處理 join 請求
  |                               |    - 使用 JWT payload 填充 PlayerSession
  |                               |    - 調用 OnJoin handler
  |                               |    - 發送初始狀態快照
  |                               |
  |  6. 收到 join 回應和初始狀態    |
  |<-------------------------------|
  |                               |
```

### 詳細步驟

#### 步驟 1: 客戶端生成 JWT Token

客戶端需要使用與伺服器相同的 secret key 和算法來生成 JWT token。

**範例（JavaScript/TypeScript）：**

```typescript
import { SignJWT } from 'jose'  // 或使用其他 JWT 庫

const secret = new TextEncoder().encode('your-secret-key-here')

const token = await new SignJWT({
  playerID: 'player-123',
  deviceID: 'device-456',
  username: 'alice',
  schoolid: 'school-789',
  level: '10'
})
  .setProtectedHeader({ alg: 'HS256' })
  .setIssuedAt()
  .setExpirationTime('2h')
  .sign(secret)
```

#### 步驟 2: 建立 WebSocket 連接

在建立 WebSocket 連接時，將 JWT token 放在 URL 的 `token` query parameter 中：

```typescript
const ws = new WebSocket(`ws://localhost:8080/game?token=${encodeURIComponent(token)}`)
```

**注意：** 使用 query parameter 方式是因為瀏覽器的標準 WebSocket API 不支援自定義 headers。這種方式簡單且與所有客戶端兼容。

#### 步驟 3: 伺服器驗證 Token

伺服器在 WebSocket 握手階段驗證 token：

1. 提取 `Authorization: Bearer <token>` header
2. 驗證簽名（使用配置的 secret key）
3. 檢查過期時間（如果啟用）
4. 檢查 Issuer/Audience（如果配置）
5. 提取 `AuthenticatedInfo`（包含 `playerID`, `deviceID`, `metadata`）

#### 步驟 4: 客戶端發送 Join 請求

連接建立後，客戶端必須明確發送 join 請求：

```typescript
const joinMessage = {
  join: {
    requestID: 'join-1',
    landID: 'my-land',
    playerID: null,  // 可選，如果提供會覆蓋 JWT payload 中的 playerID
    deviceID: null,  // 可選，如果提供會覆蓋 JWT payload 中的 deviceID
    metadata: null   // 可選，如果提供會與 JWT payload 的 metadata 合併
  }
}

ws.send(JSON.stringify(joinMessage))
```

#### 步驟 5: 伺服器處理 Join 請求

伺服器在 `handleJoinRequest` 中：

1. **優先級規則：**
   - Join 消息中的值（最高優先級）
   - JWT payload 中的值（中等優先級）
   - `createPlayerSession` closure 或默認值（最低優先級）

2. **合併 metadata：**
   - 先從 JWT payload 的 `metadata` 開始
   - 然後合併 join 消息中的 `metadata`（覆蓋衝突的鍵）

3. **創建 PlayerSession：**
   ```swift
   PlayerSession(
       playerID: finalPlayerID,      // 來自 join 消息或 JWT payload
       deviceID: finalDeviceID,     // 來自 join 消息或 JWT payload
       metadata: finalMetadata       // 合併後的 metadata
   )
   ```

4. **調用 OnJoin handler：**
   - `ctx.playerID`: 最終確定的 playerID
   - `ctx.deviceID`: 最終確定的 deviceID
   - `ctx.metadata`: 合併後的 metadata（包含所有自定義字段）

## 客戶端實現

### Playground 實現

Playground 內建了 JWT token 生成功能，使用 Web Crypto API：

```typescript
// 生成 JWT token
async function generateJWT(
  secretKey: string,
  payload: {
    playerID: string
    deviceID?: string
    username?: string
    schoolid?: string
    [key: string]: any
  }
): Promise<string> {
  // 實現見 Playground 源碼
}
```

### 自定義客戶端實現

如果您要實現自己的客戶端，可以使用任何 JWT 庫：

**Node.js:**
```javascript
const jwt = require('jsonwebtoken')

const token = jwt.sign({
  playerID: 'player-123',
  username: 'alice',
  schoolid: 'school-789'
}, 'your-secret-key-here', {
  algorithm: 'HS256',
  expiresIn: '2h'
})
```

**Python:**
```python
import jwt

token = jwt.encode({
    'playerID': 'player-123',
    'username': 'alice',
    'schoolid': 'school-789'
}, 'your-secret-key-here', algorithm='HS256')
```

## 範例

### 完整範例：伺服器端

```swift
import SwiftStateTree
import SwiftStateTreeHummingbird

// 定義 State
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerInfo] = [:]
}

struct PlayerInfo: Codable, Sendable {
    let playerID: String
    let username: String?
    let schoolID: String?
    let level: String?
}

// 定義 Land
let gameLand = Land("my-game", using: GameState.self) {
    Rules {
        OnJoin { (state: inout GameState, ctx: LandContext) in
            // JWT payload 中的自定義字段可在 ctx.metadata 中訪問
            state.players[ctx.playerID] = PlayerInfo(
                playerID: ctx.playerID.rawValue,
                username: ctx.metadata["username"],
                schoolID: ctx.metadata["schoolid"],
                level: ctx.metadata["level"]
            )
        }
    }
}

// 配置並啟動伺服器
let jwtConfig = JWTConfiguration(
    secretKey: ProcessInfo.processInfo.environment["JWT_SECRET_KEY"] ?? "default-secret",
    algorithm: .HS256,
    validateExpiration: true
)

let appContainer = AppContainer(
    land: gameLand,
    initialState: GameState(),
    configuration: AppContainer.Configuration(
        jwtConfig: jwtConfig
    )
)

try await appContainer.start()
```

### 完整範例：客戶端（Playground）

```typescript
// 1. 生成 JWT token
const secretKey = 'your-secret-key-here'
const token = await generateJWT(secretKey, {
  playerID: 'player-123',
  deviceID: 'device-456',
  username: 'alice',
  schoolid: 'school-789',
  level: '10'
})

// 2. 建立 WebSocket 連接（帶 token）
const ws = new WebSocket(`ws://localhost:8080/game?token=${token}`)

// 3. 連接成功後發送 join 請求
ws.onopen = () => {
  const joinMessage = {
    join: {
      requestID: `join-${Date.now()}`,
      landID: 'my-game',
      playerID: null,  // 使用 JWT payload 中的 playerID
      deviceID: null,  // 使用 JWT payload 中的 deviceID
      metadata: null   // 使用 JWT payload 中的 metadata
    }
  }
  ws.send(JSON.stringify(joinMessage))
}
```

## 安全注意事項

1. **Secret Key 管理：**
   - 永遠不要將 secret key 提交到版本控制系統
   - 使用環境變數或密鑰管理服務
   - 定期輪換 secret key

2. **Token 過期時間：**
   - 設置合理的過期時間（建議 1-2 小時）
   - 使用 refresh token 機制來延長會話

3. **HTTPS/WSS：**
   - 生產環境必須使用 WSS（WebSocket Secure）
   - 防止 token 在傳輸過程中被竊取

4. **Token 驗證：**
   - 始終驗證 token 簽名
   - 檢查過期時間
   - 驗證 Issuer/Audience（如果適用）

## 故障排除

### 問題：連接被拒絕，錯誤 "Missing Authorization header"

**原因：** JWT validator 已配置，但客戶端未發送 Authorization header。

**解決方案：**
- 確保在 WebSocket 連接時發送 `Authorization: Bearer <token>` header
- 或使用 Playground 的 token 生成功能

### 問題：連接被拒絕，錯誤 "Invalid or expired token"

**原因：** Token 簽名無效或已過期。

**解決方案：**
- 檢查 secret key 是否與伺服器配置一致
- 檢查 token 是否過期
- 重新生成 token

### 問題：自定義字段（username, schoolid）未傳遞到 OnJoin handler

**原因：** 字段未正確包含在 JWT payload 中。

**解決方案：**
- 確保自定義字段在生成 token 時包含在 payload 中
- 檢查 token 解碼後的 payload 是否包含這些字段

## 相關文檔

- [Land DSL 文檔](../design/DESIGN_LAND_DSL.md)
- [Transport 文檔](../design/DESIGN_TRANSPORT.md)
- [AppContainer 文檔](../design/DESIGN_APP_CONTAINER_HOSTING.md)

