| format                    | rooms | avgCostPerSyncMs(serial) | avgCostPerSyncMs(parallel) | MaxRooms(serial) | MaxRooms(parallel) | MaxPlayers(serial) | MaxPlayers(parallel) |
| ------------------------- | ----- | ------------------------ | -------------------------- | ---------------- | ------------------ | ------------------ | -------------------- |
| JSON Object               | 10    | 0.3385                   | 0.0776                     | 2481.4           | 10824.5            | 12407              | 54122                |
| JSON Object               | 30    | 0.3483                   | 0.0701                     | 2411.9           | 11975.9            | 12060              | 59880                |
| JSON Object               | 50    | 0.3834                   | 0.0801                     | 2191.2           | 10490.8            | 10956              | 52454                |
| Opcode MsgPack (PathHash) | 10    | 0.2977                   | 0.1047                     | 2821.3           | 8020.6             | 14106              | 40103                |
| Opcode MsgPack (PathHash) | 30    | 0.3199                   | 0.0632                     | 2626.0           | 13295.3            | 13130              | 66477                |
| Opcode MsgPack (PathHash) | 50    | 0.3404                   | 0.0646                     | 2467.7           | 13009.3            | 12338              | 65046                |
