| format                    | rooms | avgCostPerSyncMs(serial) | avgCostPerSyncMs(parallel) | MaxRooms(serial) | MaxRooms(parallel) | MaxPlayers(serial) | MaxPlayers(parallel) |
| ------------------------- | ----- | ------------------------ | -------------------------- | ---------------- | ------------------ | ------------------ | -------------------- |
| JSON Object               | 10    | 0.3299                   | 0.0821                     | 2546.6           | 10235.0            | 12733              | 51175                |
| JSON Object               | 30    | 0.3376                   | 0.0747                     | 2487.9           | 11238.6            | 12440              | 56193                |
| JSON Object               | 50    | 0.3329                   | 0.0660                     | 2523.6           | 12718.0            | 12618              | 63590                |
| Opcode MsgPack (PathHash) | 10    | 0.3095                   | 0.0675                     | 2714.2           | 12438.5            | 13571              | 62192                |
| Opcode MsgPack (PathHash) | 30    | 0.3017                   | 0.0622                     | 2784.1           | 13504.5            | 13921              | 67523                |
| Opcode MsgPack (PathHash) | 50    | 0.2981                   | 0.0572                     | 2817.5           | 14687.6            | 14088              | 73438                |
