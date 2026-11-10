import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// #446: map keys and `PlayerID`s are NFC on the wire and in hashes. Swift's `String ==` holds an
// NFC and an NFD spelling as one key, so the server never had two entries; only the bytes it
// wrote depended on which spelling it was given.

private let nfc = "\u{E9}", nfd = "e\u{301}"

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// The keys of a converted object, as bytes.
private func keyBytes(_ value: SnapshotValue) -> [[UInt8]] {
    guard case .object(let object) = value else { return [] }
    return object.keys.map(bytes).sorted { $0.lexicographicallyPrecedes($1) }
}

/// A key type converted through its description (the `Mirror` path).
private struct DescribedKey: Hashable, CustomStringConvertible {
    var description: String
}

private struct PlainValue: Equatable {
    var n: Int = 1
}

@StateNodeBuilder
private struct NFCKeyState: StateNodeProtocol {
    @Sync(.broadcast) var names: [String: Int] = [:]
    @Sync(.broadcast) var players: [PlayerID: Int] = [:]
    @Sync(.broadcast) var owner: PlayerID? = nil
}

@Suite("NFC map keys and player IDs (#446)")
struct NFCKeyTests {
    @Test("The key helper: NFC text is returned as given, any other form in NFC")
    func helper() {
        #expect(nfc == nfd, "String equality is canonical equivalence")
        #expect(bytes(nfc) != bytes(nfd))
        for same in ["", "plain", "a/b", "t~x", nfc, "\u{4E2D}\u{6587}", "\u{1F600}"] {
            #expect(bytes(SnapshotValue.wireKey(same)) == bytes(same), "\(same)")
            #expect(SnapshotValue.isNFC(same), "\(same)")
        }
        #expect(bytes(SnapshotValue.wireKey(nfd)) == bytes(nfc))
        #expect(bytes(SnapshotValue.wireKey("x" + nfd + "y")) == bytes("x" + nfc + "y"))
        #expect(!SnapshotValue.isNFC(nfd))
        // The first code point that is not NFC-inert is U+0300: the fast path ends just below.
        #expect(SnapshotValue.isNFC("\u{2FF}"))
        #expect(!SnapshotValue.isNFC("a\u{300}"))
        #expect(bytes(SnapshotValue.wireKey("a\u{300}")) == bytes("\u{E0}"))
        // Not NFC without a combining mark: a singleton (the Kelvin sign maps to K).
        #expect(bytes(SnapshotValue.wireKey("\u{212A}")) == bytes("K"))
        // Hangul jamo compose into a syllable.
        #expect(bytes(SnapshotValue.wireKey("\u{1100}\u{1161}")) == bytes("\u{AC00}"))
        // A bridged string has no contiguous UTF-8 storage: the slow path gives the same answer.
        let bridged = NSString(string: nfd) as String
        #expect(bytes(SnapshotValue.wireKey(bridged)) == bytes(nfc))
        #expect(SnapshotValue.wireKey(NSString(string: "plain") as String) == "plain")
    }

    @Test("Every dictionary conversion writes an NFD key in NFC, in the client view and in the full state")
    func conversionSites() throws {
        let expected = [bytes("a"), bytes(nfc)]
        let shapes: [(String, Any)] = [
            ("[String: Int]", [nfd: 1, "a": 2] as [String: Int]),
            ("[String: Any]", [nfd: 1, "a": "x"] as [String: Any]),
            ("[String: struct]", [nfd: PlainValue(), "a": PlainValue()] as [String: PlainValue]),
            ("[String: [Int]]", [nfd: [1], "a": [2]] as [String: [Int]]),
            ("[String: SnapshotValueConvertible]", [nfd: Position2(x: 1, y: 2), "a": Position2(x: 3, y: 4)] as [String: SnapshotValueConvertible]),
            ("[String: SnapshotValue]", [nfd: .int(1), "a": .int(2)] as [String: SnapshotValue]),
            ("[PlayerID: Int]", [PlayerID(nfd): 1, PlayerID("a"): 2] as [PlayerID: Int]),
            ("[PlayerID: Any]", [PlayerID(nfd): 1, PlayerID("a"): "x"] as [PlayerID: Any]),
            ("[PlayerID: SnapshotValue]", [PlayerID(nfd): .int(1), PlayerID("a"): .int(2)] as [PlayerID: SnapshotValue]),
            ("[described key: Int]", [DescribedKey(description: nfd): 1, DescribedKey(description: "a"): 2] as [DescribedKey: Int]),
            ("[String: [String: Int]]", ["a": [nfd: 1, "a": 2]] as [String: [String: Int]]),
        ]
        for (name, value) in shapes {
            var client = try SnapshotValue.make(from: value)
            var full = try SnapshotValue.makeFull(from: value)
            if name == "[String: [String: Int]]" {
                guard case .object(let outer) = client, let inner = outer["a"],
                      case .object(let fullOuter) = full, let fullInner = fullOuter["a"]
                else {
                    Issue.record("\(name): no nested object")
                    continue
                }
                client = inner
                full = fullInner
            }
            #expect(keyBytes(client) == expected, "make, \(name)")
            #expect(keyBytes(full) == expected, "makeFull, \(name)")
        }
    }

