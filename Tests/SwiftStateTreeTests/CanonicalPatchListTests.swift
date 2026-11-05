// Tests/SwiftStateTreeTests/CanonicalPatchListTests.swift
//
// The canonical form of a sync scope's patches and the hashes built on it.

import Foundation
import Testing
@testable import SwiftStateTree

private func set(_ path: String, _ value: SnapshotValue) -> StatePatch {
    StatePatch(path: path, operation: .set(value))
}

private func delete(_ path: String) -> StatePatch {
    StatePatch(path: path, operation: .delete)
}

@Suite("Streaming FNV-1a and snapshot value hashing")
struct SnapshotValueHashingTests {
    @Test("Feeding bytes one by one matches fnv1a64 over the same data")
    func streamingMatchesOneShot() {
        let data = Data("swift-state-tree".utf8)
        var hasher = DeterministicHash.FNV1a64()
        hasher.combine(bytes: data)
        #expect(hasher.value == DeterministicHash.fnv1a64(data))
        #expect(DeterministicHash.FNV1a64().value == DeterministicHash.fnv1a64(Data()))
    }

    @Test("Length prefixes keep different field splits apart")
    func lengthPrefixedStrings() {
        var ab = DeterministicHash.FNV1a64()
        ab.combine("ab")
        ab.combine("c")
        var a = DeterministicHash.FNV1a64()
        a.combine("a")
        a.combine("bc")
        #expect(ab.value != a.value)
    }

    @Test("Kinds are tagged: equal-looking values of different kinds hash differently")
    func kindsAreTagged() {
        let values: [SnapshotValue] = [.null, .bool(true), .int(1), .double(1), .string("1"), .array([.int(1)]), .object(["1": .int(1)])]
        let hashes = values.map(Self.hash)
        #expect(Set(hashes).count == values.count)
    }

    @Test("Object key order does not matter; values do")
    func objectKeyOrder() {
        let first: SnapshotValue = .object(["b": .int(2), "a": .int(1), "é": .string("x")])
        let second: SnapshotValue = .object(["é": .string("x"), "a": .int(1), "b": .int(2)])
        #expect(Self.hash(first) == Self.hash(second))
        #expect(Self.hash(first) != Self.hash(.object(["b": .int(2), "a": .int(3), "é": .string("x")])))
    }

    @Test("Array order matters")
    func arrayOrder() {
        #expect(Self.hash(.array([.int(1), .int(2)])) != Self.hash(.array([.int(2), .int(1)])))
    }

    @Test("Doubles: -0.0 hashes as 0.0, and every NaN alike")
    func canonicalDoubles() {
        #expect(Self.hash(.double(-0.0)) == Self.hash(.double(0.0)))
        #expect(Self.hash(.double(.nan)) == Self.hash(.double(-.nan)))
        #expect(Self.hash(.double(1.5)) != Self.hash(.double(1.25)))
    }

    @Test("Byte-wise UTF-8 order separates canonically equivalent keys")
    func utf8OrderIsTotal() {
        // "é" precomposed vs "e" + combining acute: String's == calls them equal.
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(precomposed == decomposed)
        #expect(SnapshotValue.utf8Less(precomposed, decomposed) != SnapshotValue.utf8Less(decomposed, precomposed))
    }

    private static func hash(_ value: SnapshotValue) -> UInt64 {
        var hasher = DeterministicHash.FNV1a64()
        value.hash(into: &hasher)
        return hasher.value
    }
}

@Suite("Canonical patch list")
struct CanonicalPatchListTests {
    @Test("Patches on unrelated paths hash equal in any order")
    func unrelatedPathsCommute() {
        let patches = [set("/b", .int(2)), set("/a/x", .int(1)), delete("/c"), set("/a/y", .string("y"))]
        let reversed = Array(patches.reversed())
        let first = CanonicalPatchList(patches)
        let second = CanonicalPatchList(reversed)
        #expect(first.hash == second.hash)
        #expect(first.patches == second.patches)
        #expect(!first.hasPrefixPairs)
    }

