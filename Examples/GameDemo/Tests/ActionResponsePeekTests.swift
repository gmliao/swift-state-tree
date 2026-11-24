import Foundation
import GameContent
import LoadTestPacing
import SwiftStateTree
import SwiftStateTreeTransport
import Testing

/// `ActionResponsePeek`: EncodingBenchmark's count of the replies the tickless visibility land
/// sends (`--game-type visibility-test-tickless`) reads it on every frame a room sends, so it
/// must find every action response the server's encoders write and nothing else.
@Suite("Action response peek")
struct ActionResponsePeekTests {
    @Test("The opcode is MessageKindOpcode.actionResponse")
    func opcode() {
        #expect(Int(ActionResponsePeek.actionResponseOpcode) == MessageKindOpcode.actionResponse.rawValue)
    }

    @Test("An action response from each message encoding is found, narrow and wide")
    func actionResponseFrames() throws {
        let narrow = AnyCodable(VisibilityTestResponse(viewEntries: 3, viewExits: 1))
        let wide = AnyCodable(WideVisibilityResponse(
            viewEntries: 3, viewExits: 1, tickCount: 7, entityCount: 40, tag: VisibilityTestConfig.wideResponseTag))
        for message in [TransportEncoding.json, .opcodeJsonArray, .messagepack] {
            let config = TransportEncodingConfig(message: message, stateUpdate: .opcodeMessagePack)
            for response in [narrow, wide] {
                let frame = try config.makeMessageEncoder().encode(.actionResponse(requestID: "r0-p0-i0-k0", response: response))
                #expect(ActionResponsePeek.isActionResponse(frame), "\(message): \(frame.prefix(16).map { String($0) })")
            }
        }
    }

    @Test("Other frames aren't action responses")
    func otherFrames() throws {
        // State updates: `[op, seq, ...]` in JSON and MessagePack (fixarray of 3: op 2, seq 5, []).
        #expect(!ActionResponsePeek.isActionResponse(Data("[2,5,[]]".utf8)))
        #expect(!ActionResponsePeek.isActionResponse(Data([0x93, 0x02, 0x05, 0x90])))
        // Another message kind, and an opcode that only starts with 102.
        #expect(!ActionResponsePeek.isActionResponse(Data("[106,\"r1\",{}]".utf8)))
        #expect(!ActionResponsePeek.isActionResponse(Data("[1020,1]".utf8)))
        #expect(!ActionResponsePeek.isActionResponse(Data([0x92, 0x6a, 0x01])))  // [106, 1]
        // An error message from each encoding.
        let error = TransportMessage.error(ErrorPayload(code: "INVALID_ACTION", message: "the payload doesn't decode"))
        for message in [TransportEncoding.json, .opcodeJsonArray, .messagepack] {
            let config = TransportEncodingConfig(message: message, stateUpdate: .opcodeMessagePack)
            #expect(!ActionResponsePeek.isActionResponse(try config.makeMessageEncoder().encode(error)), "\(message)")
        }
        // JSON objects: another kind, and a frame over the bound, which isn't searched.
        #expect(!ActionResponsePeek.isActionResponse(Data(#"{"kind":"error","payload":{}}"#.utf8)))
        let large = #"{"patches":[""# + String(repeating: "x", count: ActionResponsePeek.jsonObjectMaxBytes) + #""],"kind":"actionResponse"}"#
        #expect(!ActionResponsePeek.isActionResponse(Data(large.utf8)))
        #expect(!ActionResponsePeek.isActionResponse(Data()))
    }
}
