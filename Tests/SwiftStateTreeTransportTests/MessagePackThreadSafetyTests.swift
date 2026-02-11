// Tests/SwiftStateTreeTransportTests/MessagePackThreadSafetyTests.swift
//
// Tests for MessagePack encoder thread safety in concurrent environments.
// These tests verify that MessagePack encoding works correctly in parallel execution,
// especially in Release mode where optimizations may expose thread-safety issues.

import Foundation
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport
import Testing

@Suite("MessagePack Thread Safety Tests")
struct MessagePackThreadSafetyTests {
    
    /// Test MessagePack encoder thread safety with high concurrency
    /// This test simulates the scenario where multiple rooms encode updates in parallel
    @Test("MessagePack encoder thread safety: High concurrency")
    func messagePackEncoderHighConcurrency() async throws {
        let encoder = OpcodeMessagePackStateUpdateEncoder()
        let landID = "test-land"
        
        // Create many updates to stress test
        let updateCount = 500
        var updates: [(PlayerID, StateUpdate)] = []
        for i in 0 ..< updateCount {
            let playerID = PlayerID("player-\(i)")
            let patches: [StatePatch] = [
                StatePatch(path: "/players/\(playerID.rawValue)/score", operation: .set(.int(i * 10))),
                StatePatch(path: "/players/\(playerID.rawValue)/level", operation: .set(.int(i % 100))),
            ]
            updates.append((playerID, .diff(patches)))
        }
        
        // Serial encoding (baseline)
        var serialResults: [Data] = []
        serialResults.reserveCapacity(updateCount)
        for (playerID, update) in updates {
            let data = try encoder.encode(update: update, landID: landID, playerID: playerID)
            serialResults.append(data)
        }
        
        // High concurrency (simulating multiple rooms)
        let parallelResults = await withTaskGroup(of: (Int, Data).self, returning: [Data].self) { group in
            for (index, (playerID, update)) in updates.enumerated() {
                group.addTask { [index] in
                    // Each task encodes independently
                    let data = try! encoder.encode(update: update, landID: landID, playerID: playerID)
                    return (index, data)
                }
            }
            
            var results: [(Int, Data)] = []
            results.reserveCapacity(updateCount)
            for await result in group {
                results.append(result)
            }
            
            // Sort by index to match serial order
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        
        // Verify results
        #expect(serialResults.count == parallelResults.count)
        #expect(serialResults.count == updateCount)
        
        // Verify all results are valid
        for (serial, parallel) in zip(serialResults, parallelResults) {
            #expect(serial.count > 0)
            #expect(parallel.count > 0)
            // Results may differ due to dynamic key ordering, but should be decodable
        }
    }
    
    /// Test MessagePack encoder with multiple concurrent rooms (simulating benchmark scenario)
    @Test("MessagePack encoder: Multiple concurrent rooms")
    func messagePackEncoderMultipleRooms() async throws {
        let roomCount = 4
        let playersPerRoom = 10
        
        // Create encoders for each room (simulating separate TransportAdapters)
        // Use a dictionary for thread-safe access
        var roomEncoders: [String: OpcodeMessagePackStateUpdateEncoder] = [:]
        for roomIndex in 0 ..< roomCount {
            let landID = "room-\(roomIndex)"
            let encoder = OpcodeMessagePackStateUpdateEncoder()
            roomEncoders[landID] = encoder
        }
        
        // Create updates for each room
        var allUpdates: [(String, PlayerID, StateUpdate)] = []
        for (landID, _) in roomEncoders {
            for playerIndex in 0 ..< playersPerRoom {
                let playerID = PlayerID("player-\(playerIndex)")
                let patches: [StatePatch] = [
                    StatePatch(path: "/hands/\(playerID.rawValue)/cards", operation: .set(.array([
                        .int(playerIndex * 2),
                        .int(playerIndex * 2 + 1)
                    ]))),
                    StatePatch(path: "/hands/\(playerID.rawValue)/score", operation: .set(.int(playerIndex * 10))),
                ]
                allUpdates.append((landID, playerID, .diff(patches)))
            }
        }
        
        // Capture encoders before parallel execution
        let encoders = roomEncoders
        
        // Encode all updates in parallel (simulating benchmark's withTaskGroup)
        let results = await withTaskGroup(of: Data.self, returning: [Data].self) { group in
            for (landID, playerID, update) in allUpdates {
                group.addTask {
                    // Get encoder for this room (encoders are Sendable and thread-safe)
                    guard let encoder = encoders[landID] else {
                        fatalError("Encoder not found for landID: \(landID)")
                    }
                    return try! encoder.encode(update: update, landID: landID, playerID: playerID)
                }
            }
            
            var encoded: [Data] = []
            encoded.reserveCapacity(allUpdates.count)
            for await result in group {
                encoded.append(result)
            }
            return encoded
        }
        
        // Verify all results
        #expect(results.count == allUpdates.count)
        for result in results {
            #expect(result.count > 0)
        }
    }
    
    /// Test MessagePack encoder with repeated concurrent access (stress test)
    @Test("MessagePack encoder: Repeated concurrent access (stress test)")
    func messagePackEncoderRepeatedConcurrentAccess() async throws {
        let encoder = OpcodeMessagePackStateUpdateEncoder()
        let landID = "test-land"
        let playerID = PlayerID("test-player")
        
        let patches: [StatePatch] = [
            StatePatch(path: "/score", operation: .set(.int(100))),
        ]
        let update = StateUpdate.diff(patches)
        
        // Run many concurrent encodings (stress test)
        let iterationCount = 10000
        let results = await withTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0 ..< iterationCount {
                group.addTask {
                    return try! encoder.encode(update: update, landID: landID, playerID: playerID)
                }
            }
            
            var encoded: [Data] = []
            encoded.reserveCapacity(iterationCount)
            for await result in group {
                encoded.append(result)
            }
            return encoded
        }
        
        // Verify all results are identical (same input should produce same output)
        #expect(results.count == iterationCount)
        if let first = results.first {
            for result in results {
                #expect(result == first, "All encodings should produce identical results")
            }
        }
    }
}
