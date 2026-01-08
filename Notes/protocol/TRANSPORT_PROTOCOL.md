# WebSocket Transport Protocol

本文檔定義了 SwiftStateTree 的 WebSocket 傳輸協議格式。所有訊息都通過 WebSocket 以 JSON 格式傳輸。

## 目錄

1. [訊息類型概覽](#訊息類型概覽)
2. [TransportMessage](#transportmessage)
3. [Action 訊息](#action-訊息)
4. [Event 訊息](#event-訊息)
5. [Join 訊息](#join-訊息)
6. [State Update 訊息](#state-update-訊息)
7. [Snapshot 格式](#snapshot-格式)
8. [編碼細節](#編碼細節)

## 訊息類型概覽

所有 WebSocket 訊息都包裝在 `TransportMessage` 中，使用統一的 `kind` 欄位來識別訊息類型：

- `kind: "action"` - 客戶端發送 Action 請求
- `kind: "actionResponse"` - 伺服器回應 Action 請求
- `kind: "event"` - 客戶端或伺服器發送 Event
- `kind: "join"` - 客戶端發送加入請求
- `kind: "joinResponse"` - 伺服器回應加入請求
- `kind: "error"` - 伺服器發送錯誤訊息

此外，狀態更新以獨立的 `StateUpdate` 格式發送（不包裝在 `TransportMessage` 中）。

## TransportMessage

`TransportMessage` 使用統一的 `kind` 欄位來識別訊息類型，`payload` 欄位包含實際的訊息內容。這種設計提供了更好的可維護性和擴展性。

### TypeScript 定義

```typescript
export type MessageKind = 'action' | 'actionResponse' | 'event' | 'join' | 'joinResponse' | 'error'

export interface TransportMessage {
  kind: MessageKind
  payload: TransportActionPayload | TransportActionResponsePayload | TransportEventPayload | TransportJoinPayload | TransportJoinResponsePayload | ErrorPayload
}

// Simplified action payload - fields are flattened (not nested in "action")
export interface TransportActionPayload {
  requestID: string
  typeIdentifier: string  // Action 類型識別符（例如 "PlayAction"）
  payload: string         // Base64 編碼的 JSON payload
}

export interface TransportActionResponsePayload {
  requestID: string
  response: any
}

// Simplified event payload - directly contains fromClient or fromServer
export interface TransportEventPayload {
  fromClient?: {
    type: string
    payload: any
    rawBody?: any
  }
  fromServer?: {
    type: string
    payload: any
    rawBody?: any
  }
}

export interface TransportJoinPayload {
  requestID: string
  /// The type of Land to join (required)
  landType: string
  /// The specific instance to join (optional, if null a new room will be created)
  landInstanceId?: string | null
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
}

export interface TransportJoinResponsePayload {
  requestID: string
  success: boolean
  /// The type of Land joined
  landType?: string | null
  /// The instance ID of the Land joined
  landInstanceId?: string | null
  /// The complete landID (landType:instanceId)
  landID?: string | null
  playerID?: string
  reason?: string
}

export interface ErrorPayload {
  code: string
  message: string
  details?: Record<string, any>
}
```

### Swift 定義

```swift
public enum MessageKind: String, Codable, Sendable {
    case action
    case actionResponse
    case event
    case join
    case joinResponse
    case error
}

public struct TransportMessage: Codable, Sendable {
    public let kind: MessageKind
    public let payload: MessagePayload
}

public enum MessagePayload: Codable, Sendable {
    case action(TransportActionPayload)
    case actionResponse(TransportActionResponsePayload)
    case event(TransportEventPayload)
    case join(TransportJoinPayload)
    case joinResponse(TransportJoinResponsePayload)
    case error(ErrorPayload)
}

/// Join request payload for transport layer.
///
/// Uses `landType` (required) and `landInstanceId` (optional) instead of `landID`.
/// - If `landInstanceId` is provided: Join an existing room
/// - If `landInstanceId` is nil: Create a new room and return the generated instanceId
public struct TransportJoinPayload: Codable, Sendable {
    public let requestID: String
    /// The type of Land to join (required)
    public let landType: String
    /// The specific instance to join (optional, if nil a new room will be created)
    public let landInstanceId: String?
    public let playerID: String?
    public let deviceID: String?
    public let metadata: [String: AnyCodable]?
}

/// Join response payload for transport layer.
public struct TransportJoinResponsePayload: Codable, Sendable {
    public let requestID: String
    public let success: Bool
    /// The type of Land joined
    public let landType: String?
    /// The instance ID of the Land joined
    public let landInstanceId: String?
    /// The complete landID (landType:instanceId)
    public let landID: String?
    public let playerID: String?
    public let reason: String?
}
```

**編碼細節：**

`MessagePayload` enum 使用自定義 Codable 實現，根據 `kind` 欄位編碼為對應的 key：

- `kind: "action"` → `payload: { "requestID": string, "typeIdentifier": string, "payload": string }` (簡化格式，字段扁平化)
- `kind: "actionResponse"` → `payload: { "actionResponse": TransportActionResponsePayload }`
- `kind: "event"` → `payload: { "fromClient": {...} }` 或 `{ "fromServer": {...} }` (簡化格式，直接包含 fromClient/fromServer)
- `kind: "join"` → `payload: { "join": TransportJoinPayload }`
- `kind: "joinResponse"` → `payload: { "joinResponse": TransportJoinResponsePayload }`
- `kind: "error"` → `payload: { "error": ErrorPayload }`

範例：

```json
{
  "kind": "error",
  "payload": {
    "error": {
      "code": "INVALID_JSON",
      "message": "Failed to decode message",
      "details": { ... }
    }
  }
}
```

## Action 訊息

### Action 請求（客戶端 → 伺服器）

客戶端發送 Action 請求時，使用 `kind: "action"`：

```json
{
  "kind": "action",
  "payload": {
    "requestID": "req-1234567890-abc",
    "typeIdentifier": "AddGold",
    "payload": "eyJhbW91bnQiOjEwMH0="
  }
}
```

**注意：** Action 消息格式已簡化，字段直接扁平化在 payload 中，不再嵌套在 `action` 對象中。`landID` 已移除，伺服器從 session 映射中識別 land。

#### ActionEnvelope

```typescript
export interface ActionEnvelope {
  typeIdentifier: string  // Action 類型識別符（例如 "AddGold"）
  payload: string          // Base64 編碼的 JSON payload
}
```

**Swift 定義：**

```swift
public struct ActionEnvelope: Codable, Sendable {
    public let typeIdentifier: String
    public let payload: Data  // 編碼為 Base64 字串傳輸
}
```

**編碼細節：**

1. Action payload 先序列化為 JSON
2. JSON 字串轉換為 UTF-8 Data
3. Data 編碼為 Base64 字串
4. 在 `ActionEnvelope` 中，`payload` 欄位存儲 Base64 字串

**範例：**

```typescript
// 原始 payload
const payload = { amount: 100 }

// 1. 序列化為 JSON
const payloadJson = JSON.stringify(payload)  // '{"amount":100}'

// 2. 編碼為 Base64
const payloadBase64 = btoa(unescape(encodeURIComponent(payloadJson)))
// 結果: "eyJhbW91bnQiOjEwMH0="
```

### Action 回應（伺服器 → 客戶端）

伺服器回應 Action 請求時，使用 `kind: "actionResponse"`：

```json
{
  "kind": "actionResponse",
  "payload": {
    "requestID": "req-1234567890-abc",
    "response": {
      "success": true,
      "newBalance": 200
    }
  }
}
```

**注意：** `response` 欄位的內容取決於 Action 的 `Response` 類型定義。

如果 Action 處理失敗，伺服器會發送 `kind: "error"` 訊息：

```json
{
  "kind": "error",
  "payload": {
    "code": "ACTION_NOT_REGISTERED",
    "message": "Action not registered: AddGold",
    "details": {
      "requestID": "req-1234567890-abc",
      "actionType": "AddGold"
    }
  }
}
```

## Event 訊息

### Event 結構

Event 訊息使用 `kind: "event"`，包含 `fromClient` 或 `fromServer` 之一：

```json
{
  "kind": "event",
  "payload": {
    "fromClient": {
      "type": "ChatEvent",
      "payload": {
        "message": "Hello, world!"
      }
    }
  }
}
```

**注意：** Event 消息格式已簡化，直接包含 `fromClient` 或 `fromServer`，不再嵌套在 `event` 對象中。`landID` 已移除，伺服器從 session 映射中識別 land。

或

```json
{
  "kind": "event",
  "payload": {
    "fromServer": {
      "type": "MatchmakingEvent",
      "payload": {
        "matched": {
          "landID": {
            "rawValue": "battle-royale-123"
          }
        }
      }
    }
  }
}
```

**注意：** Event 消息格式已簡化，直接包含 `fromClient` 或 `fromServer`，不再嵌套在 `event` 對象中。

#### TransportEvent

```swift
public enum TransportEvent: Codable, Sendable {
    case fromClient(event: AnyClientEvent)
    case fromServer(event: AnyServerEvent)
}
```

**編碼細節：**

`TransportEvent` 的編碼格式已簡化，直接編碼 `fromClient` 或 `fromServer`：

- `TransportEvent.fromClient(event: AnyClientEvent)` 編碼為 `{ "fromClient": AnyClientEvent }`
- `TransportEvent.fromServer(event: AnyServerEvent)` 編碼為 `{ "fromServer": AnyServerEvent }`

**注意：** 格式已簡化，不再嵌套在 `event` 對象中，`AnyClientEvent` 和 `AnyServerEvent` 直接作為 `fromClient` 或 `fromServer` 的值。

#### AnyClientEvent / AnyServerEvent

```swift
public struct AnyClientEvent: Codable, Sendable {
    public let type: String           // Event 類型名稱（例如 "ChatEvent"）
    public let payload: AnyCodable    // Event payload
    public let rawBody: Data?         // 可選的原始資料（未來擴展用）
}

public struct AnyServerEvent: Codable, Sendable {
    public let type: String           // Event 類型名稱（例如 "MatchmakingEvent"）
    public let payload: AnyCodable    // Event payload
    public let rawBody: Data?         // 可選的原始資料（未來擴展用）
}
```

**範例：**

客戶端發送 Event：

```typescript
const message: TransportMessage = {
  kind: "event",
  payload: {
    fromClient: {
      type: "ChatEvent",
      payload: {
        message: "Hello, world!"
      }
    }
  }
}
```

伺服器發送 Event：

```typescript
const message: TransportMessage = {
  kind: "event",
  payload: {
    fromServer: {
      type: "MatchmakingEvent",
      payload: {
        matched: {
          landID: {
            rawValue: "battle-royale-123"
          }
        }
      }
    }
  }
}
```

## Join 訊息

### Join 請求（客戶端 → 伺服器）

客戶端發送加入請求，使用 `kind: "join"`：

```json
{
  "kind": "join",
  "payload": {
    "join": {
    "requestID": "join-1234567890-abc",
      "landType": "demo-game",
      "landInstanceId": null,
    "playerID": "player-123",
    "deviceID": "device-456",
    "metadata": {
      "platform": "iOS",
      "version": "1.0.0"
      }
    }
  }
}
```

**欄位說明：**

- `requestID`: 唯一請求識別符（客戶端生成）
- `landType`: 要加入的 Land 類型（必填）
- `landInstanceId`: 要加入的具體實例 ID（可選，如果為 `null` 則創建新房間）
  - **單房間模式**：通常為 `null`，使用 `landType` 作為固定 land
  - **多房間模式**：可以為 `null`（創建新房間）或指定實例 ID（加入現有房間）
- `playerID`: 可選的玩家 ID（如果未提供，伺服器會生成）
- `deviceID`: 可選的設備 ID
- `metadata`: 可選的元資料字典

**向後兼容性：**

客戶端 SDK 支援自動解析 `landID` 格式：
- `"demo-game"` → `landType: "demo-game"`, `landInstanceId: null`（單房間模式）
- `"chess:room-123"` → `landType: "chess"`, `landInstanceId: "room-123"`（多房間模式）

### Join 回應（伺服器 → 客戶端）

伺服器回應加入請求，使用 `kind: "joinResponse"`（成功時）：

```json
{
  "kind": "joinResponse",
  "payload": {
    "joinResponse": {
    "requestID": "join-1234567890-abc",
    "success": true,
      "landType": "demo-game",
      "landInstanceId": null,
      "landID": "demo-game",
    "playerID": "player-123",
    "reason": null
    }
  }
}
```

失敗時，伺服器會發送 `kind: "error"` 訊息（統一錯誤格式）：

```json
{
  "kind": "error",
  "payload": {
    "error": {
    "code": "JOIN_DENIED",
    "message": "Room is full",
    "details": {
      "requestID": "join-1234567890-abc",
        "landType": "demo-game",
        "landInstanceId": "room-123"
      }
    }
  }
}
```

**欄位說明：**

- `requestID`: 對應的請求 ID
- `success`: 是否成功
- `landType`: 成功時返回加入的 Land 類型
- `landInstanceId`: 成功時返回加入的實例 ID（單房間模式通常為 `null`）
- `landID`: 成功時返回完整的 landID（格式：`landType:instanceId` 或 `landType`）
- `playerID`: 成功時返回玩家 ID
- `reason`: 失敗時返回原因字串

## State Update 訊息

狀態更新以獨立的 `StateUpdate` 格式發送，不包裝在 `TransportMessage` 中。

### 可選編碼（階段性優化）

為了降低高頻 diff 的封包大小，規劃一個 **opcode + JSON array** 的可選編碼，
保留 `playerID` 字串並維持 JSON 可讀性。此格式為 **階段一優化目標**，
目前不取代既有 `StateUpdate`，需配合能力協商或版本切換。

詳細說明請見：`Notes/protocol/STATE_UPDATE_OPCODE_JSON_ARRAY.md`

### StateUpdate 格式

```typescript
export interface StateUpdate {
  type: 'noChange' | 'firstSync' | 'diff'
  patches: StatePatch[]
}
```

**Swift 定義：**

```swift
public enum StateUpdate: Equatable, Sendable, Codable {
    case noChange
    case firstSync([StatePatch])
    case diff([StatePatch])
}
```

### 狀態更新類型

#### 1. noChange

表示沒有狀態變化：

```json
{
  "type": "noChange",
  "patches": []
}
```

**注意：** 客戶端通常會忽略 `noChange` 訊息以減少日誌噪音。

#### 2. firstSync

首次同步信號，表示同步引擎已啟動並將開始發送 diff 更新：

```json
{
  "type": "firstSync",
  "patches": [
    {
      "op": "replace",
      "path": "/players",
      "value": {
        "type": "object",
        "value": {
          "player-1": {
            "type": "object",
            "value": {
              "name": {
                "type": "string",
                "value": "Alice"
              },
              "hpCurrent": {
                "type": "int",
                "value": 100
              }
            }
          }
        }
      }
    }
  ]
}
```

**用途：**

- 標記同步引擎已為該玩家初始化
- 包含從 join 到首次 diff 生成之間的所有變化
- 確保不會遺漏任何狀態變化

#### 3. diff

增量更新，包含狀態變化：

```json
{
  "type": "diff",
  "patches": [
    {
      "op": "replace",
      "path": "/players/player-1/hpCurrent",
      "value": 80
    },
    {
      "op": "remove",
      "path": "/players/player-2"
    }
  ]
}
```

**注意：** `value` 欄位使用原生 JSON 格式（number, string, boolean, object, array, null），不再包裝 `type + value`。這簡化了消息大小並提高了可讀性。

### StatePatch 格式

```typescript
export interface StatePatch {
  path: string      // JSON Pointer 格式的路徑（例如 "/players/alice/hpCurrent"）
  op: 'replace' | 'remove' | 'add'  // JSON Patch 操作
  value?: any       // 新值（僅 replace 和 add 操作需要）
}
```

**Swift 定義：**

```swift
public struct StatePatch: Equatable, Sendable, Codable {
    public let path: String
    public let operation: PatchOperation
}

public enum PatchOperation: Equatable, Sendable, Codable {
    case set(SnapshotValue)    // 編碼為 "replace"
    case delete                // 編碼為 "remove"
    case add(SnapshotValue)    // 編碼為 "add"
}
```

**JSON Patch 格式（RFC 6902）：**

```json
{
  "op": "replace",
  "path": "/players/player-1/hpCurrent",
  "value": 80
}
```

或

```json
{
  "op": "remove",
  "path": "/players/player-2"
}
```

**編碼細節：**

`value` 欄位使用原生 JSON 格式（number, string, boolean, object, array, null），不再包裝 `type + value`。這簡化了消息大小並提高了可讀性。

**路徑格式：**

- 使用 JSON Pointer 格式（RFC 6901）
- 路徑以 `/` 開頭
- 例如：`/players/alice/hpCurrent`

## Snapshot 格式

初始狀態快照（用於 late join 場景）以獨立的格式發送，不包裝在 `TransportMessage` 或 `StateUpdate` 中。

### Snapshot 格式

```json
{
  "values": {
    "round": 1,
    "turn": "player-1",
    "players": {
      "player-1": {
        "name": "Alice",
        "hpCurrent": 100,
        "hpMax": 100
      }
    }
  }
}
```

**TypeScript 定義：**

```typescript
interface StateSnapshot {
  values: Record<string, any>
}
```

**Swift 定義：**

```swift
public struct StateSnapshot: Sendable {
    public var values: [String: SnapshotValue]
}
```

### SnapshotValue 編碼

`SnapshotValue` 直接使用原生 JSON 形狀進行編碼：

- `.null` → `null`
- `.bool` → `true` / `false`
- `.int` / `.double` → `number`
- `.string` → `string`
- `.array` → JSON 陣列（元素為 `SnapshotValue`）
- `.object` → JSON 物件（value 為 `SnapshotValue`）

**範例：**

```json
{
  "values": {
    "round": 1,
    "players": {
      "player-1": {
        "name": "Alice",
        "hpCurrent": 100
      }
    }
  }
}
```

**解碼邏輯：**

客戶端需要解碼 `SnapshotValue` 格式：

```typescript
function decodeSnapshotValue(value: any): any {
  if (value === null || value === undefined) return null
  if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') return value
  if (Array.isArray(value)) return value.map(item => decodeSnapshotValue(item))
  if (value && typeof value === 'object') {
    const result: Record<string, any> = {}
    for (const [key, v] of Object.entries(value)) {
      result[key] = decodeSnapshotValue(v)
    }
    return result
  }
  throw new Error(`Invalid SnapshotValue format: ${JSON.stringify(value)}`)
}
```

## 編碼細節

### Base64 編碼

Action payload 使用 Base64 編碼：

```typescript
// 編碼
const payloadJson = JSON.stringify(payload)
const payloadBase64 = btoa(unescape(encodeURIComponent(payloadJson)))

// 解碼
const payloadJson = decodeURIComponent(escape(atob(payloadBase64)))
const payload = JSON.parse(payloadJson)
```

### JSON Patch 操作

狀態更新使用 JSON Patch 格式（RFC 6902）：

- `replace`: 替換路徑上的值（如果路徑不存在則創建）
- `remove`: 刪除路徑上的值
- `add`: 添加值到路徑（主要用於陣列操作）

### Swift Enum 編碼

**TransportEvent 編碼：**

`TransportEvent` 使用 label `event`，編碼格式為：
- `TransportEvent.fromClient(event: AnyClientEvent)` → `{ "fromClient": { "event": AnyClientEvent } }`
- `TransportEvent.fromServer(event: AnyServerEvent)` → `{ "fromServer": { "event": AnyServerEvent } }`

這是因為 Swift Codable 會使用 associated value 的 label 作為 JSON key。

**SnapshotValue 編碼：**

`SnapshotValue` 直接對應 JSON 原生類型：
- `SnapshotValue.int(80)` → `80`
- `SnapshotValue.string("hello")` → `"hello"`
- `SnapshotValue.bool(true)` → `true`
- `SnapshotValue.null` → `null`

**StatePatch 的 value 欄位：**

`value` 欄位直接使用原生 JSON 格式，不再包裝 `type + value`：
- `PatchOperation.set(SnapshotValue.int(80))` → `{ "op": "replace", "path": "...", "value": 80 }`
- `PatchOperation.set(SnapshotValue.string("hello"))` → `{ "op": "replace", "path": "...", "value": "hello" }`
- `PatchOperation.set(SnapshotValue.object([...]))` → `{ "op": "replace", "path": "...", "value": {...} }`

### JSON Pointer 路徑

路徑使用 JSON Pointer 格式（RFC 6901）：

- 路徑以 `/` 開頭
- 路徑段之間用 `/` 分隔
- 例如：`/players/alice/hpCurrent`

### Swift Enum 編碼範例

以下是一個具體的編碼範例：

```swift
enum TransportEvent {
    case fromClient(event: AnyClientEvent)
    case fromServer(event: AnyServerEvent)
}
```

編碼為：

```json
{
  "fromClient": {
    "event": { ... }
  }
}
```

或

```json
{
  "fromServer": {
    "event": { ... }
  }
}
```

## 完整範例

### 1. 客戶端連接並加入

```json
// 1. WebSocket 連接建立

// 2. 客戶端發送 Join 請求
{
  "kind": "join",
  "payload": {
    "join": {
    "requestID": "join-1234567890-abc",
      "landType": "demo-game",
      "landInstanceId": null,
    "playerID": "player-123",
    "deviceID": "device-456",
    "metadata": {
      "platform": "iOS"
      }
    }
  }
}

// 3. 伺服器回應 Join
{
  "kind": "joinResponse",
  "payload": {
    "joinResponse": {
    "requestID": "join-1234567890-abc",
    "success": true,
      "landType": "demo-game",
      "landInstanceId": null,
      "landID": "demo-game",
    "playerID": "player-123"
    }
  }
}

// 4. 伺服器發送初始快照（late join）
{
  "values": {
    "players": {
      "player-1": {
        "name": "Alice",
        "hpCurrent": 100
      }
    }
  }
}
```

**注意：** Snapshot 格式已簡化，直接使用原生 JSON 格式，不再包裝 `type + value`。

// 5. 伺服器發送首次同步信號
{
  "type": "firstSync",
  "patches": []
}
```

### 2. 客戶端發送 Action

```json
// 客戶端發送
{
  "kind": "action",
  "payload": {
    "requestID": "req-1234567890-xyz",
    "typeIdentifier": "AddGold",
    "payload": "eyJhbW91bnQiOjEwMH0="
  }
}

// 伺服器回應
{
  "kind": "actionResponse",
  "payload": {
    "requestID": "req-1234567890-xyz",
    "response": {
      "success": true,
      "newBalance": 200
    }
  }
}

// 伺服器發送狀態更新
{
  "type": "diff",
  "patches": [
    {
      "op": "replace",
      "path": "/gold",
      "value": 200
    }
  ]
}
```

**注意：** `value` 欄位使用原生 JSON 格式，不再包裝 `type + value`。
```
```

### 3. 客戶端發送 Event

```json
// 客戶端發送
{
  "kind": "event",
  "payload": {
    "fromClient": {
      "type": "ChatEvent",
      "payload": {
        "message": "Hello, world!"
      }
    }
  }
}

// 伺服器可能發送狀態更新（如果 Event 修改了狀態）
{
  "type": "diff",
  "patches": [
    {
      "op": "replace",
      "path": "/lastMessage",
      "value": "Hello, world!"
    }
  ]
}
```

### 4. 伺服器發送 Event

```json
// 伺服器發送
{
  "kind": "event",
  "payload": {
    "fromServer": {
      "type": "MatchmakingEvent",
      "payload": {
        "matched": {
          "landID": {
            "rawValue": "battle-royale-123"
          }
        }
      }
    }
  }
}
```

**編碼說明：** `TransportEvent.fromServer(event: AnyServerEvent)` 直接編碼為 `{ "fromServer": AnyServerEvent }` 格式（已簡化）。

## 參考資料

- [JSON Patch (RFC 6902)](https://tools.ietf.org/html/rfc6902)
- [JSON Pointer (RFC 6901)](https://tools.ietf.org/html/rfc6901)
- [WebSocket Protocol (RFC 6455)](https://tools.ietf.org/html/rfc6455)
