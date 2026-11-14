// The bytes the message encoders write for every GameDemo payload type (Hero Defense, the
// visibility test land, the resolver test land), recorded before the typed payload writer
// (#521 PR 1a) into `Fixtures/PayloadFrames/gamedemo-payload-frames.json`. The writer must
// reproduce them, in the three message encodings, with payload compression on and off, from the
// typed value and from an `AnyCodable` box of it. The root package's `PayloadFrameGoldenTests`
// covers the leaf and fallback fixtures; this file covers the game's own types, which the root
// package can't import.

import Foundation
import Testing
import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath
import SwiftStateTreeMessagePack
@testable import GameContent

enum GameDemoPayloadFrameEnvKeys {
    /// Set to `1` to rewrite the fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_PAYLOAD_FRAMES"
}

@Suite("GameDemo payload frames: the bytes per payload type and encoding (#521)")
struct GameDemoPayloadFrameGoldenTests {
    static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/PayloadFrames/gamedemo-payload-frames.json").path

    struct Case {
        let name: String
        let typed: TransportMessage
        let untyped: TransportMessage
        let serverEvent: AnyServerEvent?
    }

    static func serverEvent<E: ServerEventPayload>(_ name: String, _ value: E) -> Case {
        let typed = AnyServerEvent(value)
        return Case(
            name: name,
            typed: .event(event: .fromServer(event: typed)),
            untyped: .event(event: .fromServer(event: AnyServerEvent(type: typed.type, payload: AnyCodable(value)))),
            serverEvent: typed
        )
    }

    static func clientEvent<E: ClientEventPayload>(_ name: String, _ value: E) -> Case {
        let typed = AnyClientEvent(value)
        return Case(
            name: name,
            typed: .event(event: .fromClient(event: typed)),
            untyped: .event(event: .fromClient(event: AnyClientEvent(type: typed.type, payload: AnyCodable(value)))),
            serverEvent: nil
        )
    }

    static func response(_ name: String, _ value: some ResponsePayload) -> Case {
        let message = TransportMessage.actionResponse(requestID: "r-\(name)", response: AnyCodable(value))
        return Case(name: name, typed: message, untyped: message, serverEvent: nil)
    }

    static func action<A: ActionPayload>(_ name: String, _ value: A) -> Case {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: A.self), payload: AnyCodable(value))
        let message = TransportMessage.action(requestID: "a-\(name)", action: envelope)
        return Case(name: name, typed: message, untyped: message, serverEvent: nil)
    }

    static let a = Position2(x: 70.5, y: -80.25)
    static let b = Position2(x: -1000, y: 1000)

    static var cases: [Case] {
        [
            // Hero Defense
            serverEvent("player-shoot", PlayerShootEvent(playerID: PlayerID("p1"), from: a, to: b)),
            serverEvent("turret-fire", TurretFireEvent(turretID: 3, from: b, to: a)),
            clientEvent("move-to", MoveToEvent(target: a)),
            clientEvent("shoot", ShootEvent()),
            clientEvent("update-rotation", UpdateRotationEvent(rotation: Angle(degrees: -45.25))),
            clientEvent("place-turret", PlaceTurretEvent(position: b)),
            clientEvent("upgrade-weapon", UpgradeWeaponEvent()),
            clientEvent("upgrade-turret", UpgradeTurretEvent(turretID: 7)),
            action("play", PlayAction()),
            response("play-response", PlayResponse(newScore: 12)),
            // The visibility test land
            action("set-motion", SetMotionAction(enabled: true)),
            action("park-entities", ParkEntitiesAction()),
            action("place-entity", PlaceEntityAction(id: "e1", positions: [a, b])),
            response("visibility-response", VisibilityTestResponse(viewEntries: 2, viewExits: 1)),
            clientEvent("move-viewer", MoveViewerEvent(position: a)),
            // The resolver test land
            action("call-service", CallServiceAction(tag: "t", delayMs: 5, deadlineMs: 50, outcome: "fail")),
            response("call-service-response", CallServiceResponse(applied: 1, tickAdvance: 2)),
        ]
    }

    static let eventHashes = ["PlayerShoot": 0, "TurretFire": 1]
    static let clientEventHashes = [
        "MoveTo": 0, "MoveViewer": 1, "PlaceTurret": 2, "Shoot": 3, "UpdateRotation": 4,
        "UpgradeTurret": 5, "UpgradeWeapon": 6,
    ]

    static func record(_ binary: Bool, _ encode: () throws -> Data) -> String {
        guard let data = try? encode() else { return "error" }
        return binary ? data.base64EncodedString() : String(decoding: data, as: UTF8.self)
    }

    static func frames(_ message: TransportMessage) -> [String: String] {
        let pack = { (compressed: Bool) in
            MessagePackTransportMessageEncoder(
                eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: compressed)
        }
        let json = { (compressed: Bool) in
            OpcodeTransportMessageEncoder(
                eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: compressed)
        }
        return [
            "messagePack": record(true) { try pack(true).encode(message) },
            "messagePackPlain": record(true) { try pack(false).encode(message) },
            "opcodeJSON": record(false) { try json(true).encode(message) },
            "opcodeJSONPlain": record(false) { try json(false).encode(message) },
            "jsonObject": record(false) { try JSONTransportMessageEncoder().encode(message) },
        ]
    }

    static func fixture() throws -> Data {
        let body = MessagePackTransportMessageEncoder(
            eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: true)
        var records: [AnyCodable] = []
        for c in cases {
            var record = frames(c.typed).mapValues { AnyCodable($0) }
            record["name"] = AnyCodable(c.name)
            if let event = c.serverEvent {
                record["messagePackBody"] = AnyCodable(Self.record(true) { try pack(body.encodeServerEventBody(event)) })
            }
            records.append(AnyCodable(record))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(["cases": AnyCodable(records)]) + Data("\n".utf8)
    }

    @Test("The fixture is current, and no frame failed")
    func fixtureIsCurrent() throws {
        let data = try Self.fixture()
        if EnvHelpers.getEnvBool(key: GameDemoPayloadFrameEnvKeys.regenerate, defaultValue: false) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Self.fixturePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            return
        }
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(data == committed, "regenerate with \(GameDemoPayloadFrameEnvKeys.regenerate)=1, and say why in the PR")
        #expect(!String(decoding: committed, as: UTF8.self).contains("\"error\""))
    }

    @Test("A payload without its typed value gives the same frames")
    func untypedFormMatches() {
        for c in Self.cases {
            #expect(Self.frames(c.untyped) == Self.frames(c.typed), "\(c.name)")
        }
    }
}
