# SwiftStateTree

一个基于 Swift 的状态树（State Tree）游戏引擎库，提供纯逻辑层的状态管理，可轻松集成到任何 Swift 项目中。

## 📋 目录

- [功能特性](#功能特性)
- [系统要求](#系统要求)
- [安装](#安装)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [使用示例](#使用示例)
- [开发指南](#开发指南)
- [测试](#测试)
- [贡献](#贡献)
- [许可证](#许可证)

## ✨ 功能特性

- 🎮 **纯逻辑层**：核心 Library 不依赖任何 Web 框架，可独立使用
- 🌳 **状态树架构**：基于 StateTree 的状态管理设计
- 🎯 **Actor 并发**：使用 Swift Actor 确保线程安全
- 🔌 **WebSocket 支持**：附带 Vapor Demo 展示实时通信
- 🧪 **完整测试**：包含单元测试示例

## 📦 系统要求

- Swift 6.0+
- macOS 13.0+
- Xcode 15.0+（推荐）

## 🚀 安装

### Swift Package Manager

在你的 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/your-username/SwiftStateTree.git", from: "1.0.0")
]
```

或者在 Xcode 中：
1. File → Add Packages...
2. 输入仓库 URL
3. 选择版本并添加

## 🏃 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/your-username/SwiftStateTree.git
cd SwiftStateTree
```

### 2. 构建项目

```bash
swift build
```

### 3. 运行测试

```bash
swift test
```

### 4. 运行 Demo Server

```bash
swift run SwiftStateTreeVaporDemo
```

服务器将在 `http://localhost:8080` 启动。

## 📁 项目结构

```
SwiftStateTree/
├── Package.swift
├── Sources/
│   ├── SwiftStateTree/              # 核心 Library（纯逻辑）
│   │   ├── GameCore/
│   │   │   ├── GameState.swift      # 游戏状态定义
│   │   │   ├── GameCommand.swift    # 游戏指令枚举
│   │   │   └── RoomActor.swift      # 房间 Actor（状态管理）
│   │   └── StateTree/
│   │       ├── StateNode.swift      # 状态树节点
│   │       └── StateTreeEngine.swift # 状态树引擎
│   └── SwiftStateTreeVaporDemo/     # Demo Server（Vapor）
│       ├── main.swift               # 入口文件
│       ├── Configure.swift          # 配置与 Room 管理
│       └── Routes.swift              # WebSocket 路由
└── Tests/
    └── SwiftStateTreeTests/
        └── SwiftStateTreeTests.swift # 单元测试
```

## 💡 使用示例

### 基本使用

```swift
import SwiftStateTree

// 创建房间
let room = RoomActor(roomID: "room1")

// 创建玩家
let alice = PlayerID("alice")
let bob = PlayerID("bob")

// 加入房间
await room.handle(.join(playerID: alice, name: "Alice"))
await room.handle(.join(playerID: bob, name: "Bob"))

// 执行攻击
await room.handle(.attack(attacker: alice, target: bob, damage: 10))

// 获取状态快照
let snapshot = await room.snapshot()
print("Bob's HP: \(snapshot.players[bob]?.hp ?? 0)") // 输出: 90
```

### WebSocket 连接（Demo）

连接到 Demo Server：

```javascript
const ws = new WebSocket('ws://localhost:8080/ws/room1/alice');

ws.onmessage = (event) => {
    console.log('收到:', event.data);
};

// 攻击玩家 bob，造成 10 点伤害
ws.send('hit:bob:10');
```

### 自定义状态树

```swift
import SwiftStateTree

// 创建状态树节点
let root = StateNode(id: "root", children: [
    StateNode(id: "child1"),
    StateNode(id: "child2")
])

// 创建引擎
let engine = StateTreeEngine(root: root)

// 评估状态
let newState = engine.evaluate()
```

## 🛠 开发指南

### 扩展 GameState

在 `Sources/SwiftStateTree/GameCore/GameState.swift` 中添加你的状态字段：

```swift
public struct GameState: Sendable {
    public var players: [PlayerID: PlayerState]
    public var gameMode: String  // 新增字段
    // ... 更多字段
}
```

### 添加新的 GameCommand

在 `Sources/SwiftStateTree/GameCore/GameCommand.swift` 中扩展指令：

```swift
public enum GameCommand: Sendable {
    case join(playerID: PlayerID, name: String)
    case leave(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
    case heal(playerID: PlayerID, amount: Int)  // 新增指令
}
```

### 实现 StateTreeEngine

在 `Sources/SwiftStateTree/StateTree/StateTreeEngine.swift` 中实现你的状态树逻辑：

```swift
public func evaluate() -> StateNode<ID> {
    // 实现你的状态树评估逻辑
    // 例如：计算下一帧状态、处理事件等
    return root
}
```

## 🧪 测试

运行所有测试：

```bash
swift test
```

运行特定测试：

```bash
swift test --filter SwiftStateTreeTests.testJoinAndAttack
```

### 编写新测试

在 `Tests/SwiftStateTreeTests/` 中添加测试用例：

```swift
func testYourFeature() async throws {
    // 你的测试代码
}
```

## 📝 API 文档

### RoomActor

管理单个房间的游戏状态。

```swift
public actor RoomActor {
    public let roomID: String
    public init(roomID: String, initialState: GameState = GameState())
    public func handle(_ command: GameCommand)
    public func snapshot() -> GameState
}
```

### GameCommand

游戏指令枚举，用于状态更新。

```swift
public enum GameCommand: Sendable {
    case join(playerID: PlayerID, name: String)
    case leave(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
}
```

### StateTreeEngine

状态树引擎，用于评估和更新状态树。

```swift
public struct StateTreeEngine<ID: Hashable & Sendable>: Sendable {
    public var root: StateNode<ID>
    public init(root: StateNode<ID>)
    public func evaluate() -> StateNode<ID>
}
```

## 🤝 贡献

欢迎贡献代码！请遵循以下步骤：

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

### 代码规范

- 遵循 Swift API 设计指南
- 使用 Swift 6 并发特性（Actor、async/await）
- 确保所有公开 API 符合 `Sendable`
- 为新功能添加测试用例

## 📄 许可证

本项目采用 MIT 许可证。详见 [LICENSE](LICENSE) 文件。

## 🔗 相关链接

- [Swift 官方文档](https://swift.org/documentation/)
- [Vapor 文档](https://docs.vapor.codes/)
- [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)

## 📧 联系方式

如有问题或建议，请通过以下方式联系：

- 提交 [Issue](https://github.com/your-username/SwiftStateTree/issues)
- 发送邮件至：your-email@example.com

---

**注意**：本项目仍在积极开发中，API 可能会发生变化。建议在生产环境使用前仔细测试。

