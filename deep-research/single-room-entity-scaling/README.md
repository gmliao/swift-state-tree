# Single-room entity scaling — bytesPerSync vs. players / monsters

## Question

hero-defense 單一房間內，玩家數與怪物數各自（及同時）增長時，`bytesPerSync` 是隨實體數線性成長還是保持穩定？（回應「單房內 state tree 變大時同步成本是否穩定」的疑問）

## Environment

- date: 2026-08-31（UTC）
- git_sha: 怪物軸 `648fce5`；玩家軸與 joint cell `9f65c9e`（`--active-players` 與 `makeLand(maxPlayers:)` 落地後；兩版間 hero-defense 演化邏輯無變更）
- swift_version: Apple Swift 6.3.2, build_config: release
- host: Apple M2, macOS（8 cores, 16 GB）
- `USE_SNAPSHOT_FOR_SYNC=false`（legacy sync 路徑，與 RQ1 Stage 1 同口徑）

## Command(s)

```bash
cd Examples/GameDemo

# Monster axis (idle, players fixed at 5); cap = 4, 10, 50, 100
USE_SNAPSHOT_FOR_SYNC=false swift run -c release EncodingBenchmark --scalability \
  --format <json-object|messagepack-pathhash> \
  --players-per-room-list 5 --room-counts 1 --monster-cap <N> \
  --iterations 200 --ticks-per-sync 2

# Player axis, idle / active (monster cap fixed at 4)
USE_SNAPSHOT_FOR_SYNC=false swift run -c release EncodingBenchmark --scalability \
  --format <...> --players-per-room-list 5,10,20,50 --room-counts 1 --monster-cap 4 \
  [--active-players] --iterations 200 --ticks-per-sync 2

# Joint cell: players 20 x cap 20, active
USE_SNAPSHOT_FOR_SYNC=false swift run -c release EncodingBenchmark --scalability \
  --format <...> --players-per-room-list 20 --room-counts 1 --monster-cap 20 \
  --active-players --iterations 200 --ticks-per-sync 2
```

- `--monster-cap N`：spawn interval 固定 1、每 tick 補滿到 N（land 端 clamp），存活怪物數整場 ≈ N（`finalMonsterCount` 驗證欄位）。
- `--active-players`：每 iteration 經正式 `handleClientEvent` 路徑對每位玩家注入確定性 `MoveTo` 事件，使每位玩家每 tick 產生 position/rotation diff。
- 設計文件：`Notes/plans/2026-08-31-active-players-experiment-design.md`。

## Parameter matrix

| 軸 | 值 | 固定 |
|---|---|---|
| monster cap（idle） | 4, 10, 50, 100 | players = 5 |
| players（idle 與 active 各一組） | 5, 10, 20, 50 | monster cap = 4 |
| joint cell（active） | players 20 × cap 20 | — |
| encoding | json-object, messagepack-pathhash | — |

共同固定：rooms=1、ticksPerSync=2（tick 20 Hz / sync 10 Hz）、iterations=200、無砲塔。

## Results

### Monster axis (idle, players = 5)

| Format | players | monster cap | final monsters | bytesPerSync |
|---|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 2954 |
| JSON Object | 5 | 10 | 10 | 7050 |
| JSON Object | 5 | 50 | 50 | 32854 |
| JSON Object | 5 | 100 | 100 | 63941 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 828 |
| Opcode MsgPack (PathHash) | 5 | 10 | 10 | 2032 |
| Opcode MsgPack (PathHash) | 5 | 50 | 50 | 9112 |
| Opcode MsgPack (PathHash) | 5 | 100 | 100 | 18139 |

### Player axis — idle players (monster cap = 4)

| Format | players | monster cap | final monsters | bytesPerSync | bytes/player |
|---|---:|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 2954 | 591 |
| JSON Object | 10 | 4 | 4 | 5713 | 571 |
| JSON Object | 20 | 4 | 4 | 11744 | 587 |
| JSON Object | 50 | 4 | 4 | 29415 | 588 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 828 | 166 |
| Opcode MsgPack (PathHash) | 10 | 4 | 4 | 1593 | 159 |
| Opcode MsgPack (PathHash) | 20 | 4 | 4 | 3362 | 168 |
| Opcode MsgPack (PathHash) | 50 | 4 | 4 | 8384 | 168 |

