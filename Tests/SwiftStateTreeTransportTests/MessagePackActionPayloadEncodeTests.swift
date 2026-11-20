// An action envelope whose type-erased payload MessagePack can't write fails that encode with a
// thrown error, through both public entry points (#592). It used to trap with `try!`.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeMessagePack

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Neither a type `encodeAnyCodable` lists nor `Encodable`: its `default` refuses it.
private struct NotEncodablePayload: Sendable {
    let value = 1
}

private func unencodableEnvelope() -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: "NotEncodablePayload", payload: AnyCodable(NotEncodablePayload()))
}

@Suite("MessagePack: an action payload it can't write throws, never traps (#592)")
struct MessagePackActionPayloadEncodeTests {
    // Exit tests: a trapping build fails the test instead of ending the test run.

    @Test("MessagePackSerializer.encode(ActionEnvelope) throws unsupportedAnyCodable")
    func serializerThrows() async {
        await #expect(processExitsWith: .success) {
            do {
                _ = try MessagePackSerializer().encode(unencodableEnvelope())
                exit(1)
            } catch MessagePackDirectEncodingError.unsupportedAnyCodable(let typeName) {
                guard typeName.contains("NotEncodablePayload") else { exit(2) }
            } catch {
                exit(3)
            }
        }
    }

    @Test("MessagePackTransportCodec.encode(TransportMessage.action) throws unsupportedAnyCodable")
    func codecThrows() async {
        await #expect(processExitsWith: .success) {
            do {
                _ = try MessagePackTransportCodec().encode(TransportMessage.action(requestID: "r-1", action: unencodableEnvelope()))
                exit(1)
            } catch MessagePackDirectEncodingError.unsupportedAnyCodable(let typeName) {
                guard typeName.contains("NotEncodablePayload") else { exit(2) }
            } catch {
                exit(3)
            }
        }
    }
}
