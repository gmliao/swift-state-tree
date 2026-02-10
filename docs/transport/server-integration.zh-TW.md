# Server 整合指南

[English](server-integration.md) | [中文版](server-integration.zh-TW.md)

本指南說明如何將 SwiftStateTree 與**任意的** HTTP/WebSocket 框架（NIO、Vapor、Hummingbird、Kitura 等）整合。Transport 層與框架無關，只需接好少數擴充點即可。

## 契約：任何 Server 必須做的事

1. **建立 `WebSocketTransport`**：每個 land 類型（或路徑）一個，並接到 `LandRouter` 或 `TransportAdapter`。
2. **在 WebSocket upgrade 時**：從 handshake（path + URI）解析 auth，再呼叫 `WebSocketTransport.handleConnection(sessionID:connection:authInfo:)`。
3. **可選**：提供 HTTP 端點 `/schema`（給客戶端/codegen）與 `/admin/*`（管理用）。

Auth 與 schema 都是**可選**；唯一必要的是呼叫 `handleConnection` 並傳入 `WebSocketConnection` 與可選的 `AuthenticatedInfo`。

## 擴充點（SwiftStateTreeTransport）

以下型別都在 **SwiftStateTreeTransport**，因此 server 實作只需依賴 transport 模組。

### 1. Auth：`AuthInfoResolverProtocol`

在接受連線**之前**，從 WebSocket handshake 解析出已驗證資訊。

```swift
public protocol AuthInfoResolverProtocol: Sendable {
    func resolve(path: String, uri: String) async throws -> AuthenticatedInfo?
}
```

- **path**：正規化路徑（例如 `/game/counter`）。
- **uri**：完整請求 URI（例如 `/game/counter?token=eyJ...`），可從中讀取 query 或傳給 token 驗證器。
- **回傳**：已驗證使用者回傳 `AuthenticatedInfo`，允許的訪客回傳 `nil`，或 **throw** 以拒絕 upgrade。

**便利用法**：若 server 只接受函式，可用 `ClosureAuthInfoResolver { path, uri in ... }` 包成 protocol。

### 2. Token 驗證：`TokenValidatorProtocol`

驗證 token 字串（例如 JWT）並回傳 `AuthenticatedInfo`。當你從 URI/headers 取出 token 並希望用可重用的方式驗證時使用。

```swift
public protocol TokenValidatorProtocol: Sendable {
    func validate(token: String) async throws -> AuthenticatedInfo
}
```

- **SwiftStateTreeNIO** 提供 `DefaultJWTAuthValidator`（HS256/384/512，可選 RS/ES），並 conform `TokenValidatorProtocol`。任何框架都可使用：從請求取出 token，再呼叫 `validator.validate(token:)`。
- 也可自行實作（例如 API key、自訂 JWT claims），並將結果傳入 `handleConnection(..., authInfo:)`。

### 3. 連線：`WebSocketConnection`

Server 必須提供 conform `WebSocketConnection` 的型別（send/receive 與 close）。Transport 只依賴此介面，不關心底層是 NIO、Vapor 或其他。

### 4. Schema 與 admin（可選）

- **Schema**：若提供 `GET /schema`，回傳 Land 定義產生的 JSON（例如透過 `SchemaGenCLI.generateSchema`）。NIO host 使用 `schemaProvider: () -> Data?` 閉包；其他框架可實作相同契約。
- **Admin**：實作你需要的管理路由（列出 lands、統計、reevaluation record 等）。NIO 實作使用 `NIOAdminRoutes`；可對齊相同 API 或子集。

## 最小整合檢查表

| 步驟 | 動作 |
|------|------|
| 1 | 建立 `WebSocketTransport`，並將 `delegate` 設為你的 `TransportAdapter`（或對應物）。 |
| 2 | WebSocket upgrade 時：建立 `SessionID`，取得 path 與完整 URI，呼叫你的 `AuthInfoResolverProtocol.resolve(path:uri:)`（或略過 auth 傳 `nil`）。 |
| 3 | 呼叫 `transport.handleConnection(sessionID: sessionID, connection: yourConnection, authInfo: resolvedAuthInfo)`。 |
| 4 | （可選）用框架的 router 提供 `/schema` 與 admin 路由。 |
| 5 | （可選）若需要 JWT，在 auth resolver 內使用 `TokenValidatorProtocol`（例如 SwiftStateTreeNIO 的 `DefaultJWTAuthValidator`）。 |

## 參考實作

**SwiftStateTreeNIO** 為參考實作：使用純 SwiftNIO、透過 `ClosureAuthInfoResolver` 與 per-path JWT 設定實作 `AuthInfoResolverProtocol`，並將結果傳入 `WebSocketTransport.handleConnection`。在 Vapor 或其他框架可套用相同模式：實作 `AuthInfoResolverProtocol`（或以閉包包裝）、為該框架的 WebSocket 型別做 `WebSocketConnection` 轉接，並在 upgrade 時呼叫 `handleConnection`。

## 相關文件

- [Transport README](README.md) – transport 層概覽與資料流
- [SwiftStateTreeNIO](../../Sources/SwiftStateTreeNIO/) – NIO WebSocket server 與 `NIOLandHost`
