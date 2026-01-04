[English](snapshot-convertible.md) | [中文版](snapshot-convertible.zh-TW.md)

# @SnapshotConvertible 效能優化指南

> `@SnapshotConvertible` macro 自動生成 `SnapshotValueConvertible` 實作，避免使用 runtime reflection（Mirror），大幅提升轉換效能。

## 概述

`@SnapshotConvertible` 是 SwiftStateTree 的效能優化 macro，用於標記需要高效能轉換的型別。它會自動生成 `SnapshotValueConvertible` protocol 實作，完全避免使用 runtime reflection。

### 核心優勢

- **避免 Mirror**：不使用 runtime reflection，大幅提升效能
- **編譯期生成**：型別安全，減少執行時錯誤
- **自動生成**：只需標記，無需手寫程式碼
- **遞迴優化**：巢狀結構會優先檢查 protocol，完全避免 Mirror

## 基本使用

### 標記型別

```swift
import SwiftStateTree

@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
    var position: Position
}

@SnapshotConvertible
struct Position: Codable, Sendable {
    var x: Double
    var y: Double
}
```

### 生成的程式碼

Macro 會自動生成以下 extension：

```swift
// 自動生成（簡化版）
extension PlayerState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "name": .string(name),
            "hpCurrent": .int(hpCurrent),
            "hpMax": .int(hpMax),
            "position": try position.toSnapshotValue()  // 遞迴處理巢狀結構
        ])
    }
}

extension Position: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "x": .double(x),
            "y": .double(y)
        ])
    }
}
```

## 效能優勢

### 與 Mirror 的對比

使用 `@SnapshotConvertible` 可以大幅提升轉換效能：

| 方法 | 轉換時間 | 說明 |
|------|---------|------|
| **@SnapshotConvertible** | ~0.15ms | 編譯期生成，直接轉換 |
| **Mirror (runtime reflection)** | ~0.38ms | 使用 runtime reflection，較慢 |

**效能提升**：約 **2.5x** 的效能提升（根據實際測試）

### 轉換優先順序

`SnapshotValue.make(from:)` 會按以下優先順序處理：

1. **Priority 1: SnapshotValueConvertible**（最佳效能）
   - 檢查是否實作 `SnapshotValueConvertible`
   - 直接呼叫 `toSnapshotValue()`，完全避免 Mirror

2. **Priority 2: 基本型別**（良好效能）
   - String、Int、Bool 等基本型別直接轉換

3. **Priority 3: Mirror fallback**（確保功能完整）
   - 其他型別使用 Mirror 作為後備方案

```swift
// 內部實作（簡化版）
public extension SnapshotValue {
    static func make(from value: Any) throws -> SnapshotValue {
        // Priority 1: 檢查 protocol（最佳效能）
        if let convertible = value as? SnapshotValueConvertible {
            return try convertible.toSnapshotValue()  // 完全避免 Mirror
        }
        
        // Priority 2: 處理基本型別
        if let string = value as? String {
            return .string(string)
        }
        // ...
        
        // Priority 3: Fallback to Mirror
        // ...
    }
}
```

## 適用場景

### ✅ 建議使用

1. **頻繁轉換的型別**：在 StateTree 中頻繁使用的巢狀結構
2. **複雜的巢狀結構**：多層級的巢狀結構
3. **效能關鍵路徑**：需要高效能轉換的型別

### ❌ 不需要使用

1. **基本型別**：String、Int、Bool 等已經優化
2. **簡單的型別**：只有一兩個欄位的簡單結構可能不需要
3. **不常轉換的型別**：很少被轉換的型別

## 使用範例

### 範例 1：基本使用

```swift
@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

// 在 StateNode 中使用
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // PlayerState 使用 @SnapshotConvertible
}
```

### 範例 2：巢狀結構

```swift
@SnapshotConvertible
struct Position: Codable, Sendable {
    var x: Double
    var y: Double
}

@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var position: Position  // 巢狀結構
    var inventory: [Item]   // 陣列
}

@SnapshotConvertible
struct Item: Codable, Sendable {
    var id: String
    var name: String
    var count: Int
}
```

### 範例 3：複雜結構

```swift
@SnapshotConvertible
struct Card: Codable, Sendable {
    var id: String
    var name: String
    var cost: Int
    var effects: [Effect]
}

@SnapshotConvertible
struct Effect: Codable, Sendable {
    var type: String
    var value: Int
}

@SnapshotConvertible
struct HandState: Codable, Sendable {
    var cards: [Card]  // 巢狀陣列
    var ownerID: PlayerID
}
```

