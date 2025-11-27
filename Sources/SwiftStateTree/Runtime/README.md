# Runtime

此目錄包含運行時相關的實現。

## 預期內容

- `LandKeeper.swift`：LandKeeper 定義（不含 Transport）

## 設計原則

- LandKeeper 負責處理 Transport 細節，但不暴露給 StateTree 層
- LandKeeper 不應直接依賴 Transport（在 transport 模組中才會有完整實現）
- 詳見 [DESIGN_RUNTIME.md](../../../DESIGN_RUNTIME.md)

