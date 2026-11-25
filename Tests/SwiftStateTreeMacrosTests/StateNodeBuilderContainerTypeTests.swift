// Tests/SwiftStateTreeMacrosTests/StateNodeBuilderContainerTypeTests.swift
//
// @StateNodeBuilder classifies a field's container type (dictionary, array, set) to emit its
// helper methods. A field whose element type has its own `:` or `,` (a nested literal
// dictionary, a labeled tuple, a generic argument with two parameters) was split at the first
// separator, so the helpers got broken key and element types and the expansion didn't parse
// (#582). Each spelling here must expand to valid Swift with the helpers typed as written.
//
// Before the fix four of these cases failed: `[[String: Int]]`, `[(a: Int, b: Int)]`,
// `Dictionary<Pair<Int, Int>, Int>` and `[[String: Int]: Int]`. In the others the first separator
// is the top-level one, or the type isn't a container (an optional, a qualified `Swift.` name),
// so they guard that the syntax-tree classification matches the old one. A tuple can't be
// stored in state (it can't conform to PlainData), so the tuple cases use `PlainPair` instead and
// a tuple field is checked to be refused.

import SwiftSyntaxMacros
import Testing
import SwiftStateTreeMacros

struct StateNodeBuilderContainerTypeTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let fieldType: String
        /// Helper signatures the expansion must contain, as the macro prints them.
        let helpers: [String]
        /// Helper names the expansion must not contain (a wrong container kind).
        let absentHelpers: [String]

        var testDescription: String { fieldType }
    }

    static let cases: [Case] = [
        Case(
            fieldType: "[[String: Int]]",
            helpers: [
                "public mutating func appendItems(_ element: [String: Int])",
                "public mutating func insertItems(_ element: [String: Int], at index: Int)",
            ],
            absentHelpers: ["func updateItems", "func setItems"]
        ),
        Case(
            fieldType: "Array<[String: Int]>",
            helpers: ["public mutating func appendItems(_ element: [String: Int])"],
            absentHelpers: ["func updateItems"]
        ),
        Case(
            fieldType: "[PlainPair<Int, Int>]",
            helpers: ["public mutating func appendItems(_ element: PlainPair<Int, Int>)"],
            absentHelpers: ["func updateItems"]
        ),
        Case(
            fieldType: "[String: [Int: Int]]",
            helpers: [
                "public mutating func updateItems(_ value: [Int: Int], forKey key: String)",
                "public mutating func removeItems(forKey key: String) -> [Int: Int]?",
            ],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "[String: [[String: Int]]]",
            helpers: ["public mutating func updateItems(_ value: [[String: Int]], forKey key: String)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "[Int: PlainPair<Int, Int>]",
            helpers: ["public mutating func updateItems(_ value: PlainPair<Int, Int>, forKey key: Int)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "Dictionary<Pair<Int, Int>, Int>",
            helpers: ["public mutating func updateItems(_ value: Int, forKey key: Pair<Int, Int>)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "Dictionary<String, Dictionary<String, Int>>",
            helpers: ["public mutating func updateItems(_ value: Dictionary<String, Int>, forKey key: String)"],
            absentHelpers: ["func appendItems"]
        ),
        Case(
            fieldType: "Set<Pair<Int, Int>>",
            helpers: ["public mutating func insertItems(_ element: Pair<Int, Int>) -> (inserted: Bool, memberAfterInsert: Pair<Int, Int>)"],
            absentHelpers: ["func appendItems", "func updateItems"]
        ),
        Case(
            fieldType: "[[String: Int]: Int]",
            helpers: ["public mutating func updateItems(_ value: Int, forKey key: [String: Int])"],
            absentHelpers: ["func appendItems"]
        ),
        // Not a container field: an optional gets no helpers.
        Case(
            fieldType: "[[String: Int]]?",
            helpers: [],
            absentHelpers: ["func appendItems", "func updateItems", "func insertItems"]
        ),
        // A module-qualified name isn't matched (unchanged behavior).
        Case(
            fieldType: "Swift.Dictionary<String, Int>",
            helpers: [],
            absentHelpers: ["func appendItems", "func updateItems", "func insertItems"]
        ),
    ]

    @Test("A container field whose element type has its own separator expands to valid helpers", arguments: cases)
    func nestedContainerFieldExpands(_ testCase: Case) {
        let (expanded, context) = expandCollectingDiagnostics(
            """
            @StateNodeBuilder
            struct Root: StateNodeProtocol {
                @Sync(.broadcast) var items: \(testCase.fieldType) = .init()
                init() {}
            }
            """,
            macros: ["StateNodeBuilder": StateNodeBuilderMacro.self]
        )
        #expect(context.diagnostics.isEmpty, "\(context.diagnostics.map(\.message))")
        for helper in testCase.helpers {
            #expect(expanded.contains(helper), "missing `\(helper)`")
        }
        for helper in testCase.absentHelpers {
            #expect(!expanded.contains(helper), "unexpected `\(helper)`")
        }
    }

    @Test("A container field of tuples is refused: a tuple can't conform to PlainData", arguments: ["[(a: Int, b: Int)]", "[Int: (a: Int, b: Int)]"])
    func tupleContainerFieldIsRefused(fieldType: String) {
        let (_, context) = expandCollectingDiagnostics(
            """
            @StateNodeBuilder
            struct Root: StateNodeProtocol {
                @Sync(.broadcast) var items: \(fieldType) = .init()
                init() {}
            }
            """,
            macros: ["StateNodeBuilder": StateNodeBuilderMacro.self]
        )
        let messages = context.diagnostics.map(\.message)
        #expect(messages.first?.hasPrefix("a tuple can't conform to PlainData") == true, "\(messages)")
    }

    @Test("A typealias element keeps array helpers, as before #582")
    func typealiasElementKeepsArrayHelpers() {
        let (expanded, context) = expandCollectingDiagnostics(
            """
            @StateNodeBuilder
            struct Root: StateNodeProtocol {
                @Sync(.broadcast) var items: [Counts] = []
                init() {}
            }
            """,
            macros: ["StateNodeBuilder": StateNodeBuilderMacro.self]
        )
        #expect(context.diagnostics.isEmpty)
        #expect(expanded.contains("public mutating func appendItems(_ element: Counts)"))
    }

    @Test("Golden: an array of literal dictionaries gets array helpers only (#582)")
    func arrayOfLiteralDictionariesGolden() {
        expectMacroExpansion(
            """
            @StateNodeBuilder
            struct Root: StateNodeProtocol {
                @Sync(.broadcast) var maps: [[String: Int]] = []
                init() {}
            }
            """,
            expandedSource: """

            struct Root: StateNodeProtocol {
                @Sync(.broadcast) var maps: [[String: Int]] = []
                init() {}

                public func getSyncFields() -> [SyncFieldInfo] {
                    return [SyncFieldInfo(name: "maps", policyType: .broadcast)]
                }

                public func validateSyncFields() -> Bool {
                    return true
                }

                public func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>?, budget: NestingBudget) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]

                    // Include maps if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("maps") == true {
                        if let value = Self._syncPolicy_maps.filteredValue(self._maps.wrappedValue, for: playerID) {
                            result["maps"] = try SnapshotValue.make(from: value, for: playerID, budget: budget)
                        }
                    }

                    return StateSnapshot(values: result)
                }

                public func broadcastSnapshot(dirtyFields: Set<String>?, budget: NestingBudget) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]

                    // Include maps if no dirtyFields filter or if field is dirty
                    if dirtyFields == nil || dirtyFields?.contains("maps") == true {
                        do {
                            result["maps"] = try SnapshotValue.make(from: self._maps.wrappedValue, budget: budget)
                        } catch {
                            throw error
                        }
                    }

                    return StateSnapshot(values: result)
                }

                public func fullStateSnapshot(budget: NestingBudget) throws -> StateSnapshot {
                    var result: [String: SnapshotValue] = [:]
                    result.reserveCapacity(1)
                    result["maps"] = try SnapshotValue.makeFull(from: self._maps.wrappedValue as Any, budget: budget)
                    return StateSnapshot(values: result)
                }

                public func snapshotForSync(playerIDs: [PlayerID], dirtyFields: Set<String>?, budget: NestingBudget) throws -> (broadcast: StateSnapshot, perPlayer: [PlayerID: StateSnapshot]) {
                    var broadcastResult: [String: SnapshotValue] = [:]
                    let perPlayerResult: [PlayerID: [String: SnapshotValue]] = [:]

                    if dirtyFields == nil || dirtyFields?.contains("maps") == true {
                        do {
                            broadcastResult["maps"] = try SnapshotValue.make(from: self._maps.wrappedValue, budget: budget)
                        } catch {
                            throw error
                        }
                    }

                    return (StateSnapshot(values: broadcastResult), perPlayerResult.mapValues {
                            StateSnapshot(values: $0)
                        })
                }

                public func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    try snapshot(for: playerID, dirtyFields: dirtyFields, budget: NestingBudget())
                }

                public func broadcastSnapshot(dirtyFields: Set<String>? = nil) throws -> StateSnapshot {
                    try broadcastSnapshot(dirtyFields: dirtyFields, budget: NestingBudget())
                }

                public func fullStateSnapshot() throws -> StateSnapshot {
                    try fullStateSnapshot(budget: NestingBudget())
                }

                public func snapshotForSync(playerIDs: [PlayerID], dirtyFields: Set<String>?) throws -> (broadcast: StateSnapshot, perPlayer: [PlayerID: StateSnapshot]) {
                    try snapshotForSync(playerIDs: playerIDs, dirtyFields: dirtyFields, budget: NestingBudget())
                }

                public func isDirty() -> Bool {
                    return _maps.isDirty
                }

                public func getDirtyFields() -> Set<String> {
                    var dirtyFields: Set<String> = []

                    if _maps.isDirty {
                        dirtyFields.insert("maps")
                    }

                    return dirtyFields
                }

                public mutating func clearDirty() {
                    _maps.clearDirty()
                }

                public static func getFieldMetadata() -> [FieldMetadata] {
                    return [FieldMetadata(
                    name: "maps",
                    type: [[String: Int]].self,
                    policy: .broadcast,
                    nodeKind: SchemaHelper.determineNodeKind(from: [[String: Int]].self),
                    defaultValue: try? SnapshotValue.make(from: ([]) as Any)
                        )]
                }

                public static func _syncTableFields() -> [SyncTableField<Self>]? {
                    var fields: [SyncTableField<Self>] = []
                    fields.reserveCapacity(1)
                    fields.append(SyncTableField<Self>.make(
                        name: "maps",
                        policy: .broadcast,
                        conversion: .standard,
                        read: {
                                Self._syncPolicy_maps.filteredValue($0._maps.wrappedValue, for: nil)
                            },
                        convert: { value in
                                try SnapshotValue.make(from: value)
                            }
                        ))
                    _syncCheck_maps(_syncFieldKind { (node: Self) in
                            Self._syncPolicy_maps.filteredValue(node._maps.wrappedValue, for: nil)
                        })
                    return fields
                }

                public static func _syncTablePerPlayerFields(for playerID: PlayerID) -> [SyncTableField<Self>]? {
                    let fields: [SyncTableField<Self>] = []
                    return fields
                }

                /// Append an element to maps array and mark as dirty
                /// Note: This method always marks the field as dirty
                public mutating func appendMaps(_ element: [String: Int]) {
                    _maps.wrappedValue.append(element)
                    _maps.markDirty()
                }

                /// Remove an element from maps array at index and mark as dirty
                /// Note: This method always marks the field as dirty
                @discardableResult
                public mutating func removeMaps(at index: Int) -> [String: Int] {
                    let result = _maps.wrappedValue.remove(at: index)
                    _maps.markDirty()
                    return result
                }

                /// Insert an element into maps array at index and mark as dirty
                /// Note: This method always marks the field as dirty
                public mutating func insertMaps(_ element: [String: Int], at index: Int) {
                    _maps.wrappedValue.insert(element, at: index)
                    _maps.markDirty()
                }

                private static func _syncCheck_maps(_: _SyncTypedField) {
                }

                @available(*, deprecated, message: "'maps' ([[String: Int]]) is not Equatable, so it is diffed by the slower snapshot diff; make it Equatable")
                private static func _syncCheck_maps(_: _SyncFallbackField) {
                }

                /// Compiled, never called: each line fails to compile unless the value it reads is PlainData.
                static func _plainDataCheck() {
                    @available(*, deprecated, message: "the PlainData checks; never called")
                    func check(_ value: inout Self) {
                        SwiftStateTurns.PlainDataCheck.field(value._maps)
                        SwiftStateTurns.PlainDataCheck.field(value.maps)
                    }
                }

                private static let _syncPolicy_maps: SyncPolicy<[[String: Int]]> = .broadcast

                private static let _hasPlayerDependentSyncFields: Bool = SyncPolicyNesting.hasPlayerDependentFields(Root.self)

                public static var hasPlayerDependentSyncFields: Bool {
                    _hasPlayerDependentSyncFields
                }
            }
            """,
            macros: ["StateNodeBuilder": StateNodeBuilderMacro.self]
        )
    }
}
