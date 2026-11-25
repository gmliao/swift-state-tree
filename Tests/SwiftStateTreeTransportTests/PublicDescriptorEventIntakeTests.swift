// Tests/SwiftStateTreeTransportTests/PublicDescriptorEventIntakeTests.swift
//
// #700 K1b-1, the tests-first commit, F11: a client event registered with the public
// `AnyEventDescriptor` init has no intake decoder. Today it is queued undecoded and its handler
// decodes it at apply. After F11 the keeper decodes it at intake with the descriptor's type, and
// holds a payload that doesn't decode as failed, dropped at apply. These tests pin what a client
// and a record see, which both forms must keep. Each one passes every gate before the one it pins
// (plan rev 2, MF3): the registry is built by hand, because the DSL's registration makes a decoder.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeMessagePack

@StateNodeBuilder
struct PublicDescriptorState: StateNodeProtocol {
    @Sync(.broadcast)
    var applied: [String] = []

    public init() {}
}

@Payload
struct PublicDescriptorEvent: ClientEventPayload {
    let label: String
}

private let eventName = EventRegistry<AnyClientEvent>.eventName(for: PublicDescriptorEvent.self)

/// A tick land that handles `PublicDescriptorEvent`, with its client registry rebuilt from the
/// public descriptor init: the event has no intake decoder.
private func makePublicDescriptorLand() -> LandDefinition<PublicDescriptorState> {
    let built = Land("public-descriptor", using: PublicDescriptorState.self) {
        ClientEvents { Register(PublicDescriptorEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { _, _ in }
        }
        Rules {
            HandleEvent(PublicDescriptorEvent.self) { state, event, _ in
                state.applied.append(event.label)
            }
        }
    }
    let registry = EventRegistry<AnyClientEvent>(registered: [
        AnyEventDescriptor(type: PublicDescriptorEvent.self, eventName: eventName, direction: .client),
    ])
    return LandDefinition(
        id: built.id,
        stateType: built.stateType,
        clientEventRegistry: registry,
        serverEventRegistry: built.serverEventRegistry,
        config: built.config,
        actionHandlers: built.actionHandlers,
        eventHandlers: built.eventHandlers,
        serverInputHandlers: built.serverInputHandlers,
        duplicateHandlers: built.duplicateHandlers,
        clientEventMismatches: built.clientEventMismatches,
        unrecognizedNodes: built.unrecognizedNodes,
        resolverDeclarationProblems: built.resolverDeclarationProblems,
        lifetimeHandlers: built.lifetimeHandlers,
        servicesType: built.servicesType,
        acceptsServices: built.acceptsServices
    )
}

/// How a client's payload reaches the keeper: the JSON decoders' tree, or the MessagePack
/// decoder's value.
enum PublicDescriptorForm: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case json
    case messagepack
    var testDescription: String { rawValue }

    func event(_ json: [String: Any], _ value: MessagePackValue) throws -> AnyClientEvent {
        switch self {
        case .json: AnyClientEvent(type: eventName, payload: AnyCodable(json))
        case .messagepack: AnyClientEvent(type: eventName, source: try MessagePackPayloadSource(validating: value))
        }
    }
}

private let player = PlayerID("p"), client = ClientID("c"), session = SessionID("s")

/// A joined keeper on the public-descriptor land, recording when `recording`.
private func makeKeeper(recording: Bool) async throws -> LandKeeper<PublicDescriptorState> {
    let definition = makePublicDescriptorLand()
    #expect(definition.clientEventRegistry.registered.allSatisfy { $0.decodeClientEvent == nil },
            "control: no intake decoder")
    let keeper = LandKeeper<PublicDescriptorState>(
        definition: definition,
        initialState: PublicDescriptorState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        landID: "public-descriptor:local"
    )
    await keeper.awaitInitialization()
    try await keeper.join(playerID: player, clientID: client, sessionID: session)
    await keeper.stepTickOnce()
    return keeper
}

/// The sequences of the client events the keeper's recorder holds.
private func recordedEventSequences(_ keeper: LandKeeper<PublicDescriptorState>) async throws -> [Int64] {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    return await recorder.getAllFrames().flatMap { $0.clientEvents.map(\.sequence) }
}