    @Test("Two patches on the same path keep their order")
    func samePathOrderMatters() {
        let forward = CanonicalPatchList([set("/a", .int(1)), set("/a", .int(2))])
        let backward = CanonicalPatchList([set("/a", .int(2)), set("/a", .int(1))])
        #expect(forward.hash != backward.hash)
        #expect(forward.hasPrefixPairs)
    }

    @Test("A path and its descendant keep their order and are flagged")
    func prefixPairOrderMatters() {
        let parentFirst = CanonicalPatchList([set("/a", .object([:])), set("/a/b", .int(1))])
        let childFirst = CanonicalPatchList([set("/a/b", .int(1)), set("/a", .object([:]))])
        #expect(parentFirst.hash != childFirst.hash)
        #expect(parentFirst.hasPrefixPairs)
        #expect(childFirst.patches.map(\.path) == ["/a/b", "/a"])
    }

    @Test("Prefix classes are component-wise: /a and /ab are unrelated")
    func componentWisePrefix() {
        let list = CanonicalPatchList([set("/ab", .int(1)), set("/a", .int(2))])
        #expect(!list.hasPrefixPairs)
        #expect(list.patches.map(\.path) == ["/a", "/ab"])
        #expect(list.hash == CanonicalPatchList([set("/a", .int(2)), set("/ab", .int(1))]).hash)
    }

    @Test("A class keeps its original order among unrelated paths that are reordered")
    func classOrderAmongOthers() {
        let patches = [set("/z", .int(0)), set("/a/b", .int(1)), set("/m", .int(2)), delete("/a")]
        let shuffled = [set("/m", .int(2)), set("/a/b", .int(1)), delete("/a"), set("/z", .int(0))]
        #expect(CanonicalPatchList(patches).hash == CanonicalPatchList(shuffled).hash)
        let swappedClass = [set("/z", .int(0)), delete("/a"), set("/m", .int(2)), set("/a/b", .int(1))]
        #expect(CanonicalPatchList(patches).hash != CanonicalPatchList(swappedClass).hash)
    }

    @Test("NFC and NFD forms of a key are different components")
    func canonicallyEquivalentKeys() {
        let nfc = set("/k/\u{00E9}", .int(1))
        let nfd = set("/k/e\u{0301}", .int(2))
        let forward = CanonicalPatchList([nfc, nfd])
        let backward = CanonicalPatchList([nfd, nfc])
        // Byte-wise both ways: not one prefix class, and the same order for either input order.
        #expect(!forward.hasPrefixPairs)
        #expect(forward.patches == backward.patches)
        #expect(forward.hash == backward.hash)
    }

    @Test("A changed value, operation or missing patch changes the hash")
    func contentChanges() {
        let base = CanonicalPatchList([set("/a", .int(1)), delete("/b")]).hash
        #expect(CanonicalPatchList([set("/a", .int(2)), delete("/b")]).hash != base)
        #expect(CanonicalPatchList([StatePatch(path: "/a", operation: .add(.int(1))), delete("/b")]).hash != base)
        #expect(CanonicalPatchList([set("/a", .int(1)), set("/b", .null)]).hash != base)
        #expect(CanonicalPatchList([set("/a", .int(1))]).hash != base)
        #expect(CanonicalPatchList([]).hash != base)
    }

    @Test("Reordered events hash differently; equal events hash equal")
    func eventsKeepOrder() {
        let first = CanonicalSyncEvent(sequence: 1, type: "Hit", payload: .object(["damage": .int(3)]))
        let second = CanonicalSyncEvent(sequence: 2, type: "Heal", payload: .int(1))
        #expect(CanonicalSyncEvent.hash([first, second]) == CanonicalSyncEvent.hash([first, second]))
        #expect(CanonicalSyncEvent.hash([first, second]) != CanonicalSyncEvent.hash([second, first]))
        #expect(CanonicalSyncEvent.hash([first]) != CanonicalSyncEvent.hash([first, second]))
        let resequenced = CanonicalSyncEvent(sequence: 3, type: "Hit", payload: .object(["damage": .int(3)]))
        #expect(CanonicalSyncEvent.hash([first]) != CanonicalSyncEvent.hash([resequenced]))
    }
}

