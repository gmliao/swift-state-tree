// expect-error: does not conform to protocol 'PlainData'
import SwiftStateTree

// A hand-written state node without @PlainData: StateNodeProtocol refines PlainData, so the
// conformance needs its witness.
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
