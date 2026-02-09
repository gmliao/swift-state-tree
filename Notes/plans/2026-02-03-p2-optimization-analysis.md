.# P2 優化分析（compareSnapshotValues + SnapshotValue.make）

## 背景

P1 queue-based send 完成後，Profile 顯示 sync 路徑仍是主要 CPU 消耗：

| 函數 | P1 樣本數 | 說明 |
|------|-----------|------|
| SnapshotValue.make | 2,655 | 最高，型別轉換入口 |
| extractPerPlayerSnapshot | 2,085 | 每玩家快照擷取 |
| compareSnapshotValues | 1,651 | snapshot diff 計算 |
| computeBroadcastDiffFromSnapshot | 1,066 | broadcast diff |
| broadcastSnapshot | 911 | broadcast 快照建立 |
| compareSnapshots | 887 | 頂層快照比較 |

---

## P2.1 compareSnapshotValues / escapeJsonPointer

### 現況

```swift
// SyncEngine.swift:311-316
private func escapeJsonPointer(_ key: String) -> String {
    if !key.contains("~"), !key.contains("/") { return key }
    return key.replacingOccurrences(of: "~", with: "~0")
        .replacingOccurrences(of: "/", with: "~1")
}
```

- **Profile**：escapeJsonPointer 相關約 343 樣本（P0 時期）
- **呼叫頻率**：`compareSnapshotValues` 遞迴時，每個 object 的每個 key 都會呼叫一次
- **常見 key**：`x`, `y`, `position`, `rotation`, `players`, `monsters` 等，多數不含 `~` 或 `/`

### 瓶頸分析

1. **兩次 `contains`**：`key.contains("~")` 和 `key.contains("/")` 各掃描字串一次，共兩次遍歷
2. **`replacingOccurrences`**：若需 escape，會產生兩次新字串分配（先 ~ 再 /）
3. **遊戲 key 幾乎不需 escape**：Hero Defense 的 key 如 `x`, `y`, `degrees`, `position` 等皆無特殊字元

### 優化建議

| 方案 | 作法 | 預期效益 | 難度 |
|------|------|----------|------|
| **A. 單次掃描** | 用 `key.unicodeScalars.contains(where: { $0 == "~" || $0 == "/" })` 取代兩次 `contains` | 減少一次字串遍歷 | 低 |
| **B. 單次 replace** | 若需 escape，用單一迴圈建構結果，避免兩次 `replacingOccurrences` | 減少一次 allocation | 中 |
| **C. 常見 key 快取** | 對高頻 key（如 `x`, `y`, `position`）做靜態 cache 回傳 | 多數情況零成本 | 低（但需維護 key 列表） |

**建議**：先做 A，驗證後再考慮 B。C 需與 schema 耦合，效益不確定。

---

## P2.2 SnapshotValue.make

### 現況

```swift
// SnapshotValue.swift:167-351
static func make(from value: Any, for playerID: PlayerID? = nil) throws -> SnapshotValue
```

- **Profile**：2,655 樣本，sync 路徑最高
- **呼叫來源**：`state.snapshot()` 巨集產生的程式碼，每個 @Sync 欄位都會呼叫

### 呼叫鏈

```
extractBroadcastSnapshot / extractPerPlayerSnapshot
  → state.broadcastSnapshot() / state.snapshot(for:)
    → 巨集產生：for each @Sync field { SnapshotValue.make(from: value) }
      → 基本型別：Int, Bool, String 等直接回傳
      → SnapshotValueConvertible：Position2, Angle, IVec2 等呼叫 toSnapshotValue()
      → [PlayerID: PlayerState]：匹配 [PlayerID: any StateNodeProtocol]，每個呼叫 state.snapshot()
```

### 瓶頸分析

1. **`value as? SomeType` 鏈**：每個 cast 都是動態型別檢查，順序影響效能
   - 目前順序：SnapshotValue → StateSnapshot → StateNodeProtocol → SnapshotValueConvertible → 已知集合 → 基本型別 → Mirror
   - `StateNodeProtocol` 為 existential (`any`)，檢查成本高，但對 [PlayerID: PlayerState] 等結構必須先處理

2. **SnapshotValueConvertible 熱路徑**：Profile 顯示 `Position2.toSnapshotValue`、`IVec2.toSnapshotValue`、`Angle.toSnapshotValue` 大量出現
   - 這些型別已走最佳路徑，但 `value as? SnapshotValueConvertible` 的 protocol witness 查表仍有成本

3. **Mirror 後備**：若型別未匹配任何已知分支，會 fallback 到 `Mirror(reflecting: value)`，成本極高
   - Hero Defense 若所有型別都有 @SnapshotConvertible 或已知分支，應可避免

4. **遞迴 [String: Any]**：`value as? [String: Any]` 時，每個 value 遞迴呼叫 `make(from: val)`
   - 若 game state 有深層 [String: Any]，會放大成本

