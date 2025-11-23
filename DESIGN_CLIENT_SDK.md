# 客戶端 SDK 與程式碼生成

> 本文檔說明客戶端 SDK 的設計理念、自動生成機制，以及 Code-gen 架構

## 執行概念

### 為什麼需要自動生成客戶端 SDK？

StateTree 的核心設計理念是**單一來源真相（Single Source of Truth）**：

1. **Server 定義是權威來源**：
   - Server 端定義 StateTree、RPC、Event 的完整型別和結構
   - 這些定義包含所有業務邏輯和同步規則

2. **客戶端需要型別安全的介面**：
   - 客戶端必須知道如何呼叫 RPC、處理 Event
   - 必須確保型別一致性，避免執行時錯誤

3. **手動維護容易出錯**：
   - 手動定義客戶端型別容易與 Server 不同步
   - 型別不匹配會在執行時才發現，難以維護

### 自動生成的優勢

- **型別安全**：從 Server 定義自動生成，確保型別完全一致
- **自動同步**：Server 定義變更時，客戶端 SDK 自動更新
- **減少錯誤**：避免手動定義導致的型別不匹配
- **開發體驗**：提供完整的 TypeScript 型別提示和自動完成

## 客戶端 SDK 自動生成

### 設計決策：採用自動生成

**決定**：客戶端 SDK **必須**從 Server 定義自動生成，不支援手動定義。

**原因**：
1. 確保型別一致性
2. 減少維護成本
3. 提供更好的開發體驗

### 生成流程

```
Server 定義（Swift）
    ↓
提取型別資訊（AST 分析 / Macro 輸出）
    ↓
生成中間格式（JSON Schema / Protocol Buffer）
    ↓
Code Generator（TypeScript Generator）
    ↓
TypeScript 客戶端 SDK
```

### 生成內容

從 Server 定義自動生成以下內容：

1. **型別定義**：
   - StateTree 型別（對應 Server 的 StateTree）
   - RPC 型別（對應 Server 的 RPC enum）
   - Event 型別（對應 Server 的 ClientEvent / ServerEvent）
   - Response 型別（對應 Server 的 RPCResponse）

2. **客戶端 SDK 類別**：
   - `StateTreeClient`：WebSocket 連接管理
   - RPC 方法：型別安全的 RPC 呼叫
   - Event 處理：型別安全的 Event 訂閱

3. **型別輔助**：
   - TypeScript 型別定義
   - 自動完成提示
   - 編譯時型別檢查

### TypeScript 客戶端 SDK 範例

#### Server 定義（Swift）

```swift
// Server 端定義
enum GameRPC: Codable {
    case join(playerID: PlayerID, name: String)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
    case getPlayerHand(PlayerID)
}

enum ClientEvent: Codable {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
}

enum ServerEvent: Codable {
    case stateUpdate(StateSnapshot)
    case gameEvent(GameEventDetail)
}

@StateTree
struct GameStateTree {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState]
    
    @Sync(.perPlayer(\.ownerID))
    var hands: [PlayerID: HandState]
}
```

#### 自動生成的 TypeScript SDK

