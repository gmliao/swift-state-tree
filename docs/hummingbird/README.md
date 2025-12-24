# Hummingbird

Hummingbird 模組提供 WebSocket hosting，主要入口是 `LandServer`。

> `AppContainer` 是 `LandServer` 的型別別名，舊範例仍可使用。

## 單房間模式

使用 `LandServer.makeServer` 建立固定房間：

```swift
let server = try await LandServer.makeServer(
    configuration: .init(),
    land: demoLand,
    initialState: GameState()
)
try await server.run()
```

## 多房間模式

使用 `LandServer.makeMultiRoomServer` 建立多房間架構：

- `LandManager` 管理房間
- `LandRouter` 負責 land 路由

## 重要設定

`LandServer.Configuration`：

- `host` / `port`
- `webSocketPath` / `healthPath`
- `jwtConfig` / `jwtValidator` / `allowGuestMode`
- `enableAdminRoutes` / `adminAuth`

## 內建路由

- WebSocket：`webSocketPath`
- Health：`healthPath`（可關閉）
- Schema：`/schema`（自動輸出 Land schema，含 CORS）

## 相關文件

- `docs/hummingbird/auth.md`
