import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath
@testable import GameContent

/// Hero Defense state updates on the wire with positional atomic values: a fixed patch list
/// with int32-sized coordinates through the schema's path hashes, so every size is exact.
@Suite("Hero Defense wire bytes")
struct HeroDefenseWireBytesTests {
    static func pathHashes() throws -> [String: UInt32] {
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(HeroDefense.makeLand())])
        return try #require(schema.lands["hero-defense"]?.pathHashes)
    }

    /// Two moved players (position and rotation) and one moved monster.
    static func patches() throws -> [StatePatch] {
        func set(_ path: String, _ value: some SnapshotValueConvertible) throws -> StatePatch {
            StatePatch(path: path, operation: .set(try value.toSnapshotValue()))
        }
        return [
            try set("/players/p1/position", Position2(x: 70, y: 80)),
            try set("/players/p1/rotation", Angle(degrees: 90.5)),
            try set("/players/p2/position", Position2(x: -70, y: 75)),
            try set("/players/p2/rotation", Angle(degrees: -45.25)),
            try set("/monsters/7/position", Position2(x: 100, y: -90)),
        ]
    }

    static func frameSize(atomicValues: AtomicValueEncoding) throws -> Int {
        // Field merge and the path index off: this pins the atomic values' sizes, entry by entry,
        // with 32-bit path hashes.
        let config = TransportEncodingConfig(
            message: .messagepack, stateUpdate: .opcodeMessagePack, atomicValues: atomicValues, pathIndex: false, fieldMerge: false
        )
        let encoder = config.makeStateUpdateEncoder(
            pathHashes: try pathHashes(),
            atomicLayout: AtomicLayoutTable.forState(HeroDefenseState.self)
        )
        // The second diff: every dynamic key is a slot by then, as in a running game.
        _ = try encoder.encode(update: .diff(try patches()), landID: "hero-defense:wire", playerID: PlayerID("viewer"))
        return try encoder.encode(update: .diff(try patches()), landID: "hero-defense:wire", playerID: PlayerID("viewer")).count
    }

    @Test("Positional values save 7 B per position and 8 B per rotation over keyed, at the same framing")
    func positionalSavings() throws {
        let positional = try Self.frameSize(atomicValues: .positional)
        let keyed = try Self.frameSize(atomicValues: .keyed)
        // 3 positions x 7 B + 2 rotations x 8 B.
        #expect(keyed - positional == 37)
        #expect(positional == Self.pinnedPositionalFrameSize, "positional frame \(positional) B, keyed \(keyed) B")
    }

    /// The measured frame size; a change to the framing or the leaves shows here.
    static let pinnedPositionalFrameSize = 87
}
