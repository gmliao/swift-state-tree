// Tests/SwiftStateTreeMacrosTests/StateNodeBuilderMacroTests.swift

import SwiftSyntaxMacros
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
                        if let value = Self._syncPolicy_players.filteredValue(self._players.wrappedValue, for: playerID) {
                            result["players"] = try SnapshotValue.make(from: value, for: playerID)
                        }
                    }

                    // Include hiddenData if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("hiddenData") == true {
                        if let value = Self._syncPolicy_hiddenData.filteredValue(self._hiddenData.wrappedValue, for: playerID) {
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

                public static func _syncTableFields() -> [SyncTableField<Self>]? {
                    var fields: [SyncTableField<Self>] = []
                    fields.reserveCapacity(2)
                    fields.append(SyncTableField<Self>.make(
                        name: "players",
                        policy: .broadcast,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_players.filteredValue($0._players.wrappedValue, for: nil)
                            },
                        convert: { value in
                                try SnapshotValue.make(from: value)
                            }
                        ))
                    fields.append(SyncTableField<Self>.make(
                        name: "hiddenData",
                        policy: .serverOnly,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_hiddenData.filteredValue($0._hiddenData.wrappedValue, for: nil)
                            },
                        convert: { value in
                                .int(value)
                            }
                        ))
                    _syncCheck_players(_syncFieldKind { (node: Self) in
                            Self._syncPolicy_players.filteredValue(node._players.wrappedValue, for: nil)
                        })
                    return fields
                }

                public static func _syncTablePerPlayerFields(for playerID: PlayerID) -> [SyncTableField<Self>]? {
                    let fields: [SyncTableField<Self>] = []
                    return fields
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

                private static func _syncCheck_players(_: _SyncTypedField) {
                }

                @available(*, deprecated, message: "'players' ([String: String]) is not Equatable, so it is diffed by the slower snapshot diff; make it Equatable")
                private static func _syncCheck_players(_: _SyncFallbackField) {
                }

                private static let _syncPolicy_players: SyncPolicy<[String: String]> = .broadcast

                private static let _syncPolicy_hiddenData: SyncPolicy<Int> = .serverOnly

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
                        if let value = Self._syncPolicy_secret.filteredValue(self._secret.wrappedValue, for: playerID) {
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
                        if let value = Self._syncPolicy_secret.filteredValue(self._secret.wrappedValue, for: playerID) {
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

                public static func _syncTableFields() -> [SyncTableField<Self>]? {
                    var fields: [SyncTableField<Self>] = []
                    fields.reserveCapacity(1)
                    fields.append(SyncTableField<Self>.make(
                        name: "secret",
                        policy: .custom,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_secret.filteredValue($0._secret.wrappedValue, for: nil)
                            },
                        convert: { value in
                                .string(value)
                            }
                        ))
                    _syncCheck_secret(_syncFieldKind { (node: Self) in
                            Self._syncPolicy_secret.filteredValue(node._secret.wrappedValue, for: nil)
                        })
                    return fields
                }

                public static func _syncTablePerPlayerFields(for playerID: PlayerID) -> [SyncTableField<Self>]? {
                    var fields: [SyncTableField<Self>] = []
                    fields.reserveCapacity(1)
                    fields.append(SyncTableField<Self>.make(
                        name: "secret",
                        policy: .custom,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_secret.filteredValue($0._secret.wrappedValue, for: playerID)
                            },
                        convert: { value in
                                .string(value)
                            }
                        ))
                    return fields
                }

                private static func _syncCheck_secret(_: _SyncTypedField) {
                }

                @available(*, deprecated, message: "'secret' (String) is not Equatable, so it is diffed by the slower snapshot diff; make it Equatable")
                private static func _syncCheck_secret(_: _SyncFallbackField) {
                }

                private static let _syncPolicy_secret: SyncPolicy<String> = .custom { playerID, value in
                    value
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
    func testStateNodeBuilderMacroRejectsUnmarkedProperties() throws {
        let (expanded, context) = expandCollectingDiagnostics(
            """
            @StateNodeBuilder
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                var unmarkedProperty: Int = 0
            }
            """,
            macros: testMacros
        )
        #expect(expanded == """
            struct InvalidStateNode: StateNodeProtocol {
                @Sync(.broadcast)
                var players: [String: String] = [:]
                
                var unmarkedProperty: Int = 0
            }
            """)
        // The macro reports this error twice (#404): the diagnostic below, then the thrown error's
        // description at the attribute. This asserts today's behavior exactly; when #404 is
        // fixed the count drops to 1 and this test fails, so update it then.
        try #require(context.diagnostics.count == 2)
        expectDiagnostic(
            context.diagnostics[0],
            in: context,
            message: "Stored property 'unmarkedProperty' in StateNode must be marked with @Sync or @Internal",
            line: 6,
            column: 5
        )
        expectDiagnostic(
            context.diagnostics[1],
            in: context,
            messageStartingWith: "missingMarker(propertyName: \"unmarkedProperty\"",
            containing: [],
            line: 1,
            column: 1
        )
    }
}

