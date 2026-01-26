# Benchmark Results

此目錄存放所有 benchmark 測試的 JSON 結果文件。

**結果文件位置**：`Examples/GameDemo/results/encoding-benchmark/`

所有測試結果會自動保存在此目錄中，方便版本控制和分享。

## 文件命名規則

### 並行比較測試（Parallel Comparison）
- 格式：`parallel-comparison-multiroom-{rooms}rooms-ppr{playersPerRoom}-{iterations}iterations{tickN}-{timestamp}.json`
- 範例：`parallel-comparison-multiroom-4rooms-ppr5-1000iterations-tick2-2026-01-24T15-57-24Z.json`
- 說明：測試不同編碼格式在序列化 vs 並行執行下的性能對比

### 可擴展性測試（Scalability Test）
- 格式：`scalability-matrix-{formatOrAll}{playersPerRoomList}-{iterations}iterations{tickN}-{timestamp}.json`
- 範例：`scalability-matrix-all-formats-ppr5+10-1000iterations-tick2-2026-01-24T16-12-01Z.json`
- 說明：可同時測試多個房間數、多個每房間人數、以及（可選）多個編碼格式的矩陣結果

### 所有格式測試（All Formats）
- 格式：`all-formats-{players}players-{iterations}iterations{parallel}-{timestamp}.json`（單房間）
- 格式：`all-formats-multiroom-{rooms}rooms-ppr{playersPerRoom}-{iterations}iterations{parallel}{tickN}-{timestamp}.json`（多房間）
- 範例：`all-formats-multiroom-4rooms-ppr5-1000iterations-parallel-tick2-2026-01-24T16-01-11Z.json`
- 說明：測試所有編碼格式的性能對比

## JSON 結構

所有結果檔案都使用「單檔自描述」的 envelope 結構：

```json
{
  "metadata": {
    "timestampUTC": "2026-01-24T16:12:01.123Z",
    "build": {
      "configuration": "release",
      "swiftVersion": "Swift version ..."
    },
    "git": {
      "commit": "1ffdd69...",
      "branch": "feature/..."
    },
    "environment": {
      "arch": "x86_64",
      "cpuModel": "AMD Ryzen ...",
      "cpuPhysicalCores": 6,
      "cpuLogicalCores": 12,
      "memoryTotalMB": 16384,
      "wsl": true,
      "container": false
    },
    "benchmarkConfig": {
      "mode": "scalability-matrix",
      "iterations": 1000,
      "ticksPerSync": 2
    }
  },
  "results": [ /* 以下各類測試的 result array */ ]
}
```

### 並行比較測試結果

```json
{
  "metadata": { "...": "..." },
  "results": [
  {
    "format": "json-object",
    "displayName": "JSON Object",
    "serial": {
      "timeMs": 645.63,
      "totalBytes": 1234567,
      "bytesPerSync": 1234,
      "throughputSyncsPerSecond": 5879.9,
      "avgCostPerSyncMs": 0.1701
    },
    "parallel": {
      "timeMs": 251.46,
      "totalBytes": 1234567,
      "bytesPerSync": 1234,
      "throughputSyncsPerSecond": 12443.8,
      "avgCostPerSyncMs": 0.0804
    },
    "speedup": 2.57,
    "config": {
      "rooms": 4,
      "playersPerRoom": 5,
      "iterations": 1000,
      "ticksPerSync": 2,
      "gameType": "hero-defense"
    }
  }
  ]
}
```

### 可擴展性測試結果

```json
{
  "metadata": { "...": "..." },
  "results": [
  {
    "rooms": 1,
    "playersPerRoom": 5,
    "format": "json-object",
    "displayName": "JSON Object",
    "serial": {
      "timeMs": 82.11,
      "totalBytes": 123456,
      "bytesPerSync": 123,
      "throughputSyncsPerSecond": 5317.3,
      "avgCostPerSyncMs": 0.1882
    },
    "parallel": {
      "timeMs": 94.03,
      "totalBytes": 123456,
      "bytesPerSync": 123,
      "throughputSyncsPerSecond": 5317.3,
      "avgCostPerSyncMs": 0.1882
    },
    "speedup": 0.87,
    "efficiency": 87.3,
    "config": {
      "iterations": 500,
      "ticksPerSync": 2,
      "gameType": "hero-defense"
    }
  }
  ]
}
```

## 使用方式

這些 JSON 文件可以用於：
- 性能分析和對比
- 生成圖表和報告
- 追蹤性能變化趨勢
- 分享測試結果

### 所有格式測試結果

```json
{
  "metadata": { "...": "..." },
  "results": [
  {
    "format": "json-object",
    "displayName": "JSON Object",
    "timeMs": 244.91,
    "totalBytes": 11420,
    "bytesPerSync": 11,
    "iterations": 1000,
    "parallel": true,
    "roomCount": 4,
    "playersPerRoom": 5,
    "timePerRoomMs": 61.23,
    "timePerSyncMs": 0.0612,
    "avgCostPerSyncMs": 0.0153,
    "throughputSyncsPerSecond": 16326.5,
    "config": {
      "ticksPerSync": 2,
      "gameType": "hero-defense"
    }
  }
  ]
}
```

## 運行測試生成 JSON

### 所有格式測試（推薦）✅
```bash
# 多房間模式（並行）- 推薦用於性能對比
swift run -c release EncodingBenchmark --all --rooms 4 --players-per-room 5 --iterations 1000

# tick=20Hz, sync=10Hz（更接近實際運行情況）
swift run -c release EncodingBenchmark --all --rooms 4 --players-per-room 5 --iterations 1000 --ticks-per-sync 2

# 單房間模式
swift run -c release EncodingBenchmark --all --players 10 --iterations 1000
```

### 並行比較測試
```bash
# 測試序列化 vs 並行執行的性能差異
swift run -c release EncodingBenchmark --compare-parallel --rooms 4 --players-per-room 5 --iterations 1000

# tick=20Hz, sync=10Hz
swift run -c release EncodingBenchmark --compare-parallel --rooms 4 --players-per-room 5 --iterations 1000 --ticks-per-sync 2
```

### 可擴展性測試
```bash
# 單一格式：測試不同房間數下的性能變化（預設 roomCounts）
swift run -c release EncodingBenchmark --scalability --format json-object --players-per-room 5 --iterations 1000 --ticks-per-sync 2

# 全格式 × 多 playersPerRoom 的矩陣（推薦用於比較 encoding impact）
swift run -c release EncodingBenchmark --scalability --all --players-per-room-list 5,10 --iterations 1000 --ticks-per-sync 2

# 指定房間數（例如 10~50）
swift run -c release EncodingBenchmark --scalability --all --players-per-room-list 5,10 --room-counts 10,20,30,40,50 --iterations 1000 --ticks-per-sync 2
```

## 注意事項

- ✅ 結果文件會自動保存在 `Examples/GameDemo/results/encoding-benchmark/` 目錄中
- ✅ 文件名包含時間戳，避免覆蓋之前的結果
- ✅ 所有數值都是實際測試結果，可以直接用於分析
- ✅ 所有 JSON 文件都可以版本控制，方便追蹤性能變化

### Release mode stability note (macOS)

In older versions, `EncodingBenchmark --compare-parallel` could crash in `-c release` with exit code 139.
The root cause was an invalid `String(format:)` usage: passing a Swift `String` to the C `%s` specifier
(which expects a C string pointer). This has been fixed by using type-safe formatting (`%@` / interpolation).
