[English](README.md) | [中文版](README.zh-TW.md)

# Hummingbird

Hummingbird 模組提供 WebSocket hosting，主要入口是 `LandHost`。

## 架構概述

### LandHost vs LandServer

`LandHost` 是統一的主機入口，負責管理 HTTP 服務器和所有遊戲邏輯。`LandServer` 則負責單一 land type 的遊戲邏輯實現。

**關係說明**：

- **`LandHost`**: 統一管理 HTTP 服務器（Hummingbird Application）、共享 Router、以及 `LandRealm`（遊戲邏輯統一管理）。一個 `LandHost` 可以註冊多個 `LandServer` 實例。
- **`LandServer`**: 負責單一 land type 的遊戲邏輯，包括 runtime、transport、WebSocket 適配器。不直接管理 HTTP 服務器或 Router，而是由 `LandHost` 統一管理。
- **`LandRealm`**: 由 `LandHost` 內部管理，負責多個 `LandServer` 的統一管理和協調。

## 快速開始

### 基本使用

使用 `LandHost` 建立伺服器並註冊 land type：

```swift
import SwiftStateTreeHummingbird

@main
struct DemoServer {
    static func main() async throws {
        // Create LandHost with HTTP server configuration
        let host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
            port: 8080,
            logger: logger
        ))

        // Register land type - router is automatically used
        try await host.register(
            landType: "cookie",
            land: CookieGame.makeLand(),
            initialState: CookieGameState(),
            webSocketPath: "/game/cookie",
            configuration: LandServerConfiguration(
                logger: logger,
                jwtConfig: jwtConfig,
                allowGuestMode: true,
                allowAutoCreateOnJoin: true
            )
        )

        // Run unified server
        try await host.run()
    }
}
```

### 多 Land Type 支援

在同一個 `LandHost` 中註冊多個遊戲：

```swift
let host = LandHost(configuration: .init(
    host: "localhost",
    port: 8080,
    logger: logger
))

// Register Cookie Game
try await host.register(
    landType: "cookie",
    land: CookieGame.makeLand(),
    initialState: CookieGameState(),
    webSocketPath: "/game/cookie",
    configuration: serverConfig
)

// Register Counter Demo
try await host.register(
    landType: "counter",
    land: CounterDemo.makeLand(),
    initialState: CounterState(),
    webSocketPath: "/game/counter",
    configuration: serverConfig
)

try await host.run()
```

## 配置選項

### LandHost.HostConfiguration

HTTP 服務器層面的配置：

```swift
public struct HostConfiguration: Sendable {
    public var host: String              // Server host (default: "localhost")
    public var port: UInt16             // Server port (default: 8080)
    public var healthPath: String        // Health check path (default: "/health")
    public var enableHealthRoute: Bool   // Enable health check route (default: true)
    public var logStartupBanner: Bool   // Enable startup banner (default: true)
    public var logger: Logger?           // Logger instance (optional)
}
```

### LandServerConfiguration

遊戲邏輯層面的配置：

```swift
public struct LandServerConfiguration: Sendable {
    public var logger: Logger?
    public var jwtConfig: JWTConfiguration?
    public var jwtValidator: JWTAuthValidator?
    public var allowGuestMode: Bool              // Allow connections without JWT (default: false)
    public var allowAutoCreateOnJoin: Bool       // Auto-create rooms on join (default: false)
}
```

**重要設定說明**：

- `allowGuestMode`: 啟用後允許沒有 JWT token 的連線（使用 guest session）
- `allowAutoCreateOnJoin`: 啟用後，客戶端可以通過指定 `landID` 自動創建新房間。**注意**：生產環境應設為 `false`，僅在 demo/testing 時啟用。

## 內建路由

`LandHost` 自動提供以下路由：

- **WebSocket**: 由 `webSocketPath` 參數指定（例如 `/game/cookie`、`/game/counter`）
- **Health Check**: `healthPath`（預設 `/health`，可透過 `enableHealthRoute` 關閉）
- **Schema**: `/schema`（自動輸出所有已註冊 Land 的 JSON schema，含 CORS 支援）

啟動時，`LandHost` 會自動打印連接資訊，包括所有已註冊的 WebSocket 端點。

## 房間管理

### 多房間模式

`LandHost` 預設支援多房間模式：

- 客戶端可以通過 `JoinRequest` 的 `landID` 參數指定要加入的房間
- `landID` 格式：`"landType:instanceId"`（例如 `"cookie:room-123"`）
- 如果只提供 `instanceId`（例如 `"room-123"`），codegen 會自動添加 `landType` 前綴

### 自動創建房間

當 `allowAutoCreateOnJoin: true` 時：

- 客戶端可以通過指定不存在的 `landID` 來創建新房間
- 例如：連接到 `"cookie:my-room"` 會自動創建一個新的 cookie 遊戲房間

### 單房間行為

即使啟用了多房間模式，也可以通過以下方式實現單房間行為：

- 客戶端不指定 `landID`（或使用預設值），所有客戶端會連接到同一個房間
- 或者所有客戶端都指定相同的 `landID`

## 進階用法

### 自定義路由

`LandHost` 內部管理 Router，如果需要添加自定義路由，可以通過 `LandHost` 的擴展來實現（未來版本可能會提供更直接的 API）。

### Admin Routes

`LandHost` 提供 `registerAdminRoutes` 方法來註冊管理路由：

```swift
try await host.registerAdminRoutes(
    adminAuth: adminAuth,
    enableAdminRoutes: true
)
```

## 環境變數配置

可以通過環境變數配置伺服器：

```bash
# Set port
PORT=3000 swift run DemoServer

# Set host and port
HOST=0.0.0.0 PORT=3000 swift run DemoServer
```

## 相關文件

- [JWT 與 Guest 模式](auth.zh-TW.md) - 了解認證和授權機制
- [快速開始](../quickstart.zh-TW.md) - 從零開始建立第一個伺服器
- [Transport 層](../transport/README.zh-TW.md) - 了解網路傳輸機制
