// Tests/SwiftStateTreeTests/ShapeMatrixRoundTripTests.swift
//
// One state that holds every schema shape a wire-form change has missed before (#257, #271,
// #272, #278, #284): optionals (nested too), `$ref`s, wrapper structs, `let`-only types, arrays,
// maps and optionals of atomic values, and map keys that a path parser can get wrong (`a[0]`,
// `a/b`, `t~x`, a decomposed accent). A recursive state type has no case: schema generation
// refuses it (#286, `RecursiveStateSchemaTests`).
//
// Known issues are marked per case and flag their own fix (a marked case that passes fails):
// #288, a non-atomic `let`-only struct's atomic values stay keyed. The fixture carries a decode
// marker (`knownIssue`), so `sdk/ts` and `Tools/CLI` expect the same failures; no case has one
// since #289 (a dynamic key slot shared by canonically equivalent keys) was fixed.
//
// Each case is one patch. Swift encodes it in both opcode formats with the production settings
// (path hashes from the schema, dynamic key compression, the atomic layout table) and checks the
// payloads: the patch value on the wire against a hand-written expected value, the MessagePack
// frame against the JSON frame element by element, and the decoded patch against the logical one.
// The fixture `Tests/SwiftStateTreeTransportTests/Fixtures/ShapeMatrix/shape-matrix.json` (the
// schema, and per case the frames, the wire value and the logical value) is decoded by `sdk/ts`
// (the view, from the raw frames) and `Tools/CLI` (schema conformance), which must reach the same
// logical value.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath
import SwiftStateTreeMessagePack

// MARK: - Shapes

/// Atomic and `let`-only: no `init()`, described by the macro's field metadata.
@SnapshotConvertible(atomic: true)
struct ShapeMark: Equatable, Sendable {
    let x: Int32
    let y: Int32
}

/// Not atomic, `let`-only, holding an atomic value.
@SnapshotConvertible
struct ShapeFixed: Equatable, Sendable {
    let at: Position2
    let label: String
}

/// A wrapper struct around one atomic value.
@SnapshotConvertible
struct ShapeWrapper: Codable, Equatable, Sendable {
    var at: Position2

    init() { at = Position2(x: 0, y: 0) }
    init(at: Position2) { self.at = at }
}

@SnapshotConvertible
struct ShapeInner: Codable, Equatable, Sendable {
    var at: Position2?
    var heading: Angle

    init() {
        at = nil
        heading = Angle()
    }

    init(at: Position2?, heading: Angle) {
        self.at = at
        self.heading = heading
    }
}

/// An optional holding an optional holding an optional atomic value.
@SnapshotConvertible
struct ShapeHolder: Codable, Equatable, Sendable {
    var inner: ShapeInner?
    var tag: Int

    init() {
        inner = nil
        tag = 0
    }

    init(inner: ShapeInner?, tag: Int) {
        self.inner = inner
        self.tag = tag
    }
}

@StateNodeBuilder
struct ShapeMatrixState: StateNodeProtocol {
    @Sync(.broadcast) var pos: Position2 = Position2(x: 0, y: 0)
    @Sync(.broadcast) var angle: Angle = Angle()
    @Sync(.broadcast) var maybePos: Position2? = nil
    @Sync(.broadcast) var holder: ShapeHolder? = nil
    @Sync(.broadcast) var wrapper: ShapeWrapper = ShapeWrapper()
    @Sync(.broadcast) var mark: ShapeMark = ShapeMark(x: 0, y: 0)
    @Sync(.broadcast) var fixed: ShapeFixed = ShapeFixed(at: Position2(x: 0, y: 0), label: "")
    @Sync(.broadcast) var points: [Position2] = []
    @Sync(.broadcast) var maybePoints: [Position2]? = nil
    @Sync(.broadcast) var angles: [Angle] = []
    @Sync(.broadcast) var byKey: [String: Position2] = [:]
    @Sync(.broadcast) var maybeByKey: [String: Position2]? = nil
    @Sync(.broadcast) var marks: [String: ShapeMark] = [:]
    @Sync(.broadcast) var wrappers: [String: ShapeWrapper] = [:]
}

func makeShapeMatrixLand() -> LandDefinition<ShapeMatrixState> {
    Land("shape-matrix", using: ShapeMatrixState.self) {}
}

enum ShapeMatrixEnvKeys {
    /// Set to `1` to rewrite the fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_SHAPE_MATRIX"
}

