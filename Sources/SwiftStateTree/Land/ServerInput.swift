import Foundation

// MARK: - Server-originated turn inputs (#387)

/// A value the server delivers to a land as a turn input, outside any client.
///
/// Work that a land's turn requests runs outside the land's turns (I/O, a long computation,
/// another service). Its result comes back as a server input: the keeper sequences it when it is
/// submitted, applies it in a turn of its own (in order with the land's other inputs), and records
/// it, so replay reproduces it without the outside work.
///
/// Declare the land's server input types with `HandleServerInput(T.self) { ... }`. They are not
/// part of the client schema.
///
/// A handler checks a ticket the turn captured when it sent the request against the land's state,
/// and drops a stale input:
/// ```swift
/// HandleServerInput(RunProgress.self) { (state: inout State, input: RunProgress, ctx: LandContext) in
///     guard input.ticket == state.runTicket else { return }
///     state.processed = input.processed
/// }
/// ```
public protocol ServerInputPayload: Codable, Sendable {}

/// What `LandKeeper.submitServerInput` did with an input. A debug freeze doesn't refuse: the
/// input is accepted and applied after the resume.
public enum ServerInputOutcome: Sendable, Equatable {
    /// Taken as a turn input with this sequence; the keeper applies it in a turn of its own.
    case accepted(sequence: Int64)
    /// Not taken; nothing was queued.
    case refused(ServerInputRefusal)
}

/// Why a server input was not taken.
public enum ServerInputRefusal: Sendable, Equatable {
    /// The land is closing, or its keeper is gone.
    case draining
    /// The land already holds the maximum number of server inputs not yet applied
    /// (`SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND`).
    case overCap
    /// The land declares no `HandleServerInput` for this type (matched by the type itself, so a
    /// same-named type from another module or scope is refused).
    case unknownType
    /// The payload has no record form: the canonical record encoding refuses it (a `Set`, a
    /// `Date` outside the years 0001–9999, nesting too deep for `CanonicalMessagePack.maxDepth`
    /// once inside its turn record).
    case unencodable
    /// The keeper isn't live: a replaying keeper takes its server inputs from the record only.
    case notLive
}

/// Submits server inputs to one land's keeper, from any task.
///
/// A turn gets one from `LandContext.serverInputs` and hands it to the work it requests, with the
/// ticket it took; the work submits its result through it. It holds the keeper weakly: a submit
/// after the keeper is gone returns `.refused(.draining)`, it doesn't keep the land alive or crash.
public struct ServerInputSubmitter: Sendable {
    private let submitErased: @Sendable (any ServerInputPayload) async -> ServerInputOutcome

    init(_ submit: @escaping @Sendable (any ServerInputPayload) async -> ServerInputOutcome) {
        self.submitErased = submit
    }

    /// A submitter bound to no keeper: every submit returns `.refused(.notLive)`.
    public static let unavailable = ServerInputSubmitter { _ in .refused(.notLive) }

    /// Submits `input` to the land; see `LandKeeper.submitServerInput`.
    public func submit<I: ServerInputPayload>(_ input: I) async -> ServerInputOutcome {
        await submitErased(input)
    }
}

// MARK: - Handler type erasure

/// Type-erased server input handler collected from the DSL (`HandleServerInput`).
public struct AnyServerInputHandler<State: StateNodeProtocol>: LandNode {
    let inputType: Any.Type
    /// The type identifier recorded with the input: `String(describing: I.self)`.
    let typeIdentifier: String
    private let handler: @Sendable (inout State, AnyCodable, LandContext) throws -> Void

    init<I: ServerInputPayload>(
        inputType: I.Type,
        handler: @escaping @Sendable (inout State, I, LandContext) throws -> Void
    ) {
        self.inputType = inputType
        self.typeIdentifier = String(describing: inputType)
        self.handler = { state, payload, ctx in
            // Live and replay take the same path: the payload in its record form, decoded to `I`
            // by the record codec.
            let input = try ServerInputCodec.decode(I.self, from: payload)
            try handler(&state, input, ctx)
        }
    }

    func invoke(_ state: inout State, payload: AnyCodable, ctx: LandContext) throws {
        try handler(&state, payload, ctx)
    }
}

/// Declares a server input type and handles it in a turn of its own (#387).
///
/// The input comes from `LandKeeper.submitServerInput` (or a `ServerInputSubmitter`), from work
/// running outside the land's turns. The handler runs with the system identity
/// (`LandContext.systemPlayerID`). Server input types are not part of the client schema.
///
/// The handler gets the input in its record form, live and in replay alike: encoded with the
/// canonical record encoding and decoded back (`ServerInputCodec`). A `Date` arrives at whole
/// seconds, as the record holds it: fractional seconds are truncated live, the same as in replay.
///
/// A throwing handler fails that input alone, as for any input: it stays recorded (replay fails
/// it the same way), the state it wrote before throwing is kept, and its events are dropped
/// (outputs of a failed input: #374). Validate before the first write (#87); debug builds warn
/// when a throwing handler wrote.
///
/// A land declares each type name once: types are keyed by `String(describing:)`, so two
/// types with the same name in different modules can't both be declared. A submit matches the
/// declared type itself, not only its name.
///
/// Under a debug freeze the input is accepted and held until the resume. On a tickless land,
/// joins and leaves still run during a freeze, so one that arrives after a held input is
/// applied before it, with a higher sequence; the record keeps that order and replay follows it.
public func HandleServerInput<State: StateNodeProtocol, I: ServerInputPayload>(
    _ type: I.Type,
    _ body: @escaping @Sendable (inout State, I, LandContext) throws -> Void
) -> AnyServerInputHandler<State> {
    AnyServerInputHandler(inputType: type, handler: body)
}

// MARK: - Record form

/// The form a server input is applied in, live and in replay: the canonical record encoding
/// (`CanonicalMessagePack`), so a live apply and its replay decode the same value.
enum ServerInputCodec {
    /// `input` encoded canonically and decoded back as a type-erased value: what the record
    /// holds, and what live applies.
    ///
    /// Also encodes it inside the turn record it will be written in. The record nests the
    /// payload a few levels deep, so a payload within the depth limit alone can exceed it there,
    /// and an accepted input must never stop the recorder.
    static func recordedForm(of input: any ServerInputPayload) throws -> AnyCodable {
        let payload = try CanonicalMessagePack.decode(AnyCodable.self, from: CanonicalMessagePack.encode(AnyCodable(input)))
        _ = try ReevaluationRecordLog.framed(.turn(ReevaluationTickRecord(
            tickId: 0,
            serverInputs: [ReevaluationRecordedServerInput(sequence: 0, typeIdentifier: "", payload: payload, resolvedAtTick: 0)]
        )))
        return payload
    }

    /// Decodes a recorded payload as `I`, with the record codec.
    static func decode<I: Decodable>(_ type: I.Type, from payload: AnyCodable) throws -> I {
        try CanonicalMessagePack.decode(type, from: CanonicalMessagePack.encode(payload))
    }
}

// MARK: - Limits

/// The per-land bound on server inputs submitted but not yet applied.
enum ServerInputLimits {
    static let defaultMaxInFlightPerLand = 64

    /// `SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND`; 0 means no bound.
    static func maxInFlightPerLand(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        max(0, EnvHelpers.getEnvInt(
            key: EnvKeys.Runtime.serverInputInFlightMaxPerLand,
            defaultValue: defaultMaxInFlightPerLand,
            environment: environment
        ))
    }
}
