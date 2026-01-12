
import Testing
import Foundation
@testable import SwiftStateTree

/// Test PathHasher logic (Trie-based resolution).
@Suite("PathHasher Tests")
struct PathHasherTests {
    
    @Test("Simple static path resolution")
    func testSimpleStaticPath() {
        // Schema:
        // round -> 0x1111
        // score -> 0x2222
        let hashes: [String: UInt32] = [
            "round": 0x1111,
            "score": 0x2222
        ]
        
        let hasher = PathHasher(pathHashes: hashes)
        
        // Test /round
        let (hash1, key1) = hasher.split("/round")
        #expect(hash1 == 0x1111)
        #expect(key1 == nil)
        
        // Test /score
        let (hash2, key2) = hasher.split("/score")
        #expect(hash2 == 0x2222)
        #expect(key2 == nil)
    }
    
    @Test("Map path resolution (single level)")
    func testMapPath() {
        // Schema:
        // players.*.hp -> 0x3333
        // players.*.id -> 0x4444
        let hashes: [String: UInt32] = [
            "players.*.hp": 0x3333,
            "players.*.id": 0x4444
        ]
        
        let hasher = PathHasher(pathHashes: hashes)
        
        // Test /players/123/hp
        let (hash1, key1) = hasher.split("/players/123/hp")
        #expect(hash1 == 0x3333)
        #expect(key1 == "123")
        
        // Test /players/abc-def/id
        let (hash2, key2) = hasher.split("/players/abc-def/id")
        #expect(hash2 == 0x4444)
        #expect(key2 == "abc-def")
    }
    
    @Test("Nested map path resolution (multi level)")
    func testNestedMapPath() {
        // Schema:
        // guilds.*.members.*.name -> 0x5555
        // guilds.*.members.*.level -> 0x6666
        let hashes: [String: UInt32] = [
            "guilds.*.members.*.name": 0x5555,
            "guilds.*.members.*.level": 0x6666
        ]
        
        let hasher = PathHasher(pathHashes: hashes)
        
        // Test /guilds/g1/members/m2/name
        // Note: The system currently only captures the FIRST dynamic key encountered.
        // This is specified in PathHasher.split documentation.
        let (hash1, key1) = hasher.split("/guilds/g1/members/m2/name")
        #expect(hash1 == 0x5555)
        #expect(key1 == "g1")
        
        let (hash2, key2) = hasher.split("/guilds/777/members/888/level")
        #expect(hash2 == 0x6666)
        #expect(key2 == "777")
    }
    
    @Test("Complex static structure inside map")
    func testComplexStaticStructureInsideMap() {
        // Schema:
        // monsters.*.position.v.x -> 0x7777
        // monsters.*.position.v.y -> 0x8888
        // This was the specific failure case: 
        // /monsters/6/position would fail with naive normalization which expected monsters.*.position
        // but if we were accessing a sub-property, e.g. .x, it might send a different path.
        // Actually the failure was simpler: the server side naive logic turned "/monsters/6/position" -> "monsters.*.position"
        // but also turned "/monsters/6/position/v/x" -> "monsters.*.position.*.x" (incorrectly assuming intermediate 'v' was dynamic?)
        // The Trie logic should strictly follow the schema.
        
        let hashes: [String: UInt32] = [
            "monsters.*.position": 0xAAAA,
            "monsters.*.position.v": 0xBBBB,
            "monsters.*.position.v.x": 0x7777,
            "monsters.*.position.v.y": 0x8888
        ]
        
        let hasher = PathHasher(pathHashes: hashes)
        
        // Test deep path
        let (hash1, key1) = hasher.split("/monsters/6/position/v/x")
        #expect(hash1 == 0x7777, "Should match specific leaf path hash")
        #expect(key1 == "6")
        
        // Test intermediate path (if sent as diff)
        let (hash2, key2) = hasher.split("/monsters/6/position")
        #expect(hash2 == 0xAAAA)
        #expect(key2 == "6")
    }
    
    @Test("Handling of non-matching paths (fallback)")
    func testFallbackBehavior() {
        // Schema:
        // known -> 0x1111
        let hashes: [String: UInt32] = [
            "known": 0x1111
        ]
        
        let hasher = PathHasher(pathHashes: hashes)
        
        // Unknown path: /unknown
        // Should fallback to FNV1a of "unknown"
        let (hash1, _) = hasher.split("/unknown")
        #expect(hash1 != 0x1111)
        #expect(hash1 == DeterministicHash.fnv1a32("unknown"))
        
        // Unknown dynamic path: /unknown/123
        // Should fallback to naive normalization: unknown.* -> FNV1a("unknown.*")
        let (hash2, key2) = hasher.split("/unknown/123")
        #expect(key2 == nil) // Naive fallback doesn't capture key reliably or maybe it does?
        // Let's check fallback implementation:
        // normalizePathFallback returns (pattern, dynamicKey)
        // /unknown/123 -> components [unknown, 123] -> pattern "unknown.*", key "123" if intermediate?
        // Actually normalizePathFallback for 2 components:
        // index 0: "unknown" -> append "unknown"
        // index 1: "123" -> append "123" (last component is static in fallback)
        // so pattern is "unknown.123". Wait, 
        // The fallback logic:
        // if index == 0 || index == count-1 -> static.
        // So /unknown/123 -> unknown.123
        // /unknown/123/prop -> unknown.*.prop (123 becomes *)
        
        let (hash3, _) = hasher.split("/unknown/123/prop")
        // fallback pattern: unknown.*.prop
        #expect(hash3 == DeterministicHash.fnv1a32("unknown.*.prop"))
    }
}
