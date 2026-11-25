// Tests/SwiftStateTreeTransportTests/DecimalSendTests.swift
//
// #597, #557: what the macros and registration can't see is refused at the first send. A JSON
// encoding would write a `Decimal` as a number, and a Decimal NaN as a bare `NaN`, which isn't
// JSON; the MessagePack encoders refuse it themselves. The land ends as for any payload that
// doesn't encode. A typed payload can't hold a `Decimal` (it isn't plain data), so the only way
// one reaches an encoder is an untyped event, `AnyServerEvent(type:payload:)`. The compressed
// encoders refuse every untyped payload (#544), so these cases run on the uncompressed ones.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// A plain `Codable` type: nothing sees its Decimal before the encoder.
struct DecimalSendHolder: Codable, Sendable {
    var amount: Decimal
}

/// An untyped event holding `holder` under the key `holder`.
private func holderEvent(_ amount: Decimal) -> AnyServerEvent {
    AnyServerEvent(type: "DecimalSendHolder", payload: AnyCodable(["holder": AnyCodable(DecimalSendHolder(amount: amount))]))
}

/// An untyped event holding `value` under the key `value`.
private func anyEvent(_ value: AnyCodable) -> AnyServerEvent {
    AnyServerEvent(type: "DecimalSendAny", payload: AnyCodable(["value": value]))
}

/// 128-bit integers (SE-0425): their `encode(to:)` calls the containers' concrete overloads.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct DecimalSendWide: Codable, Sendable {
    let big: Int128
    let ubig: UInt128
    let items: [Int128]
}

/// Calls the single-value and unkeyed containers' 128-bit overloads directly, as a hand-written
/// `encode(to:)` does; an array's elements go through the generic `encode` instead.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct DecimalSendWideManual: Encodable {
    let single: DecimalSendWideSingle
    let pair: DecimalSendWidePair
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct DecimalSendWideSingle: Encodable {
    let value: Int128
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
struct DecimalSendWidePair: Encodable {
    let low: Int128
    let high: UInt128
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(low)
        try container.encode(high)
    }
}

/// Records the coding paths its `encode(to:)` sees, for comparing the scan with `JSONEncoder`.
final class DecimalSendPathLog: @unchecked Sendable {
    var paths: [String] = []
}

struct DecimalSendPathProbe: Encodable {
    let log: DecimalSendPathLog
    func encode(to encoder: Encoder) throws {
        log.paths.append(encoder.codingPath.map(\.stringValue).joined(separator: "/"))
        try "x".encode(to: encoder)
    }
}

/// An element of an array, a keyed `superEncoder()` and an unkeyed one: the path shapes a
/// path-dependent `encode(to:)` could branch on.
struct DecimalSendPathHolder: Encodable {
    let log: DecimalSendPathLog
    enum Keys: String, CodingKey { case list, base, inner, named }
    func encode(to encoder: Encoder) throws {
        var keyed = encoder.container(keyedBy: Keys.self)
        try keyed.encode([DecimalSendPathProbe(log: log), DecimalSendPathProbe(log: log)], forKey: .list)
        try DecimalSendPathProbe(log: log).encode(to: keyed.superEncoder())
        var unkeyed = keyed.nestedUnkeyedContainer(forKey: .base)
        try DecimalSendPathProbe(log: log).encode(to: unkeyed.superEncoder())
        var nested = keyed.nestedContainer(keyedBy: Keys.self, forKey: .inner)
        try DecimalSendPathProbe(log: log).encode(to: nested.superEncoder())
        try DecimalSendPathProbe(log: log).encode(to: nested.superEncoder(forKey: .named))
    }
}

/// A land whose tick emits `event`, untyped, and syncs.
private func makeDecimalEmitLand(_ event: @escaping @Sendable () -> AnyServerEvent) -> LandDefinition<UntypedPayloadState> {
    Land("decimal-emit", using: UntypedPayloadState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.round += 1
                ctx.emitAnyServerEventForTesting(event(), to: .all)
                ctx.requestSyncNow()
            }
        }
        ServerEvents {
            Register(UntypedPayloadTypedEvent.self)
        }
    }
}

/// The JSON message encoders that write an untyped payload: json, and opcode JSON without
/// payload compression (the compressed one refuses any untyped payload, #544).
private let jsonEncoders: [(String, any TransportMessageEncoder)] = [
    ("json", JSONTransportMessageEncoder()),
    ("opcode plain", OpcodeTransportMessageEncoder(enablePayloadCompression: false)),
]

private func eventMessage(_ payload: some ServerEventPayload) -> TransportMessage {
    .event(event: .fromServer(event: AnyServerEvent(payload)))
}

private func eventMessage(_ event: AnyServerEvent) -> TransportMessage {
    .event(event: .fromServer(event: event))
}

