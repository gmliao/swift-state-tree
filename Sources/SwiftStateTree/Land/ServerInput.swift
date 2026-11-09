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
    /// The land declares no `HandleServerInput` for this type.
    case unknownType
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
            // Live and replay take the same path: the payload as recorded, decoded to `I`.
            let data = try JSONEncoder().encode(payload)
            let input = try JSONDecoder().decode(I.self, from: data)
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
/// (`LandContext.systemPlayerID`). A throwing handler fails that input alone, as for any input.
/// Server input types are not part of the client schema.
public func HandleServerInput<State: StateNodeProtocol, I: ServerInputPayload>(
    _ type: I.Type,
    _ body: @escaping @Sendable (inout State, I, LandContext) throws -> Void
) -> AnyServerInputHandler<State> {
    AnyServerInputHandler(inputType: type, handler: body)
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