## 生成的轉換邏輯

### 基本型別

對於基本型別，macro 會生成直接轉換：

```swift
@SnapshotConvertible
struct SimpleState: Codable {
    var name: String
    var count: Int
    var isActive: Bool
}

// 生成（簡化版）
extension SimpleState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "name": .string(name),        // 直接轉換
            "count": .int(count),         // 直接轉換
            "isActive": .bool(isActive)   // 直接轉換
        ])
    }
}
```

### 可選型別

對於可選型別，使用 `SnapshotValue.make(from:)` 處理：

```swift
@SnapshotConvertible
struct OptionalState: Codable {
    var name: String?
    var count: Int?
}

// 生成（簡化版）
extension OptionalState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "name": try SnapshotValue.make(from: name),   // 處理 nil
            "count": try SnapshotValue.make(from: count)  // 處理 nil
        ])
    }
}
```

### 巢狀結構

對於巢狀結構，會遞迴呼叫 `toSnapshotValue()`：

```swift
@SnapshotConvertible
struct NestedState: Codable {
    var position: Position
    var items: [Item]
}

// 生成（簡化版）
extension NestedState: SnapshotValueConvertible {
    func toSnapshotValue() throws -> SnapshotValue {
        return .object([
            "position": try position.toSnapshotValue(),  // 遞迴處理
            "items": try SnapshotValue.make(from: items) // 陣列處理
        ])
    }
}
```

## 效能測試結果

根據實際測試（單核心、100 iterations）：

| 場景 | 使用 Mirror | 使用 @SnapshotConvertible | 效能提升 |
|------|------------|---------------------------|---------|
| Tiny (5 players, 3 cards) | 0.378ms | 0.154ms | **2.45x** |
| Small (10 players, 5 cards) | 0.306ms | 0.167ms | **1.83x** |
| Medium (100 players, 10 cards) | 1.768ms | 0.935ms | **1.89x** |

**結論**：使用 `@SnapshotConvertible` 可以獲得約 **2x** 的效能提升。

## 最佳實踐

### 1. 標記所有巢狀結構

確保整個轉換路徑都使用 macro：

```swift
// ✅ 正確：所有巢狀結構都標記
@SnapshotConvertible
struct PlayerState: Codable {
    var position: Position  // Position 也標記了 @SnapshotConvertible
}

@SnapshotConvertible
struct Position: Codable {
    var x: Double
    var y: Double
}
```

### 2. 優先使用基本型別

基本型別已經優化，不需要額外標記：

```swift
@SnapshotConvertible
struct SimpleState: Codable {
    var name: String      // ✅ 基本型別，已經優化
    var count: Int        // ✅ 基本型別，已經優化
    var isActive: Bool    // ✅ 基本型別，已經優化
}
```

### 3. 避免過度使用

簡單的型別可能不需要此 macro：

```swift
// ⚠️ 考慮：只有一個欄位的簡單結構
@SnapshotConvertible  // 可能不需要
struct SimpleWrapper: Codable {
    var value: String
}
```

### 4. 在 StateTree 中頻繁使用的型別

優先標記在 StateTree 中頻繁使用的型別：

```swift
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]  // PlayerState 應該標記 @SnapshotConvertible
    
    @Sync(.broadcast)
    var items: [ItemID: Item] = [:]  // Item 應該標記 @SnapshotConvertible
}
```

## 常見問題

### Q: 什麼時候應該使用 @SnapshotConvertible？

A: 當型別滿足以下條件時建議使用：
- 在 StateTree 中頻繁使用
- 包含多個欄位或巢狀結構
- 需要高效能轉換

### Q: 不標記會怎樣？

A: 不標記的型別會使用 Mirror 作為 fallback，效能較差但功能完整。

### Q: 可以手動實作 SnapshotValueConvertible 嗎？

A: 可以，但建議使用 macro 自動生成，避免手寫錯誤。

### Q: 巢狀結構需要都標記嗎？

A: 建議標記所有巢狀結構，確保整個轉換路徑都使用 macro。

## 相關文檔

- [Macros 總覽](README.zh-TW.md) - 了解所有 macro 的使用
- [StateNode 定義](../core/README.zh-TW.md) - 了解 StateNode 的使用
- [同步規則](../core/sync.zh-TW.md) - 了解狀態同步機制

