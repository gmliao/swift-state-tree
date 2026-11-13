// Examples/GameDemo/Tests/StateLayoutPinTests.swift
//
// The memory layout of Hero Defense's node types (#520). `Sync` stores only the value and its
// dirty flag, so a node of trivially copyable values is trivially copyable: a monster is copied
// by memcpy, not through value witnesses. Before #520, with a policy in every wrapper:
// MonsterState size 281 / stride 288, PlayerState stride 296, TurretState stride 232, none POD.

import Testing
@testable import GameContent

@Suite("Hero Defense state layout")
struct StateLayoutPinTests {
    @Test("MonsterState is trivially copyable, 96 bytes per element")
    func monster() {
        #expect(_isPOD(MonsterState.self))
        #expect(MemoryLayout<MonsterState>.size == 89)
        #expect(MemoryLayout<MonsterState>.stride == 96)
    }

    @Test("PlayerState is trivially copyable, 112 bytes per element")
    func player() {
        #expect(_isPOD(PlayerState.self))
        #expect(MemoryLayout<PlayerState>.size == 105)
        #expect(MemoryLayout<PlayerState>.stride == 112)
    }

    @Test("TurretState holds a String (its owner's PlayerID), 88 bytes per element")
    func turret() {
        #expect(!_isPOD(TurretState.self))
        #expect(MemoryLayout<TurretState>.size == 81)
        #expect(MemoryLayout<TurretState>.stride == 88)
    }
}