    @Test("A PlayerID is NFC however it is created, and ASCII is kept as given")
    func playerIDCreation() throws {
        #expect(bytes(PlayerID(nfd).rawValue) == bytes(nfc))
        #expect(bytes(PlayerID(nfc).rawValue) == bytes(nfc))
        #expect(PlayerID("guest-1").rawValue == "guest-1")
        #expect(PlayerID(nfd) == PlayerID(nfc))
        #expect(bytes(PlayerID(nfd).description) == bytes(nfc))

        // Decoded as a value and as a dictionary key (JSON keeps the escaped NFD spelling).
        let decoder = JSONDecoder()
        let value = try decoder.decode([PlayerID].self, from: Data(#"["e\u0301"]"#.utf8))
        #expect(bytes(value[0].rawValue) == bytes(nfc))
        let keyed = try decoder.decode([PlayerID: Int].self, from: Data(#"{"e\u0301":1}"#.utf8))
        #expect(keyed.keys.map { bytes($0.rawValue) } == [bytes(nfc)])
        let viaCanonical = try CanonicalMessagePack.decode(PlayerID.self, from: try CanonicalMessagePack.encode(nfd))
        #expect(bytes(viaCanonical.rawValue) == bytes(nfc))

        // Encoded as the stored (NFC) bytes.
        let encoded = try JSONEncoder().encode([PlayerID(nfd)])
        #expect(Array(encoded) == Array(Data("[\"\(nfc)\"]".utf8)))
    }

    @Test("An NFD player ID is the same bytes as a map key and as a value in state")
    func playerIDInState() throws {
        var state = NFCKeyState()
        state.players[PlayerID(nfd)] = 1
        state.owner = PlayerID(nfd)
        state.names[nfd] = 2
        let snapshot = try state.snapshot(for: nil, dirtyFields: nil).values
        #expect(keyBytes(snapshot["players"] ?? .null) == [bytes(nfc)])
        #expect(keyBytes(snapshot["names"] ?? .null) == [bytes(nfc)])
        guard case .string(let owner)? = snapshot["owner"] else {
            Issue.record("owner is \(String(describing: snapshot["owner"]))")
            return
        }
        #expect(bytes(owner) == bytes(nfc))
    }

    @Test("The state hash is the same for either spelling of a key")
    func stateHash() throws {
        var composed = NFCKeyState()
        composed.names[nfc] = 1
        composed.players[PlayerID(nfc)] = 2
        var decomposed = NFCKeyState()
        decomposed.names[nfd] = 1
        decomposed.players[PlayerID(nfd)] = 2
        let first = ReevaluationEngine.stateHash(composed, definition: .fullState)
        let second = ReevaluationEngine.stateHash(decomposed, definition: .fullState)
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("A record older than 3.3 holding text that is not NFC has a not-comparable state hash")
    func recordIncomparability() throws {
        #expect(ReevaluationRecordVersion.current == "3.3")
        #expect(ReevaluationRecordVersion.hashIncomparability(recorded: "3.2", holdsNonNFCText: false) == nil)
        #expect(ReevaluationRecordVersion.hashIncomparability(recorded: "3.3", holdsNonNFCText: true) == nil)
        #expect(ReevaluationRecordVersion.hashIncomparability(recorded: nil, holdsNonNFCText: true) == nil)
        for old in ["2.5", "2.6", "3.0", "3.2"] {
            #expect(ReevaluationRecordVersion.hashIncomparability(recorded: old, holdsNonNFCText: true) != nil, "\(old)")
        }

        // The scan sees strings and map keys at any depth, and nothing in ASCII or NFC text.
        struct Holder: Codable {
            var list: [[String: String]]
        }
        func scan(_ holder: Holder) throws -> Bool {
            try CanonicalMessagePack.holdsNonNFCText(try CanonicalMessagePack.encode(holder))
        }
        #expect(try !scan(Holder(list: [["a": "b"], [nfc: nfc]])))
        #expect(try scan(Holder(list: [["a": nfd]])))
        #expect(try scan(Holder(list: [["a": "b"], [nfd: "x"]])))
    }

    @Test("A record file older than 3.3 is scanned for text that is not NFC; a 3.3 file is not")
    func recordSourcesScan() async throws {
        func log(minor: UInt8, landID: String) throws -> [UInt8] {
            var header = ReevaluationLogRecord(kind: .header)
            header.metadata = ReevaluationRecordMetadata(
                landID: landID, landType: "t", createdAt: Date(timeIntervalSince1970: 0), metadata: [:], version: "3.\(minor)"
            )
            var bytes = ReevaluationRecordLog.preamble
            bytes[5] = minor
            bytes += try ReevaluationRecordLog.framed(header)
            bytes += try ReevaluationRecordLog.framed(.turn(ReevaluationTickRecord(tickId: 0, stateHash: "h")))
            return bytes
        }
        #expect(try await ReevaluationRecordLogSource(bytes: log(minor: 2, landID: nfd)).getHoldsNonNFCText())
        #expect(try await !ReevaluationRecordLogSource(bytes: log(minor: 2, landID: nfc)).getHoldsNonNFCText())
        #expect(try await !ReevaluationRecordLogSource(bytes: log(minor: 2, landID: "ascii")).getHoldsNonNFCText())
        // From 3.3 on the recorder wrote NFC keys and IDs; other text is not a reason.
        #expect(try await !ReevaluationRecordLogSource(bytes: log(minor: 3, landID: nfd)).getHoldsNonNFCText())

        // A 2.x JSON record.
        func json(landID: String) -> Data {
            Data(#"{"recordMetadata":{"landID":"\#(landID)","landType":"t","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"2.6"},"tickFrames":[]}"#.utf8)
        }
        #expect(try await JSONReevaluationSource(data: json(landID: nfd)).getHoldsNonNFCText())
        #expect(try await !JSONReevaluationSource(data: json(landID: nfc)).getHoldsNonNFCText())
        // Frames built in memory: the default.
        let built = JSONReevaluationSource(
            metadata: ReevaluationRecordMetadata(landID: nfd, landType: "t", createdAt: Date(), metadata: [:]), frames: []
        )
        #expect(try await !built.getHoldsNonNFCText())
    }
}
