# Runtime

此目錄包含運行時執行器（executor）相關的實現。

## 內容

- `LandKeeper.swift`：LandKeeper 執行器（不含 Transport）

## 設計原則

- LandKeeper 負責處理 Transport 細節，但不暴露給 StateTree 層
- LandKeeper 不應直接依賴 Transport（在 transport 模組中才會有完整實現）
- Runtime 目錄用於存放執行器類型的組件，未來可能包含其他執行器
- 詳見 [DESIGN_RUNTIME.md](../../../docs/design/DESIGN_RUNTIME.md)