```typescript
// 自動生成的型別定義
export type PlayerID = string;

export interface PlayerState {
    name: string;
    hpCurrent: number;
    hpMax: number;
}

export interface HandState {
    ownerID: PlayerID;
    cards: Card[];
}

export interface GameStateSnapshot {
    players: Record<PlayerID, PlayerState>;
    hands: Record<PlayerID, HandState>;
}

// RPC 型別
export type GameRPC =
    | { type: 'join'; playerID: PlayerID; name: string }
    | { type: 'attack'; attacker: PlayerID; target: PlayerID; damage: number }
    | { type: 'getPlayerHand'; playerID: PlayerID };

// Event 型別
export type ClientEvent =
    | { type: 'playerReady'; playerID: PlayerID }
    | { type: 'heartbeat'; timestamp: Date };

export type ServerEvent =
    | { type: 'stateUpdate'; snapshot: GameStateSnapshot }
    | { type: 'gameEvent'; detail: GameEventDetail };

// 客戶端 SDK
export class StateTreeClient {
    private ws: WebSocket;
    private pendingRPCs: Map<string, {
        resolve: (response: RPCResponse) => void;
        reject: (error: Error) => void;
    }> = new Map();
    
    private eventHandlers: Map<string, Set<(event: ServerEvent) => void>> = new Map();
    
    constructor(config: {
        websocketURL: string;
        playerID: PlayerID;
        onConnect?: () => void;
        onDisconnect?: () => void;
        onError?: (error: Error) => void;
    }) {
        this.ws = new WebSocket(config.websocketURL);
        this.setupWebSocket(config);
    }
    
    // 型別安全的 RPC 呼叫
    async rpc(realmID: string, rpc: GameRPC): Promise<RPCResponse> {
        const requestID = crypto.randomUUID();
        const message: TransportMessage = {
            type: 'rpc',
            requestID,
            realmID,
            rpc
        };
        
        return new Promise((resolve, reject) => {
            this.pendingRPCs.set(requestID, { resolve, reject });
            
            // 設定 timeout
            setTimeout(() => {
                if (this.pendingRPCs.has(requestID)) {
                    this.pendingRPCs.delete(requestID);
                    reject(new Error('RPC timeout'));
                }
            }, 30000); // 30 秒 timeout
            
            this.ws.send(JSON.stringify(message));
        });
    }
    
    // 便利方法：針對特定 RPC 的型別安全方法
    async join(realmID: string, playerID: PlayerID, name: string): Promise<JoinResponse> {
        const response = await this.rpc(realmID, {
            type: 'join',
            playerID,
            name
        });
        
        if (response.success && response.data.type === 'joinResult') {
            return response.data.result;
        }
        throw new Error('Invalid join response');
    }
    
    async attack(
        realmID: string,
        attacker: PlayerID,
        target: PlayerID,
        damage: number
    ): Promise<AttackResponse> {
        const response = await this.rpc(realmID, {
            type: 'attack',
            attacker,
            target,
            damage
        });
        
        if (response.success && response.data.type === 'attackResult') {
            return response.data.result;
        }
        throw new Error('Invalid attack response');
    }
    
    // 發送 Event
    sendEvent(realmID: string, event: ClientEvent): void {
        const message: TransportMessage = {
            type: 'event',
            realmID,
            event: { type: 'fromClient', clientEvent: event }
        };
        this.ws.send(JSON.stringify(message));
    }
    
    // 訂閱 Event
    onEvent(realmID: string, handler: (event: ServerEvent) => void): () => void {
        if (!this.eventHandlers.has(realmID)) {
            this.eventHandlers.set(realmID, new Set());
        }
        this.eventHandlers.get(realmID)!.add(handler);
        
        // 返回取消訂閱函數
        return () => {
            this.eventHandlers.get(realmID)?.delete(handler);
        };
    }
    
    private setupWebSocket(config: {
        onConnect?: () => void;
        onDisconnect?: () => void;
        onError?: (error: Error) => void;
    }): void {
        this.ws.onopen = () => {
            config.onConnect?.();
        };
        
        this.ws.onmessage = (event) => {
            const message: TransportMessage = JSON.parse(event.data);
            this.handleMessage(message);
        };
        
        this.ws.onerror = (error) => {
            config.onError?.(new Error('WebSocket error'));
        };
        
        this.ws.onclose = () => {
            config.onDisconnect?.();
        };
    }
    
    private handleMessage(message: TransportMessage): void {
        switch (message.type) {
            case 'rpcResponse':
                const pending = this.pendingRPCs.get(message.requestID);
                if (pending) {
                    pending.resolve(message.response);
                    this.pendingRPCs.delete(message.requestID);
                }
                break;
                
            case 'event':
                const handlers = this.eventHandlers.get(message.realmID);
                if (handlers) {
                    if (message.event.type === 'fromServer') {
                        handlers.forEach(handler => handler(message.event.serverEvent));
                    }
                }
                break;
        }
    }
    
    close(): void {
        this.ws.close();
    }
}

// 使用範例
const client = new StateTreeClient({
    websocketURL: 'wss://api.example.com/ws/player-123',
    playerID: 'player-123',
    onConnect: () => console.log('Connected'),
    onDisconnect: () => console.log('Disconnected')
});

// 型別安全的 RPC 呼叫
const joinResponse = await client.join('game-room', 'player-123', 'Alice');

// 訂閱 Event
const unsubscribe = client.onEvent('game-room', (event) => {
    if (event.type === 'stateUpdate') {
        // 更新本地狀態
        updateLocalState(event.snapshot);
    } else if (event.type === 'gameEvent') {
        // 處理遊戲事件
        handleGameEvent(event.detail);
    }
});

// 發送 Event
client.sendEvent('game-room', {
    type: 'playerReady',
    playerID: 'player-123'
});
```

