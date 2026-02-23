import Testing
@testable import SwiftStateTree

@Suite("SnapshotValueDecodable")
struct SnapshotValueDecodableTests {

    @Test("Int decodes from .int case")
    func intFromInt() throws {
        let v: Int = try Int(fromSnapshotValue: .int(42))
        #expect(v == 42)
    }

    @Test("Int throws on wrong type")
    func intThrowsOnWrongType() {
        #expect(throws: (any Error).self) {
            _ = try Int(fromSnapshotValue: .string("bad"))
        }
    }

    @Test("String decodes from .string case")
    func stringFromString() throws {
        let v: String = try String(fromSnapshotValue: .string("hello"))
        #expect(v == "hello")
    }

    @Test("Bool decodes from .bool case")
    func boolFromBool() throws {
        #expect(try Bool(fromSnapshotValue: .bool(true)) == true)
        #expect(try Bool(fromSnapshotValue: .bool(false)) == false)
    }

    @Test("Double decodes from .double case")
    func doubleFromDouble() throws {
        #expect(try Double(fromSnapshotValue: .double(3.14)) == 3.14)
    }

    @Test("Optional decodes .null as nil")
    func optionalNull() throws {
        let v = try Optional<Int>(fromSnapshotValue: .null)
        #expect(v == nil)
    }

    @Test("Optional decodes value as .some")
    func optionalValue() throws {
        let v = try Optional<Int>(fromSnapshotValue: .int(7))
        #expect(v == 7)
    }

    @Test("Array decodes .array case")
    func arrayDecode() throws {
        let v = try [Int](fromSnapshotValue: .array([.int(1), .int(2), .int(3)]))
        #expect(v == [1, 2, 3])
    }

    @Test("Dictionary decodes .object case with String keys")
    func dictionaryStringKey() throws {
        let v = try [String: Int](fromSnapshotValue: .object(["a": .int(1), "b": .int(2)]))
        #expect(v == ["a": 1, "b": 2])
    }

    @Test("Dictionary decodes .object case with Int keys")
    func dictionaryIntKey() throws {
        let v = try [Int: Int](fromSnapshotValue: .object(["1": .int(10), "2": .int(20)]))
        #expect(v == [1: 10, 2: 20])
    }

    @Test("Dictionary skips unparseable Int keys (compactMap)")
    func dictionaryIntKeySkipsBadKeys() throws {
        let v = try [Int: Int](fromSnapshotValue: .object(["1": .int(10), "bad": .int(99)]))
        #expect(v == [1: 10])
    }
}
