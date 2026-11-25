// expect: compiles
import SwiftStateTree

// What the State PlainData checks accept: a nested @PlainData struct, a generic node whose parameter is
// PlainData, an unannotated @Internal field of a plain type, and a hand-written node with
// @PlainData.
@PlainData
struct Card: Codable, Equatable, Sendable {
    var rank: Int
}

@StateNodeBuilder
struct TableState: StateNodeProtocol {
    @Sync(.broadcast)
    var cards: [String: Card] = [:]
    @Internal
    var count = 0

    init() {}
}

@StateNodeBuilder
struct Box<T: PlainData & Codable & Equatable & Sendable>: StateNodeProtocol {
    @Sync(.broadcast)
    var value: T? = nil

    init() {}
}

@PlainData
struct HandState: StateNodeProtocol {
    init() {}
    func getSyncFields() -> [SyncFieldInfo] { [] }
    static func getFieldMetadata() -> [FieldMetadata] { [] }
    func validateSyncFields() -> Bool { true }
    func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>?) throws -> StateSnapshot { StateSnapshot(values: [:]) }
    func broadcastSnapshot(dirtyFields: Set<String>?) throws -> StateSnapshot { StateSnapshot(values: [:]) }
    func fullStateSnapshot() throws -> StateSnapshot { StateSnapshot(values: [:]) }
    func isDirty() -> Bool { false }
    func getDirtyFields() -> Set<String> { [] }
    func clearDirty() {}
    static var hasPlayerDependentSyncFields: Bool { false }
}
