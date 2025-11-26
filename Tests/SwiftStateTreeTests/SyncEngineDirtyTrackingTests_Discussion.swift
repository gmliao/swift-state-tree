// Tests/SwiftStateTreeTests/SyncEngineDirtyTrackingTests_Discussion.swift
// 
// 討論用測試案例：說明 dirty tracking 在處理「cache 中不存在但新 snapshot 中存在」的情況

import Foundation
import Testing
@testable import SwiftStateTree

/// 測試案例：說明 dirty tracking 的行為邊界情況
@Suite("Dirty Tracking Behavior Discussion")
struct SyncEngineDirtyTrackingTests_Discussion {
    
    // MARK: - 情況 1: Optional 字段從 nil 變成有值（但沒有被標記為 dirty）
    
    @Test("Case 1: Optional field appears in snapshot but not in cache - should it generate patch?")
    func testCase1_OptionalFieldAppears() throws {
        // 場景：
        // - 第一次 sync: turn = nil，可能不會被包含在 snapshot 中（或包含為 null）
        // - 第二次 sync: turn 仍然是 nil，但這次被包含在 snapshot 中
        // - 問題：即使 turn 沒有被標記為 dirty，是否應該生成 patch？
        
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync: turn = nil
        state.round = 1
        // turn 默認是 nil，可能不會被包含在 snapshot 中
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // 不改變任何東西，但 turn 可能在這次 snapshot 中被包含
        // 問題：如果 turn 在 cache 中不存在，但在新 snapshot 中存在（即使是 nil），
        //       是否應該生成 patch？
        
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        
        // 選項 A：不生成 patch（因為沒有 dirty fields）
        // 選項 B：生成 patch（因為字段在 cache 中不存在）
        // 當前行為：選項 B（會生成 patch）
    }
    
    // MARK: - 情況 2: 字典字段新增了 key（但整個字典沒有被標記為 dirty）
    
    @Test("Case 2: Dictionary field adds new key but dictionary itself is not dirty")
    func testCase2_DictionaryAddsKey() throws {
        // 場景：
        // - 第一次 sync: players = [:]
        // - 外部修改（不通過 @Sync setter）: players["bob"] = "Bob"
        // - 問題：即使 players 沒有被標記為 dirty，是否應該檢測到新增的 key？
        
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync: players 是空的
        state.round = 1
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // 模擬外部修改（不通過 @Sync setter，所以不會標記為 dirty）
        // 注意：這在實際使用中不應該發生，但我們測試邊界情況
        // state.players["bob"] = "Bob"  // 如果直接修改，不會標記 dirty
        
        // 實際上，如果通過 @Sync setter，會標記為 dirty
        state.players[PlayerID("bob")] = "Bob"  // 這會標記 players 為 dirty
        
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        
        // 選項 A：只檢測 dirty 字段（players），生成 players 的完整 patch
        // 選項 B：檢測所有字段，但只對 dirty 字段生成 patch
        // 當前行為：選項 A（會生成 patch，因為 players 是 dirty）
    }
    
    // MARK: - 情況 3: 第一次 sync 時字段沒有被包含，後續 sync 時出現了
    
    @Test("Case 3: Field missing in first sync but appears in second sync")
    func testCase3_FieldMissingInFirstSync() throws {
        // 場景：
        // - 第一次 sync: 某些字段（如 turn）可能因為是 nil 而不被包含
        // - 第二次 sync: turn 仍然是 nil，但這次被包含在 snapshot 中
        // - 問題：這是否應該被視為「新增」？
        
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync: 只設置 round，turn 保持 nil
        state.round = 1
        // turn 是 nil，可能不會被包含在 snapshot 中
        let firstUpdate = try syncEngine.generateDiff(for: playerID, from: state)
        
        // 檢查第一次 sync 的 snapshot 是否包含 turn
        if case .firstSync(let patches) = firstUpdate {
            _ = patches.contains { $0.path == "/turn" }
        }
        
        state.clearDirty()
        
        // 不改變任何東西
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        
        // 問題：如果 turn 在第一次 snapshot 中不存在，但在第二次中存在，
        //       是否應該生成 patch？
        
        // 選項 A：不生成 patch（因為沒有 dirty fields，且值沒有改變）
        // 選項 B：生成 patch（因為字段在 cache 中不存在，視為新增）
        // 當前行為：選項 B（會生成 patch）
    }
    
    // MARK: - 情況 4: 嵌套對象中的字段新增
    
    @Test("Case 4: Nested object field appears but parent is not dirty")
    func testCase4_NestedObjectFieldAppears() throws {
        // 場景：
        // - 第一次 sync: players = ["alice": "Alice"]
        // - 外部修改: players["bob"] = "Bob"（但 players 沒有被標記為 dirty）
        // - 問題：是否應該檢測到新增的 key？
        
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync
        state.round = 1
        state.players[playerID] = "Alice"
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // 只改變 round（只有 round 是 dirty）
        state.round = 2
        // players 沒有改變，所以不會被標記為 dirty
        
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        
        // 問題：如果 players 在 cache 中是 ["alice": "Alice"]，
        //       但在新 snapshot 中是 ["alice": "Alice", "bob": "Bob"]，
        //       是否應該檢測到新增的 "bob"？
        
        // 選項 A：不檢測（因為 players 不是 dirty）
        // 選項 B：檢測（因為比較所有字段，但只對 dirty 字段生成 patch）
        // 當前行為：選項 A（不會檢測，因為只比較 dirty 字段）
    }
    
    // MARK: - 情況 5: 字段從有值變成 nil
    
    @Test("Case 5: Field changes from value to nil")
    func testCase5_FieldChangesToNil() throws {
        // 場景：
        // - 第一次 sync: turn = PlayerID("alice")
        // - 第二次 sync: turn = nil（但沒有被標記為 dirty）
        // - 問題：是否應該生成 delete patch？
        
        var syncEngine = SyncEngine()
        var state = DiffTestStateRootNode()
        let playerID = PlayerID("alice")
        
        // First sync: turn 有值
        state.round = 1
        state.turn = playerID
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // 模擬 turn 變成 nil（但沒有被標記為 dirty）
        // 注意：這在實際使用中不應該發生，因為 @Sync setter 會標記 dirty
        state.turn = nil  // 這會標記 turn 為 dirty
        
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        
        // 問題：如果 turn 在 cache 中有值，但在新 snapshot 中是 nil，
        //       是否應該生成 delete patch？
        
        // 選項 A：不生成 patch（因為 turn 不是 dirty）
        // 選項 B：生成 delete patch（因為 turn 是 dirty）
        // 當前行為：選項 B（會生成 delete patch，因為 turn 是 dirty）
    }
}

