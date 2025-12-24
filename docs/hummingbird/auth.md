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
let config = JWTConfiguration(
    secretKey: "your-secret-key",
    algorithm: .HS256,
    validateExpiration: true
)

let server = try await LandServer.makeServer(
    configuration: .init(jwtConfig: config, allowGuestMode: true),
    land: demoLand,
    initialState: GameState()
)
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
