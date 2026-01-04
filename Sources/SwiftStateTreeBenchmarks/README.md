# SwiftStateTree Benchmarks

獨立可執行檔，用於測試不同狀態大小的 snapshot 生成效能。

## 程式碼結構

Benchmark 程式碼已模組化，方便擴展新的測試：

### 核心檔案
- **BenchmarkData.swift**: 測試數據結構和生成邏輯
- **BenchmarkConfig.swift**: 配置、結果定義和預設配置
- **BenchmarkUtilities.swift**: 共用工具函數（時間測量、大小估算）
- **BenchmarkRunner.swift**: Benchmark runner protocol 定義

### Runner 實作
- **SingleThreadedRunner.swift**: 單執行緒執行策略（測試 snapshot 生成基礎性能）
- **DiffBenchmarkRunner.swift**: Standard vs Optimized Diff 比較
- **MirrorVsMacroComparisonRunner.swift**: Mirror vs Macro 效能比較
- **TransportAdapterSyncBenchmarkRunner.swift**: TransportAdapter 完整 sync 流程性能測試
- **TransportAdapterParallelEncodingTuningBenchmarkRunner.swift**: TransportAdapter 平行編碼並行度調校測試（比較不同 maxConcurrency）
- **TransportAdapterMultiRoomParallelEncodingBenchmarkRunner.swift**: TransportAdapter 多房間平行編碼測試（固定每房間人數、掃描房間數與並行度）

### 組織檔案
- **BenchmarkSuite.swift**: Benchmark suite 執行邏輯
- **BenchmarkSuiteConfig.swift**: 所有 benchmark suite 配置
- **BenchmarkSummary.swift**: 摘要報告生成
- **CommandLineParser.swift**: 命令行參數解析
- **main.swift**: 主入口，組織和運行不同的 benchmark suite

## 執行模式

Benchmark 支援多種執行模式：

1. **單執行緒執行**：順序執行，測試 snapshot 生成的基礎性能（注意：這不是完整的 sync 流程）
2. **Standard vs Optimized Diff 比較**：比較標準 diff（無 dirty tracking）與優化 diff（有 dirty tracking）的效能差異
3. **Mirror vs Macro 比較**：比較 runtime reflection 與 compile-time macro 的效能差異
4. **TransportAdapter Sync**：測試完整的 TransportAdapter.syncNow() 流程，最接近實際使用場景

## 執行方式

### 基本使用

```bash
# 執行所有 benchmark（預設）
swift run SwiftStateTreeBenchmarks

# 使用 release 模式執行（更準確的效能測試）
swift run -c release SwiftStateTreeBenchmarks
```

### 選擇特定 Benchmark Suite

```bash
# 執行單執行緒 benchmark
swift run SwiftStateTreeBenchmarks single

# 執行 Standard vs Optimized Diff 比較
swift run SwiftStateTreeBenchmarks diff

# 執行 Mirror vs Macro 比較
swift run SwiftStateTreeBenchmarks mirror

# 執行 TransportAdapter Sync 性能測試
swift run SwiftStateTreeBenchmarks transport-sync

# 執行 TransportAdapter 平行編碼調校測試
swift run SwiftStateTreeBenchmarks transport-parallel-tuning

# 執行 TransportAdapter 多房間平行編碼測試
swift run SwiftStateTreeBenchmarks transport-multiroom-parallel-tuning

# 執行多個 suite
swift run SwiftStateTreeBenchmarks single diff mirror

# 執行比較類的 benchmark
swift run SwiftStateTreeBenchmarks diff mirror
```

### Diff Benchmark 環境變數控制

`DiffBenchmarkRunner` 支援透過環境變數 `DIFF_BENCHMARK_MODE` 來選擇要執行的測試模式：

```bash
# 只測試標準 diff (useDirtyTracking = false)
DIFF_BENCHMARK_MODE=standard swift run SwiftStateTreeBenchmarks diff

# 只測試優化 diff (useDirtyTracking = true) - 適合 Instruments 測試
DIFF_BENCHMARK_MODE=optimized swift run SwiftStateTreeBenchmarks diff

# 測試兩者並比較（預設）
DIFF_BENCHMARK_MODE=both swift run SwiftStateTreeBenchmarks diff
# 或直接
swift run SwiftStateTreeBenchmarks diff
```

**使用場景**：
- `standard`：只測試標準 diff 效能，適合單獨分析標準實作
- `optimized`：只測試優化 diff 效能，適合在 Instruments 中進行效能分析
- `both`：同時測試兩者並比較，適合驗證優化效果

**在 Instruments 中使用**：
1. 在 Xcode 中選擇 Scheme：`SwiftStateTreeBenchmarks`
2. 選擇 Scheme → Edit Scheme... → Run → Arguments
3. 在 Environment Variables 中添加：
   - Name: `DIFF_BENCHMARK_MODE`
   - Value: `optimized`（或 `standard`）
4. 在 Xcode 中選擇 Product → Profile（或按 `Cmd + I`）
5. 選擇要使用的 Instrument（例如 Time Profiler）
6. 點擊 Record 開始測試

### 顯示幫助

```bash
swift run SwiftStateTreeBenchmarks --help
# 或
swift run SwiftStateTreeBenchmarks -h
```

### 包含 CSV 輸出

