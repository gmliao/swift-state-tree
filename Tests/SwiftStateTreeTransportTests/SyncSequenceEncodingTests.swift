// Tests/SwiftStateTreeTransportTests/SyncSequenceEncodingTests.swift
//
// The sync sequence in state-update frames (#332): `[opcode, seq, patch...]` in the opcode
// encodings, a `seq` key in the JSON object, and the `syncSequence` state-update feature.

import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

private let land = "land-1"
private let player = PlayerID("p1")
private let patches = [StatePatch(path: "/count", operation: .set(.int(3)))]

@Suite("Sync sequence in state-update frames")
struct SyncSequenceEncodingTests {
    @Test("Opcode JSON puts the sequence right after the opcode, and the decoder reads it back")
    func opcodeJSONRoundTrip() throws {
        let encoder = OpcodeJSONStateUpdateEncoder()
        let data = try encoder.encode(
            update: .diff(patches), landID: land, playerID: player, playerSlot: nil, scope: .broadcast, syncSeq: 7
        )
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        #expect(array.count == 3)
        #expect((array[0] as? Int) == StateUpdateOpcode.diff.rawValue)
        #expect((array[1] as? Int) == 7)

        let decoded = try OpcodeJSONStateUpdateDecoder(syncSequence: true).decode(data: data)
        #expect(decoded.syncSeq == 7)
        #expect(decoded.update == .diff(patches))
    }

    @Test("A frame without a sequence decodes as before, with no sequence")
    func opcodeJSONWithoutSequence() throws {
        let data = try OpcodeJSONStateUpdateEncoder().encode(
            update: .diff(patches), landID: land, playerID: player, playerSlot: nil, scope: .broadcast
        )
        let decoded = try OpcodeJSONStateUpdateDecoder().decode(data: data)
        #expect(decoded.syncSeq == nil)
        #expect(decoded.update == .diff(patches))
    }

    @Test("noChange and firstSync carry the sequence too")
    func opcodeJSONOtherOpcodes() throws {
        let encoder = OpcodeJSONStateUpdateEncoder()
        let decoder = OpcodeJSONStateUpdateDecoder(syncSequence: true)
        let none = try encoder.encode(update: .noChange, landID: land, playerID: player, playerSlot: nil, scope: .broadcast, syncSeq: 1)
        #expect(String(decoding: none, as: UTF8.self) == "[0,1]")
        #expect(try decoder.decode(data: none).update == .noChange)
        #expect(try decoder.decode(data: none).syncSeq == 1)

        let first = try encoder.encode(update: .firstSync(patches), landID: land, playerID: player, playerSlot: 4, scope: .perPlayer, syncSeq: UInt64(1) << 40)
        let decoded = try decoder.decode(data: first)
        #expect(decoded.syncSeq == UInt64(1) << 40)
        #expect(decoded.update == .firstSync(patches))
    }

    @Test("The decoder follows the negotiated feature, not the frame's shape")
    func decodeByNegotiation() throws {
        let encoder = OpcodeJSONStateUpdateEncoder()
        let sequenced = try encoder.encode(update: .diff(patches), landID: land, playerID: player, playerSlot: nil, scope: .broadcast, syncSeq: 5)
        let plain = try encoder.encode(update: .diff(patches), landID: land, playerID: player, playerSlot: nil, scope: .broadcast)
        // Negotiated: a frame without a sequence is refused, whatever its patches look like.
        #expect(throws: StateUpdateDecodingError.self) { try OpcodeJSONStateUpdateDecoder(syncSequence: true).decode(data: plain) }
        #expect(throws: StateUpdateDecodingError.self) { try OpcodeJSONStateUpdateDecoder(syncSequence: true).decode(data: Data("[2]".utf8)) }
        // Not negotiated: a sequence is a malformed patch.
        #expect(throws: StateUpdateDecodingError.self) { try OpcodeJSONStateUpdateDecoder().decode(data: sequenced) }
        // A zero-patch frame with its sequence.
        let empty = try OpcodeJSONStateUpdateDecoder(syncSequence: true).decode(data: Data("[2,9]".utf8))
        #expect(empty.syncSeq == 9)
        #expect(empty.update == .diff([]))
        for bad in ["[2,-1]", "[2,1.5]", "[2,true]", "[2,\"9\"]", "[2,18446744073709551616]"] {
            #expect(throws: StateUpdateDecodingError.self, "\(bad)") { try OpcodeJSONStateUpdateDecoder(syncSequence: true).decode(data: Data(bad.utf8)) }
        }
    }

