import Testing
@testable import SwiftStateTree

// These types are not Equatable on purpose, so each warns at compile time; the test is about the
// list a land logs.

struct FallbackListBlob: Sendable, Codable {
    var n = 0
}

final class FallbackListBox: @unchecked Sendable, Codable, Equatable {
    var n = 0
    static func == (lhs: FallbackListBox, rhs: FallbackListBox) -> Bool { lhs.n == rhs.n }
}

@StateNodeBuilder
struct FallbackListRow: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var blob: FallbackListBlob = FallbackListBlob()
    @Sync(.serverOnly) var hidden: FallbackListBlob = FallbackListBlob()
    init() {}
}

@StateNodeBuilder
struct FallbackListState: StateNodeProtocol {
    @Sync(.broadcast) var rows: [String: FallbackListRow] = [:]
    @Sync(.broadcast) var other: [Int: FallbackListRow] = [:]
    @Sync(.broadcast) var one: FallbackListRow = FallbackListRow()
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var box: FallbackListBox = FallbackListBox()
    @Sync(.broadcast) var blobs: [FallbackListBlob] = []
    @Sync(.perPlayerSlice()) var own: [PlayerID: FallbackListBlob] = [:]
    @Sync(.serverOnly) var secret: FallbackListBlob = FallbackListBlob()
    init() {}
}

@StateNodeBuilder
struct FallbackListCleanState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var names: [String: String] = [:]
    init() {}
}

@Suite("Sync tables: the list of fallback fields")
struct SyncTableFallbackFieldsTests {
    @Test("Broadcast root fields and the fields of walked rows, each type once, with the reason")
    func list() {
        let found = syncTableFallbackFields(of: FallbackListState.self)
        #expect(found.map(\.field) == [
            "FallbackListState.blobs",
            "FallbackListState.box",
            // Reached first through `one`; `other` and `rows` hold the same type.
            "FallbackListRow.blob",
        ])
        #expect(found[0].reason == "Array<FallbackListBlob> is not Equatable")
        #expect(found[1].reason == "FallbackListBox is or holds a reference type")
        #expect(found[2].reason == "FallbackListBlob is not Equatable")
    }

    @Test("A state with nothing on the fallback lists nothing")
    func clean() {
        #expect(syncTableFallbackFields(of: FallbackListCleanState.self).isEmpty)
    }

    @Test("The list agrees with the kinds the tables report")
    func agreesWithKinds() {
        let tables = SyncTableBroadcastDiff<FallbackListState>()
        let roots = Set(tables.kinds.filter { $0.value == .fallback }.keys.map { "FallbackListState.\($0)" })
        let listed = Set(syncTableFallbackFields(of: FallbackListState.self).map(\.field).filter { $0.hasPrefix("FallbackListState.") })
        #expect(roots == listed)
    }
}
