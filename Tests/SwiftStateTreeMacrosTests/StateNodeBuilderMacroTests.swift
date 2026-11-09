// Tests/SwiftStateTreeMacrosTests/StateNodeBuilderMacroTests.swift

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftStateTreeMacros

final class StateNodeBuilderMacroTests {
    let testMacros: [String: Macro.Type] = [
        "StateNodeBuilder": StateNodeBuilderMacro.self
    ]
    
    @Test("StateNodeBuilder macro generates getSyncFields and validateSyncFields")
    func testStateNodeBuilderMacro() throws {
        expectMacroExpansion(
            """
            @StateNodeBuilder
            struct TestStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                @Sync(.serverOnly)
                var hiddenData: Int = 0
                
                @Internal
                var cache: [String: String] = [:]
            }
            """,
            expandedSource: """
            struct TestStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                @Sync(.serverOnly)
                var hiddenData: Int = 0
                
                @Internal
                var cache: [String: String] = [:]

                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "players", policyType: .broadcast), SyncFieldInfo(name: "hiddenData", policyType: .serverOnly)]
                }

                public func validateSyncFields() -> Bool {
                    return true
                }

                public func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]

                    // Include players if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("players") == true {
                        if let value = self._players.policy.filteredValue(self._players.wrappedValue, for: playerID) {
                            result["players"] = try SnapshotValue.make(from: value, for: playerID)
                        }
                    }

                    // Include hiddenData if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("hiddenData") == true {
                        if let value = self._hiddenData.policy.filteredValue(self._hiddenData.wrappedValue, for: playerID) {
                            result["hiddenData"] = .int(value)
                        }
                    }

                    return StateSnapshot(values: result)
                }

                public func broadcastSnapshot(dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]

                    // Include players if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("players") == true {
                        do {
                            result["players"] = try SnapshotValue.make(from: self._players.wrappedValue)
                        } catch {
                            throw error
                        }
                    }

                    return StateSnapshot(values: result)
                }

                public func fullStateSnapshot() throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]
                    result.reserveCapacity(2)
                    result["players"] = try SnapshotValue.makeFull(from: self._players.wrappedValue as Any)
                    result["hiddenData"] = try SnapshotValue.makeFull(from: self._hiddenData.wrappedValue as Any)
                    return StateSnapshot(values: result)
                }

                public func snapshotForSync(playerIDs: [PlayerID], dirtyFields: Set<String>?) throws -> (broadcast: StateSnapshot, perPlayer: [PlayerID: StateSnapshot]) {
                    var broadcastResult: [String: SnapshotValue] = [:]
                    let perPlayerResult: [PlayerID: [String: SnapshotValue]] = [:]

                    if dirtyFields == nil || dirtyFields?.contains("players") == true {
                        do {
                            broadcastResult["players"] = try SnapshotValue.make(from: self._players.wrappedValue)
                        } catch {
                            throw error
                        }
                    }

                    return (StateSnapshot(values: broadcastResult), perPlayerResult.mapValues {
                            StateSnapshot(values: $0)
                        })
                }

                public func isDirty() -> Bool {
                    return _players.isDirty || _hiddenData.isDirty
                }

                public func getDirtyFields() -> Set<String> {
                    var dirtyFields: Set<String> = []

                    if _players.isDirty {
                        dirtyFields.insert("players")
                    }
                    if _hiddenData.isDirty {
                        dirtyFields.insert("hiddenData")
                    }

                    return dirtyFields
                }

                public mutating func clearDirty() {
                    _players.clearDirty()
                    _hiddenData.clearDirty()
                }

                public static func getFieldMetadata() -> [FieldMetadata] {
                    return [FieldMetadata(
                    name: "players",
                    type: [String: String].self,
                    policy: .broadcast,
                    nodeKind: SchemaHelper.determineNodeKind(from: [String: String].self),
                    defaultValue: try? SnapshotValue.make(from: ([:]) as Any)
                        ), FieldMetadata(
                    name: "hiddenData",
                    type: Int.self,
                    policy: .serverOnly,
                    nodeKind: SchemaHelper.determineNodeKind(from: Int.self),
                    defaultValue: try? SnapshotValue.make(from: (0) as Any)
                        )]
                }

                /// Update or insert a value in players dictionary and mark as dirty
                /// Note: This method always marks the field as dirty, even if the value didn't change
                public mutating func updatePlayers(_ value: String, forKey key: String) {
                    _players.wrappedValue[key] = value
                    _players.markDirty()
                }

                /// Remove a value from players dictionary and mark as dirty
                /// Note: This method always marks the field as dirty, even if the key didn't exist
                @discardableResult
                public mutating func removePlayers(forKey key: String) -> String? {
                    let result = _players.wrappedValue.removeValue(forKey: key)
                    _players.markDirty()
                    return result
                }

                /// Set a value in players dictionary and mark as dirty (alias for updatePlayers)
                public mutating func setPlayers(_ value: String, forKey key: String) {
                    updatePlayers(value, forKey: key)
                }

                private static let _hasPlayerDependentSyncFields: Bool = SyncPolicyNesting.hasPlayerDependentFields(TestStateNode.self)

                public static var hasPlayerDependentSyncFields: Bool {
                    _hasPlayerDependentSyncFields
                }
            }
            """,
            macros: testMacros
        )
    }
    
