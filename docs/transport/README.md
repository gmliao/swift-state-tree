# Transport

Transport 層將網路連線與 LandKeeper 串接，核心目標是「不把網路細節暴露給 Land DSL」。

## 設計重點

- Land 層只關心 `LandContext` 與 handlers，不知道 WebSocket/HTTP 細節
- Transport 層負責連線管理、訊息序列化與路由
- 同步採 snapshot + diff，避免阻塞 state mutation

## 資料流

```
Client ↔ WebSocketTransport ↔ TransportAdapter ↔ LandKeeper
```

## 三層識別

- `playerID`：帳號/玩家身分（業務層）
- `clientID`：裝置或 client instance（應用端提供）
- `sessionID`：連線層識別（server 產生）

這三層識別會進入 `LandContext`，讓 handler 有一致的使用介面，
也支援多裝置、多連線的行為控制。

## 核心組件

- Transport protocol：抽象連線行為（start/stop/send）
- WebSocketTransport：預設 WebSocket 實作
- TransportAdapter：解析訊息並呼叫 LandKeeper
- LandManager / Registry：管理多房間
- LandRouter / LandRealm：跨房間路由與控制

## Join 與 Session 流程

- client 必須明確送出 join request
- join 會建立 `PlayerSession`，並依序執行 `CanJoin` / `OnJoin`
- 初次加入會回傳 snapshot，後續由 `StateUpdate`（firstSync/diff）接續

PlayerSession 欄位優先序：

1. join request 內容
2. JWT payload
3. guest session

## 同步模型

- snapshot：完整狀態（含 per-player 過濾）
- diff：只傳變更（path-based patches）
- firstSync：玩家首次建立 cache 後送出一次

## 錯誤處理

- join/action/event 錯誤會回傳 `ErrorPayload`
- join 會檢查 landID 與 session 狀態，避免重複加入或錯誤路由

## 多房間支援

- `LandManager` 管理 Land lifecycle 與查詢
- `LandRouter` 負責將連線導向對應 land
- multi-room 模式下 join 會依 landType + instanceId 進行路由
