[English](payload.md) | [中文版](payload.zh-TW.md)

# @Payload 詳細說明

> `@Payload` macro 用於標記 Action、Event 和 Response payload，自動生成欄位 metadata 和 response type 資訊。

## 概述

`@Payload` macro 在編譯期執行以下操作：

1. **生成 field metadata**：產生 `getFieldMetadata()` 方法
2. **生成 response type**：Action payload 會額外產生 `getResponseType()` 方法
3. **Schema 生成支援**：提供 metadata 用於自動生成 JSON Schema

## 基本使用

### Action Payload

```swift
import SwiftStateTree

@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
    let deviceID: String?
}

@Payload
struct JoinResponse: ResponsePayload {
    let success: Bool
    let message: String
    let landID: String?
}
```

### Event Payload

```swift
@Payload
struct PlayerJoinedEvent: ServerEventPayload {
    let playerID: PlayerID
    let name: String
    let timestamp: Date
}

@Payload
struct ChatMessageEvent: ClientEventPayload {
    let playerID: PlayerID
    let message: String
    let timestamp: Date
}
```

## 生成的程式碼

### getFieldMetadata()

所有 `@Payload` 型別都會生成 `getFieldMetadata()` 方法：

```swift
// 自動生成（簡化版）
extension JoinAction {
    static func getFieldMetadata() -> [FieldMetadata] {
        return [
            FieldMetadata(
                name: "playerID",
                type: PlayerID.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "name",
                type: String.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: nil
            ),
            FieldMetadata(
                name: "deviceID",
                type: String?.self,
                policy: nil,
                nodeKind: .leaf,
                defaultValue: SnapshotValue.null
            )
        ]
    }
}
```

### getResponseType()

只有 `ActionPayload` 會生成 `getResponseType()` 方法：

```swift
// 自動生成（簡化版）
extension JoinAction {
    static func getResponseType() -> Any.Type {
        return JoinResponse.self
    }
}
```

## Payload 類型

### ActionPayload

Action payload 必須定義 `Response` typealias：

```swift
@Payload
struct PurchaseAction: ActionPayload {
    typealias Response = PurchaseResponse  // 必須定義
    let productID: String
    let quantity: Int
}

@Payload
struct PurchaseResponse: ResponsePayload {
    let success: Bool
    let totalCost: Double
}
```

**特點**：
- 必須定義 `typealias Response`
- 會生成 `getResponseType()` 方法
- 用於需要立即回饋的操作

### ResponsePayload

Response payload 不需要額外的 typealias：

```swift
@Payload
struct PurchaseResponse: ResponsePayload {
    let success: Bool
    let message: String
    let orderID: String?
}
```

**特點**：
- 不需要定義 typealias
- 只生成 `getFieldMetadata()` 方法
- 用於 Action 的回應

### ServerEventPayload

Server 發送給 Client 的事件：

```swift
@Payload
struct GameStartedEvent: ServerEventPayload {
    let gameID: String
    let startTime: Date
    let players: [PlayerID]
}
```

**特點**：
- 不需要 Response
- 只生成 `getFieldMetadata()` 方法
- 用於 Server → Client 的通知

### ClientEventPayload

Client 發送給 Server 的事件：

```swift
@Payload
struct HeartbeatEvent: ClientEventPayload {
    let timestamp: Date
    let clientVersion: String
}
```

**特點**：
- 不需要 Response
- 只生成 `getFieldMetadata()` 方法
- 用於 Client → Server 的通知

## 驗證規則

### 編譯期驗證

`@Payload` 在編譯期執行驗證：

#### ✅ 正確的使用

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse  // ✅ 正確
    let playerID: PlayerID
    let name: String
}
```

#### ❌ 錯誤的使用

```swift
// ❌ 錯誤 1：ActionPayload 未定義 Response
@Payload
struct JoinAction: ActionPayload {
    let playerID: PlayerID
    // 缺少 typealias Response
}

// ❌ 錯誤 2：在 class 上使用
@Payload  // 編譯錯誤：只支援 struct
class JoinAction: ActionPayload {
    // ...
}

