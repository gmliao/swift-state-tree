// Tests/SwiftStateTreeTransportTests/PathIndexTests.swift
//
// The path index (`TransportEncodingConfig.pathIndex`): an opcode patch entry carries the
// pattern's rank among the land's sorted schema path hashes instead of the 32-bit hash. A path
// without a schema pattern has no index and fails its frame on the server. A client declares the
// feature in its join metadata (`stateUpdateFeatures`); a server with it on refuses a join that
// doesn't, and echoes it in `joinResponse`.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

@StateNodeBuilder
struct PathIndexState: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var players: [String: Int] = [:]
}

@StateNodeBuilder
struct PathIndexOtherState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var names: [String: String] = [:]
    @Sync(.broadcast) var flags: [String: Bool] = [:]
}

/// Records what the transport sends to one session.
actor PathIndexReplyConnection: WebSocketConnection {
    private(set) var messages: [Data] = []
    private var waiters: [CheckedContinuation<Data, Never>] = []

    func send(_ data: Data) async throws {
        messages.append(data)
        let first = messages[0]
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: first) }
    }

    /// The first message sent to this connection, once it is sent.
    func firstMessage() async -> Data {
        if let first = messages.first { return first }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func close() async throws {}
}

@Suite("Path index")
struct PathIndexTests {
    static let landType = "path-index"