// MARK: - Tests

@Suite("Shape matrix: every schema shape round-trips through both opcode formats")
struct ShapeMatrixRoundTripTests {
    static let landType = "shape-matrix"
    static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SwiftStateTreeTransportTests/Fixtures/ShapeMatrix/shape-matrix.json").path

    static let table = AtomicLayoutTable.forState(ShapeMatrixState.self)

    static func p(_ x: Int32, _ y: Int32) -> Position2 { Position2(x: Float(x), y: Float(y)) }
    static func a(_ degrees: Int32) -> Angle { Angle(degrees: Float(degrees)) }

    /// `e` followed by a combining acute accent: canonically equal to `é` (U+00E9) for Swift's
    /// `==`, but different bytes. A map converted for the wire writes the key in NFC (#446); a
    /// patch path keeps the bytes it was given.
    static let decomposed = "e\u{301}"
    static let composed = "\u{e9}"

    struct Case {
        let name: String
        /// The patch path, a JSON Pointer (keys escaped).
        let path: String
        /// The value as `StatePatch` holds it (keyed).
        let logical: SnapshotValue
        /// What both opcode encoders must send, written by hand as JSON.
        let wire: String
        /// The frame doesn't decode to this patch until the issue is fixed: #289 (a dynamic key
        /// slot shared by canonically equivalent keys).
        var decodeIssue: Int? = nil
        /// #288: the value goes out keyed.
        var wireIssue: Int? = nil
    }