@Suite("A Decimal the macros and registration can't see is refused at the first send (#597, #557)", .serialized, .timeLimit(.minutes(1)))
struct DecimalSendTests {
    @Test("Each JSON message encoder refuses a Decimal: a NaN, a nested one, one in an AnyCodable, an NSDecimalNumber; a clean event encodes")
    func jsonEncodersRefuseDecimal() throws {
        let refused: [(String, TransportMessage)] = [
            ("nested NaN", eventMessage(holderEvent(.nan))),
            ("nested finite", eventMessage(holderEvent(2.5))),
            ("AnyCodable", eventMessage(anyEvent(AnyCodable(Decimal(2.5))))),
            ("AnyCodable in an array", eventMessage(anyEvent(AnyCodable([AnyCodable(1), AnyCodable(Decimal.nan)])))),
            ("NSDecimalNumber", eventMessage(anyEvent(AnyCodable(NSDecimalNumber(string: "2.5"))))),
        ]
        for (encoderName, encoder) in jsonEncoders {
            for (name, message) in refused {
                // Refused by the Decimal scan, not for another reason.
                let error = #expect(throws: EncodingError.self, "\(encoderName): \(name)") { _ = try encoder.encode(message) }
                #expect(String(describing: error).contains("#597"), "\(encoderName): \(name): \(String(describing: error))")
            }
            let clean = try encoder.encode(eventMessage(UntypedPayloadTypedEvent(hp: 3)))
            #expect(!clean.isEmpty, "\(encoderName)")
        }
        // The refusal names the field's path.
        do {
            _ = try JSONTransportMessageEncoder().encode(eventMessage(holderEvent(.nan)))
            Issue.record("expected a refusal")
        } catch let EncodingError.invalidValue(_, context) {
            #expect(context.codingPath.map(\.stringValue).suffix(2) == ["holder", "amount"], "\(context.codingPath)")
            #expect(context.debugDescription.contains("#597"))
        }
    }

    @Test("128-bit integers and Data pass the scan on each JSON encoder; a double-boxed NSDecimalNumber is refused")
    func scanPassesWideIntegersAndData() throws {
        for (encoderName, encoder) in jsonEncoders {
            if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
                let wide = DecimalSendWide(big: Int128.max, ubig: UInt128.max, items: [Int128.min, 0])
                try DecimalScan.check(wide)
                let manual = DecimalSendWideManual(
                    single: DecimalSendWideSingle(value: Int128.min), pair: DecimalSendWidePair(low: -1, high: UInt128.max))
                try DecimalScan.check(manual)
                #expect(!(try encoder.encode(eventMessage(anyEvent(AnyCodable(manual))))).isEmpty, "\(encoderName)")
                let data = try encoder.encode(eventMessage(anyEvent(AnyCodable(wide))))
                #expect(!data.isEmpty, "\(encoderName)")
            }
            let bytes = try encoder.encode(eventMessage(anyEvent(AnyCodable(Data(repeating: 7, count: 4096)))))
            #expect(!bytes.isEmpty, "\(encoderName)")
            #expect(throws: EncodingError.self, "\(encoderName)") {
                _ = try encoder.encode(eventMessage(anyEvent(AnyCodable(AnyCodable(NSDecimalNumber(string: "2.5"))))))
            }
        }
    }

    @Test("The scan gives an encode(to:) the coding paths JSONEncoder gives it: array indexes and superEncoder keys")
    func scanPathsMatchJSONEncoder() throws {
        let scanned = DecimalSendPathLog()
        try DecimalScan.check(DecimalSendPathHolder(log: scanned))
        let encoded = DecimalSendPathLog()
        _ = try JSONEncoder().encode(DecimalSendPathHolder(log: encoded))
        #expect(scanned.paths == encoded.paths, "scan \(scanned.paths), JSONEncoder \(encoded.paths)")
        #expect(scanned.paths.count == 6)
    }

    // JSON only: on a compressed encoding an untyped event ends the land whatever it holds (#544).
    @Test("An untyped event with a nested Decimal NaN ends the land with .eventEncode, sending nothing in the failing tick")
    func unregisteredEmitEndsTheLand() async throws {
        let land = try await UntypedPayloadLand.make(makeDecimalEmitLand { holderEvent(.nan) }, encoding: .json)
        try await expectEventEncodeFailure(land, "json")
    }

    @Test("An untyped event whose AnyCodable holds a Decimal ends the land with .eventEncode")
    func anyCodableDecimalEndsTheLand() async throws {
        let land = try await UntypedPayloadLand.make(makeDecimalEmitLand { anyEvent(AnyCodable(Decimal(2.5))) }, encoding: .json)
        try await expectEventEncodeFailure(land, "json")
    }

    private func expectEventEncodeFailure(_ land: UntypedPayloadLand, _ label: String) async throws {
        await land.adapter.waitForOutboundIdleForTesting()
        let sentBefore = await land.transport.sends
        await land.tick()
        try #require(await land.keeper.waitForFailureForTesting(), "\(label): the land failed")
        await land.keeper.waitUntilDrained()
        #expect(land.keeper.failure?.kind == .eventEncode, "\(label): \(String(describing: land.keeper.failure))")
        #expect(land.adapter.outputGate.isClosed, "\(label)")
        #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(label)")
        await land.adapter.waitForOutboundIdleForTesting()
        #expect(await land.transport.sends == sentBefore, "\(label): the failing tick sends nothing")
    }
}
