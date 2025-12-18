# Protocol 正規化計劃

## 目標

1. 統一協議格式，消除 `_0` 格式，使 JSON 更簡潔易讀
2. 加入統一的類型識別欄位（`kind` 或 `type`），提升可維護性
3. **建立統一的錯誤訊息格式，涵蓋所有錯誤場景**
4. 保持類型安全和向後兼容性（在可能的情況下）

## 當前問題

### 0. TransportMessage 缺少統一的類型識別欄位

**目前格式：**
```json
{
  "action": { ... }  // 或 "event", "join", "joinResponse", "actionResponse"
}
```

**問題：**
- 客戶端需要檢查多個可選欄位來判斷訊息類型
- 代碼冗長且容易出錯：`if (data.joinResponse)`, `if (data.event)`, `if (data.actionResponse)`
- 沒有統一的類型識別機制，不利於維護和擴展

**目標格式：**
```json
{
  "kind": "action",  // 或 "event", "join", "joinResponse", "actionResponse"
  "payload": { ... }
}
```

**優點：**
- 統一的類型識別，易於維護
- 客戶端只需檢查一個欄位：`if (data.kind === 'action')`
- 更容易擴展新的訊息類型
- 與 `StateUpdate` 的 `type` 欄位保持一致

### 1. TransportEvent 使用 `_0` 格式

**目前格式：**
```json
{
  "fromServer": {
    "_0": {
      "type": "MatchmakingEvent",
      "payload": {...}
    }
  }
}
```

**目標格式：**
```json
{
  "fromServer": {
    "event": {
      "type": "MatchmakingEvent",
      "payload": {...}
    }
  }
}
```

### 2. 缺少統一的錯誤訊息格式

**目前問題：**

1. **Join 錯誤**：使用 `joinResponse` 的 `reason` 欄位，格式不統一
   ```json
   {
     "joinResponse": {
       "success": false,
       "reason": "Session not connected"  // 只是字串，沒有錯誤代碼
     }
   }
   ```

2. **Action 錯誤**：使用 `actionResponse` 的 `response` 欄位，格式不統一
   ```json
   {
     "actionResponse": {
       "requestID": "req-123",
       "response": {
         "error": "actionNotRegistered"  // 只是字串，沒有錯誤代碼和詳細資訊
       }
     }
   }
   ```

3. **Event 錯誤**：目前沒有錯誤處理機制

4. **協議解析錯誤**：目前只是記錄到日誌，沒有發送錯誤訊息給客戶端

**目標格式：**
```json
{
  "kind": "error",
  "payload": {
    "code": "JOIN_FAILED",  // 或 "ACTION_NOT_REGISTERED", "INVALID_MESSAGE_FORMAT"
    "message": "Session not connected",
    "details": {  // 可選的詳細資訊
      "requestID": "req-123",
      "landID": "demo-game"
    }
  }
}
```

**優點：**
- 統一的錯誤格式，易於客戶端處理
- 錯誤代碼便於國際化和錯誤處理
- 詳細資訊有助於調試
- 可以擴展新的錯誤類型

### 3. SnapshotValue 使用原生 JSON 形狀

**目前格式（已採用）：**
```json
80
```

**說明：**
- `.null` → `null`
- `.bool` → `true` / `false`
- `.int` / `.double` → `number`
- `.string` → `string`
- `.array` → `[]`（元素為 SnapshotValue）
- `.object` → `{}`（value 為 SnapshotValue）

此格式移除 `type + value` 包裝，直接對應 JSON 原生類型，並在解碼時保留向後相容的 `type + value` 兼容處理。

## 改進方案

### 方案 0: TransportMessage 加入統一的 `kind` 欄位（優先）

**修改：**
```swift
// 目前：使用 enum，編碼為可選欄位
public enum TransportMessage: Codable, Sendable {
    case action(...)
    case event(...)
    // ...
}

// 改為：使用 struct + kind 欄位
public struct TransportMessage: Codable, Sendable {
    public let kind: MessageKind
    public let payload: MessagePayload
    
    public enum MessageKind: String, Codable {
        case action
        case actionResponse
        case event
        case join
        case joinResponse
    }
    
    public enum MessagePayload: Codable {
        case action(ActionPayload)
        case actionResponse(ActionResponsePayload)
        case event(EventPayload)
        case join(JoinPayload)
        case joinResponse(JoinResponsePayload)
    }
}
```

**或者保持 enum 但自定義編碼：**
```swift
public enum TransportMessage: Codable, Sendable {
    case action(...)
    case event(...)
    // ...
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let requestID, let landID, let action):
            try container.encode("action", forKey: .kind)
            try container.encode(ActionPayload(requestID: requestID, landID: landID, action: action), forKey: .payload)
        // ...
        }
    }
}
```

**編碼結果：**
```json
{
  "kind": "action",
  "payload": {
    "requestID": "req-123",
    "landID": "demo-game",
    "action": { ... }
  }
}
```

**影響範圍：**
- `Sources/SwiftStateTree/Sync/TransportMessage.swift`
- `Sources/SwiftStateTreeTransport/TransportAdapter.swift` (處理訊息的地方)
- `Examples/Playground/src/types/transport.ts`
- `Examples/Playground/src/composables/useWebSocket.ts`
- `docs/protocol/TRANSPORT_PROTOCOL.md`
- 所有相關單元測試

### 方案 1: TransportEvent 加上 label（簡單）

