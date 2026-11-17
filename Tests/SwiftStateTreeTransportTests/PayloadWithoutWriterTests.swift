// A payload type without `@Payload` (#521, EV1). Before the typed writer, its first send on a
// compressed encoding reached `PayloadCompression.encodeAsArray()`'s default `fatalError` and
// ended the process. Its default writer now throws, so the encode fails and the process lives;
// registration refuses such a type where payloads are compressed (EV1).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// Conforms by hand, with no `@Payload`: no positional writer.
struct PWHandWrittenEvent: ServerEventPayload {
    let n: Int
}

@Suite("Payload: a type without @Payload on a compressed encoding (#521 EV1)")
struct PayloadWithoutWriterTests {
    static let message = TransportMessage.event(event: .fromServer(event: AnyServerEvent(PWHandWrittenEvent(n: 1))))

    @Test("Its default writer reports no positional form")
    func defaultWriter() {
        #expect(!PWHandWrittenEvent._payloadHasTypedWriter)
        #expect(PWHandWrittenEvent._payloadFieldForms.isEmpty)
        #expect(AnyServerEvent(PWHandWrittenEvent(n: 1)).wireForm == nil)
        #expect(PWHandWrittenEvent._payloadWireName == "PWHandWritten")
    }

    @Test("Compressed MessagePack throws instead of ending the process")
    func messagePackThrows() {
        let encoder = MessagePackTransportMessageEncoder(enablePayloadCompression: true)
        #expect(throws: PayloadWithoutWriterError.self) { try encoder.encode(Self.message) }
    }

    @Test("Compressed opcode JSON throws instead of ending the process")
    func opcodeJSONThrows() {
        let encoder = OpcodeTransportMessageEncoder(enablePayloadCompression: true)
        #expect(throws: (any Error).self) { try encoder.encode(Self.message) }
    }

    @Test("Uncompressed encodings still write it by its Codable form")
    func uncompressedWrites() throws {
        let data = try OpcodeTransportMessageEncoder(enablePayloadCompression: false).encode(Self.message)
        #expect(String(decoding: data, as: UTF8.self) == #"[103,1,"PWHandWritten",{"n":1}]"#)
    }
}
