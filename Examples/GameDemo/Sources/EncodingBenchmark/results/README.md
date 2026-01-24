# Benchmark Results

此目錄存放所有 benchmark 測試的 JSON 結果文件。

**結果文件位置**：`Examples/GameDemo/Sources/EncodingBenchmark/results/`

所有測試結果會自動保存在此目錄中，方便版本控制和分享。

## 文件命名規則

### 並行比較測試（Parallel Comparison）
- 格式：`parallel-comparison-multiroom-{rooms}rooms-{iterations}iterations{tick}-{timestamp}.json`
- 範例：`parallel-comparison-multiroom-4rooms-1000iterations-2026-01-24T15-57-24Z.json`
- 說明：測試不同編碼格式在序列化 vs 並行執行下的性能對比

### 可擴展性測試（Scalability Test）
- 格式：`scalability-test-{format}-{iterations}iterations{tick}-{timestamp}.json`
- 範例：`scalability-test-json-object-500iterations-2026-01-24T15-57-52Z.json`
- 說明：測試不同房間數（1, 2, 4, 8, 16, 32, 50）下的性能變化

### 所有格式測試（All Formats）
- 格式：`all-formats-{players}players-{iterations}iterations{parallel}-{timestamp}.json`（單房間）
- 格式：`all-formats-multiroom-{rooms}rooms-{iterations}iterations{parallel}{tick}-{timestamp}.json`（多房間）
- 範例：`all-formats-multiroom-4rooms-1000iterations-parallel-2026-01-24T16-01-11Z.json`
- 說明：測試所有編碼格式的性能對比

## JSON 結構

### 並行比較測試結果

```json
[
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
      "includeTick": false,
      "gameType": "hero-defense"
    }
  }
]
```

### 可擴展性測試結果

```json
[
  {
    "rooms": 1,
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
      "playersPerRoom": 5,
      "iterations": 500,
      "includeTick": false,
      "gameType": "hero-defense"
    }
  }
]
```

## 使用方式

這些 JSON 文件可以用於：
- 性能分析和對比
- 生成圖表和報告
- 追蹤性能變化趨勢
- 分享測試結果

### 所有格式測試結果

```json
[
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
      "includeTick": false,
      "gameType": "hero-defense"
    }
  }
]
```

## 運行測試生成 JSON

### 所有格式測試（推薦）✅
```bash
# 多房間模式（並行）- 推薦用於性能對比
swift run -c release EncodingBenchmark --all --rooms 4 --players-per-room 5 --iterations 1000

# 包含 tick 模擬（更接近實際運行情況）
swift run -c release EncodingBenchmark --all --rooms 4 --players-per-room 5 --iterations 1000 --include-tick

# 單房間模式
swift run -c release EncodingBenchmark --all --players 10 --iterations 1000
```

### 並行比較測試
```bash
# 測試序列化 vs 並行執行的性能差異
swift run -c release EncodingBenchmark --compare-parallel --rooms 4 --players-per-room 5 --iterations 1000

# 包含 tick 模擬
swift run -c release EncodingBenchmark --compare-parallel --rooms 4 --players-per-room 5 --iterations 1000 --include-tick
```

### 可擴展性測試
```bash
# 測試不同房間數（1, 2, 4, 8, 16, 32, 50）下的性能變化
swift run -c release EncodingBenchmark --scalability --format json-object --players-per-room 5 --iterations 500

# 包含 tick 模擬
swift run -c release EncodingBenchmark --scalability --format json-object --players-per-room 5 --iterations 500 --include-tick
```

## 注意事項

- ✅ 結果文件會自動保存在源碼目錄的 `results/` 子目錄中
- ✅ 文件名包含時間戳，避免覆蓋之前的結果
- ✅ 所有數值都是實際測試結果，可以直接用於分析
- ✅ 所有 JSON 文件都可以版本控制，方便追蹤性能變化
