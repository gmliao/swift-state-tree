# Linux 容器開發環境

這個目錄包含 VS Code Dev Container 配置，用於在 Linux 環境中測試 SwiftStateTree 的編譯。

## 使用方法

### 方法 1：使用 VS Code Dev Containers（推薦）

1. 安裝 [Dev Containers 擴展](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
2. 在 VS Code 中按 `F1` 或 `Cmd+Shift+P`
3. 選擇 **"Dev Containers: Reopen in Container"**
4. VS Code 會自動構建並啟動 Linux 容器
5. 在容器中運行：
   ```bash
   swift build
   swift test
   ```

## 注意事項

在 Dev Container 中，即使 `Package.swift` 指定了 `platforms: [.macOS(.v14)]`，Swift Package Manager 在 Linux 容器環境中仍可直接編譯，無需額外修改。

如果遇到編譯錯誤，請檢查：
- 是否有 macOS 特定的 API（需要使用條件編譯 `#if os(macOS)`）
- 所有依賴是否支援 Linux（Hummingbird 等應該都支援）
