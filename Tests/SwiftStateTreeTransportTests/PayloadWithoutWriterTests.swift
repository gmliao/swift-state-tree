// A payload type without `@Payload` (#521, EV1). On base, its first send on a compressed encoding
// reaches `PayloadCompression.encodeAsArray()`'s default `fatalError` and ends the process.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// Conforms by hand, with no `@Payload`: no positional form.
struct PWHandWrittenEvent: ServerEventPayload {
    let n: Int
}

@Suite("Payload: a type without @Payload on a compressed encoding (#521 EV1)")
struct PayloadWithoutWriterTests {
    @Test("base: its first send on compressed MessagePack ends the process")
    func messagePackTraps() async {
        await #expect(processExitsWith: .failure) {
            let encoder = MessagePackTransportMessageEncoder(enablePayloadCompression: true)
            _ = try? encoder.encode(.event(event: .fromServer(event: AnyServerEvent(PWHandWrittenEvent(n: 1)))))
        }
    }

    @Test("base: and on compressed opcode JSON")
    func opcodeJSONTraps() async {
        await #expect(processExitsWith: .failure) {
            let encoder = OpcodeTransportMessageEncoder(enablePayloadCompression: true)
            _ = try? encoder.encode(.event(event: .fromServer(event: AnyServerEvent(PWHandWrittenEvent(n: 1)))))
        }
    }
}
