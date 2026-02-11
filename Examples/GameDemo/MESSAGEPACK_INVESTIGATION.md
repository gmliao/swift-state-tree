# MessagePack 多房間 Release 模式記憶體問題調查報告

## 問題描述

在 Release 模式下運行多房間 benchmark 時，會出現 "freed pointer was not the last allocation" 錯誤。此錯誤僅在多房間環境下出現，單房間測試正常。

**✅ 已解決：** 問題的根本原因是 `String(format:)` 使用不當，將 Swift `String` 傳遞給 C `printf`-style 的 `%s` 格式說明符，導致 ABI 不匹配和記憶體錯誤。

## 測試結果

### ✅ 通過的測試
1. **Thread Sanitizer** (`-sanitize=thread`) - 無數據競爭
2. **Address Sanitizer** (`-sanitize=address`) - 無記憶體錯誤
3. **單房間測試** - 所有格式都正常（JSON、opcode JSON、MessagePack）
4. **Linux Docker (AMD 7600x)** - 多房間測試正常（所有編碼器：JSON、opcode JSON、MessagePack）✅

### ❌ 失敗的測試（僅 macOS）
1. **純 Release 模式** - 多房間測試失敗（所有編碼器：JSON、opcode JSON、MessagePack）
2. **MallocStackLogging** - 同樣的錯誤
3. **-O 優化** - 同樣的錯誤
4. **-Ounchecked 優化** - 同樣的錯誤

### 重要發現
- **問題與編碼器類型無關**：所有編碼器（JSON、opcode JSON、MessagePack）在多房間環境下都有同樣的問題
- **問題與並行編碼無關**：即使禁用並行編碼（`--parallel false`），問題仍然存在
- **問題與 `withTaskGroup` 無關**：即使改為序列化執行（不使用 `withTaskGroup`），問題仍然存在
- **問題與多房間實例同時存在有關**：多個 `LandKeeper` 實例都有自動的 tick loop 在背景執行，即使序列化執行 `syncNow()`，多個房間的 tick loop 仍然在並行執行，可能導致記憶體分配順序問題
- **✅ 問題是平台特定的**：在 Linux Docker (AMD 7600x) 環境下，多房間測試正常通過，確認問題是 macOS 的 libmalloc 記憶體管理器特有的嚴格檢查，而非代碼問題

## 錯誤訊息

```
freed pointer was not the last allocation
```

**實際根因：** 這是 `String(format:)` 使用不當導致的 ABI 不匹配問題，而非 libmalloc 的 LIFO 限制。

## 根本原因

### ✅ 已確認：`String(format:)` 的 ABI 不匹配問題

在 Release 模式下，當使用 `String(format: "%s", swiftString)` 時：
- `%s` 是 C `printf`-style 格式說明符，期望 `char*` (C 字符串)
- Swift `String` 在 Release 模式下的記憶體佈局與 C 字符串不同
- 這導致 ABI 不匹配，進而觸發記憶體錯誤（表現為 "freed pointer was not the last allocation"）

**問題代碼示例：**
```swift
// ❌ 錯誤：將 Swift String 傳遞給 %s
print(String(format: "Best: %s saves %.1f%% vs JSON Object",
             best.format.displayName, savings))

// ✅ 正確：使用 %@ (Objective-C 對象) 或字符串插值
print(String(format: "Best: %@ saves %.1f%% vs JSON Object",
             best.format.displayName, savings))
// 或
print("Best: \(best.format.displayName) saves \(String(format: "%.1f", savings))% vs JSON Object")
```

### 為什麼只在 Release 模式出現？

- Debug 模式下，Swift 編譯器可能使用不同的記憶體佈局或額外的檢查
- Release 模式的優化導致 ABI 不匹配問題更容易暴露
- 多房間環境下，並行執行增加了觸發問題的機率

## 已實施的修復

### ✅ 主要修復：修正 `String(format:)` 使用