```bash
# 使用 --csv 或 -c 參數
swift run SwiftStateTreeBenchmarks --csv
swift run SwiftStateTreeBenchmarks single -c
```

### 進階參數

- `--dirty-on`: 強制啟用 dirty tracking
- `--dirty-off`: 強制停用 dirty tracking
- `--dirty-ratio=VAL`: 覆寫 dirty player ratio（0.0–1.0）
- `--suite-name=NAME`: 只執行名稱完全匹配的 suite
- `--player-counts=VAL`: 覆寫測試玩家數（comma-separated，例如 "4,10,20,30,50"）
- `--room-counts=VAL`: 覆寫多房間測試的房間數（comma-separated，例如 "1,2,4,8"）
- `--tick-mode=VAL`: 覆寫多房間 tick 模式（"synchronized" 或 "staggered"）
- `--tick-strides=VAL`: 覆寫多房間 tick stride（comma-separated，例如 "1,2,3,4"）
- `--no-wait`: 跳過「Press Enter」提示

### 可用的 Benchmark Suite

| Suite | 說明 |
|-------|------|
| `single` | 單執行緒執行（snapshot 生成基礎性能） |
| `diff` | Standard vs Optimized Diff 比較 |
| `mirror` | Mirror vs Macro 比較 |
| `transport-sync` | TransportAdapter 完整 sync 流程性能測試 |
| `transport-parallel-tuning` | TransportAdapter 平行編碼並行度調校測試 |
| `transport-multiroom-parallel-tuning` | TransportAdapter 多房間平行編碼測試 |
| `all` | 執行所有 suite（預設） |

## 輸出說明

Benchmark 會測試以下場景：

- **Tiny State**: 5 個玩家，每個玩家 3 張卡
- **Small State**: 10 個玩家，每個玩家 5 張卡
- **Medium State**: 100 個玩家，每個玩家 10 張卡
- **Large State**: 500 個玩家，每個玩家 20 張卡
- **Very Large State**: 1000 個玩家，每個玩家 30 張卡
- **Huge State**: 5000 個玩家，每個玩家 50 張卡

每個場景會輸出：
- **Execution Mode**: 執行模式（單執行緒/並行）
- **Average Time**: 平均執行時間（毫秒）
- **Min Time**: 最短執行時間（毫秒）
- **Max Time**: 最長執行時間（毫秒）
- **Throughput**: 每秒可生成的 snapshot 數量
- **Snapshot Size**: 快照大小（位元組）

### 效能比較

Benchmark 會自動比較單執行緒和並行執行的效能：
- **Speedup**: 實際加速比 vs 理論加速比（核心數）
- **Efficiency**: 並行效率（實際加速比 / 核心數 × 100%）

## CSV 輸出（可選）

如果需要 CSV 格式的結果進行後續分析，可以使用 `--csv` 或 `-c` 參數：

```bash
# 執行 benchmark 並包含 CSV 輸出
swift run SwiftStateTreeBenchmarks --csv

# 執行特定 suite 並包含 CSV 輸出
swift run SwiftStateTreeBenchmarks single parallel --csv

# 將 CSV 輸出重定向到檔案
swift run SwiftStateTreeBenchmarks --csv > benchmark_results.csv
```

CSV 格式：
```csv
Name,Players,Cards/Player,PlayerStateFields,Iterations,ExecutionMode,AvgTime(ms),MinTime(ms),MaxTime(ms),Throughput(snapshots/sec),Size(bytes)
```

**注意**：預設情況下不會輸出 CSV，只有在明確指定 `--csv` 參數時才會輸出。

## 使用場景

- 效能回歸測試：在 CI/CD 中執行，檢測效能退化
- 優化驗證：比較不同實作方式的效能差異
- 容量規劃：了解不同狀態大小下的效能表現
- 開發除錯：執行特定 suite 快速驗證變更

## 擴展新的 Benchmark

要添加新的 benchmark 測試，只需：

1. **創建新的 Runner**（如果需要新的執行策略）：
   ```swift
   struct MyCustomRunner: BenchmarkRunner {
       func run(
           config: BenchmarkConfig,
           state: BenchmarkStateRootNode,
           playerID: PlayerID
       ) async -> BenchmarkResult {
           // Your custom benchmark logic
       }
   }
   ```

2. **在 BenchmarkSuiteConfig.swift 中添加配置**：
   ```swift
   BenchmarkSuiteConfig(
       type: .myCustom,
       name: "My Custom Benchmark",
       runner: MyCustomRunner(),
       configurations: BenchmarkConfigurations.standard
   )
   ```

3. **在 BenchmarkSuiteType enum 中添加新類型**（如果需要命令行支援）

## 注意事項

- **單執行緒執行**：測試 snapshot 生成的基礎性能，但不是完整的 sync 流程（實際使用中會分開提取 broadcast 和 per-player snapshot）
- **TransportAdapter Sync**：最接近實際使用場景的 benchmark，測試完整的 sync 流程
- **Release 模式**：建議使用 `-c release` 進行準確的效能測試（但編譯時間較長）
- **系統負載**：建議在系統負載較低時執行，以獲得最準確的結果
- **SwiftSyntax 編譯時間**：第一次編譯 release 模式時，SwiftSyntax 可能需要 2-5 分鐘
- **錯誤處理**：如果輸入無效的 suite 名稱，程式會顯示錯誤訊息並退出，不會執行任何 benchmark