@Suite("A client event registered with the public descriptor init (#700 K1b-1, F11)", .timeLimit(.minutes(1)))
struct PublicDescriptorEventIntakeTests {
    @Test("A payload that doesn't decode: no error to the client, recorded when the land records, dropped, the handler doesn't run",
          arguments: PublicDescriptorForm.allCases, [false, true])
    func publicDescriptorMalformedPayloadIsRecordedAndDropped(form: PublicDescriptorForm, recording: Bool) async throws {
        let keeper = try await makeKeeper(recording: recording)
        // `label` is a number: shallow, finite, so its bytes can be made, and it doesn't decode.
        let malformed = try form.event(["label": 5], .map([.string("label"): .int(5)]))
        try await keeper.handleClientEvent(malformed, playerID: player, clientID: client, sessionID: session)
        let queued = try #require(await keeper.pendingItemSequencesForTesting().only, "queued")
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().applied.isEmpty, "the handler didn't run")
        if recording {
            #expect(try await recordedEventSequences(keeper).contains(queued), "recorded")
        }

        // Control: a payload that decodes runs the handler with its value.
        let good = try form.event(["label": "ok"], .map([.string("label"): .string("ok")]))
        try await keeper.handleClientEvent(good, playerID: player, clientID: client, sessionID: session)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().applied == ["ok"])
        await keeper.forceShutdown()
    }

    @Test("On a recording land, a payload whose bytes can't be made is refused at intake: nothing queued, no sequence taken")
    func publicDescriptorUnrecordablePayloadIsRefusedAtIntake() async throws {
        let keeper = try await makeKeeper(recording: true)
        let first = try PublicDescriptorForm.messagepack.event(["label": "a"], .map([.string("label"): .string("a")]))
        try await keeper.handleClientEvent(first, playerID: player, clientID: client, sessionID: session)
        let firstSequence = try #require(await keeper.pendingItemSequencesForTesting().last)

        // A non-finite number: the record can't hold it.
        let nonFinite = try PublicDescriptorForm.messagepack.event(
            [:], .map([.string("label"): .string("x"), .string("ratio"): .double(.nan)])
        )
        let error = await #expect(throws: ClientEventPayloadError.self) {
            try await keeper.handleClientEvent(nonFinite, playerID: player, clientID: client, sessionID: session)
        }
        #expect(error?.eventType == eventName)
        #expect(await keeper.pendingItemSequencesForTesting() == [firstSequence], "nothing queued")

        let second = try PublicDescriptorForm.messagepack.event(["label": "b"], .map([.string("label"): .string("b")]))
        try await keeper.handleClientEvent(second, playerID: player, clientID: client, sessionID: session)
        #expect(await keeper.pendingItemSequencesForTesting() == [firstSequence, firstSequence + 1], "no sequence taken")
        await keeper.forceShutdown()
    }

    @Test("With recording off, a payload nested past the limit from a direct source is dropped and counted once")
    func publicDescriptorTooDeepPayloadIsDroppedAndCountedOnce() async throws {
        let keeper = try await makeKeeper(recording: false)
        // A direct source, not a frame decoder's (which refuses past its own limit first): its
        // walk notes the depth, and `validateRecordable` throws `PayloadNesting.TooDeep`.
        var deep = MessagePackValue.string("leaf")
        for _ in 0..<4 { deep = .map([.string("inner"): deep]) }
        let source = try MessagePackPayloadSource(validating: .map([.string("label"): deep]), maxDepth: 3)
        let event = AnyClientEvent(type: eventName, source: source)

        let counter = PayloadNesting.WalkCounter()
        try await PayloadNesting.$droppedForTesting.withValue(counter) {
            try await keeper.handleClientEvent(event, playerID: player, clientID: client, sessionID: session)
            await keeper.stepTickOnce()
        }
        #expect(counter.count == 1, "counted once")
        #expect(await keeper.currentState().applied.isEmpty, "dropped")
        await keeper.forceShutdown()
    }
}

private extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
