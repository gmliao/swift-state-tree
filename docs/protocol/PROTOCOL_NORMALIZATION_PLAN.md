# Protocol 正規化計劃

## 目標

統一協議格式，消除 `_0` 格式，使 JSON 更簡潔易讀，並保持類型安全。

## 當前問題

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

### 2. SnapshotValue 使用 `_0` 格式

**目前格式：**
```json
{
  "int": {
    "_0": 80
  }
}
```

**目標格式（選項 A - type + value）：**
```json
{
  "type": "int",
  "value": 80
}
```

**目標格式（選項 B - 直接值，但會失去類型區分）：**
```json
80
```

**目標格式（選項 C - 加上 label）：**
```json
{
  "int": {
    "value": 80
  }
}
```

## 改進方案

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

### 方案 2: SnapshotValue 自定義編碼（複雜）

**選項 A - type + value 格式（推薦）：**
```swift
public enum SnapshotValue: Equatable, Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    // ...
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .type)
        case .bool(let value):
            try container.encode("bool", forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode("int", forKey: .type)
            try container.encode(value, forKey: .value)
        // ...
        }
    }
}
```

**編碼結果：**
```json
{
  "type": "int",
  "value": 80
}
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
2. ⏳ 改進 TransportEvent：加上 label
3. ⏳ 改進 SnapshotValue：自定義編碼
4. ⏳ 更新 TypeScript 類型定義
5. ⏳ 更新 Playground 客戶端代碼
6. ⏳ 更新協議文檔
7. ⏳ 更新單元測試
8. ⏳ 驗證所有測試通過

## 向後兼容性

**注意：** 這些更改會破壞向後兼容性。需要：
- 更新版本號
- 在文檔中標註 breaking changes
- 確保客戶端和伺服器同步更新

## 測試計劃

1. 單元測試：確保所有 Codable 編碼/解碼測試通過
2. 整合測試：確保 Playground 能正確解析新格式
3. 文檔測試：確保所有範例都反映新格式

