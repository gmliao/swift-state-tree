# SwiftStateTree Benchmarks

獨立可執行檔，用於測試不同狀態大小的 snapshot 生成效能。

## 程式碼結構

Benchmark 程式碼已模組化，方便擴展新的測試：

- **BenchmarkData.swift**: 測試數據結構和生成邏輯
- **BenchmarkConfig.swift**: 配置、結果定義和預設配置
- **BenchmarkRunner.swift**: 不同的執行策略（單執行緒、並行、多玩家並行）
- **main.swift**: 主入口，組織和運行不同的 benchmark suite

## 執行模式

Benchmark 支援多種執行模式：

1. **單執行緒執行**：順序執行，確保準確的時間測量
2. **並行執行**：使用多核心並行生成 snapshot，測試實際加速比
3. **多玩家並行執行**：模擬真實場景，同時為多個玩家生成 snapshot

## 執行方式

```bash
# 執行 benchmark
swift run SwiftStateTreeBenchmarks

# 使用 release 模式執行（更準確的效能測試）
swift run -c release SwiftStateTreeBenchmarks
```

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

## CSV 輸出

Benchmark 結束時會輸出 CSV 格式的結果，方便後續分析：

```csv
Name,Players,Cards/Player,Iterations,ExecutionMode,AvgTime(ms),MinTime(ms),MaxTime(ms),Throughput(snapshots/sec),Size(bytes)
```

可以將輸出重定向到檔案：

```bash
swift run SwiftStateTreeBenchmarks > benchmark_results.csv
```

## 使用場景

- 效能回歸測試：在 CI/CD 中執行，檢測效能退化
- 優化驗證：比較不同實作方式的效能差異
- 容量規劃：了解不同狀態大小下的效能表現

## 擴展新的 Benchmark

要添加新的 benchmark 測試，只需：

1. **創建新的 Runner**（如果需要新的執行策略）：
   ```swift
   struct MyCustomRunner: BenchmarkRunner {
       func run(config: BenchmarkConfig, state: BenchmarkStateTree, playerID: PlayerID) async -> BenchmarkResult {
           // Your custom benchmark logic
       }
   }
   ```

2. **在 main.swift 中添加新的 Suite**：
   ```swift
   let mySuite = BenchmarkSuite(
       name: "My Custom Benchmark",
       runner: MyCustomRunner(),
       configurations: BenchmarkConfigurations.standard
   )
   allResults.append(contentsOf: await mySuite.run())
   ```

3. **或使用現有的配置**：
   - `BenchmarkConfigurations.standard`: 完整的測試配置
   - `BenchmarkConfigurations.quick`: 快速測試配置

## 注意事項

- **單執行緒執行**：單執行緒模式確保準確的時間測量
- **並行執行**：並行模式測試實際的多核心加速比，可能受記憶體頻寬限制
- **Release 模式**：建議使用 `-c release` 進行準確的效能測試（但編譯時間較長）
- **系統負載**：建議在系統負載較低時執行，以獲得最準確的結果
- **SwiftSyntax 編譯時間**：第一次編譯 release 模式時，SwiftSyntax 可能需要 2-5 分鐘