## Code-gen 架構設計

### 設計決策：必須使用中間格式（JSON Schema）

**核心設計決策**：Code-gen 架構**必須**採用兩階段設計：

1. **第一階段**：Swift → JSON Schema（中間格式）
2. **第二階段**：JSON Schema → 各語言 SDK

**為什麼必須使用中間格式？**

#### ❌ 不推薦：Swift 直接生成所有語言

```
Swift 定義 → Swift Generator → TypeScript / Kotlin / ...
```

**缺點**：
- **耦合度高**：Swift 工具需要知道所有目標語言
- **難以擴充**：新增語言需要修改 Swift 工具
- **難以重用**：其他工具無法使用
- **維護成本高**：所有生成邏輯集中在一個工具

#### ✅ 推薦：使用 JSON Schema 作為中間格式

```
Swift 定義 → JSON Schema → 各語言生成器（可獨立實作）
```

**優點**：
- **解耦**：Swift 工具只需輸出一次 JSON，不需要知道目標語言
- **獨立開發**：各語言生成器可以用不同語言實作（TypeScript 生成器可用 Node.js）
- **可重用**：JSON Schema 可以被其他工具使用（文檔生成、API 測試等）
- **可驗證**：JSON Schema 可以獨立驗證和測試
- **易擴充**：新增語言只需新增一個生成器，不需要修改 Swift 工具
- **版本控制**：JSON Schema 可以版本化，追蹤變更

### 設計目標

Code-gen 架構必須滿足以下需求：

1. **可擴充**：容易新增新的目標語言（Kotlin、Swift、Rust 等）
2. **模組化**：每個語言生成器獨立，互不影響
3. **可測試**：每個生成器可以獨立測試
4. **可維護**：清晰的架構，容易理解和修改
5. **解耦**：Swift 工具與目標語言生成器完全解耦

### 架構設計

```
┌─────────────────────────────────────────┐
│   Server Definition (Swift)             │
│   - StateTree                           │
│   - RPC / Event                         │
│   - Realm DSL                           │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│   Type Extractor (Swift)                │
│   - AST Analysis / Macro Output        │
│   - 提取型別資訊                        │
│   - 輸出：JSON Schema                   │
└─────────────────────────────────────────┘
              ↓
┌─────────────────────────────────────────┐
│   JSON Schema (中間格式)                │
│   - 語言無關的型別定義                  │
│   - Realm / RPC / Event 定義            │
│   - 可版本化、可驗證                    │
└─────────────────────────────────────────┘
              ↓
    ┌─────────┴─────────┐
    ↓                   ↓
┌──────────┐      ┌──────────┐
│ TypeScript│      │  Kotlin  │
│ Generator│      │ Generator│
│ (Node.js)│      │ (Kotlin) │
└──────────┘      └──────────┘
    ↓                   ↓
┌──────────┐      ┌──────────┐
│ TypeScript│      │  Kotlin  │
│   SDK    │      │   SDK    │
└──────────┘      └──────────┘
```

**關鍵設計要點**：
1. **JSON Schema 是必須的**：所有生成器都必須從 JSON Schema 讀取
2. **生成器可以獨立實作**：TypeScript 生成器可以用 Node.js 寫，Kotlin 生成器可以用 Kotlin 寫
3. **Swift 工具只負責提取**：不需要知道目標語言
4. **JSON Schema 可以重用**：文檔生成、API 測試等工具也可以使用

### 核心組件

#### 1. Type Extractor（型別提取器）

**職責**：從 Server 定義中提取型別資訊

**實作方式**：
- **Swift Macros**：在編譯時輸出型別資訊
- **AST Analysis**：分析 Swift AST，提取型別
- **Reflection**：執行時反射（不推薦，效能較差）

**輸出**：中間格式（JSON Schema / Protocol Buffer）