@Suite("Snapshot patch applier")
struct SnapshotPatchApplierTests {
    @Test("Hand-written patches give the expected view")
    func appliesHandWrittenPatches() throws {
        var view = SnapshotClientView()
        try view.apply([
            set("/players", .object(["alice": .object(["hp": .int(10)])])),
            set("/round", .int(1)),
            set("/players/alice/hp", .int(7)),
            set("/players/bob", .object(["hp": .int(5)])),
            delete("/round"),
            set("/log", .array([.string("a")])),
            set("/log", .array([.string("a"), .string("b")])),
        ])
        #expect(view.fields == [
            "players": .object([
                "alice": .object(["hp": .int(7)]),
                "bob": .object(["hp": .int(5)]),
            ]),
            "log": .array([.string("a"), .string("b")]),
        ])
    }

    @Test("Escaped components unescape ~1 to / and ~0 to ~")
    func unescapes() throws {
        #expect(try SnapshotClientView.keys(of: "/a~1b/c~0d/~01") == ["a/b", "c~d", "~1"])
        var view = SnapshotClientView(fields: ["map": .object([:])])
        try view.apply(set("/map/x~1y", .int(1)))
        #expect(view.fields["map"] == .object(["x/y": .int(1)]))
    }

    @Test("Invalid paths and missing parents or targets throw")
    func strict() {
        var view = SnapshotClientView(fields: ["a": .int(1)])
        #expect(throws: SnapshotPatchError.invalidPath("a")) { try view.apply(set("a", .int(1))) }
        #expect(throws: SnapshotPatchError.invalidPath("/")) { try view.apply(set("/", .int(1))) }
        #expect(throws: SnapshotPatchError.invalidPath("/a~2")) { try view.apply(set("/a~2", .int(1))) }
        #expect(throws: SnapshotPatchError.nonObjectParent("/a/x")) { try view.apply(set("/a/x", .int(1))) }
        #expect(throws: SnapshotPatchError.nonObjectParent("/a/x")) { try view.apply(delete("/a/x")) }
        #expect(throws: SnapshotPatchError.missingParent("/missing/x")) { try view.apply(delete("/missing/x")) }
        #expect(throws: SnapshotPatchError.missingTarget("/b")) { try view.apply(delete("/b")) }
        #expect(view.fields == ["a": .int(1)], "a throwing patch changes nothing")
    }

    @Test("A set below a missing parent creates it, as the client does")
    func createsMissingParents() throws {
        var view = SnapshotClientView()
        try view.apply(set("/inventories/p1/sword", .int(1)))
        #expect(view.fields == ["inventories": .object(["p1": .object(["sword": .int(1)])])])
    }

    @Test("Delimiters followed by a combining mark are still delimiters")
    func combiningMarks() throws {
        // A key that starts with a combining mark: "/\u{301}x" is one grapheme cluster "/́".
        #expect(try SnapshotClientView.keys(of: "/a/\u{301}x") == ["a", "\u{301}x"])
        // "~1" followed by a combining mark: the escape is still "/", the mark stays in the key.
        #expect(try SnapshotClientView.keys(of: "/a~1\u{301}b") == ["a/\u{301}b"])
        var view = SnapshotClientView()
        try view.apply(set("/items/\u{301}x", .int(1)))
        #expect(view.fields == ["items": .object(["\u{301}x": .int(1)])])
    }

    @Test("An empty key is a valid component")
    func emptyKey() throws {
        #expect(try SnapshotClientView.keys(of: "/a/") == ["a", ""])
    }
}
