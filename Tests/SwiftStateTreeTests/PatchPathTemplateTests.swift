// Tests/SwiftStateTreeTests/PatchPathTemplateTests.swift
//
// A patch's path rebuilt from its split (#392): the hasher's templates, the lossless rule, and
// the three forms of `StatePatch`.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("A patch's path rebuilt from its split (#392)")
struct PatchPathTemplateTests {
    /// NFC "café" as a label; the NFD spelling of the same name is `String`-equal to it.
    static let nfc = "caf\u{E9}"
    static let nfd = "cafe\u{301}"

    let hasher = PathHasher(pathHashes: Dictionary(uniqueKeysWithValues: [
        "players.*.position",
        "players.*.inventory.*.itemId",
        "players.*",
        "m.*",
        "m.*.v",
        "a.b.c",
        "K.x",
        "a~1b",
        "\(PatchPathTemplateTests.nfc).x",
    ].map { ($0, DeterministicHash.fnv1a32($0)) }))

    /// The cursor after walking `path`'s components from the root; nil when the walk leaves
    /// the trie.
    func walk(_ path: String) -> PathHasher.Cursor? {
        var cursor: PathHasher.Cursor? = hasher.rootCursor
        for component in PathHasher.components(of: path) {
            cursor = cursor?.descending(component)
        }
        return cursor
    }

    @Test("A split rebuilds the walked path byte for byte, keys with `~`, `/`, `[` and empty ones included")
    func templatesRebuildTheWalkedPath() throws {
        let paths = [
            "/players/42/position",
            "/players/a~1b/inventory/7/itemId",
            "/players/t~0x",
            "/players/a[0]",
            "/m/",
            "/m//v",
            "/m/\(Self.nfd)/v",
            "/a/b/c",
            "/K/x",
            "/a~1b",
        ]
        for path in paths {
            let cursor = try #require(walk(path), "\(path)")
            #expect(cursor.isLossless, "\(path)")
            let split = try #require(cursor.split, "\(path)")
            #expect(split.rebuiltPath().utf8.elementsEqual(path.utf8), "\(path)")
            #expect(split.pathHash == hasher.split(path).pathHash)
            #expect(split.dynamicKeys == hasher.split(path).dynamicKeys)
        }
    }

    @Test("An unhashed intermediate position rebuilds its own path")
    func intermediateRebuilds() throws {
        let cursor = try #require(walk("/a/b"))
        #expect(cursor.split == nil)
        #expect(cursor.rebuiltPath == "/a/b")
        #expect(cursor.descending("z") == nil, "a walk-off below it")
    }

    @Test("A literal String-equal to its label but spelled with other bytes is lossy")
    func canonicallyEqualLiteralIsLossy() throws {
        // A non-ASCII label against its NFD spelling.
        let nfd = try #require(walk("/\(Self.nfd)/x"))
        #expect(!nfd.isLossless)
        #expect(nfd.split != nil, "the split still names the pattern")
        #expect(!nfd.rebuiltPath.utf8.elementsEqual("/\(Self.nfd)/x".utf8))
        #expect(try #require(walk("/\(Self.nfc)/x")).isLossless)
        // An ASCII label against a longer canonically equal spelling (U+212A KELVIN SIGN).
        let kelvin = try #require(walk("/\u{212A}/x"))
        #expect(!kelvin.isLossless)
        #expect(try #require(walk("/K/x")).isLossless)
        // A lossy ancestor keeps the position lossy below it.
        #expect(try #require(walk("/\(Self.nfd)")).isLossless == false)
    }

    @Test("A split-only patch rebuilds its path; == compares splits of one hasher by String equality")
    func splitOnlyPatch() throws {
        let split = try #require(walk("/players/42/position")?.split)
        let patch = StatePatch(split: split, operation: .set(.int(1)))
        #expect(patch.isSplitOnly)
        #expect(patch.path == "/players/42/position")
        #expect(patch == StatePatch(path: "/players/42/position", operation: .set(.int(1))))
        #expect(patch != StatePatch(split: split, operation: .set(.int(2))))

        // Keys compared with String equality, as the paths would be.
        let nfcKey = try #require(walk("/m/\(Self.nfc)/v")?.split)
        let nfdKey = try #require(walk("/m/\(Self.nfd)/v")?.split)
        #expect(StatePatch(split: nfcKey, operation: .delete) == StatePatch(split: nfdKey, operation: .delete))
        let other = try #require(walk("/players/43/position")?.split)
        #expect(StatePatch(split: split, operation: .delete) != StatePatch(split: other, operation: .delete))
    }

    @Test("retagged keeps the form; Codable writes the rebuilt path and decodes the string form")
    func retaggedAndCodable() throws {
        let split = try #require(walk("/players/42")?.split)
        let row = split.asRow(3, generation: 7)
        let splitOnly = StatePatch(split: split, operation: .set(.int(1))).retagged(row)
        #expect(splitOnly.isSplitOnly && splitOnly.split?.row?.generation == 7)
        let stored = StatePatch(path: "/players/42", operation: .set(.int(1)), split: split).retagged(row)
        #expect(!stored.isSplitOnly && stored.split?.row?.slot == 3 && stored.path == "/players/42")

        let data = try JSONEncoder().encode(splitOnly)
        let decoded = try JSONDecoder().decode(StatePatch.self, from: data)
        #expect(decoded.path == "/players/42" && decoded.split == nil && !decoded.isSplitOnly)
        #expect(decoded == splitOnly)
    }

    #if DEBUG
    @Test("The rebuild counter counts path on a split-only patch, not debugRebuiltPath or a stored path")
    func rebuildCounter() throws {
        let split = try #require(walk("/players/42/position")?.split)
        let splitOnly = StatePatch(split: split, operation: .delete)
        let stored = StatePatch(path: "/players/42/position", operation: .delete, split: split)
        let counter = PathRebuildCounter()
        StatePatch.$pathRebuilds.withValue(counter) {
            _ = splitOnly.debugRebuiltPath
            _ = stored.path
            #expect(counter.count == 0)
            _ = splitOnly.path
            #expect(counter.count == 1)
        }
    }
    #endif
}