    /// In order: a container is set before a patch into it, as the SDK view applies them.
    static func cases() throws -> [Case] {
        func v(_ value: Any) throws -> SnapshotValue { try SnapshotValue.make(from: value) }
        let d = decomposed, c = composed
        return [
            Case(name: "atomic", path: "/pos", logical: try v(p(1, 2)), wire: "[1000,2000]"),
            Case(name: "atomic, one leaf", path: "/angle", logical: try v(a(90)), wire: "[90000]"),
            Case(name: "optional atomic nil", path: "/maybePos", logical: .null, wire: "null"),
            Case(name: "optional atomic set", path: "/maybePos", logical: try v(p(3, 4)), wire: "[3000,4000]"),
            Case(
                name: "optional struct with nested optionals",
                path: "/holder",
                logical: try v(ShapeHolder(inner: ShapeInner(at: p(5, 6), heading: a(45)), tag: 7)),
                wire: #"{"inner":{"at":[5000,6000],"heading":[45000]},"tag":7}"#
            ),
            Case(name: "nested optional atomic", path: "/holder/inner/at", logical: try v(p(7, 8)), wire: "[7000,8000]"),
            Case(name: "nested optional atomic nil", path: "/holder/inner/at", logical: .null, wire: "null"),
            Case(name: "nested optional struct nil", path: "/holder/inner", logical: .null, wire: "null"),
            Case(name: "wrapper struct", path: "/wrapper", logical: try v(ShapeWrapper(at: p(9, 10))), wire: #"{"at":[9000,10000]}"#),
            Case(name: "wrapper struct field", path: "/wrapper/at", logical: try v(p(11, 12)), wire: "[11000,12000]"),
            Case(name: "let-only atomic", path: "/mark", logical: try v(ShapeMark(x: 1, y: 2)), wire: "[1,2]"),
            Case(
                name: "let-only struct",
                path: "/fixed",
                logical: try v(ShapeFixed(at: p(13, 14), label: "f")),
                wire: #"{"at":[13000,14000],"label":"f"}"#,
                wireIssue: 288
            ),
            Case(name: "array of atomic", path: "/points", logical: try v([p(1, 1), p(2, 2)]), wire: "[[1000,1000],[2000,2000]]"),
            Case(name: "array element", path: "/points/1", logical: try v(p(3, 3)), wire: "[3000,3000]"),
            Case(name: "optional array set", path: "/maybePoints", logical: try v([p(4, 4)]), wire: "[[4000,4000]]"),
            Case(name: "optional array element", path: "/maybePoints/0", logical: try v(p(5, 5)), wire: "[5000,5000]"),
            Case(name: "array of one-leaf atomic", path: "/angles", logical: try v([a(10), a(20)]), wire: "[[10000],[20000]]"),
            Case(
                name: "map of atomic with odd keys",
                path: "/byKey",
                logical: try v(["a[0]": p(1, 0), "a/b": p(2, 0), "t~x": p(3, 0), d: p(4, 0), "plain": p(5, 0)]),
                wire: #"{"a/b":[2000,0],"a[0]":[1000,0],"plain":[5000,0],"t~x":[3000,0],"\#u{e9}":[4000,0]}"#
            ),
            Case(name: "map key ending in [n]", path: "/byKey/a[0]", logical: try v(p(6, 0)), wire: "[6000,0]"),
            Case(name: "map key with a slash", path: "/byKey/a~1b", logical: try v(p(7, 0)), wire: "[7000,0]"),
            Case(name: "map key with a tilde", path: "/byKey/t~0x", logical: try v(p(8, 0)), wire: "[8000,0]"),
            Case(name: "map key decomposed", path: "/byKey/\(d)", logical: try v(p(9, 0)), wire: "[9000,0]"),
            Case(name: "map key composed, a new key", path: "/byKey/\(c)", logical: try v(p(10, 0)), wire: "[10000,0]"),
            Case(name: "optional map nil", path: "/maybeByKey", logical: .null, wire: "null"),
            Case(name: "optional map set", path: "/maybeByKey", logical: try v(["k": p(1, 1)]), wire: #"{"k":[1000,1000]}"#),
            Case(name: "optional map key", path: "/maybeByKey/a[1]", logical: try v(p(2, 2)), wire: "[2000,2000]"),
            Case(name: "map of let-only atomic", path: "/marks", logical: try v(["m": ShapeMark(x: 3, y: 4)]), wire: #"{"m":[3,4]}"#),
            Case(name: "map of let-only atomic key", path: "/marks/m", logical: try v(ShapeMark(x: 5, y: 6)), wire: "[5,6]"),
            // An empty key is a key: `/byKey/` is the entry under "", `/wrappers//at` its field.
            Case(name: "map key empty", path: "/byKey/", logical: try v(p(11, 0)), wire: "[11000,0]"),
            Case(name: "map key empty, struct entry", path: "/wrappers/", logical: try v(ShapeWrapper(at: p(12, 0))), wire: #"{"at":[12000,0]}"#),
            Case(name: "map key empty, a field", path: "/wrappers//at", logical: try v(p(13, 0)), wire: "[13000,0]"),
        ]
    }

    // MARK: Encoding

    struct Frames {
        let json: [Data]
        let messagePack: [Data]
    }

    static func schema() throws -> ProtocolSchema {
        try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(makeShapeMatrixLand())])
    }

    static func pathHasher() throws -> PathHasher {
        let hashes = try #require(try schema().lands[landType]?.pathHashes)
        return PathHasher(pathHashes: hashes)
    }

    /// One frame per case, in order, from one encoder per format: the dynamic key table carries
    /// over between frames, as on a connection.
    static func encodeFrames() throws -> Frames {
        let hasher = try pathHasher()
        let json = OpcodeJSONStateUpdateEncoder(pathHasher: hasher, dynamicKeyCompression: true, atomicLayout: table)
        let messagePack = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, dynamicKeyCompression: true, atomicLayout: table)
        var jsonFrames: [Data] = []
        var packFrames: [Data] = []
        for c in try cases() {
            let update = StateUpdate.diff([StatePatch(path: c.path, operation: .set(c.logical))])
            jsonFrames.append(try json.encode(update: update, landID: landType, playerID: PlayerID("p1")))
            packFrames.append(try messagePack.encode(update: update, landID: landType, playerID: PlayerID("p1")))
        }
        return Frames(json: jsonFrames, messagePack: packFrames)
    }

    /// A JSON-compatible value, so a MessagePack frame and a JSON frame compare element by element.
    static func plain(_ value: MessagePackValue) throws -> Any {
        switch value {
        case .nil: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .uint(let u): return u
        case .float(let f): return Double(f)
        case .double(let d): return d
        case .string(let s): return s
        case .array(let elements): return try elements.map(plain)
        case .map(let pairs):
            var object: [String: Any] = [:]
            for (key, element) in pairs {
                guard case .string(let name) = key else { throw ShapeMatrixError.nonStringKey }
                object[name] = try plain(element)
            }
            return object
        case .binary, .extended: throw ShapeMatrixError.unexpectedType
        }
    }

    enum ShapeMatrixError: Error { case nonStringKey, unexpectedType }

    /// A canonical text for comparing JSON values: sorted keys, numbers as JSONSerialization
    /// writes them. Strings keep their bytes (no normalization).
    static func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func canonical(json text: String) throws -> String {
        try canonical(try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
    }

    /// Runs `body` as a known issue when `issue` is set: it must fail until the issue is fixed,
    /// and only with that issue's failure (`isExpected`). Any other failure is a real one.
    static func known(_ issue: Int?, _ body: () throws -> Void) throws {
        guard let issue else { return try body() }
        try withKnownIssue("#\(issue)") {
            try body()
        } matching: { recorded in
            isExpected(issue, error: recorded.error, comments: recorded.comments.map(\.rawValue))
        }
    }

    /// The one failure each open issue causes here:
    /// - #288: the value at a let-only struct's atomic path isn't positional (an expectation
    ///   commented "wire value");
    /// - #289: the decoded path keeps the first-defined key's bytes ("path bytes").
    static func isExpected(_ issue: Int, error: (any Error)?, comments: [String]) -> Bool {
        let commented = { (suffix: String) in comments.contains { $0.hasSuffix(suffix) } }
        switch issue {
        case 288:
            return error == nil && (commented(": wire value") || commented("fixed.at is positional"))
        case 289:
            return error == nil && commented(": path bytes")
        default:
            return false
        }
    }

    // MARK: Tests

    @Test("The table, the path hashes and the schema cover every shape")
    func schemaCoversEveryShape() throws {
        let schema = try Self.schema()
        let hashes = try #require(schema.lands[Self.landType]?.pathHashes)
        let leaves = [["v", "x"], ["v", "y"]]
        for pattern in ["pos", "maybePos", "holder.inner.at", "wrapper.at", "points.*", "maybePoints.*", "byKey.*", "maybeByKey.*", "wrappers.*.at"] {
            #expect(Self.table.patterns[pattern] == leaves, "atomic pattern \(pattern)")
        }
        try Self.known(288) { () throws -> Void in
            #expect(Self.table.patterns["fixed.at"] == leaves, "fixed.at is positional")
        }
        #expect(Self.table.patterns["angle"] == [["degrees"]])
        #expect(Self.table.patterns["angles.*"] == [["degrees"]])
        #expect(Self.table.patterns["mark"] == [["x"], ["y"]])
        #expect(Self.table.patterns["marks.*"] == [["x"], ["y"]])
        for c in try Self.cases() {
            let (hash, _) = try Self.pathHasher().split(c.path)
            #expect(hashes.values.contains(hash), "\(c.name): \(c.path) has a path hash in the schema")
        }
    }

    @Test("Every case's patch value on the wire is the expected positional value")
    func wireValues() throws {
        for c in try Self.cases() {
            let wire = try Self.table.positional(c.logical, atPath: c.path)
            let encoded = try JSONEncoder().encode(wire)
            try Self.known(c.wireIssue) { () throws -> Void in
                #expect(try Self.canonical(json: String(decoding: encoded, as: UTF8.self)) == Self.canonical(json: c.wire), "\(c.name): wire value")
            }
        }
    }

    @Test("Both opcode frames carry the expected value, and the MessagePack frame equals the JSON frame")
    func framesCarryThePayload() throws {
        let frames = try Self.encodeFrames()
        for (index, c) in try Self.cases().enumerated() {
            let jsonFrame = try #require(try JSONSerialization.jsonObject(with: frames.json[index]) as? [Any], "\(c.name)")
            // [opcode, [pathHash, dynamicKey, op, value]]
            let patch = try #require(jsonFrame.count == 2 ? jsonFrame[1] as? [Any] : nil, "\(c.name): one patch")
            let value = try #require(patch.last, "\(c.name)")
            try Self.known(c.wireIssue) { () throws -> Void in
                #expect(try Self.canonical(value) == Self.canonical(json: c.wire), "\(c.name): JSON frame: wire value")
            }

            let packed = try Self.plain(try unpack(frames.messagePack[index]))
            #expect(try Self.canonical(packed) == Self.canonical(jsonFrame), "\(c.name): MessagePack frame equals the JSON frame")
        }
    }

    @Test("The decoded JSON frames are the logical patches, keys byte for byte")
    func swiftDecodesTheLogicalPatches() throws {
        let frames = try Self.encodeFrames()
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: try Self.pathHasher(), atomicLayout: Self.table)
        for (index, c) in try Self.cases().enumerated() {
            guard case .diff(let patches) = try decoder.decode(data: frames.json[index]).update else {
                Issue.record("\(c.name): not a diff")
                continue
            }
            #expect(patches == [StatePatch(path: c.path, operation: .set(c.logical))], "\(c.name)")
            try Self.known(c.decodeIssue == 289 ? 289 : nil) { () throws -> Void in
                // Swift's == on String is canonical equivalence; the path must keep its bytes.
                #expect(patches.first.map { Array($0.path.utf8) } == Array(c.path.utf8), "\(c.name): path bytes")
            }
        }
    }

    @Test("A known-issue case still fails on any other failure")
    func knownIssuesAreNarrow() throws {
        // The matcher takes only the issue's own failure.
        #expect(!Self.isExpected(289, error: StateUpdateDecodingError.invalidPayload("Unknown pathHash: 1"), comments: []))
        #expect(!Self.isExpected(289, error: nil, comments: ["c: MessagePack frame equals the JSON frame"]))
        #expect(Self.isExpected(289, error: nil, comments: ["c: path bytes"]))
        #expect(!Self.isExpected(289, error: nil, comments: ["c: wire value"]))
        #expect(!Self.isExpected(288, error: StateUpdateDecodingError.invalidPayload("Unknown pathHash: 1"), comments: []))
        // A mutant: a different failure inside a #289 case escapes it. The outer known issue
        // fails this test if the inner one swallowed it.
        try withKnownIssue("a different failure isn't absorbed by #289") {
            try Self.known(289) { () throws -> Void in
                throw StateUpdateDecodingError.invalidPayload("Invalid dynamic key format: mutant")
            }
        } matching: { recorded in
            guard let error = recorded.error as? StateUpdateDecodingError, case .invalidPayload(let message) = error else { return false }
            return message.hasSuffix("mutant")
        }
    }

    // MARK: Fixture

    struct FixtureCase: Codable, Equatable {
        let name: String
        let path: String
        /// The patch value both encoders send.
        let wire: SnapshotValue
        /// The value as `StatePatch` holds it (keyed).
        let logical: SnapshotValue
        /// The opcode JSON frame, as text.
        let jsonFrame: String
        /// The opcode MessagePack frame, base64.
        let messagePackFrame: String
        /// Set when the frame doesn't decode to this patch until the issue is fixed (#289).
        let knownIssue: Int?
    }

    struct Fixture: Codable {
        let schema: ProtocolSchema
        let landType: String
        let cases: [FixtureCase]
    }

    static func encodeFixture() throws -> Data {
        let frames = try encodeFrames()
        let cases = try cases().enumerated().map { index, c in
            FixtureCase(
                name: c.name,
                path: c.path,
                wire: try table.positional(c.logical, atPath: c.path),
                logical: c.logical,
                jsonFrame: String(decoding: frames.json[index], as: UTF8.self),
                messagePackFrame: frames.messagePack[index].base64EncodedString(),
                knownIssue: c.decodeIssue
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Fixture(schema: try schema(), landType: landType, cases: cases))
    }

    @Test("The checked-in fixture for sdk/ts and Tools/CLI is current")
    func fixtureIsCurrent() throws {
        let data = try Self.encodeFixture()
        if EnvHelpers.getEnvBool(key: ShapeMatrixEnvKeys.regenerate, defaultValue: false) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Self.fixturePath).deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            return
        }
        // Frames are compared decoded: map order in an encoded frame follows Dictionary order, which
        // differs between processes.
        let checkedIn = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(
            try Self.comparable(data) == Self.comparable(checkedIn),
            "if intended, rerun with \(ShapeMatrixEnvKeys.regenerate)=1 swift test --filter ShapeMatrixRoundTripTests"
        )
    }

    /// The fixture with each frame replaced by its decoded, canonical text.
    static func comparable(_ data: Data) throws -> String {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(object["cases"] as? [[String: Any]])
        object["cases"] = try cases.map { c -> [String: Any] in
            var c = c
            let json = try #require(c["jsonFrame"] as? String)
            let base64 = try #require(c["messagePackFrame"] as? String)
            let pack = try #require(Data(base64Encoded: base64))
            c["jsonFrame"] = try canonical(json: json)
            c["messagePackFrame"] = try canonical(try plain(try unpack(pack)))
            return c
        }
        return try canonical(object)
    }
}