### Player axis — active players (monster cap = 4)

| Format | players | monster cap | final monsters | bytesPerSync | bytes/player |
|---|---:|---:|---:|---:|---:|
| JSON Object | 5 | 4 | 4 | 10125 | 2025 |
| JSON Object | 10 | 4 | 4 | 34670 | 3467 |
| JSON Object | 20 | 4 | 4 | 128010 | 6400 |
| JSON Object | 50 | 4 | 4 | 760889 | 15218 |
| Opcode MsgPack (PathHash) | 5 | 4 | 4 | 2490 | 498 |
| Opcode MsgPack (PathHash) | 10 | 4 | 4 | 8340 | 834 |
| Opcode MsgPack (PathHash) | 20 | 4 | 4 | 30148 | 1507 |
| Opcode MsgPack (PathHash) | 50 | 4 | 4 | 176264 | 3525 |

### Joint cell — active, players and monsters raised together

| Format | players | monster cap | final monsters | bytesPerSync | bytes/player |
|---|---:|---:|---:|---:|---:|
| JSON Object | 20 | 4 | 4 | 128010 | 6400 |
| JSON Object | 20 | 20 | 20 | 170634 | 8532 |
| Opcode MsgPack (PathHash) | 20 | 4 | 4 | 30148 | 1507 |
| Opcode MsgPack (PathHash) | 20 | 20 | 20 | 42470 | 2124 |

### Marginal payload cost per monster (idle, players = 5, cap 4 → 100)

| Format | bytes/monster |
|---|---:|
| JSON Object | 635.3 |
| Opcode MsgPack (PathHash) | 180.3 |

## Conclusion

`bytesPerSync` 不隨 state tree 成長保持穩定；它符合 **cost ∝ |changed nodes| × |recipients|**：

- **怪物軸**（changed nodes ↑、recipients 固定 5）：線性成長，JSON 每隻 ~635 B、MsgPack ~180 B（≈ JSON 的 28%）。
- **idle 玩家軸**（changed nodes 固定 ≈4 隻怪、recipients ↑）：線性成長，每玩家 bytes 幾乎恆定（JSON ~588 B、MsgPack ~166 B）。
- **active 玩家軸**（changed nodes ≈ n、recipients = n）：總量 ~n²，每玩家 bytes 隨 n 線性上升（MsgPack 498 → 3,525 B）。
- **joint cell**：p20 由 cap4 → cap20 增加 16 隻怪，MsgPack +12.3 KB ≈ 每隻 770 B ≈ 20 recipients × ~38 B，同一公式吻合。

## Caveats

- **bytesPerSync 口徑**：`CountingTransport` 累計所有 `send()` 呼叫的 bytes。此 legacy sync 路徑對每個 session 各送一份 merged update，因此本指標已含「× recipients」——它是全房間下行 application payload 總量，不是單份編碼大小。
- **資料修正紀錄**：本 topic 首版（commit `27e2673`）的 idle 玩家軸 p20/p50 數據無效——`HeroDefense` land 寫死 `MaxPlayers(10)`，超額 join 被 benchmark 靜默吞掉，房間實際只有 10 人；當時據此寫出的「玩家軸持平／encode-once」結論是錯的。`9f65c9e` 起 `makeLand(maxPlayers:)` 可參數化且 benchmark 會對帳 join 數並警告。
- active 注入的 `MoveTo` 事件也使 `targetPosition`（broadcast 欄位）入 diff；這符合真實客戶端行為。
- 怪物軸用 refill-to-cap 機制，非自然 spawn/擊殺動態。
- 每 cell 1 run；serial/parallel 差 <1.5%（事件時序）。
- host 為 Apple M2 macOS，與 2026-02 RQ1 基線（AMD/WSL2, Swift 6.2.3）不同機器；跨表僅比相對趨勢。
- 未變動軸：ticksPerSync、iterations、砲塔數（0）、rooms（1）、dirty tracking（on）。

Raw benchmark envelopes: `raw/`（EncodingBenchmark 原始輸出，含完整 metadata 與 git sha）。
