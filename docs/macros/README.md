# Macros

SwiftStateTree 提供三個主要 macro，用於產生 metadata 與提升效能：

## 設計說明

- 以編譯期產生 metadata，降低 runtime reflection 成本
- 把驗證提前到編譯期，避免 runtime 出錯

## @StateNodeBuilder

- 驗證所有 stored property 都標記為 `@Sync` 或 `@Internal`
- 產生 sync metadata 與 dirty tracking 方法

## @Payload

- 產生 `getFieldMetadata()`
- Action payload 會額外產生 `getResponseType()`
- 若 Action 未標記 `@Payload`，`getResponseType()` 會在 runtime trap

## @SnapshotConvertible

- 自動產生 `SnapshotValueConvertible` 實作
- 減少 runtime reflection 成本
