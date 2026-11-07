// Tests/SwiftStateTreeTests/EmptyMapKeyTests.swift
//
// An empty map key (`""`) is a key: `/m/` is the entry of `m` under `""`, and `/m//v` that
// entry's field `v`. Splitting a path with Swift's default `split(separator:)` drops empty
// components, so `/m/` was hashed as `m` (a patch for the whole map) and `/m//v` as `m.*` with
// the key `v`.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

@SnapshotConvertible
struct EmptyKeyEntry: Codable, Equatable, Sendable {
    var at: Position2
    var tag: Int

    init() {
        at = Position2(x: 0, y: 0)
        tag = 0
    }

    init(at: Position2, tag: Int) {
        self.at = at
        self.tag = tag
    }
}

@StateNodeBuilder
struct EmptyMapKeyState: StateNodeProtocol {
    @Sync(.broadcast) var byKey: [String: Position2] = [:]
    @Sync(.broadcast) var entries: [String: EmptyKeyEntry] = [:]
}

@Suite("An empty map key is a key")
struct EmptyMapKeyTests {
    static let landType = "empty-map-key"

    static func schema() throws -> ProtocolSchema {
        try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(Land(landType, using: EmptyMapKeyState.self) {})])
    }

    static func hasher() throws -> PathHasher {
        PathHasher(pathHashes: try #require(try schema().lands[landType]?.pathHashes))
    }

    static func expectSplit(_ hasher: PathHasher, _ path: String, _ hash: UInt32, _ keys: [String]) throws {
        let (actualHash, actualKeys) = hasher.split(path)
        #expect(actualHash == hash, "\(path): hash")
        #expect(actualKeys == keys, "\(path): dynamic keys")
    }

    @Test("A pointer's components keep the empty ones; the root has none")
    func components() {
        #expect(PathHasher.components(of: "/m/") == ["m", ""])
        #expect(PathHasher.components(of: "/m//v") == ["m", "", "v"])
        #expect(PathHasher.components(of: "/m/a") == ["m", "a"])
        #expect(PathHasher.components(of: "/") == [])
        #expect(PathHasher.components(of: "") == [])
    }

    @Test("PathHasher hashes a path under an empty key by its pattern, with the key")
    func split() throws {
        let hasher = PathHasher(pathHashes: ["m": 1, "m.*": 2, "m.*.v": 3])
        try Self.expectSplit(hasher, "/m/", 2, [""])
        try Self.expectSplit(hasher, "/m//v", 3, [""])
        try Self.expectSplit(hasher, "/m/a", 2, ["a"])
        try Self.expectSplit(hasher, "/m", 1, [])
    }

    @Test("SyncEngine sends a change under an empty key as a patch at that key")
    func syncEnginePatches() throws {
        var engine = SyncEngine(for: EmptyMapKeyState.self)
        var state = EmptyMapKeyState()
        state.byKey["a"] = Position2(x: 1, y: 1)
        state.entries[""] = EmptyKeyEntry(at: Position2(x: 1, y: 1), tag: 1)
        let player = PlayerID("p")
        _ = try engine.generateDiff(for: player, from: state)
        state.byKey[""] = Position2(x: 2, y: 2)
        state.entries[""]?.at = Position2(x: 3, y: 3)
        guard case .diff(let patches) = try engine.generateDiff(for: player, from: state) else {
            Issue.record("not a diff")
            return
        }
        #expect(Set(patches.map(\.path)).isSuperset(of: ["/byKey/"]))
        #expect(patches.allSatisfy { $0.path.hasPrefix("/byKey/") || $0.path.hasPrefix("/entries//") })
    }

    @Test("The opcode JSON encoder sends a patch under an empty key to that key, and the decoder reads it back")
    func roundTrip() throws {
        let table = AtomicLayoutTable.forState(EmptyMapKeyState.self)
        let hasher = try Self.hasher()
        let hashes = try #require(try Self.schema().lands[Self.landType]?.pathHashes)
        let patches = [
            StatePatch(path: "/byKey/", operation: .set(try SnapshotValue.make(from: Position2(x: 4, y: 5)))),
            StatePatch(path: "/entries//at", operation: .set(try SnapshotValue.make(from: Position2(x: 6, y: 7)))),
            StatePatch(path: "/byKey/", operation: .set(try SnapshotValue.make(from: Position2(x: 8, y: 9)))),
        ]
        try Self.expectSplit(hasher, "/byKey/", try #require(hashes["byKey.*"]), [""])
        try Self.expectSplit(hasher, "/entries//at", try #require(hashes["entries.*.at"]), [""])

        let json = OpcodeJSONStateUpdateEncoder(pathHasher: hasher, dynamicKeyCompression: true, atomicLayout: table)
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, atomicLayout: table)
        for patch in patches {
            let data = try json.encode(update: .diff([patch]), landID: Self.landType, playerID: PlayerID("p1"))
            // [opcode, [pathHash, dynamicKey, op, value]]: the value is positional.
            let frame = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
            let entry = try #require(frame[1] as? [Any])
            #expect((entry.last as? [Int])?.count == 2, "\(patch.path): positional")
            guard case .diff(let decoded) = try decoder.decode(data: data).update else {
                Issue.record("not a diff")
                continue
            }
            #expect(decoded == [patch])
        }

    }
}
