# Single-room entity scaling — bytesPerSync vs. players / monsters

## Question

hero-defense 單一房間內，玩家數與怪物數各自增長時，`bytesPerSync`（CountingTransport 量測的 application payload）是隨實體數線性成長還是保持穩定？

## Environment

- date: 2026-08-31（UTC 02:48–02:50）
- git_sha: `648fce5`（`--monster-cap` knob 落地後）
- swift_version: Apple Swift 6.3.2
- build_config: release
- host: Apple M2, macOS（8 cores, 16 GB）
- `USE_SNAPSHOT_FOR_SYNC=false`（legacy 路徑，與 RQ1 Stage 1 同口徑）

## Command(s)

```bash
cd Examples/GameDemo

# Player axis (monster cap fixed at 4)
USE_SNAPSHOT_FOR_SYNC=false swift run -c release EncodingBenchmark --scalability \
  --format <json-object|messagepack-pathhash> \
  --players-per-room-list 5,10,20,50 --room-counts 1 \
  --monster-cap 4 --iterations 200 --ticks-per-sync 2

# Monster axis (players fixed at 5); repeat for cap = 10, 50, 100
USE_SNAPSHOT_FOR_SYNC=false swift run -c release EncodingBenchmark --scalability \
  --format <json-object|messagepack-pathhash> \
  --players-per-room-list 5 --room-counts 1 \
  --monster-cap <N> --iterations 200 --ticks-per-sync 2
```

`--monster-cap N` 會把 spawn interval 固定為 1 並每 tick 補滿怪物到 N（land 端 clamp），使存活怪物數整場穩定在 N；輸出 JSON 的 `finalMonsterCount` 為驗證欄位。

## Parameter matrix

| 軸 | 值 | 固定 |
|---|---|---|
| players | 5, 10, 20, 50 | monster cap = 4 |
| monster cap | 4, 10, 50, 100 | players = 5 |
| encoding | json-object, messagepack-pathhash | — |

共同固定：rooms=1、ticksPerSync=2（tick 20 Hz / sync 10 Hz）、iterations=200、無砲塔、無 client actions。

## Results

### Monster axis (players = 5)

| Format | players | monster cap | final monsters | bytesPerSync (parallel) | bytesPerSync (serial) |
|---|---:|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 2954 | 2954 |
| JSON Object | 5 | 10 | 10 | 7050 | 7050 |
| JSON Object | 5 | 50 | 50 | 32854 | 32637 |
| JSON Object | 5 | 100 | 100 | 63941 | 63941 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 828 | 828 |
| Opcode MsgPack (PathHash) | 5 | 10 | 10 | 2032 | 2032 |
| Opcode MsgPack (PathHash) | 5 | 50 | 50 | 9112 | 9112 |
| Opcode MsgPack (PathHash) | 5 | 100 | 100 | 18139 | 18139 |

### Player axis (monster cap = 4)

| Format | players | monster cap | final monsters | bytesPerSync (parallel) | bytesPerSync (serial) |
|---|---:|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 2954 | 2954 |
| JSON Object | 10 | 4 | 4 | 5713 | 5629 |
| JSON Object | 20 | 4 | 4 | 5629 | 5713 |
| JSON Object | 50 | 4 | 4 | 5713 | 5713 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 828 | 828 |
| Opcode MsgPack (PathHash) | 10 | 4 | 4 | 1593 | 1609 |
| Opcode MsgPack (PathHash) | 20 | 4 | 4 | 1609 | 1609 |
| Opcode MsgPack (PathHash) | 50 | 4 | 4 | 1593 | 1609 |

### Marginal payload cost per monster (parallel, relative to cap=4)

| Format | cap range | bytes/monster |
|---|---|---:|
| JSON Object | 4 → 100 | 635.3 |
| Opcode MsgPack (PathHash) | 4 → 100 | 180.3 |

## Conclusion

`bytesPerSync`（編碼後 application payload）**隨怪物數線性成長**（JSON 每隻約 635 B、MsgPack+PathHash 每隻約 180 B，MsgPack 約為 JSON 的 28%），並非穩定；「保持穩定」的說法不成立。玩家軸在本 workload 下（閒置玩家、broadcast 只編碼一次）於 10 人後持平——payload 由「有變動的實體（怪物 + 交戰中玩家）」決定，而非房間總人數。

## Caveats

- **bytesPerSync 是 encode-once 口徑**：`CountingTransport` 對 broadcast update（`send(to: .all)`）只計一次 bytes。這代表「每次 sync 需編碼的 application payload」；實際下行頻寬約為此值 × 訂閱該 broadcast 的玩家數（per-player 私有 diff 除外）。
- **玩家是閒置的**：benchmark 玩家 join 後不發任何 action，只有 auto-shoot 與怪物互動會產生玩家側 diff。玩家軸反映「房間人數」而非「活躍玩家數」；全員移動的 workload 下玩家軸應另行量測。
- **怪物軸用 refill-to-cap 機制**（spawn interval=1、每 tick 補滿），非自然 spawn/擊殺動態；它量的是「穩定 N 隻且持續變動」的 payload。
- 每 cell 僅 1 run；serial vs parallel 有 ~1.5% 的事件時序差（p10/p20 的 5629↔5713）。
- host 為 Apple M2 macOS，與 2026-02 RQ1 基線（AMD/WSL2, Swift 6.2.3）不同機器、不同 Swift 版本；跨表比較僅限相對趨勢。
- 未變動軸：ticksPerSync、iterations、砲塔數（0）、房間數（1）、dirty tracking（on）。

Raw benchmark envelopes: `raw/`（EncodingBenchmark 原始輸出，含完整 metadata）。