```swift
// Type Extractor 輸出範例
struct ExtractedTypeInfo {
    let stateTrees: [StateTreeInfo]
    let rpcs: [RPCInfo]
    let events: [EventInfo]
}

struct StateTreeInfo {
    let name: String
    let properties: [PropertyInfo]
}

struct PropertyInfo {
    let name: String
    let type: TypeInfo
    let syncPolicy: SyncPolicy
}
```

#### 2. Intermediate Format（中間格式）：JSON Schema

**職責**：語言無關的型別定義，**必須使用 JSON Schema**

**設計決策**：統一使用 JSON Schema 作為中間格式

**原因**：
- **標準化**：JSON Schema 是業界標準，工具支援豐富
- **易讀易寫**：人類可讀，容易除錯和驗證
- **語言無關**：任何語言都可以讀取和處理
- **可驗證**：可以使用 JSON Schema 驗證器驗證格式
- **可版本化**：可以追蹤變更歷史

**JSON Schema 結構範例**：

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "version": "1.0",
  "metadata": {
    "generatedAt": "2024-01-01T00:00:00Z",
    "sourceLanguage": "swift",
    "sourceVersion": "6.0",
    "extractorVersion": "1.0.0"
  },
  "realms": [
    {
      "id": "game-room",
      "stateTree": {
        "name": "GameStateTree",
        "properties": [
          {
            "name": "players",
            "type": {
              "kind": "dictionary",
              "keyType": "PlayerID",
              "valueType": "PlayerState"
            },
            "syncPolicy": {
              "type": "broadcast"
            }
          },
          {
            "name": "hands",
            "type": {
              "kind": "dictionary",
              "keyType": "PlayerID",
              "valueType": "HandState"
            },
            "syncPolicy": {
              "type": "perPlayer",
              "keyPath": "ownerID"
            }
          },
          {
            "name": "hiddenDeck",
            "type": {
              "kind": "array",
              "elementType": "Card"
            },
            "syncPolicy": {
              "type": "serverOnly"
            }
          }
        ]
      },
      "rpcs": [
        {
          "name": "join",
          "cases": [
            {
              "name": "join",
              "parameters": [
                {
                  "name": "playerID",
                  "type": "PlayerID"
                },
                {
                  "name": "name",
                  "type": "String"
                }
              ],
              "response": {
                "type": "JoinResponse",
                "includesState": true
              }
            }
          ]
        },
        {
          "name": "attack",
          "cases": [
            {
              "name": "attack",
              "parameters": [
                {
                  "name": "attacker",
                  "type": "PlayerID"
                },
                {
                  "name": "target",
                  "type": "PlayerID"
                },
                {
                  "name": "damage",
                  "type": "Int"
                }
              ],
              "response": {
                "type": "AttackResponse",
                "includesState": false
              }
            }
          ]
        }
      ],
      "events": {
        "clientEvents": [
          {
            "name": "playerReady",
            "parameters": [
              {
                "name": "playerID",
                "type": "PlayerID"
              }
            ],
            "allowed": true
          },
          {
            "name": "heartbeat",
            "parameters": [
              {
                "name": "timestamp",
                "type": "Date"
              }
            ],
            "allowed": true
          }
        ],
        "serverEvents": [
          {
            "name": "stateUpdate",
            "parameters": [
              {
                "name": "snapshot",
                "type": "GameStateSnapshot"
              }
            ]
          },
          {
            "name": "gameEvent",
            "parameters": [
              {
                "name": "detail",
                "type": "GameEventDetail"
              }
            ]
          }
        ]
      }
    }
  ],
  "types": {
    "PlayerID": {
      "kind": "alias",
      "underlyingType": "String"
    },
    "PlayerState": {
      "kind": "struct",
      "properties": [
        {
          "name": "name",
          "type": "String"
        },
        {
          "name": "hpCurrent",
          "type": "Int"
        },
        {
          "name": "hpMax",
          "type": "Int"
        }
      ]
    },
    "HandState": {
      "kind": "struct",
      "properties": [
        {
          "name": "ownerID",
          "type": "PlayerID"
        },
        {
          "name": "cards",
          "type": {
            "kind": "array",
            "elementType": "Card"
          }
        }
      ]
    },
    "Card": {
      "kind": "struct",
      "properties": [
        {
          "name": "id",
          "type": "Int"
        },
        {
          "name": "suit",
          "type": "Int"
        },
        {
          "name": "rank",
          "type": "Int"
        }
      ]
    },
    "GameStateSnapshot": {
      "kind": "struct",
      "properties": [
        {
          "name": "players",
          "type": {
            "kind": "dictionary",
            "keyType": "PlayerID",
            "valueType": "PlayerState"
          }
        },
        {
          "name": "hands",
          "type": {
            "kind": "dictionary",
            "keyType": "PlayerID",
            "valueType": "HandState"
          }
        }
      ]
    },
    "JoinResponse": {
      "kind": "struct",
      "properties": [
        {
          "name": "realmID",
          "type": "String"
        },
        {
          "name": "roomID",
          "type": "String"
        },
        {
          "name": "state",
          "type": "GameStateSnapshot",
          "optional": true
        }
      ]
    },
    "AttackResponse": {
      "kind": "struct",
      "properties": [
        {
          "name": "success",
          "type": "Bool"
        }
      ]
    },
    "GameEventDetail": {
      "kind": "enum",
      "cases": [
        {
          "name": "damage",
          "parameters": [
            {
              "name": "from",
              "type": "PlayerID"
            },
            {
              "name": "to",
              "type": "PlayerID"
            },
            {
              "name": "amount",
              "type": "Int"
            }
          ]
        },
        {
          "name": "playerJoined",
          "parameters": [
            {
              "name": "playerID",
              "type": "PlayerID"
            },
            {
              "name": "name",
              "type": "String"
            }
          ]
        }
      ]
    }
  }
}
```

**JSON Schema 的優勢**：
- **可驗證**：可以使用 JSON Schema 驗證器驗證格式正確性
- **可版本化**：可以追蹤變更歷史，比較不同版本
- **可重用**：文檔生成、API 測試等工具也可以使用
- **易除錯**：人類可讀，容易發現問題

#### 3. Generator Interface（生成器介面）

**職責**：定義統一的生成器介面（**不限定實作語言**）

**重要設計決策**：生成器可以用任何語言實作，只需要：
1. 讀取 JSON Schema
2. 生成目標語言的 SDK
3. 遵循統一的介面規範

**介面規範（語言無關）**：

```typescript
// TypeScript Generator 範例（可以用 Node.js 實作）
interface CodeGenerator {
    name: string;
    targetLanguage: string;
    