1. **`EncodingBenchmark/main.swift`**
   - 將所有 `String(format: "%s", swiftString)` 改為 `String(format: "%@", swiftString)`
   - 或使用字符串插值替代 `String(format:)`
   - 修復位置：
     - 第 114 行：`"Best: %s saves..."` → `"Best: %@ saves..."`
     - 第 217 行：`"Best: %s saves..."` → `"Best: %@ saves..."`
     - 其他表格輸出中的 `%s` 格式說明符

2. **`DeterministicHash.swift`**
   - 移除 `String(format: "%016llx", ...)` 和 `String(format: "%08x", ...)`
   - 改用純 Swift 實現的 `paddedLowerHex` 輔助函數

3. **`TransportAdapter.swift`**
   - 移除 `String(format: "%02x", ...)` 用於 hex 預覽
   - 改用自定義的 `HexEncoding.lowercaseHexString` 輔助函數

### 其他修復

1. **延遲初始化 `keyTableStore`**
   - 只在有 `pathHasher` 時才初始化，減少不必要的記憶體分配
   - 確認問題不在 `keyTableStore`

2. **狀態更新編碼**
   - 狀態更新以串行方式編碼（per-player parallel encoding 已移除）

## 解決方案

### ✅ 已解決

修復所有不安全的 `String(format:)` 使用後，Release 模式下的 crash 問題已解決。

### 最佳實踐

1. **避免使用 `%s` 格式化 Swift `String`**
   - 使用 `%@` (Objective-C 對象格式) 替代 `%s`
   - 或使用字符串插值 `"\(variable)"` 替代 `String(format:)`

2. **數字格式化是安全的**
   - `String(format: "%.1f", doubleValue)` 是安全的
   - `String(format: "%d", intValue)` 是安全的

3. **Hex 格式化**
   - 避免使用 `String(format: "%x", ...)` 或 `String(format: "%02x", ...)`
   - 使用純 Swift 實現的 hex 轉換函數

### 相關文檔

- `AGENTS.md` 中的 "Safe String Formatting" 章節提供了詳細的指導原則
- `Examples/GameDemo/Sources/EncodingBenchmark/results/README.md` 包含 Release 模式穩定性說明

## 相關代碼位置

### 已修復的文件
- `Examples/GameDemo/Sources/EncodingBenchmark/main.swift` - 修正 `String(format: "%s", ...)` 為 `%@`
- `Sources/SwiftStateTree/Core/DeterministicHash.swift` - 移除 `String(format:)`，改用純 Swift hex 轉換
- `Sources/SwiftStateTreeTransport/TransportAdapter.swift` - 移除 `String(format: "%02x", ...)`，改用自定義 hex 函數

### 其他相關文件
- `Sources/SwiftStateTreeMessagePack/MessagePackValue.swift` - `pack()` 函數
- `Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift` - `OpcodeMessagePackStateUpdateEncoder`
- `AGENTS.md` - Safe String Formatting 章節

## 測試命令

### macOS 測試
```bash
# Thread Sanitizer（通過）
swift run -c release -Xswiftc -sanitize=thread EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format messagepack --parallel false

# Address Sanitizer（通過）
swift run -c release -Xswiftc -sanitize=address EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format messagepack --parallel false

# Release 模式（失敗 - 所有編碼器，僅 macOS）
swift run -c release EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format messagepack --parallel false
swift run -c release EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format opcode-json --parallel false
swift run -c release EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format json-object --parallel false

# 單房間測試（通過 - 所有編碼器）
swift run -c release EncodingBenchmark --game-type card-game --rooms 1 --players-per-room 20 --iterations 100 --format messagepack --parallel false
swift run -c release EncodingBenchmark --game-type card-game --rooms 1 --players-per-room 20 --iterations 100 --format opcode-json-pathhash --parallel false
swift run -c release EncodingBenchmark --game-type card-game --rooms 1 --players-per-room 20 --iterations 100 --format json-object --parallel false
```

### Linux Docker 測試（AMD 7600x）
```bash
# 多房間測試（通過 - 所有編碼器）✅
swift run -c release EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format messagepack --parallel false
swift run -c release EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format opcode-json --parallel false
swift run -c release EncodingBenchmark --game-type card-game --rooms 2 --players-per-room 5 --iterations 10 --format json-object --parallel false
```