**修改：**
```swift
// 目前
public enum TransportEvent: Codable, Sendable {
    case fromClient(AnyClientEvent)
    case fromServer(AnyServerEvent)
}

// 改為
public enum TransportEvent: Codable, Sendable {
    case fromClient(event: AnyClientEvent)
    case fromServer(event: AnyServerEvent)
}
```

**影響範圍：**
- `Sources/SwiftStateTree/Sync/TransportMessage.swift`
- `Examples/Playground/src/types/transport.ts`
- `Examples/Playground/src/composables/useWebSocket.ts`
- `docs/protocol/TRANSPORT_PROTOCOL.md`
- 相關單元測試

### 方案 2: 建立統一的錯誤訊息格式（重要）

**新增錯誤訊息類型：**
```swift
public enum TransportError: Codable, Sendable {
    case joinFailed(code: String, message: String, details: [String: AnyCodable]?)
    case actionFailed(code: String, message: String, requestID: String, details: [String: AnyCodable]?)
    case invalidMessageFormat(code: String, message: String, details: [String: AnyCodable]?)
    case eventFailed(code: String, message: String, details: [String: AnyCodable]?)
}

public struct ErrorPayload: Codable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: AnyCodable]?
    
    public init(code: String, message: String, details: [String: AnyCodable]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}
```

**在 TransportMessage 中加入錯誤類型：**
```swift
public enum TransportMessage: Codable, Sendable {
    case action(...)
    case actionResponse(...)
    case event(...)
    case join(...)
    case joinResponse(...)
    case error(ErrorPayload)  // 新增
}
```

**錯誤代碼定義：**
```swift
public enum ErrorCode: String {
    // Join errors
    case joinSessionNotConnected = "JOIN_SESSION_NOT_CONNECTED"
    case joinAlreadyJoined = "JOIN_ALREADY_JOINED"
    case joinLandIDMismatch = "JOIN_LAND_ID_MISMATCH"
    case joinDenied = "JOIN_DENIED"
    case joinRoomFull = "JOIN_ROOM_FULL"
    
    // Action errors
    case actionNotRegistered = "ACTION_NOT_REGISTERED"
    case actionInvalidPayload = "ACTION_INVALID_PAYLOAD"
    case actionHandlerError = "ACTION_HANDLER_ERROR"
    
    // Message format errors
    case invalidMessageFormat = "INVALID_MESSAGE_FORMAT"
    case invalidJSON = "INVALID_JSON"
    case missingRequiredField = "MISSING_REQUIRED_FIELD"
    
    // Event errors
    case eventNotRegistered = "EVENT_NOT_REGISTERED"
    case eventInvalidPayload = "EVENT_INVALID_PAYLOAD"
}
```

**影響範圍：**
- `Sources/SwiftStateTree/Sync/TransportMessage.swift`
- `Sources/SwiftStateTreeTransport/TransportAdapter.swift` (所有錯誤處理)
- `Examples/Playground/src/types/transport.ts`
- `Examples/Playground/src/composables/useWebSocket.ts`
- `docs/protocol/TRANSPORT_PROTOCOL.md`
- 所有相關單元測試

### 方案 3: SnapshotValue 原生編碼（已採用）

**實作重點：**
- 直接使用 JSON 原生類型表示 SnapshotValue（`null/bool/number/string/array/object`）。
- 編碼不包裝 `type + value`；解碼時仍支援舊版 `type + value` 以保持相容。

**範例：**
```json
80
```

**影響範圍：**
- `Sources/SwiftStateTree/Sync/SnapshotValue.swift`
- `Sources/SwiftStateTree/Sync/StatePatch.swift` (value 欄位)
- `Examples/HummingbirdDemo/schema.json` (default 值)
- `Examples/Playground/src/composables/useWebSocket.ts` (decodeSnapshotValue)
- `docs/protocol/TRANSPORT_PROTOCOL.md`
- `docs/protocol/SCHEMA_DEFINITION.md`
- 所有相關單元測試

## 實施步驟

1. ✅ 建立 feature branch
2. ⏳ **優先：改進 TransportMessage：加入統一的 `kind` 欄位**
3. ⏳ **優先：建立統一的錯誤訊息格式**
4. ⏳ 改進 TransportEvent：加上 label
5. ⏳ 改進 SnapshotValue：自定義編碼
6. ⏳ 更新 TypeScript 類型定義
7. ⏳ 更新 Playground 客戶端代碼
8. ⏳ 更新協議文檔
9. ⏳ 更新單元測試
10. ⏳ 驗證所有測試通過

## 設計決策

### 為什麼選擇 `kind` 而不是 `type`？

- `type` 已經被 `StateUpdate` 使用，避免混淆
- `kind` 更通用，表示「種類」或「類型」
- 與其他協議（如 GraphQL 的 `__typename`）保持一致

### 為什麼不保持 enum 的默認編碼？

- enum 的默認編碼會產生可選欄位結構，不利於類型識別
- 自定義編碼可以統一格式，加入 `kind` 欄位
- 更容易擴展和維護

## 向後兼容性

**注意：** 這些更改會破壞向後兼容性。需要：
- 更新版本號
- 在文檔中標註 breaking changes
- 確保客戶端和伺服器同步更新

## 測試計劃

1. 單元測試：確保所有 Codable 編碼/解碼測試通過
2. 整合測試：確保 Playground 能正確解析新格式
3. 文檔測試：確保所有範例都反映新格式
