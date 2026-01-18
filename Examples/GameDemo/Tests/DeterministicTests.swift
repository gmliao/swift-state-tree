// Examples/GameDemo/Tests/DeterministicTests.swift

import Testing
import Foundation
import Logging
@testable import GameContent
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

struct DeterministicTests {
    
    @Test("Deterministic RNG produces consistent sequence from same seed")
    func testRngConsistency() {
        let seed: UInt64 = 12345
        let rng1 = DeterministicRngService(seed: seed)
        let rng2 = DeterministicRngService(seed: seed)
        
        for _ in 0..<100 {
            let v1 = rng1.nextInt(in: 0...100)
            let v2 = rng2.nextInt(in: 0...100)
            #expect(v1 == v2)
            
            let f1 = rng1.nextFloat(in: 0.0..<1.0)
            let f2 = rng2.nextFloat(in: 0.0..<1.0)
            #expect(f1 == f2)
        }
    }
    
    @Test("Deterministic RNG produces different sequence from different seed")
    func testRngVariance() {
        let rng1 = DeterministicRngService(seed: 12345)
        let rng2 = DeterministicRngService(seed: 67890)
        
        var differences = 0
        for _ in 0..<100 {
            if rng1.nextInt(in: 0...100) != rng2.nextInt(in: 0...100) {
                differences += 1
            }
        }
        #expect(differences > 0)
    }
    
    @Test("LandID hashing is deterministic")
    func testLandIDHashing() {
        let landID1 = "game:room-1"
        let landID2 = "game:room-1"
        let landID3 = "game:room-2"
        
        let seed1 = DeterministicSeed.fromLandID(landID1)
        let seed2 = DeterministicSeed.fromLandID(landID2)
        let seed3 = DeterministicSeed.fromLandID(landID3)
        
        #expect(seed1 == seed2)
        #expect(seed1 != seed3)
    }
    
    @Test("Simulation is deterministic with same seed")
    func testSimulationDeterminism() async throws {
        // Run two separate simulations with the same landID (same seed)
        let landID = LandID("hero-defense:test-room")
        
        let state1 = await runSimulation(landID: landID, steps: 50)
        let state2 = await runSimulation(landID: landID, steps: 50)
        
        // Verify states match exactly
        #expect(state1.monsters.count == state2.monsters.count)
        #expect(state1.score == state2.score)
        
        for (id, m1) in state1.monsters {
            guard let m2 = state2.monsters[id] else {
                Issue.record("Monster \(id) missing in simulation 2")
                continue
            }
            #expect(m1.position == m2.position)
            #expect(m1.health == m2.health)
        }
    }
    
    // Helper to run a short simulation
    func runSimulation(landID: LandID, steps: Int) async -> HeroDefenseState {
        // Setup configuration
        let configProvider = DefaultGameConfigProvider()
        
        // Setup Services
        var services = LandServices()
        services.register(GameConfigProviderService(provider: configProvider), as: GameConfigProviderService.self)
        let seed = DeterministicSeed.fromLandID(landID.stringValue)
        services.register(DeterministicRngService(seed: seed), as: DeterministicRngService.self)
        
        // Create Land
        let definition = HeroDefense.makeLand()
        var state = HeroDefenseState()
        
        // Create Context
        let ctx = LandContext(
            landID: landID.stringValue,
            playerID: LandContext.systemPlayerID,
            clientID: LandContext.systemClientID,
            sessionID: LandContext.systemSessionID,
            services: services,
            logger: createGameLogger(scope: "Test", logLevel: .error),
            tickId: 0, // Start at tick 0
            sendEventHandler: { _, _ in },
            syncHandler: { }
        )
        
        // Run ticks
        // Note: We need to access the tick handler from the definition
        guard let tickHandler = definition.lifetimeHandlers.tickHandler else {
            fatalError("No tick handler found")
        }
        
        for i in 0..<steps {
            // Update tickId in context
            let stepCtx = LandContext(
                landID: landID.stringValue,
                playerID: LandContext.systemPlayerID,
                clientID: LandContext.systemClientID,
                sessionID: LandContext.systemSessionID,
                services: services,
                logger: ctx.logger,
                tickId: Int64(i),
                sendEventHandler: { _, _ in },
                syncHandler: { }
            )
            
            tickHandler(&state, stepCtx)
        }
        
        return state
    }
}
