# 🔍 1000 Rooms 測試問題診斷指南

## 問題總結

**現象**: 1000 rooms 測試運行超過 4 小時，CPU 使用率 1050%（12核心全滿），最終被強制終止。

**成功測試**:
- ✅ 100 rooms: 5.9% CPU
- ✅ 500 rooms: 35.5% CPU

---

## 🔎 根本原因分析

### 代碼瓶頸（main.swift:498-503）

```swift
// 問題代碼：串行處理所有 sessions
for _ in 0..<config.actionsPerPlayerPerSecond {
    for sessionID in connectedSessions {
        await traffic.recordReceived(bytes: payloadData.count)
        await transport.handleIncomingMessage(sessionID: sessionID, data: payloadData)
        actionsSent += 1
    }
}
```

**問題**:
- 1000 rooms × 5 players = **5,000 sessions**
- 每秒要執行 **5,000 次 `await handleIncomingMessage`**
- 每個 `await` 都要等待 actor 處理完成
- **串行化處理**導致嚴重阻塞

### 計算量分析

| 房間數 | Sessions | Actions/秒 | 問題嚴重度 |
|--------|----------|------------|------------|
| 100    | 500      | 500        | ✅ 正常    |
| 500    | 2,500    | 2,500      | ⚠️  開始變慢 |
| 1000   | 5,000    | 5,000      | 🔴 嚴重阻塞 |

---

## 🛠️ 診斷工具

### 1. 增量測試（推薦）

**用途**: 找到實際上限，避免直接測試 1000 rooms

```bash
cd Examples/GameDemo
bash scripts/server-loadtest/run-incremental-test.sh \
  --start-rooms 600 \
  --max-rooms 900 \
  --increment 100 \
  --duration-seconds 20 \
  --timeout-seconds 120
```

**優點**:
- ✅ 自動超時保護（不會卡住）
- ✅ 逐步找到實際上限
- ✅ 記錄每個測試的 CPU 使用率

### 2. 效能分析（perf）

**用途**: 找出 CPU 熱點和瓶頸函數

```bash
cd Examples/GameDemo
bash scripts/server-loadtest/run-profiling-test.sh \
  --rooms 800 \
  --duration-seconds 20 \
  --profile-tool perf
```

**輸出**:
- `perf.data`: 原始性能數據
- `perf.report.txt`: 函數 CPU 使用率報告
- 可以查看哪些函數消耗最多 CPU

### 3. 時間分析

**用途**: 查看系統調用和資源使用

```bash
bash scripts/server-loadtest/run-profiling-test.sh \
  --rooms 800 \
  --profile-tool time
```

**輸出**: 記憶體、系統調用、上下文切換等統計

---

## 💡 解決方案

### 短期：找到實際上限

```bash
# 測試 600-900 rooms，找出實際上限
bash scripts/server-loadtest/run-incremental-test.sh \
  --start-rooms 600 \
  --max-rooms 900 \
  --increment 50 \
  --duration-seconds 30 \
  --timeout-seconds 180
```

### 中期：優化代碼

**問題**: 串行處理導致阻塞

**解決方案 1: 並行化處理**

```swift
// 改為並行處理
await withTaskGroup(of: Void.self) { group in
    for sessionID in connectedSessions {
        group.addTask {
            await traffic.recordReceived(bytes: payloadData.count)
            await transport.handleIncomingMessage(sessionID: sessionID, data: payloadData)
        }
    }
}
```

**解決方案 2: 批量處理**

```swift
// 分批處理，避免一次性處理太多
let batchSize = 100
for batch in connectedSessions.chunked(into: batchSize) {
    await withTaskGroup(of: Void.self) { group in
        for sessionID in batch {
            group.addTask {
                await transport.handleIncomingMessage(sessionID: sessionID, data: payloadData)
            }
        }
    }
}
```

**解決方案 3: 使用 Worker Pool**

- 之前討論過的 Worker Pool 方案
- 限制並發數量，避免過度競爭

---

## 📊 診斷步驟

### Step 1: 確認實際上限

```bash
# 用增量測試找到實際上限
bash scripts/server-loadtest/run-incremental-test.sh \
  --start-rooms 600 \
  --max-rooms 850 \
  --increment 50
```

### Step 2: 分析瓶頸

```bash
# 用 perf 分析 700 rooms（接近上限但能完成）
bash scripts/server-loadtest/run-profiling-test.sh \
  --rooms 700 \
  --duration-seconds 20 \
  --profile-tool perf
```

### Step 3: 查看報告

```bash
# 查看 perf 報告
cat results/server-loadtest/profiling/profile-rooms700-*.perf.report.txt | head -n 50
```

---

## 🎯 預期結果

基於線性模型預測：
- 600 rooms: ~44% CPU
- 700 rooms: ~52% CPU  
- 800 rooms: ~59% CPU
- 900 rooms: ~67% CPU
- 1000 rooms: ~73% CPU（但可能因串行化問題導致實際更高）

**實際上限可能在 700-800 rooms 之間**

---

## 📝 建議

1. **立即行動**: 使用增量測試找到實際上限
2. **短期優化**: 如果上限 < 800 rooms，考慮優化代碼（並行化）
3. **長期規劃**: 
   - 如果生產需要 > 800 rooms，考慮水平擴展
   - 或實現 Worker Pool 方案

---

**診斷工具位置**:
- `scripts/server-loadtest/run-incremental-test.sh` - 增量測試
- `scripts/server-loadtest/run-profiling-test.sh` - 效能分析