    // 從 JSON Schema 生成程式碼
    generate(
        schemaPath: string,
        config: GeneratorConfig
    ): Promise<GeneratedCode>;
    
    // 驗證生成的程式碼
    validate(code: GeneratedCode): Promise<void>;
}

interface GeneratorConfig {
    outputPath: string;
    packageName?: string;
    options: Record<string, any>;
}

interface GeneratedCode {
    files: GeneratedFile[];
}

interface GeneratedFile {
    path: string;
    content: string;
}
```

**各語言生成器可以獨立實作**：

```typescript
// TypeScript Generator（Node.js）
class TypeScriptGenerator implements CodeGenerator {
    name = "TypeScript";
    targetLanguage = "typescript";
    
    async generate(schemaPath: string, config: GeneratorConfig) {
        const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf-8'));
        // 生成 TypeScript SDK
        return { files: [...] };
    }
}
```

```kotlin
// Kotlin Generator（Kotlin）
class KotlinGenerator : CodeGenerator {
    override val name = "Kotlin"
    override val targetLanguage = "kotlin"
    
    override suspend fun generate(
        schemaPath: String,
        config: GeneratorConfig
    ): GeneratedCode {
        val schema = Json.decodeFromString<Schema>(File(schemaPath).readText())
        // 生成 Kotlin SDK
        return GeneratedCode(files = listOf(...))
    }
}
```

**優勢**：
- **語言無關**：生成器可以用最適合的語言實作
- **獨立開發**：每個生成器可以獨立開發和測試
- **易擴充**：新增語言只需新增一個生成器實作

#### 4. Template Engine（模板引擎）

**職責**：使用模板生成程式碼

**選擇**：
- **Stencil**：Swift 模板引擎，語法簡單
- **Mustache**：語言無關，但功能較少
- **自定義模板**：完全控制，但需要自己實作

**建議**：使用 Stencil（如果 Server 是 Swift）或 Mustache（如果需要跨語言）

### 實作範例

#### Stage 1: Type Extractor（Swift）

```swift
// StateTreeExtractor 實作範例
struct StateTreeExtractor {
    func extract(from sourcePath: String) throws -> Schema {
        // 1. 分析 Swift 源碼
        let ast = try parseSwiftAST(at: sourcePath)
        
        // 2. 提取型別資訊
        var schema = Schema(
            version: "1.0",
            metadata: Metadata(
                generatedAt: Date(),
                sourceLanguage: "swift",
                sourceVersion: "6.0"
            ),
            realms: [],
            types: [:]
        )
        
        // 3. 提取 StateTree 定義
        let stateTrees = try extractStateTrees(from: ast)
        schema.realms = try extractRealms(from: ast, stateTrees: stateTrees)
        
        // 4. 提取型別定義
        schema.types = try extractTypes(from: ast)
        
        // 5. 輸出 JSON Schema
        return schema
    }
    
