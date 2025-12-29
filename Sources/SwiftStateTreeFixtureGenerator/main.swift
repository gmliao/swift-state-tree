import Foundation
import SwiftStateTree
import SwiftStateTreeTransport

private struct FixtureActionPayload: Codable, Sendable {
    let amount: Int
    let note: String
}

private struct FixtureClientEvent: ClientEventPayload {
    let message: String
    let count: Int
}

private enum FixtureGeneratorError: Error {
    case invalidOutputPath(String)
}

private let codec = MessagePackTransportCodec()

private func writeFixture(named name: String, data: Data, to outputDirectory: URL) throws {
    let fileURL = outputDirectory.appendingPathComponent(name)
    try data.write(to: fileURL, options: [.atomic])
}

private func outputDirectoryURL() throws -> URL {
    let rootPath = FileManager.default.currentDirectoryPath
    let outputPath = "\(rootPath)/sdk/ts/src/fixtures/messagepack"
    let outputURL = URL(fileURLWithPath: outputPath)
    if outputURL.pathComponents.count < 2 {
        throw FixtureGeneratorError.invalidOutputPath(outputPath)
    }
    return outputURL
}

private func generateFixtures() throws {
    let outputURL = try outputDirectoryURL()
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    let landType = "fixture-land"
    let landInstanceId = "fixture-instance"
    let landID = "\(landType):\(landInstanceId)"

    let joinMessage = TransportMessage.join(
        requestID: "req-join-1",
        landType: landType,
        landInstanceId: landInstanceId,
        playerID: "player-fixture",
        deviceID: "device-fixture",
        metadata: [
            "role": AnyCodable("mage"),
            "level": AnyCodable(7)
        ]
    )
    try writeFixture(named: "join.msgpack", data: try codec.encode(joinMessage), to: outputURL)

    let actionPayload = FixtureActionPayload(amount: 3, note: "spin")
    let actionPayloadData = try JSONEncoder().encode(actionPayload)
    let actionEnvelope = ActionEnvelope(
        typeIdentifier: "FixtureActionPayload",
        payload: actionPayloadData
    )
    let actionMessage = TransportMessage.action(
        requestID: "req-action-1",
        landID: landID,
        action: actionEnvelope
    )
    try writeFixture(named: "action.msgpack", data: try codec.encode(actionMessage), to: outputURL)

    let clientEvent = AnyClientEvent(FixtureClientEvent(message: "hello", count: 2))
    let eventMessage = TransportMessage.event(
        landID: landID,
        event: .fromClient(event: clientEvent)
    )
    try writeFixture(named: "event.msgpack", data: try codec.encode(eventMessage), to: outputURL)

    let snapshot = StateSnapshot(values: [
        "round": .int(2),
        "active": .bool(true),
        "players": .object([
            "player-1": .string("Alice"),
            "player-2": .string("Bob")
        ])
    ])
    try writeFixture(named: "snapshot.msgpack", data: try codec.encode(snapshot), to: outputURL)

    let update = StateUpdate.diff([
        StatePatch(path: "/round", operation: .set(.int(3))),
        StatePatch(path: "/players/player-1", operation: .set(.string("Alicia"))),
        StatePatch(path: "/players/player-2", operation: .delete),
        StatePatch(path: "/scores", operation: .add(.array([.int(10), .int(20)])))
    ])
    try writeFixture(named: "update.msgpack", data: try codec.encode(update), to: outputURL)
}

do {
    try generateFixtures()
    print("MessagePack fixtures generated in sdk/ts/src/fixtures/messagepack")
} catch {
    fputs("Fixture generation failed: \(error)\n", stderr)
    exit(1)
}
