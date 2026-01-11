import Testing
import Foundation
@testable import SwiftStateTree

@Suite("DeterministicHash Tests")
struct DeterministicHashTests {
    
    // MARK: - FNV-1a 64-bit Tests
    
    @Test("fnv1a64 produces consistent hash for same input")
    func fnv1a64Consistency() {
        let input = Data("hello world".utf8)
        let hash1 = DeterministicHash.fnv1a64(input)
        let hash2 = DeterministicHash.fnv1a64(input)
        #expect(hash1 == hash2)
    }
    
    @Test("fnv1a64 produces different hashes for different inputs")
    func fnv1a64Difference() {
        let hash1 = DeterministicHash.fnv1a64("hello")
        let hash2 = DeterministicHash.fnv1a64("world")
        #expect(hash1 != hash2)
    }
    
    @Test("fnv1a64 matches known FNV-1a test vector for empty string")
    func fnv1a64EmptyString() {
        // FNV-1a 64-bit offset basis for empty input
        let hash = DeterministicHash.fnv1a64("")
        #expect(hash == 14695981039346656037) // FNV offset basis
    }
    
    @Test("fnv1a64 string and data produce same result")
    func fnv1a64StringDataEquivalence() {
        let string = "test string"
        let hashFromString = DeterministicHash.fnv1a64(string)
        let hashFromData = DeterministicHash.fnv1a64(Data(string.utf8))
        #expect(hashFromString == hashFromData)
    }
    
    // MARK: - FNV-1a 32-bit Tests
    
    @Test("fnv1a32 produces consistent hash for same input")
    func fnv1a32Consistency() {
        let input = Data("hello world".utf8)
        let hash1 = DeterministicHash.fnv1a32(input)
        let hash2 = DeterministicHash.fnv1a32(input)
        #expect(hash1 == hash2)
    }
    
    @Test("fnv1a32 produces different hashes for different inputs")
    func fnv1a32Difference() {
        let hash1 = DeterministicHash.fnv1a32("abc")
        let hash2 = DeterministicHash.fnv1a32("xyz")
        #expect(hash1 != hash2)
    }
    
    // MARK: - stableInt32 Tests
    
    @Test("stableInt32 produces positive values")
    func stableInt32Positive() {
        // Test with various inputs to ensure all produce positive values
        let testCases = ["user1", "user2", "guest-abc-123", "player@example.com", ""]
        for input in testCases {
            let hash = DeterministicHash.stableInt32(input)
            #expect(hash >= 0, "stableInt32 should produce non-negative values for '\(input)'")
        }
    }
    
    @Test("stableInt32 produces consistent results")
    func stableInt32Consistency() {
        let accountKey = "user@example.com"
        let slot1 = DeterministicHash.stableInt32(accountKey)
        let slot2 = DeterministicHash.stableInt32(accountKey)
        #expect(slot1 == slot2)
    }
    
    @Test("stableInt32 produces different slots for different users")
    func stableInt32Distribution() {
        let slot1 = DeterministicHash.stableInt32("player1")
        let slot2 = DeterministicHash.stableInt32("player2")
        #expect(slot1 != slot2)
    }
    
    // MARK: - Hex Conversion Tests
    
    @Test("toHex64 produces 16-character string")
    func toHex64Length() {
        let hex = DeterministicHash.toHex64(12345)
        #expect(hex.count == 16)
    }
    
    @Test("toHex64 is zero-padded")
    func toHex64ZeroPadded() {
        let hex = DeterministicHash.toHex64(0)
        #expect(hex == "0000000000000000")
    }
    
    @Test("toHex32 produces 8-character string")
    func toHex32Length() {
        let hex = DeterministicHash.toHex32(12345)
        #expect(hex.count == 8)
    }
    
    @Test("toHex32 is zero-padded")
    func toHex32ZeroPadded() {
        let hex = DeterministicHash.toHex32(0)
        #expect(hex == "00000000")
    }
    
    // MARK: - Cross-platform Determinism
    
    @Test("Hash values are deterministic across multiple calls")
    func crossCallDeterminism() {
        // Run 100 iterations to ensure no randomization
        let input = "deterministic-test-input"
        let expectedHash = DeterministicHash.fnv1a64(input)
        
        for i in 0..<100 {
            let hash = DeterministicHash.fnv1a64(input)
            #expect(hash == expectedHash, "Hash should be identical on iteration \(i)")
        }
    }
}
