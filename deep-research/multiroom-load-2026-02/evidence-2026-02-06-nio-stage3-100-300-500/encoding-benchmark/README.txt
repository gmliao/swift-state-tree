RQ1 Stage 1 - Encoding Benchmark (100, 300, 500 rooms)
Date: 2026-02-06
Command (JSON Object):
cd Examples/GameDemo && USE_SNAPSHOT_FOR_SYNC=false swift run -c release EncodingBenchmark --scalability --format json-object --players-per-room 5 --room-counts 100,300,500 --iterations 200 --ticks-per-sync 2

Command (MessagePack PathHash):
cd Examples/GameDemo && USE_SNAPSHOT_FOR_SYNC=false swift run -c release EncodingBenchmark --scalability --format messagepack-pathhash --players-per-room 5 --room-counts 100,300,500 --iterations 200 --ticks-per-sync 2

Summary (100 rooms, 500 players, parallel mode):
| Format                    | bytesPerSync | avgCostPerSyncMs | Improvement |
|---------------------------|-------------:|-----------------:|------------:|
| JSON Object               | 175471       | 0.0809 ms        | baseline    |
| Opcode MsgPack (PathHash) | 49851        | 0.0566 ms        | -71.6% / -30.0% |