    static func pathHashes<State: StateNodeProtocol>(_ type: State.Type, _ landType: String) throws -> [String: UInt32] {
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(Land(landType, using: type) {})])
        return try #require(schema.lands[landType]?.pathHashes)
    }

    // MARK: Rank table

    @Test("The rank table is the land's path hashes, de-duplicated and sorted ascending, per land")
    func rankTable() throws {
        let hashes = try Self.pathHashes(PathIndexState.self, Self.landType)
        let other = try Self.pathHashes(PathIndexOtherState.self, "path-index-other")
        for table in [hashes, other] {
            let hasher = PathHasher(pathHashes: table)
            #expect(hasher.sortedHashes == Array(Set(table.values)).sorted())
            for (index, hash) in hasher.sortedHashes.enumerated() {
                #expect(hasher.pathIndex(of: hash) == index)
                #expect(hasher.hash(atPathIndex: index) == hash)
            }
            #expect(hasher.hash(atPathIndex: hasher.sortedHashes.count) == nil)
            #expect(hasher.hash(atPathIndex: -1) == nil)
        }
        // The same rank names a different pattern in each land: a rank is per land.
        let (first, second) = (PathHasher(pathHashes: hashes), PathHasher(pathHashes: other))
        let patternAtOne = { (h: PathHasher) in h.hash(atPathIndex: 1).flatMap { h.getPath(for: $0) } }
        #expect(patternAtOne(first) != nil)
        #expect(patternAtOne(first) != patternAtOne(second))
    }

    // MARK: Encoding

    static let patches = [
        StatePatch(path: "/score", operation: .set(.int(3))),
        StatePatch(path: "/players/a", operation: .set(.int(1))),
        StatePatch(path: "/players/b", operation: .add(.int(2))),
        StatePatch(path: "/players/a", operation: .delete),
    ]

    @Test("With the path index on, both opcode encoders send the index; the decoder reads the logical patches back")
    func roundTrip() throws {
        let hasher = PathHasher(pathHashes: try Self.pathHashes(PathIndexState.self, Self.landType))
        let json = OpcodeJSONStateUpdateEncoder(pathHasher: hasher, pathIndex: true)
        let messagePack = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: true)
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)

        let jsonData = try json.encode(update: .diff(Self.patches), landID: Self.landType, playerID: PlayerID("p1"))
        let frame = try #require(try JSONSerialization.jsonObject(with: jsonData) as? [Any])
        let packed = try unpack(try messagePack.encode(update: .diff(Self.patches), landID: Self.landType, playerID: PlayerID("p1")))
        guard case .array(let packedFrame) = packed else {
            Issue.record("MessagePack frame is not an array")
            return
        }
        #expect(frame.count == Self.patches.count + 1)
        #expect(packedFrame.count == Self.patches.count + 1)
        for (offset, patch) in Self.patches.enumerated() {
            let (hash, _) = hasher.split(patch.path)
            let index = try #require(hasher.pathIndex(of: hash))
            let entry = try #require(frame[offset + 1] as? [Any])
            #expect(entry.first as? Int == index, "\(patch.path): JSON path id")
            guard case .array(let packedEntry) = packedFrame[offset + 1] else {
                Issue.record("\(patch.path): MessagePack entry is not an array")
                continue
            }
            let packedID: Int? = switch packedEntry.first {
            case .int(let v): Int(v)
            case .uint(let v): Int(v)
            default: nil
            }
            #expect(packedID == index, "\(patch.path): MessagePack path id")
        }
        guard case .diff(let decoded) = try decoder.decode(data: jsonData).update else {
            Issue.record("not a diff")
            return
        }
        #expect(decoded == Self.patches)
    }

    @Test("With the path index off, the encoders send the hash, as before")
    func offSendsHash() throws {
        let hasher = PathHasher(pathHashes: try Self.pathHashes(PathIndexState.self, Self.landType))
        let data = try OpcodeJSONStateUpdateEncoder(pathHasher: hasher).encode(
            update: .diff([Self.patches[0]]), landID: Self.landType, playerID: PlayerID("p1")
        )
        let frame = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        let entry = try #require(frame[1] as? [Any])
        #expect(entry.first as? Int == Int(hasher.split("/score").pathHash))
    }

    @Test("A path index out of range is a decode error")
    func unknownIndex() throws {
        let hasher = PathHasher(pathHashes: ["a": 5, "b": 9])
        let decoder = OpcodeJSONStateUpdateDecoder(pathHasher: hasher, pathIndex: true)
        let data = Data("[2,[2,null,1,1]]".utf8)
        #expect {
            try decoder.decode(data: data)
        } throws: { error in
            guard case StateUpdateDecodingError.invalidPayload(let message) = error else { return false }
            return message == "Unknown path index: 2"
        }
    }

    // MARK: Paths outside the schema

    @Test("With the path index on, an encoder throws for a path outside the schema and logs its pattern once")
    func unmappedPath() throws {
        let hasher = PathHasher(pathHashes: try Self.pathHashes(PathIndexState.self, Self.landType))
        let logged = LockedPaths()
        let counter = UnmappedPathCounter { logged.append($0) }
        let encoders: [any StateUpdateEncoder] = [
            OpcodeJSONStateUpdateEncoder(pathHasher: hasher, pathIndex: true, unmappedPaths: counter),
            OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, pathIndex: true, unmappedPaths: counter),
        ]
        for encoder in encoders {
            for path in ["/nowhere", "/nowhere", "/elsewhere/x"] {
                let patches = [Self.patches[0], StatePatch(path: path, operation: .set(.int(1)))]
                #expect(throws: StateUpdateEncodingError.pathNotInSchema(path)) {
                    try encoder.encode(update: .diff(patches), landID: Self.landType, playerID: PlayerID("p1"))
                }
            }
        }
        // The encoders don't count; the adapter counts the patches it drops.
        #expect(counter.droppedPatches == 0)
        #expect(logged.paths == ["/nowhere", "/elsewhere/x"])

        // Off: the same patch goes out with the fallback hash, as before, and isn't logged.
        let off = UnmappedPathCounter { _ in Issue.record("logged with the index off") }
        _ = try OpcodeJSONStateUpdateEncoder(pathHasher: hasher, unmappedPaths: off).encode(
            update: .diff([StatePatch(path: "/nowhere", operation: .set(.int(1)))]), landID: Self.landType, playerID: PlayerID("p1")
        )
    }

    @Test("The adapter drops each patch outside the schema, sends the rest of the update and counts each dropped patch")
    func adapterDropsUnmappedPatches() async throws {
        for encoding in [InTurnEncoding.opcodeJsonArray, .messagepack] {
            // Top-level hashes only: each tick's `/board/t<n>` has no pattern, `/ticks` has one.
            let f = await VerifierFixture.make(encoding: encoding, pathIndex: true, pathHashes: verifierPathHashes)
            try await f.join(1)
            await f.tick(2)
            #expect(await f.adapter.unmappedPathPatches == 2, "\(encoding): one board entry per tick, counted once")
        }
    }

    @Test("Without path hashes, pathIndex is off in effect and no client must declare it")
    func effectiveConfigWithoutPathHashes() {
        let on = TransportEncodingConfig.messagepack.withPathIndex(true)
        #expect(on.effective(pathHashes: nil).stateUpdateFeatures == [])
        #expect(on.effective(pathHashes: ["round": 1]).stateUpdateFeatures == ["pathIndex"])
    }

    // MARK: Config and handshake

    @Test("The config's features: pathIndex with an opcode state-update encoding only")
    func configFeatures() {
        #expect(TransportEncodingConfig.messagepack.stateUpdateFeatures == [])
        #expect(TransportEncodingConfig.messagepack.withPathIndex(true).stateUpdateFeatures == ["pathIndex"])
        #expect(TransportEncodingConfig.jsonOpcode.withPathIndex(true).stateUpdateFeatures == ["pathIndex"])
        #expect(TransportEncodingConfig.json.withPathIndex(true).stateUpdateFeatures == [])
        #expect(TransportEncodingConfig.messagepack.withPathIndex(true).withDynamicKeyCompression(false).pathIndex)
        #expect(TransportEncodingConfig.pathIndexFromEnvironment(environment: [:]) == false)
        #expect(TransportEncodingConfig.pathIndexFromEnvironment(environment: ["PATH_INDEX": "true"]) == true)
    }

    @Test("missingStateUpdateFeatures: none required, declared, missing, and malformed metadata")
    func missingFeatures() {
        typealias A = TransportAdapter<PathIndexState>
        #expect(A.missingStateUpdateFeatures(required: [], metadata: nil) == nil)
        #expect(A.missingStateUpdateFeatures(required: ["pathIndex"], metadata: nil) == ["pathIndex"])
        #expect(A.missingStateUpdateFeatures(required: ["pathIndex"], metadata: ["stateUpdateFeatures": AnyCodable(["pathIndex", "fieldMerge"])]) == nil)
        #expect(A.missingStateUpdateFeatures(required: ["pathIndex"], metadata: ["stateUpdateFeatures": AnyCodable(["fieldMerge"])]) == ["pathIndex"])
        #expect(A.missingStateUpdateFeatures(required: ["pathIndex"], metadata: ["stateUpdateFeatures": AnyCodable("pathIndex")]) == ["pathIndex"])
        // As decoded from a client's JSON join.
        let decoded = try? JSONDecoder().decode([String: AnyCodable].self, from: Data(#"{"stateUpdateFeatures":["pathIndex"]}"#.utf8))
        #expect(A.missingStateUpdateFeatures(required: ["pathIndex"], metadata: decoded) == nil)
    }

    static func router(encoding: TransportEncodingConfig) throws -> (WebSocketTransport, LandRouter<PathIndexState>, LandManager<PathIndexState>) {
        let transport = WebSocketTransport()
        let hashes = try pathHashes(PathIndexState.self, landType)
        let registry = try LandTypeRegistry<PathIndexState>(
            landFactory: { landType, _ in Land(landType, using: PathIndexState.self) { Rules {} } },
            initialStateFactory: { _, _ in PathIndexState() }
        )
        let manager = LandManager<PathIndexState>(
            landFactory: { landID in registry.getLandDefinition(landType: landID.landType, landID: landID) },
            initialStateFactory: { landID in registry.initialStateFactory(landID.landType, landID) },
            transport: transport,
            transportEncoding: encoding,
            pathHashes: hashes
        )
        let router = LandRouter<PathIndexState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true,
            transportEncoding: encoding
        )
        return (transport, router, manager)
    }

    static func join(features: [String]?) throws -> Data {
        try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-1",
            landType: landType,
            landInstanceId: "handshake",
            playerID: "p1",
            deviceID: nil,
            metadata: features.map { ["stateUpdateFeatures": AnyCodable($0)] }
        ))
    }

    static func reply(_ data: Data) -> TransportMessage? {
        try? JSONDecoder().decode(TransportMessage.self, from: data)
    }

    static func waitForReply(_ connection: PathIndexReplyConnection) async throws -> TransportMessage {
        try #require(reply(await connection.firstMessage()))
    }

    @Test("Path index on: a join without stateUpdateFeatures is refused with a clear error, before any land is created")
    func refusesOldClient() async throws {
        for encoding in [TransportEncodingConfig.messagepack, .jsonOpcode] {
            let (transport, router, manager) = try Self.router(encoding: encoding.withPathIndex(true))
            await transport.setDelegate(router)
            for features in [nil, ["fieldMerge"]] as [[String]?] {
                let session = SessionID("s-old-\(features?.count ?? 0)")
                let connection = PathIndexReplyConnection()
                await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
                await transport.handleIncomingMessage(sessionID: session, data: try Self.join(features: features))
                let message = try await Self.waitForReply(connection)
                guard case .error(let payload) = message.payload else {
                    Issue.record("not an error: \(message)")
                    continue
                }
                #expect(payload.code == ErrorCode.joinStateUpdateFeatureMissing.rawValue)
                #expect(payload.message == "unsupported state update encoding: missing pathIndex")
                #expect(await router.getBoundLandID(for: session) == nil)
            }
            #expect(await manager.listLands().isEmpty, "refused before any land is created")
        }
    }

    @Test("Path index on: a client declaring it joins, and joinResponse echoes the features", arguments: [true, false])
    func acceptsDeclaringClient(pathIndex: Bool) async throws {
        let (transport, router, _) = try Self.router(encoding: TransportEncodingConfig.messagepack.withPathIndex(pathIndex))
        await transport.setDelegate(router)
        // Off: a client with no declaration joins (an old client keeps working).
        for features in (pathIndex ? [["pathIndex"], ["pathIndex", "fieldMerge"]] : [nil, ["pathIndex"]]) as [[String]?] {
            let session = SessionID("s-new-\(features?.count ?? 0)")
            let connection = PathIndexReplyConnection()
            await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
            await transport.handleIncomingMessage(sessionID: session, data: try Self.join(features: features))
            let message = try await Self.waitForReply(connection)
            guard case .joinResponse(let payload) = message.payload else {
                Issue.record("not a joinResponse: \(message)")
                continue
            }
            #expect(payload.success)
            #expect(payload.stateUpdateFeatures == (pathIndex ? ["pathIndex"] : nil))
        }
    }

    @Test("joinResponse carries stateUpdateFeatures in the JSON and both array forms")
    func joinResponseForms() throws {
        let response = TransportMessage.joinResponse(requestID: "r", success: true, encoding: "messagepack", stateUpdateFeatures: ["pathIndex"])
        let json = try #require(Self.reply(try JSONEncoder().encode(response)))
        guard case .joinResponse(let fromJSON) = json.payload else {
            Issue.record("JSON: not a joinResponse")
            return
        }
        #expect(fromJSON.stateUpdateFeatures == ["pathIndex"])

        let opcode = try OpcodeTransportMessageEncoder().encode(response)
        let array = try #require(try JSONSerialization.jsonObject(with: opcode) as? [Any])
        #expect(array.count == 9)
        #expect(array[8] as? [String] == ["pathIndex"])
        let decoded = try OpcodeTransportMessageDecoder().decode(from: opcode)
        guard case .joinResponse(let fromArray) = decoded.payload else {
            Issue.record("array: not a joinResponse")
            return
        }
        #expect(fromArray.stateUpdateFeatures == ["pathIndex"])
        #expect(fromArray.encoding == "messagepack")

        // No features: the array ends where it did before.
        let plain = TransportMessage.joinResponse(requestID: "r", success: true, encoding: "messagepack")
        let plainArray = try #require(try JSONSerialization.jsonObject(with: try OpcodeTransportMessageEncoder().encode(plain)) as? [Any])
        #expect(plainArray.count == 7)
    }
}

/// Paths passed to `UnmappedPathCounter`'s log closure.
private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ path: String) {
        lock.lock()
        storage.append(path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
