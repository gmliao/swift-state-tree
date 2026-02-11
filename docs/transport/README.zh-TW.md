[English](README.md) | [中文版](README.zh-TW.md)

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

若要將 SwiftStateTree 與其他 HTTP/WebSocket 框架（如 Vapor、Kitura）整合，請參閱 [Server 整合指南](server-integration.zh-TW.md)。

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

### Broadcast 與 Per-Player 更新

- **Broadcast**：每次 sync 只編碼一次並送給所有 session（MessagePack 時為 opcode **107**）。
- **Per-player**：以標準 StateUpdate opcode（0/1/2）逐玩家送出，與 broadcast 分離。
- **firstSync**：仍維持單一合併更新（該玩家完整狀態）。
- **Events**：broadcast events 可合併進 opcode 107；targeted events 仍獨立送出。

## 錯誤處理

- join/action/event 錯誤會回傳 `ErrorPayload`
- join 會檢查 landID 與 session 狀態，避免重複加入或錯誤路由

## 多房間支援

- `LandManager` 管理 Land lifecycle 與查詢
- `LandRouter` 負責將連線導向對應 land
- multi-room 模式下 join 會依 landType + instanceId 進行路由

## 狀態更新編碼（State Update Encoding）

狀態更新在每個 sync 週期內以串行方式編碼。同一房間內每位玩家的更新依序編碼；多房間場景下，每個 `TransportAdapter` 獨立管理一個房間。

## 環境變數

Transport 相關行為可透過環境變數調整。所有變數在 `TransportAdapter` 初始化時讀取。完整清單與解析規則見 `TransportEnvConfig`（SwiftStateTreeTransport 模組）。

| 變數 | 型別 | 預設 | 說明 |
|------|------|------|------|
| `ENABLE_DIRTY_TRACKING` | Bool | init 參數 | 啟用 dirty-field 追蹤以產生較小 diff；高更新比例場景可關閉 |
| `USE_SNAPSHOT_FOR_SYNC` | Bool | true | 使用單次 snapshot 擷取；設為 `false` 使用舊版 broadcast + per-player 路徑 |
| `ENABLE_CHANGE_OBJECT_METRICS` | Bool | false | 記錄每次 sync 的 changed vs unchanged 物件比例 |
| `CHANGE_OBJECT_METRICS_LOG_EVERY` | Int | 10 | 變更物件 metrics 日誌的 sync 週期間隔 |
| `CHANGE_OBJECT_METRICS_EMA_ALPHA` | Double | 0.2 | 變更率 EMA alpha（0.01–1.0） |
| `AUTO_DIRTY_TRACKING` | Bool | true | 依變更率遲滯曲線自動切換 dirty tracking |
| `AUTO_DIRTY_OFF_THRESHOLD` | Double | 0.55 | 關閉 dirty tracking 的 EMA 門檻 |
| `AUTO_DIRTY_ON_THRESHOLD` | Double | 0.30 | 開啟 dirty tracking 的 EMA 門檻 |
| `AUTO_DIRTY_REQUIRED_SAMPLES` | Int | 30 | 模式切換前需連續採樣次數 |
| `TRANSPORT_PROFILE_JSONL_PATH` | String | 關閉 | 設定後啟用 transport profiling，將 JSONL 寫入此路徑 |
| `TRANSPORT_PROFILE_INTERVAL_MS` | Int | 1000 | Profiling 寫入間隔 (ms)，最小 100 |
| `TRANSPORT_PROFILE_SAMPLE_RATE` | Double | 0.01 | Latency 採樣率 (0.001–1.0) |
| `TRANSPORT_PROFILE_MAX_SAMPLES_PER_INTERVAL` | Int | 500 | 每間隔最大 latency 採樣數 (10–10000) |

布林解析：truthy = `1`, `true`, `yes`, `y`, `on`；falsy = `0`, `false`, `no`, `n`, `off`。