### 優化建議

| 方案 | 作法 | 預期效益 | 難度 |
|------|------|----------|------|
| **A. 型別檢查順序** | 依 Hero Defense 實際型別頻率重排：基本型別 (Int, Bool) 提前、StateNodeProtocol 維持在集合處理前 | 減少不必要的 cast 嘗試 | 低 |
| **B. 避免 Mirror** | 確保所有 game 型別都有 @SnapshotConvertible 或明確分支，必要時在 make 內 throw 而非用 Mirror | 避免最貴路徑 | 中（需 audit 型別） |
| **C. 特化 [PlayerID: StateNodeProtocol]** | 此分支已存在且優先，可考慮針對 [PlayerID: PlayerState] 等具體型別做特化，減少 existential 開銷 | 理論可行，實作複雜 | 高 |
| **D. 內聯 / @_transparent** | 對 make 的熱路徑（如 SnapshotValueConvertible 分支）加 @inline(__always) 等提示 | 編譯器優化 | 低，需實測 |

**建議**：先做 A 和 D，再 audit 是否有型別 fallback 到 Mirror（B）。

---

## P2.3 相關路徑：extractPerPlayerSnapshot、compareSnapshots

### extractPerPlayerSnapshot（2,085 樣本）

```swift
// SyncEngine.swift:118-140
let fullSnapshot = try state.snapshot(for: playerID, dirtyFields: mode.fields)
let perPlayerFieldNames = Set(...)
for (key, value) in fullSnapshot.values where perPlayerFieldNames.contains(key) {
    perPlayerValues[key] = value
}
```

- **成本**：先產生完整 snapshot，再過濾
- **優化**：若 `state.snapshot` 能支援「只擷取 per-player 欄位」的 mode，可避免產生 broadcast 欄位
- **難度**：需改 StateNodeProtocol / 巨集，較高

### compareSnapshots / anyPathMatches

```swift
// SyncEngine.swift:318-326
private func anyPathMatches(_ path: String, in onlyPaths: Set<String>) -> Bool {
    for allowedPath in onlyPaths {
        if path == allowedPath || path.hasPrefix(allowedPath + "/") {
            return true
        }
    }
    return false
}
```

- `allowedPath + "/"` 每次迴圈都分配新字串
- 若 `onlyPaths` 常為 nil 或空，此函數可能不常被呼叫
- **優化**：可預先建好 `allowedPath + "/"` 的 Set，避免重複分配

---

## 實作優先順序

| 優先級 | 項目 | 預期效益 | 風險 |
|--------|------|----------|------|
| 1 | escapeJsonPointer 單次掃描 (A) | 低～中 | 極低 |
| 2 | SnapshotValue.make 型別順序 + 內聯 (A, D) | 低～中 | 低 |
| 3 | escapeJsonPointer 單次 replace (B) | 低 | 低 |
| 4 | 避免 Mirror fallback (B) | 若有用到則高 | 中 |
| 5 | extractPerPlayerSnapshot 結構優化 | 中 | 高 |

---

## 驗證方式

1. **Benchmark**：在 SwiftStateTreeBenchmarks 加 compareSnapshotValues、SnapshotValue.make 的 micro-benchmark
2. **Profile 比對**：實作前後跑 `run-500-with-profile-recorder.sh`，比較 samples.perf 中相關函數樣本數
3. **E2E**：確保 `cd Tools/CLI && npm test` 與 500-room load test 通過

---

## P0/P1/P2 優化效益評估（2026-02-04）

### A/B 測試：P1 Queue-based vs sendBatch 路徑

| 配置 | 400 rooms | 500 rooms |
|------|-----------|-----------|
| **P0+P1 (queue)** | PASS, rtt 39–48 ms | FAIL, rtt 480–1777 ms |
| **P0 only (sendBatch)** | PASS, rtt 33–54 ms | 變異大：PASS 68 ms / FAIL 197 ms |

### 結論

1. **P0 (batch send)**：**保留**。`sendEncodedUpdatesBatch` 將多筆更新合併為單次 transport 呼叫，減少 actor 競爭，為核心優化。
2. **P1 (queue-based)**：**保留**。Profile 顯示 `_dispatch_sema4_timedwait` 降 45%。E2E 在 400 rooms 兩者相近；500 rooms 有變異，無法斷定 P1 明顯較差，且 Profile 證據支持保留。
3. **P2 (escapeJsonPointer / SnapshotValue.make)**：**可暫緩**。escapeJsonPointer 約 343 樣本（~1.5%），預期效益低～中；SnapshotValue.make 較高但實作成本高。建議先做 escapeJsonPointer 單次掃描 (A) 驗證，若 micro-benchmark 無明顯改善可跳過。

### 可移除項目

**無**。P0、P1 皆有實測或 Profile 支持；P2 未實作，無需移除。
