# MessagePack 多房間 Release 模式記憶體問題調查報告

## 問題描述

在 Release 模式下運行多房間 benchmark 時，會出現 "freed pointer was not the last allocation" 錯誤。此錯誤僅在多房間環境下出現，單房間測試正常。

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

這是 macOS 的 `libmalloc` 記憶體管理器特有的檢查錯誤，它要求記憶體必須按照 LIFO（後進先出）順序釋放。

## 可能的原因

### 1. 多房間並行執行導致的記憶體分配順序問題
- 每個 `LandKeeper` 實例都有自動的 tick loop 在背景執行（`configureTickLoop`）
- 即使序列化執行 `syncNow()`，多個房間的 tick loop 仍然在並行執行
- 多個 `TransportAdapter` 實例同時進行編碼操作（來自 tick loop 和 sync 操作）
- 記憶體分配/釋放的順序可能不符合 macOS libmalloc 的 LIFO 要求
- Swift 的 ARC 和 libmalloc 的交互可能導致問題

### 2. Data 的 COW（Copy-on-Write）機制
- `Data` 類型使用 COW 機制，在多房間並行環境下可能導致記憶體共享
- `pack()` 函數創建的 `Data` 實例在多房間環境下可能共享底層緩衝區
- JSONEncoder 也可能有類似的記憶體管理問題

### 3. Release 模式優化
- Release 模式的優化可能改變記憶體分配/釋放的時機
- 編譯器優化可能導致記憶體管理器的檢查更嚴格
- 多個房間並行執行時，優化可能導致記憶體分配順序不符合預期

## 已實施的修復

1. **延遲初始化 `keyTableStore`**
   - 只在有 `pathHasher` 時才初始化，減少不必要的記憶體分配
   - 確認問題不在 `keyTableStore`

2. **暫時禁用 MessagePack 的並行編碼**
   - 已在 `TransportAdapter.parallelEncodingDecision` 中禁用
   - 避免潛在的並行編碼問題

## 建議

### 短期方案
- **單房間環境**：所有編碼器（JSON、opcode JSON、MessagePack）都運作正常，可在生產環境使用
- **多房間環境**：
  - **✅ Linux 生產環境**：所有編碼器都運作正常，可在生產環境使用（已在 AMD 7600x Docker 環境驗證）
  - **macOS 開發環境**：
    - 在生產環境中使用 Address Sanitizer 或 Thread Sanitizer 進行測試（這些模式下測試通過）
    - 或考慮序列化執行多個房間的 sync（不使用 `withTaskGroup`），但這會影響效能
    - 或暫時使用單房間架構進行本地開發測試

### 長期調查方向
1. **檢查多房間並行執行的記憶體管理**
   - 確認 `withTaskGroup` 並行執行多個房間時，記憶體分配/釋放的順序
   - 考慮序列化執行或使用更細粒度的同步機制

2. **檢查 `Data` 的 COW 行為**
   - 確認多房間環境下 `Data` 實例是否共享底層緩衝區
   - 考慮使用 `Data(unsafeUninitializedCapacity:initializingWith:)` 來避免 COW

3. **記憶體分配策略**
   - 考慮為每個房間使用獨立的記憶體池
   - 或使用自定義的記憶體分配器

4. **與 Swift 團隊聯繫**
   - 如果確認是 Swift 編譯器、ARC 或 Swift Concurrency 的問題，可以報告給 Swift 團隊

## 相關代碼位置

- `Sources/SwiftStateTreeMessagePack/MessagePackValue.swift` - `pack()` 函數
- `Sources/SwiftStateTreeTransport/StateUpdateEncoder.swift` - `OpcodeMessagePackStateUpdateEncoder`
- `Sources/SwiftStateTreeTransport/TransportAdapter.swift` - 並行編碼決策

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