    @Test("MessagePack puts the sequence right after the opcode, as an unsigned integer")
    func messagePackLayout() throws {
        let encoder = OpcodeMessagePackStateUpdateEncoder()
        let data = try encoder.encode(
            update: .diff(patches), landID: land, playerID: player, playerSlot: nil, scope: .broadcast, syncSeq: 9
        )
        guard case .array(let array) = try unpack(data) else {
            Issue.record("not an array")
            return
        }
        #expect(array.count == 3)
        #expect(array[0] == .int(Int64(StateUpdateOpcode.diff.rawValue)))
        // The packer may write a small unsigned value as a positive fixint.
        #expect(array[1] == .uint(9) || array[1] == .int(9))
        guard case .array = array[2] else {
            Issue.record("the patch isn't an array")
            return
        }

        let plain = try encoder.encode(update: .diff(patches), landID: land, playerID: player, playerSlot: nil, scope: .broadcast)
        guard case .array(let plainArray) = try unpack(plain) else {
            Issue.record("not an array")
            return
        }
        #expect(plainArray.count == 2)
    }

    @Test("The JSON object gains a seq key, and the decoder reads it back")
    func jsonObjectRoundTrip() throws {
        let data = try JSONStateUpdateEncoder().encode(
            update: .diff(patches), landID: land, playerID: player, playerSlot: nil, scope: .broadcast, syncSeq: 12
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["seq"] as? Int) == 12)
        #expect((object["type"] as? String) == "diff")

        let decoded = try JSONStateUpdateDecoder().decode(data: data)
        #expect(decoded.syncSeq == 12)
        #expect(decoded.update == .diff(patches))

        let plain = try JSONStateUpdateDecoder().decode(data: try JSONStateUpdateEncoder().encode(update: .diff(patches), landID: land, playerID: player))
        #expect(plain.syncSeq == nil)
    }

    @Test("With the sync sequence on, every encoding requires the syncSequence feature")
    func requiredFeature() {
        #expect(StateUpdateFeature.supported.contains(StateUpdateFeature.syncSequence))
        for config in [TransportEncodingConfig.json, .jsonOpcode, .opcode, .messagepack] {
            #expect(!config.stateUpdateFeatures.contains(StateUpdateFeature.syncSequence))
            let on = config.withSyncSequence(true)
            #expect(on.syncSequence)
            #expect(on.stateUpdateFeatures.contains(StateUpdateFeature.syncSequence), "\(config.stateUpdate)")
            // The other features are unchanged by it.
            #expect(on.stateUpdateFeatures.filter { $0 != StateUpdateFeature.syncSequence } == config.stateUpdateFeatures)
        }
    }

    @Test("Without path hashes the sync sequence stays required")
    func effectiveKeepsSyncSequence() {
        let on = TransportEncodingConfig.messagepack.withSyncSequence(true)
        #expect(on.effective(pathHashes: nil).stateUpdateFeatures == [StateUpdateFeature.syncSequence])
    }
}

@Suite("Sync ack frame")
struct SyncAckFrameTests {
    @Test("Round trips in JSON text and in MessagePack, across the integer widths")
    func roundTrip() {
        for seq: UInt64 in [0, 1, 127, 128, 255, 256, 65_535, 65_536, 4_294_967_295, 4_294_967_296, .max] {
            #expect(SyncAckFrame.parse(SyncAckFrame.encode(seq: seq, binary: false)) == seq, "json \(seq)")
            #expect(SyncAckFrame.parse(SyncAckFrame.encode(seq: seq, binary: true)) == seq, "msgpack \(seq)")
        }
        #expect(String(decoding: SyncAckFrame.encode(seq: 42, binary: false), as: UTF8.self) == "[108,42]")
    }

    @Test("Whitespace in the JSON text is allowed")
    func jsonWhitespace() {
        #expect(SyncAckFrame.parse(Data(" [ 108 ,\n 5 ] ".utf8)) == 5)
        #expect(SyncAckFrame.parse(Data("[108,18446744073709551615]".utf8)) == .max)
    }

    @Test("MessagePack written by another packer parses too")
    func messagePackFromPacker() throws {
        let data = try pack(.array([.int(108), .uint(300)]))
        #expect(SyncAckFrame.parse(data) == 300)
    }

    @Test("Every other frame is not an ack")
    func otherFrames() throws {
        let others: [Data] = [
            Data(),
            Data("[103,0,\"move\",{}]".utf8),
            Data("{\"kind\":\"action\"}".utf8),
            Data("[108]".utf8),
            Data("[108,1,2]".utf8),
            Data("[108,-1]".utf8),
            Data("[108,1.5]".utf8),
            Data("[108,true]".utf8),
            Data("[1080,1]".utf8),
            Data("[108,18446744073709551616]".utf8),
            Data("[108,\"1\"]".utf8),
            try pack(.array([.int(103), .int(1)])),
            try pack(.array([.int(108), .string("x")])),
            try pack(.array([.int(108), .int(-1)])),
        ]
        for data in others {
            #expect(SyncAckFrame.parse(data) == nil, "\(String(decoding: data, as: UTF8.self))")
        }
    }
}
