[English](README.md) | [中文版](README.zh-TW.md)

# 確定性數學運算

`SwiftStateTreeDeterministicMath` 模組為伺服器權威遊戲提供確定性的整數基礎數學運算。所有操作都使用 Int32 固定點運算，確保在不同平台和重播中行為一致。

## 概述

此模組專為需要以下功能的遊戲設計：
- **確定性計算** - 相同輸入在不同平台上產生相同輸出
- **重播支援** - 遊戲狀態可以完全按照發生時的方式重播
- **伺服器權威** - 伺服器控制所有遊戲邏輯，客戶端進行插值
- **高效能** - SIMD 優化的向量運算，用於高效能碰撞檢測

## 核心組件

### 固定點運算

- **`FixedPoint`** - 集中式固定點轉換工具
  - 比例因子：1000 (1.0 Float = 1000 Int32)
  - `quantize()` - 將 Float 轉換為 Int32
  - `dequantize()` - 將 Int32 轉換為 Float

### 向量類型

- **`IVec2`** - 2D 整數向量，帶 SIMD 優化
  - 算術運算 (+, -, *)
  - 點積、叉積
  - 距離計算
  - 角度轉換
  - 反射和投影

- **`IVec3`** - 3D 整數向量，帶 SIMD 優化
  - 類似 IVec2 的操作，擴展到 3D

### 語義類型

類型安全的包裝器，防止誤用：
- **`Position2`** - 2D 空間中的位置
- **`Velocity2`** - 速度向量
- **`Acceleration2`** - 加速度向量

### 碰撞檢測

完整的 2D 碰撞檢測套件：
- **`IAABB2`** - 軸對齊邊界框
  - 點包含檢測
  - 框相交檢測
  - 限制、擴展、合併

- **`ICircle`** - 圓形碰撞
  - 圓-圓相交
  - 圓-AABB 相交
  - 點包含檢測

- **`IRay`** - 射線檢測（用於子彈判定）
  - 射線-AABB 相交
  - 射線-圓相交

- **`ILineSegment`** - 線段運算
  - 點到線段距離
  - 線段-線段相交
  - 線段-圓相交

### 網格工具

- **`Grid2`** - 基於網格的座標轉換
  - 世界座標到網格座標轉換
  - 網格座標到世界座標轉換
  - 對齊到網格

### 溢出處理

- **`OverflowPolicy`** - 集中式溢出行為
  - 包裝、限制、陷阱

## 使用範例

```swift
import SwiftStateTreeDeterministicMath

// 使用 Float 創建位置（更直觀）
let playerPos = Position2(x: 1.5, y: 2.3)

// 創建速度
let velocity = Velocity2(x: 0.1, y: 0.05)

// 更新位置（確定性整數運算）
let newPos = Position2(v: playerPos.v + velocity.v)

// 碰撞檢測
let circle = ICircle(center: IVec2(x: 0.0, y: 0.0), radius: 0.5)
let box = IAABB2(min: IVec2(x: -1.0, y: -1.0), max: IVec2(x: 1.0, y: 1.0))

if circle.intersects(aabb: box) {
    // 處理碰撞
}

// 射線檢測用於子彈判定
let ray = IRay(origin: IVec2(x: 0.0, y: 0.0), direction: IVec2(x: 1.0, y: 0.0))
if let (hitPoint, distance) = ray.intersects(aabb: box) {
    // 子彈擊中框體於 hitPoint
}
```

## 客戶端整合

### 自動轉換

TypeScript SDK 會自動將固定點整數轉換為浮點數：

```typescript
// 伺服器發送：{ x: 1500, y: 2300 }
// 客戶端接收：{ x: 1.5, y: 2.3 }（自動轉換）

const pos = game.state.playerPositions['player1']
// pos.v.x 和 pos.v.y 已經是浮點數，可直接使用
```

### 手動轉換輔助函數

如果需要，也可以使用轉換輔助函數：

```typescript
import { IVec2ToFloat, FloatToIVec2 } from './generated/defs'

const vec: IVec2 = { x: 1500, y: 2300 }
const float = IVec2ToFloat(vec)  // { x: 1.5, y: 2.3 }
```

## 效能

所有向量運算都使用 SIMD（單指令多數據）加速：
- 向量加減法：並行 SIMD 運算
- 點積：SIMD 並行乘法
- 距離計算：SIMD 並行平方運算
- 所有操作都標記為 `@inlinable` 以允許編譯器優化

## 確定性規則

有關維護確定性的詳細規則，請參閱[確定性規則](../../Sources/SwiftStateTreeDeterministicMath/Docs/DeterminismRules.md)。

關鍵原則：
- ✅ 僅使用整數運算
- ✅ 對 Float 值使用固定點量化
- ❌ 在 tick 邏輯中不使用 Float 運算
- ❌ 不使用平台特定的數學庫

## Schema 生成

所有 DeterministicMath 類型都會自動包含在 schema 生成中：
- 類型會導出到 JSON Schema
- TypeScript codegen 會生成對應的類型
- 客戶端轉換輔助函數會自動生成

## 測試

所有類型在 `SwiftStateTreeDeterministicMathTests` 中都有完整的單元測試：
- 固定點轉換測試
- 向量運算測試
- 碰撞檢測測試
- 與 StateNode 的整合測試

執行測試：
```bash
swift test --filter SwiftStateTreeDeterministicMathTests
```