    func writeSchema(_ schema: Schema, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(schema)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
```

#### Stage 2: TypeScript Generator（Node.js）

```typescript
// tools/typescript-generator/src/generator.ts
import * as fs from 'fs';
import * as path from 'path';

interface Schema {
    version: string;
    metadata: Metadata;
    realms: Realm[];
    types: Record<string, TypeInfo>;
}

class TypeScriptGenerator {
    async generate(schemaPath: string, outputPath: string): Promise<void> {
        // 1. 讀取 JSON Schema
        const schema: Schema = JSON.parse(
            fs.readFileSync(schemaPath, 'utf-8')
        );
        
        // 2. 生成型別定義
        const typeDefinitions = this.generateTypes(schema.types);
        fs.writeFileSync(
            path.join(outputPath, 'types.ts'),
            typeDefinitions
        );
        
        // 3. 生成客戶端 SDK
        const clientSDK = this.generateClientSDK(schema.realms);
        fs.writeFileSync(
            path.join(outputPath, 'client.ts'),
            clientSDK
        );
        
        // 4. 生成 package.json
        const packageJson = this.generatePackageJson();
        fs.writeFileSync(
            path.join(outputPath, 'package.json'),
            JSON.stringify(packageJson, null, 2)
        );
    }
    
    private generateTypes(types: Record<string, TypeInfo>): string {
        const lines: string[] = [];
        
        for (const [name, typeInfo] of Object.entries(types)) {
            switch (typeInfo.kind) {
                case 'alias':
                    lines.push(`export type ${name} = ${this.toTypeScriptType(typeInfo.underlyingType)};`);
                    break;
                    
                case 'struct':
                    lines.push(`export interface ${name} {`);
                    for (const prop of typeInfo.properties) {
                        const optional = prop.optional ? '?' : '';
                        lines.push(`  ${prop.name}${optional}: ${this.toTypeScriptType(prop.type)};`);
                    }
                    lines.push(`}`);
                    break;
                    
                case 'enum':
                    lines.push(`export type ${name} =`);
                    for (let i = 0; i < typeInfo.cases.length; i++) {
                        const case_ = typeInfo.cases[i];
                        const prefix = i === 0 ? '  ' : '| ';
                        lines.push(`${prefix}{ type: '${case_.name}'; ${this.generateCaseParams(case_.parameters)} }`);
                    }
                    lines.push(';');
                    break;
            }
            lines.push('');
        }
        
        return lines.join('\n');
    }
    
    private generateClientSDK(realms: Realm[]): string {
        // 生成客戶端 SDK 程式碼
        // （見前面的完整範例）
        return `// Generated Client SDK...`;
    }
    
    private toTypeScriptType(type: TypeInfo | string): string {
        if (typeof type === 'string') {
            return this.mapPrimitiveType(type);
        }
        
        switch (type.kind) {
            case 'array':
                return `${this.toTypeScriptType(type.elementType)}[]`;
            case 'dictionary':
                return `Record<${this.toTypeScriptType(type.keyType)}, ${this.toTypeScriptType(type.valueType)}>`;
            default:
                return type.name || 'unknown';
        }
    }
    
    private mapPrimitiveType(type: string): string {
        const mapping: Record<string, string> = {
            'String': 'string',
            'Int': 'number',
            'Bool': 'boolean',
            'Date': 'Date',
            'Double': 'number',
            'Float': 'number',
        };
        return mapping[type] || type;
    }
}

// CLI 入口
const generator = new TypeScriptGenerator();
generator.generate(process.argv[2], process.argv[3])
    .then(() => console.log('✅ TypeScript SDK generated successfully'))
    .catch(err => {
        console.error('❌ Error generating TypeScript SDK:', err);
        process.exit(1);
    });
```

#### 模板範例（Mustache，可選）

如果使用模板引擎，可以這樣寫：

```mustache
{{! types.ts.mustache }}
{{#types}}
{{#alias}}
export type {{name}} = {{underlyingType}};
{{/alias}}

{{#struct}}
export interface {{name}} {
{{#properties}}
  {{name}}{{#optional}}?{{/optional}}: {{type}};
{{/properties}}
}
{{/struct}}

{{#enum}}
export type {{name}} =
{{#cases}}
  {{#first}}  {{/first}}{{#notFirst}}| {{/notFirst}}{ type: '{{name}}'; {{#parameters}}{{name}}: {{type}}; {{/parameters}} }
{{/cases}};
{{/enum}}
{{/types}}
```

**使用模板**：

```typescript
import Mustache from 'mustache';

const template = fs.readFileSync('templates/types.ts.mustache', 'utf-8');
const output = Mustache.render(template, { types: schema.types });
```

### 擴充新語言

新增新語言生成器**完全獨立**，不需要修改 Swift 工具：

#### 步驟 1：建立生成器專案（可以用任何語言）

```bash
# 例如：建立 Kotlin 生成器
mkdir tools/kotlin-generator
cd tools/kotlin-generator

# 可以用 Kotlin、Node.js、Python 等任何語言實作
```

#### 步驟 2：實作生成器（讀取 JSON Schema）

```kotlin
// tools/kotlin-generator/src/main/kotlin/Generator.kt
class KotlinGenerator : CodeGenerator {
    override val name = "Kotlin"
    override val targetLanguage = "kotlin"
    
    override suspend fun generate(
        schemaPath: String,
        config: GeneratorConfig
    ): GeneratedCode {
        // 1. 讀取 JSON Schema
        val schema = Json.decodeFromString<Schema>(
            File(schemaPath).readText()
        )
        
        // 2. 生成 Kotlin 程式碼
        val typeDefinitions = generateTypes(schema.types)
        val clientSDK = generateClientSDK(schema.realms)
        
        // 3. 返回生成的檔案
        return GeneratedCode(
            files = listOf(
                GeneratedFile("types.kt", typeDefinitions),
                GeneratedFile("client.kt", clientSDK)
            )
        )
    }
    
    private fun generateTypes(types: Map<String, TypeInfo>): String {
        // 使用模板或直接生成
        return buildString {
            types.forEach { (name, info) ->
                appendLine(generateType(name, info))
            }
        }
    }
}
```

#### 步驟 3：建立模板檔案（可選）

```
tools/kotlin-generator/
├── templates/
│   ├── types.kt.mustache
│   └── client.kt.mustache
└── src/
    └── main/
        └── kotlin/
            └── Generator.kt
```

#### 步驟 4：整合到工作流程

```bash
# 在 generate-client-sdk.sh 中新增
echo "Generating Kotlin SDK..."
kotlin ./tools/kotlin-generator/main.kt \
  --input ./generated/schema.json \
  --output ./generated/kotlin
```

**關鍵優勢**：
- ✅ **完全獨立**：不需要修改 Swift 工具
- ✅ **語言自由**：可以用最適合的語言實作
- ✅ **易於測試**：可以獨立測試和驗證
- ✅ **版本獨立**：每個生成器可以獨立版本化

### 使用方式

#### 兩階段流程

**Stage 1：從 Swift 定義提取 JSON Schema**

```bash
# 使用 Swift 工具提取型別資訊，輸出 JSON Schema
swift run StateTreeExtractor \
  --input ./Sources/SwiftStateTree \
  --output ./generated/schema.json \
  --format json-schema
```

**Stage 2：從 JSON Schema 生成各語言 SDK**

```bash
# 生成 TypeScript SDK（使用 Node.js 工具）
node ./tools/typescript-generator/index.js \
  --input ./generated/schema.json \
  --output ./generated/typescript

# 生成 Kotlin SDK（使用 Kotlin 工具，未來）
kotlin ./tools/kotlin-generator/main.kt \
  --input ./generated/schema.json \
  --output ./generated/kotlin

# 或使用統一的 CLI（內部會呼叫對應的生成器）
swift run StateTreeCodeGen \
  --schema ./generated/schema.json \
  --target typescript \
  --output ./generated/typescript
```

#### 完整工作流程

```bash
# 1. 提取 JSON Schema
swift run StateTreeExtractor \
  --input ./Sources/SwiftStateTree \
  --output ./generated/schema.json

# 2. 驗證 JSON Schema（可選）
node ./tools/schema-validator/index.js \
  --input ./generated/schema.json

# 3. 生成 TypeScript SDK
node ./tools/typescript-generator/index.js \
  --input ./generated/schema.json \
  --output ./generated/typescript

# 4. 驗證生成的 TypeScript（可選）
cd ./generated/typescript && npm install && npm run type-check
```

#### Build Phase 整合

```swift
// Package.swift
let extractor = ExecutableTarget(
    name: "StateTreeExtractor",
    dependencies: [...]
)

// 在 build phase 中自動執行
// 當 Server 定義變更時，自動重新生成 JSON Schema
// 然後觸發各語言生成器重新生成 SDK
```

**自動化腳本範例**：

```bash
#!/bin/bash
# scripts/generate-client-sdk.sh

set -e

echo "Step 1: Extracting type information..."
swift run StateTreeExtractor \
  --input ./Sources/SwiftStateTree \
  --output ./generated/schema.json

echo "Step 2: Validating JSON Schema..."
node ./tools/schema-validator/index.js \
  --input ./generated/schema.json

echo "Step 3: Generating TypeScript SDK..."
node ./tools/typescript-generator/index.js \
  --input ./generated/schema.json \
  --output ./generated/typescript

echo "Step 4: Validating generated TypeScript..."
cd ./generated/typescript && npm install && npm run type-check

echo "✅ Client SDK generation completed!"
```

#### JSON Schema 的額外用途

JSON Schema 不僅用於生成 SDK，還可以用於：

1. **API 文檔生成**：
```bash
node ./tools/api-doc-generator/index.js \
  --input ./generated/schema.json \
  --output ./docs/api.md
```

2. **API 測試生成**：
```bash
node ./tools/test-generator/index.js \
  --input ./generated/schema.json \
  --output ./Tests/GeneratedAPITests.swift
```

3. **OpenAPI/Swagger 轉換**：
```bash
node ./tools/openapi-converter/index.js \
  --input ./generated/schema.json \
  --output ./generated/openapi.yaml
```

## 開發順序

### Phase 1：TypeScript 支援（優先）

1. **實作 Type Extractor**
   - 從 Swift 定義提取型別資訊
   - 輸出 JSON Schema

2. **實作 TypeScript Generator**
   - 生成型別定義
   - 生成客戶端 SDK
   - 建立模板檔案

3. **建立 CLI 工具**
   - 命令列介面
   - 整合到 Build Phase

4. **測試和驗證**
   - 生成程式碼測試
   - 型別一致性測試
   - 端到端測試

### Phase 2：架構優化

1. **優化 Intermediate Format**
   - 評估 Protocol Buffer
   - 優化 JSON Schema

2. **改進 Template Engine**
   - 更好的錯誤處理
   - 更豐富的模板功能

3. **文件生成**
   - 自動生成 API 文檔
   - 使用範例生成

### Phase 3：擴充其他語言

1. **Kotlin Generator**
2. **Swift Client Generator**
3. **其他語言（根據需求）**

## 相關文檔

- **[DESIGN_CORE.md](./DESIGN_CORE.md)**：StateTree 核心概念
- **[DESIGN_COMMUNICATION.md](./DESIGN_COMMUNICATION.md)**：RPC 與 Event 通訊模式
- **[DESIGN_REALM_DSL.md](./DESIGN_REALM_DSL.md)**：Realm DSL 定義
- **[APP_APPLICATION.md](./APP_APPLICATION.md)**：跨平台實現範例

