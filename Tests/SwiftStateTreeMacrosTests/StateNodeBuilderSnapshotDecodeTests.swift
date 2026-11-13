// Tests/SwiftStateTreeMacrosTests/StateNodeBuilderSnapshotDecodeTests.swift
// Verifies @StateNodeBuilder generates init(fromBroadcastSnapshot:) conformance.

import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

final class StateNodeBuilderSnapshotDecodeTests {
    let testMacros: [String: Macro.Type] = [
        "StateNodeBuilder": StateNodeBuilderMacro.self
    ]

    @Test("StateNodeBuilder generates fromBroadcastSnapshot initializer when conformance is declared")
    func generatesFromBroadcastSnapshotInit() throws {
        expectMacroExpansion(
            """
            @StateNodeBuilder
            struct SimpleState: StateNodeProtocol, StateFromSnapshotDecodable {
                @Sync(.broadcast)
                var score: Int = 0
                @Sync(.broadcast)
                var name: String = ""
                @Sync(.serverOnly)
                var internal_counter: Int = 0

                init() {}
            }
            """,
            expandedSource: """
            struct SimpleState: StateNodeProtocol, StateFromSnapshotDecodable {
                @Sync(.broadcast)
                var score: Int = 0
                @Sync(.broadcast)
                var name: String = ""
                @Sync(.serverOnly)
                var internal_counter: Int = 0

                init() {}

                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "score", policyType: .broadcast), SyncFieldInfo(name: "name", policyType: .broadcast), SyncFieldInfo(name: "internal_counter", policyType: .serverOnly)]
                }

                public func validateSyncFields() -> Bool {
                    return true
                }

                public func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]

                    // Include score if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("score") == true {
                        if let value = Self._syncPolicy_score.filteredValue(self._score.wrappedValue, for: playerID) {
                            result["score"] = .int(value)
                        }
                    }

                    // Include name if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("name") == true {
                        if let value = Self._syncPolicy_name.filteredValue(self._name.wrappedValue, for: playerID) {
                            result["name"] = .string(value)
                        }
                    }

                    // Include internal_counter if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("internal_counter") == true {
                        if let value = Self._syncPolicy_internal_counter.filteredValue(self._internal_counter.wrappedValue, for: playerID) {
                            result["internal_counter"] = .int(value)
                        }
                    }

                    return StateSnapshot(values: result)
                }

                public func broadcastSnapshot(dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]

                    // Include score if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("score") == true {
                        result["score"] = .int(self._score.wrappedValue)
                    }

                    // Include name if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("name") == true {
                        result["name"] = .string(self._name.wrappedValue)
                    }

                    return StateSnapshot(values: result)
                }

                public func fullStateSnapshot() throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]
                    result.reserveCapacity(3)
                    result["score"] = try SnapshotValue.makeFull(from: self._score.wrappedValue as Any)
                    result["name"] = try SnapshotValue.makeFull(from: self._name.wrappedValue as Any)
                    result["internal_counter"] = try SnapshotValue.makeFull(from: self._internal_counter.wrappedValue as Any)
                    return StateSnapshot(values: result)
                }

                public func snapshotForSync(playerIDs: [PlayerID], dirtyFields: Set<String>?) throws -> (broadcast: StateSnapshot, perPlayer: [PlayerID: StateSnapshot]) {
                    var broadcastResult: [String: SnapshotValue] = [:]
                    let perPlayerResult: [PlayerID: [String: SnapshotValue]] = [:]

                    if dirtyFields == nil || dirtyFields?.contains("score") == true {
                        broadcastResult["score"] = .int(self._score.wrappedValue)
                    }

                    if dirtyFields == nil || dirtyFields?.contains("name") == true {
                        broadcastResult["name"] = .string(self._name.wrappedValue)
                    }

                    return (StateSnapshot(values: broadcastResult), perPlayerResult.mapValues {
                            StateSnapshot(values: $0)
                        })
                }

                public func isDirty() -> Bool {
                    return _score.isDirty || _name.isDirty || _internal_counter.isDirty
                }

                public func getDirtyFields() -> Set<String> {
                    var dirtyFields: Set<String> = []

                    if _score.isDirty {
                        dirtyFields.insert("score")
                    }
                    if _name.isDirty {
                        dirtyFields.insert("name")
                    }
                    if _internal_counter.isDirty {
                        dirtyFields.insert("internal_counter")
                    }

                    return dirtyFields
                }

                public mutating func clearDirty() {
                    _score.clearDirty()
                    _name.clearDirty()
                    _internal_counter.clearDirty()
                }

                public static func getFieldMetadata() -> [FieldMetadata] {
                    return [FieldMetadata(
                    name: "score",
                    type: Int.self,
                    policy: .broadcast,
                    nodeKind: SchemaHelper.determineNodeKind(from: Int.self),
                    defaultValue: try? SnapshotValue.make(from: (0) as Any)
                        ), FieldMetadata(
                    name: "name",
                    type: String.self,
                    policy: .broadcast,
                    nodeKind: SchemaHelper.determineNodeKind(from: String.self),
                    defaultValue: try? SnapshotValue.make(from: ("") as Any)
                        ), FieldMetadata(
                    name: "internal_counter",
                    type: Int.self,
                    policy: .serverOnly,
                    nodeKind: SchemaHelper.determineNodeKind(from: Int.self),
                    defaultValue: try? SnapshotValue.make(from: (0) as Any)
                        )]
                }

                public static func _syncTableFields() -> [SyncTableField<Self>]? {
                    var fields: [SyncTableField<Self>] = []
                    fields.reserveCapacity(3)
                    fields.append(SyncTableField<Self>.make(
                        name: "score",
                        policy: .broadcast,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_score.filteredValue($0._score.wrappedValue, for: nil)
                            },
                        convert: { value in
                                .int(value)
                            }
                        ))
                    fields.append(SyncTableField<Self>.make(
                        name: "name",
                        policy: .broadcast,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_name.filteredValue($0._name.wrappedValue, for: nil)
                            },
                        convert: { value in
                                .string(value)
                            }
                        ))
                    fields.append(SyncTableField<Self>.make(
                        name: "internal_counter",
                        policy: .serverOnly,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_internal_counter.filteredValue($0._internal_counter.wrappedValue, for: nil)
                            },
                        convert: { value in
                                .int(value)
                            }
                        ))
                    _syncCheck_score(_syncFieldKind { (node: Self) in
                            Self._syncPolicy_score.filteredValue(node._score.wrappedValue, for: nil)
                        })
                    _syncCheck_name(_syncFieldKind { (node: Self) in
                            Self._syncPolicy_name.filteredValue(node._name.wrappedValue, for: nil)
                        })
                    return fields
                }

                public static func _syncTablePerPlayerFields(for playerID: PlayerID) -> [SyncTableField<Self>]? {
                    let fields: [SyncTableField<Self>] = []
                    return fields
                }

                private static func _syncCheck_score(_: _SyncTypedField) {
                }

                @available(*, deprecated, message: "'score' (Int) is not Equatable, so it is diffed by the slower snapshot diff; make it Equatable")
                private static func _syncCheck_score(_: _SyncFallbackField) {
                }

                private static func _syncCheck_name(_: _SyncTypedField) {
                }

                @available(*, deprecated, message: "'name' (String) is not Equatable, so it is diffed by the slower snapshot diff; make it Equatable")
                private static func _syncCheck_name(_: _SyncFallbackField) {
                }

                private static let _syncPolicy_score: SyncPolicy<Int> = .broadcast

                private static let _syncPolicy_name: SyncPolicy<String> = .broadcast

                private static let _syncPolicy_internal_counter: SyncPolicy<Int> = .serverOnly

                private static let _hasPlayerDependentSyncFields: Bool = SyncPolicyNesting.hasPlayerDependentFields(SimpleState.self)

                public static var hasPlayerDependentSyncFields: Bool {
                    _hasPlayerDependentSyncFields
                }

                public init(fromBroadcastSnapshot snapshot: StateSnapshot) throws {
                    self.init()
                    if let _v = snapshot.values["score"] {
                        self._score.wrappedValue = try _snapshotDecode(_v)
                    }
                    if let _v = snapshot.values["name"] {
                        self._name.wrappedValue = try _snapshotDecode(_v)
                    }
                }
            }
            """,
            macros: testMacros
        )
    }
}
