# Schema

SchemaGen 用於從 LandDefinition 和 StateNode 產生 JSON Schema。

## 設計目的

- 提供 client SDK 生成的穩定輸入
- 支援版本對齊與工具驗證
- 由 macro metadata 驅動，避免手寫 schema

## 產生流程

- `@StateNodeBuilder` 與 `@Payload` 產生欄位 metadata
- `SchemaExtractor` 以 `LandDefinition` 產生完整 schema
- `SchemaGenCLI` 可輸出 JSON 檔案

參考：`Sources/SwiftStateTree/SchemaGen/README.md`

## Hummingbird Schema 端點

`LandServer` 會提供 `/schema` endpoint，輸出當前 Land 的 JSON schema。
