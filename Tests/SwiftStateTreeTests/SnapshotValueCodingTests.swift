import Foundation
import Testing
@testable import SwiftStateTree

@Test("Encodes SnapshotValue using native JSON shapes")
func testSnapshotValueEncodesAsNativeJSON() throws {
    let snapshot: SnapshotValue = .object([
        "hp": .int(5),
        "name": .string("Alice"),
        "dead": .bool(false),
        "inventory": .array([.string("sword"), .int(2)]),
        "missing": .null
    ])

    let encoder = JSONEncoder()
    let data = try encoder.encode(snapshot)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    #expect(json?["hp"] as? Int == 5)
    #expect(json?["name"] as? String == "Alice")
    #expect(json?["dead"] as? Bool == false)
    #expect((json?["inventory"] as? [Any])?.count == 2)
    #expect(json?["missing"] is NSNull)
}

@Test("Decodes SnapshotValue using native JSON format")
func testSnapshotValueDecodesNativeJSON() throws {
    let nativeJSON = """
    {
        "hp": 7,
        "name": "Bob",
        "dead": false,
        "inventory": ["bow"],
        "missing": null
    }
    """

    let data = Data(nativeJSON.utf8)
    let decoded = try JSONDecoder().decode(SnapshotValue.self, from: data)

    guard case let .object(object) = decoded else {
        Issue.record("Expected object SnapshotValue from native JSON format")
        return
    }

    #expect(object["hp"] == .int(7))
    #expect(object["name"] == .string("Bob"))
    #expect(object["dead"] == .bool(false))
    #expect(object["inventory"] == .array([.string("bow")]))
    #expect(object["missing"] == .null)
}
