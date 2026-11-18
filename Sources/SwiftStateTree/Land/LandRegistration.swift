import Foundation

// One registration check for a land definition, shared by every entry point (#521, #535): each
// plan adds its rows to `validateForRegistration(context:)` and its field to
// `LandRegistrationError`, so a definition is checked once and every problem is reported in one
// throw.

/// What the entry point knows about how the land will be served. A nil field skips the rows that
/// need it.
public struct LandRegistrationContext: Sendable {
    /// Whether payloads go out in their positional (compressed) form: the `messagepack` and
    /// `opcodeJsonArray` message encodings.
    public var payloadsCompressed: Bool?
    /// Whether the land's records will be replayed: it records (`enableLiveStateHashRecording`),
    /// or its definition is registered for reevaluation. Such a land must have a record schema
    /// fingerprint (#521 D15), or none of its records could replay.
    public var recordsForReplay: Bool?

    public init(payloadsCompressed: Bool? = nil, recordsForReplay: Bool? = nil) {
        self.payloadsCompressed = payloadsCompressed
        self.recordsForReplay = recordsForReplay
    }

    /// The rows that hold whatever the encoding.
    public static let encodingIndependent = LandRegistrationContext()
}

/// Payload types the server would send that can't be written in the land's encoding.
public struct PayloadRegistrationError: Error, CustomStringConvertible, Sendable {
    /// One line per type: its role and name (`server event PlayerShootEvent`,
    /// `response BuyResponse of action BuyAction`).
    public let typesWithoutWriter: [String]

    public var description: String {
        "payloads are compressed, and these types have no positional writer; add @Payload to each: "
            + typesWithoutWriter.joined(separator: ", ")
    }
}

/// A land definition the registration refused, with every problem found.
public struct LandRegistrationError: Error, CustomStringConvertible, Sendable {
    public let landType: String
    public let payload: PayloadRegistrationError?
    /// The state type's synced-state problems (#535): a class in a synced field
    /// (`.valueSemantics`, #464), a per-player field under a broadcast one (`.policyNesting`,
    /// #179), an unsupported key type, or a type that holds a value of any type. Before #535 the
    /// first two were thrown on their own, as `SyncValueSemanticsError` and
    /// `SyncPolicyNestingError`; each is now this field's associated value.
    public let sync: SyncRegistrationError?
    /// Client-event or server-input types declared with more than one handler (#586): an input
    /// runs exactly one `validate` and one `apply`. Empty when there are none.
    public let duplicateHandlers: [DuplicateHandlerDeclaration]
    /// Why a land whose records will be replayed has no record schema fingerprint (#521 D15).
    /// Checked only under `LandRegistrationContext.recordsForReplay`, and only when `sync` is nil.
    public let schemaFingerprint: SchemaFingerprintError?

    init(
        landType: String,
        payload: PayloadRegistrationError?,
        sync: SyncRegistrationError? = nil,
        duplicateHandlers: [DuplicateHandlerDeclaration] = [],
        schemaFingerprint: SchemaFingerprintError? = nil
    ) {
        self.landType = landType
        self.payload = payload
        self.sync = sync
        self.duplicateHandlers = duplicateHandlers
        self.schemaFingerprint = schemaFingerprint
    }

    public var description: String {
        "land type '\(landType)' can't be registered: "
            + ([payload?.description, sync?.description].compactMap { $0 } + duplicateHandlers.map(\.description)
                + [schemaFingerprint?.description].compactMap { $0 })
            .joined(separator: "; ")
    }
}

extension LandDefinition {
    /// Every registration check this definition fails under `context`, in one throw.
    ///
    /// The synced-state rows hold whatever the context: they depend on the state type alone, and
    /// their result is cached per type (`SyncRegistration.cachedProblems`), under the contract that
    /// a state type's default `init()` is deterministic.
    public func validateForRegistration(context: LandRegistrationContext) throws {
        let payload = context.payloadsCompressed == true ? payloadsWithoutWriter() : nil
        let problems = SyncRegistration.cachedProblems(State.self)
        let sync = problems.isEmpty ? nil : SyncRegistrationError(problems: problems)
        // A land whose records will be replayed needs a fingerprint (#521 D15, U3). Computed once
        // per definition and cached; any error other than the fingerprint's own propagates.
        var fingerprint: SchemaFingerprintError?
        if context.recordsForReplay == true, sync == nil {
            do {
                _ = try ReevaluationSchemaFingerprint.cached(for: self)
            } catch let error as SchemaFingerprintError {
                fingerprint = error
            }
        }
        if payload != nil || sync != nil || !duplicateHandlers.isEmpty || fingerprint != nil {
            throw LandRegistrationError(
                landType: id, payload: payload, sync: sync,
                duplicateHandlers: duplicateHandlers, schemaFingerprint: fingerprint
            )
        }
    }

    /// EV1: the types the server writes positionally (its events, and each action's declared
    /// `Response` type) that have no positional writer, which would throw at their first send.
    /// Every public way to declare an action handler (the `HandleAction` forms and
    /// `AnyActionHandler`'s generic init) returns the action's declared `Response` (#586, #561),
    /// so this covers them all.
    func payloadsWithoutWriter() -> PayloadRegistrationError? {
        var problems: [String] = []
        for descriptor in serverEventRegistry.registered where !hasWriter(descriptor.type) {
            problems.append("server event \(descriptor.type)")
        }
        for handler in actionHandlers {
            guard let response = handler.getResponseType(), !hasWriter(response) else { continue }
            problems.append("response \(response) of action \(handler.getActionType())")
        }
        return problems.isEmpty ? nil : PayloadRegistrationError(typesWithoutWriter: problems)
    }

    /// The payload types the server writes and their fields written through `Codable` rather than
    /// a typed form, for the registration log: `[(type, [field])]`, types with such fields only.
    package func payloadFallbackFields() -> [(type: String, fields: [String])] {
        var types: [Any.Type] = serverEventRegistry.registered.map(\.type)
        types += actionHandlers.compactMap { $0.getResponseType() }
        return types.compactMap { type in
            guard let payload = type as? any PayloadCompression.Type else { return nil }
            let fields = payload._payloadFieldForms.filter { $0.form == .codable }.map(\.name)
            return fields.isEmpty ? nil : ("\(type)", fields)
        }
    }

    private func hasWriter(_ type: Any.Type) -> Bool {
        (type as? any PayloadCompression.Type)?._payloadHasTypedWriter ?? false
    }
}