// ❌ 錯誤 3：可選型別（目前不支援）
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID?
    // 編譯錯誤：可選型別不支援
}
```

### 限制

1. **只支援 struct**：不支援 class 或 enum
2. **不支援可選型別**：欄位不能是可選型別（`String?`）
3. **必須標記 @Payload**：未標記的 payload 在 runtime 會 trap

## 使用場景

### 場景 1：簡單的 Action

```swift
@Payload
struct GetPlayerInfoAction: ActionPayload {
    typealias Response = PlayerInfoResponse
    let playerID: PlayerID
}

@Payload
struct PlayerInfoResponse: ResponsePayload {
    let playerID: PlayerID
    let name: String
    let level: Int
}
```

### 場景 2：複雜的 Action

```swift
@Payload
struct PurchaseItemAction: ActionPayload {
    typealias Response = PurchaseItemResponse
    let playerID: PlayerID
    let itemID: String
    let quantity: Int
    let paymentMethod: String
}

@Payload
struct PurchaseItemResponse: ResponsePayload {
    let success: Bool
    let orderID: String
    let remainingBalance: Double
    let purchasedItems: [PurchasedItem]
}
```

### 場景 3：事件通知

```swift
@Payload
struct PlayerLevelUpEvent: ServerEventPayload {
    let playerID: PlayerID
    let oldLevel: Int
    let newLevel: Int
    let rewards: [Reward]
}
```

## 常見錯誤

### 錯誤 1：忘記標記 @Payload

```swift
// ❌ 錯誤：未標記 @Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
}

// 在 runtime 會 trap
let responseType = JoinAction.getResponseType()  // ❌ Runtime error
```

**解決方案**：

```swift
@Payload  // ✅ 正確
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
}
```

### 錯誤 2：Action 未定義 Response

```swift
@Payload
struct JoinAction: ActionPayload {
    // ❌ 錯誤：缺少 typealias Response
    let playerID: PlayerID
}
```

**解決方案**：

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse  // ✅ 正確
    let playerID: PlayerID
}
```

### 錯誤 3：使用可選型別

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID?
    // ❌ 編譯錯誤：可選型別不支援
}
```

**解決方案**：使用非可選型別，或使用預設值：

```swift
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let deviceID: String  // 使用非可選，在 handler 中處理空值
}
```

## 最佳實踐

### 1. 所有 Payload 都標記 @Payload

確保所有 Action、Event、Response 都標記 `@Payload`：

```swift
// ✅ 正確：所有 Payload 都標記
@Payload struct JoinAction: ActionPayload { ... }
@Payload struct JoinResponse: ResponsePayload { ... }
@Payload struct PlayerJoinedEvent: ServerEventPayload { ... }
```

### 2. 使用明確的型別

避免使用過於泛型的型別：

```swift
// ✅ 正確：明確的型別
@Payload
struct PurchaseAction: ActionPayload {
    typealias Response = PurchaseResponse
    let productID: String
    let quantity: Int
}

// ❌ 錯誤：過於泛型
@Payload
struct GenericAction: ActionPayload {
    typealias Response = GenericResponse
    let data: [String: Any]  // 太泛型
}
```

### 3. 保持 Payload 簡單

避免過於複雜的巢狀結構：

```swift
// ✅ 正確：簡單的結構
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
}

// ⚠️ 注意：複雜的巢狀結構可能需要額外處理
@Payload
struct ComplexAction: ActionPayload {
    typealias Response = ComplexResponse
    let nestedData: NestedStructure  // 確保 NestedStructure 也標記了 @Payload 或 @SnapshotConvertible
}
```

## 與 Schema 生成的關係

`@Payload` 生成的 metadata 用於自動生成 JSON Schema：

```swift
// Payload 定義
@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
}

// 自動生成的 Schema（簡化版）
{
  "defs": {
    "JoinAction": {
      "type": "object",
      "properties": {
        "playerID": { "type": "string" },
        "name": { "type": "string" }
      },
      "required": ["playerID", "name"]
    }
  }
}
```

## 相關文檔

- [Macros 總覽](README.zh-TW.md) - 了解所有 macro 的使用
- [Schema 生成](../schema/README.zh-TW.md) - 了解 Schema 生成機制
- [Land DSL](../core/land-dsl.zh-TW.md) - 了解如何在 Land DSL 中使用 Payload