    @Test("StateNodeBuilder macro still expands the deprecated .custom policy (#173)")
    func testStateNodeBuilderMacroExpandsDeprecatedCustom() throws {
        expectMacroExpansion(
            """
            @StateNodeBuilder
            struct CustomPolicyNode: StateNodeProtocol {
                @Sync(.custom { playerID, value in value })
                var secret: String = ""
            }
            """,
            expandedSource: """
            struct CustomPolicyNode: StateNodeProtocol {
                @Sync(.custom { playerID, value in value })
                var secret: String = ""

                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "secret", policyType: .custom)]
                }

                public func validateSyncFields() -> Bool {
                    return true
                }

                public func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]

                    // Include secret if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("secret") == true {
                        if let value = self._secret.policy.filteredValue(self._secret.wrappedValue, for: playerID) {
                            result["secret"] = .string(value)
                        }
                    }

                    return StateSnapshot(values: result)
                }

                public func broadcastSnapshot(dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    let result: [String: SnapshotValue] = [:]

                    return StateSnapshot(values: result)
                }

                public func fullStateSnapshot() throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]
                    result.reserveCapacity(1)
                    result["secret"] = try SnapshotValue.makeFull(from: self._secret.wrappedValue as Any)
                    return StateSnapshot(values: result)
                }

                public func snapshotForSync(playerIDs: [PlayerID], dirtyFields: Set<String>?) throws -> (broadcast: StateSnapshot, perPlayer: [PlayerID: StateSnapshot]) {
                    let broadcastResult: [String: SnapshotValue] = [:]
                    var perPlayerResult: [PlayerID: [String: SnapshotValue]] = [:]
                    for playerID in playerIDs {
                        perPlayerResult[playerID] = [:]
                    }

                    for playerID in playerIDs {
                        if let value = self._secret.policy.filteredValue(self._secret.wrappedValue, for: playerID) {
                            perPlayerResult[playerID]! ["secret"] = .string(value)
                        }
                    }

                    return (StateSnapshot(values: broadcastResult), perPlayerResult.mapValues {
                            StateSnapshot(values: $0)
                        })
                }

                public func isDirty() -> Bool {
                    return _secret.isDirty
                }

                public func getDirtyFields() -> Set<String> {
                    var dirtyFields: Set<String> = []

                    if _secret.isDirty {
                        dirtyFields.insert("secret")
                    }

                    return dirtyFields
                }

                public mutating func clearDirty() {
                    _secret.clearDirty()
                }

                public static func getFieldMetadata() -> [FieldMetadata] {
                    return [FieldMetadata(
                    name: "secret",
                    type: String.self,
                    policy: .custom,
                    nodeKind: SchemaHelper.determineNodeKind(from: String.self),
                    defaultValue: try? SnapshotValue.make(from: ("") as Any)
                        )]
                }

                private static let _hasPlayerDependentSyncFields: Bool = SyncPolicyNesting.hasPlayerDependentFields(CustomPolicyNode.self)

                public static var hasPlayerDependentSyncFields: Bool {
                    _hasPlayerDependentSyncFields
                }
            }
            """,
            macros: testMacros
        )
    }

    @Test("StateNodeBuilder macro rejects unmarked stored properties")
    func testStateNodeBuilderMacroRejectsUnmarkedProperties() {
        // The macro reports this error twice (#404): the expected diagnostic, plus the thrown
        // error's description at 1:1. Remove the wrapper when #404 is fixed.
        withKnownIssue("Duplicate diagnostic (#404)") {
            expectMacroExpansion(
                """
                @StateNodeBuilder
                struct InvalidStateNode: StateNodeProtocol {
                    @Sync(.broadcast)
                    var players: [String: String] = [:]
                
                    var unmarkedProperty: Int = 0
                }
                """,
                expandedSource: """
                struct InvalidStateNode: StateNodeProtocol {
                    @Sync(.broadcast)
                    var players: [String: String] = [:]
                
                    var unmarkedProperty: Int = 0
                }
                """,
                diagnostics: [
                    DiagnosticSpec(
                        message: "Stored property 'unmarkedProperty' in StateNode must be marked with @Sync or @Internal",
                        line: 6,
                        column: 5
                    )
                ],
                macros: testMacros
            )
        }
    }
}

