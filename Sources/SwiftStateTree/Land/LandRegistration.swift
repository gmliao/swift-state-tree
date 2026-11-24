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
    /// The host's server event opcode table, when it passes one: each registered server event
    /// must have an entry (#521 EV3). Nil skips the row; the encoders then send event names.
    public var eventHashes: [String: Int]?

    public init(payloadsCompressed: Bool? = nil, recordsForReplay: Bool? = nil, eventHashes: [String: Int]? = nil) {
        self.payloadsCompressed = payloadsCompressed
        self.recordsForReplay = recordsForReplay
        self.eventHashes = eventHashes
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
    /// Client event types the land registers without handling, or handles without registering
    /// (#771 §3.3), one line per type: its name and the missing side (`registered, no
    /// HandleEvent`, `handled, not in ClientEvents`). Empty when there are none.
    public let clientEventMismatches: [String]
    /// Nodes in the land's definition that its builder doesn't recognize, by type (#794): a node
    /// built for another State, or a node type the builder has no case for. Such a node would
    /// otherwise be dropped, with its handlers. Empty when there are none.
    public let unrecognizedNodes: [String]
    /// Why a land whose records will be replayed has no record schema fingerprint (#521 D15).
    /// Checked only under `LandRegistrationContext.recordsForReplay`, and only when `sync` is nil.
    public let schemaFingerprint: SchemaFingerprintError?
    /// Server event types a replay can't decode (#521 EV8): their descriptor has no decoder,
    /// because it was built with the public `AnyEventDescriptor` init. Checked only under
    /// `LandRegistrationContext.recordsForReplay`.
    /// Empty when there are none.
    public let serverEventsWithoutDecoder: [String]
    /// Registered server event, client event and action types whose wire name
    /// (`_payloadWireName`) isn't the schema's ID for them (#521 EV2), one line per type: its
    /// kind, the type, both names. Empty when there are none.
    public let wireNameMismatches: [String]
    /// Registered server events with no entry in the host's `eventHashes` (#521 EV3), by event
    /// name and type. Checked only when the context has `eventHashes`. Empty when there are none.
    public let serverEventsWithoutHash: [String]
    /// Distinct types that the record schema fingerprint's walk would define under one name
    /// (#602). That walk covers the whole land: its state, payloads and server inputs, and set
    /// elements, which the registration row's walk doesn't convert. So this holds, for example,
    /// a server input named like a server event or a state type, or a set element named like a
    /// state type. Checked with the fingerprint, under `LandRegistrationContext.recordsForReplay`.
    /// Empty when there are none. Such types the state's own walk finds are `sync`'s
    /// `.typeNameCollision`.
    public let typeNameCollisions: [SchemaTypeNameCollision]
    /// Payload fields that hold a `Decimal` (#597), which has no wire form, one per path: the
    /// payload's role and the field's path (`server event PriceEvent.amount`,
    /// `response BuyResponse of action BuyAction.total`). Covers client and server events,
    /// actions, responses and server inputs, whatever the encoding. Empty when there are none.
    /// A synced state field is `sync`'s `.decimalField`.
    public let decimalFields: [String]

    init(
        landType: String,
        payload: PayloadRegistrationError?,
        sync: SyncRegistrationError? = nil,
        duplicateHandlers: [DuplicateHandlerDeclaration] = [],
        clientEventMismatches: [String] = [],
        unrecognizedNodes: [String] = [],
        schemaFingerprint: SchemaFingerprintError? = nil,
        serverEventsWithoutDecoder: [String] = [],
        wireNameMismatches: [String] = [],
        serverEventsWithoutHash: [String] = [],
        typeNameCollisions: [SchemaTypeNameCollision] = [],
        decimalFields: [String] = []
    ) {
        self.landType = landType
        self.payload = payload
        self.sync = sync
        self.duplicateHandlers = duplicateHandlers
        self.clientEventMismatches = clientEventMismatches
        self.unrecognizedNodes = unrecognizedNodes
        self.schemaFingerprint = schemaFingerprint
        self.serverEventsWithoutDecoder = serverEventsWithoutDecoder
        self.wireNameMismatches = wireNameMismatches
        self.serverEventsWithoutHash = serverEventsWithoutHash
        self.typeNameCollisions = typeNameCollisions
        self.decimalFields = decimalFields
    }

    public var description: String {
        let undecodable = serverEventsWithoutDecoder.isEmpty ? nil
            : "its records will be replayed, and these server event types can't be decoded from a record; "
                + "register each with ServerEvents { Register(E.self) }: "
                + serverEventsWithoutDecoder.joined(separator: ", ")
        let mismatched = wireNameMismatches.isEmpty ? nil
            : "these types' wire names aren't the schema's names for them; keep the type's name, or rename and "
                + "regenerate the schema and the clients: " + wireNameMismatches.joined(separator: ", ")
        let unhashed = serverEventsWithoutHash.isEmpty ? nil
            : "eventHashes has no entry for these server events; pass the schema's table: "
                + serverEventsWithoutHash.joined(separator: ", ")
        let collided = typeNameCollisions.isEmpty ? nil
            : SchemaTypeNameCollisionError(collisions: typeNameCollisions).description
        let decimals = decimalFields.isEmpty ? nil
            : "these payload fields hold a Decimal: " + decimalFields.joined(separator: ", ")
                + "; " + DecimalFields.advice
        let unmatchedEvents = clientEventMismatches.isEmpty ? nil
            : "its client event registrations and handlers disagree; register each handled event in "
                + "ClientEvents { Register(E.self) } and handle each registered one with HandleEvent(E.self): "
                + clientEventMismatches.joined(separator: ", ")
        let unrecognized = unrecognizedNodes.isEmpty ? nil
            : "its definition holds nodes the land's builder doesn't recognize (a node built for another State, "
                + "or a node type the builder has no case for), whose handlers would be dropped: "
                + unrecognizedNodes.joined(separator: ", ")
        return "land type '\(landType)' can't be registered: "
            + ([payload?.description, sync?.description, decimals].compactMap { $0 } + duplicateHandlers.map(\.description)
                + [unrecognized, unmatchedEvents, mismatched, unhashed, schemaFingerprint?.description, collided, undecodable].compactMap { $0 })
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
        // EV2 and EV3 (#521 PR 1b-2b): the wire name is the schema's, and the host's opcode table
        // covers every registered server event.
        let mismatched = wireNameMismatches()
        let unhashed = context.eventHashes.map { serverEventsWithoutHash(in: $0) } ?? []
        // A land whose records will be replayed needs a fingerprint (#521 D15, U3). Computed once
        // per definition and cached; any error other than the fingerprint's own propagates. Only
        // when every other row holds: an error from the schema walk would replace those rows (the
        // walk re-runs this check, so EV2 would throw from inside it).
        // #597: whatever the encoding, a payload's Decimal has no wire form.
        let decimals = payloadDecimalFields()
        var fingerprint: SchemaFingerprintError?
        var typeNameCollisions: [SchemaTypeNameCollision] = []
        if context.recordsForReplay == true, payload == nil, sync == nil, duplicateHandlers.isEmpty,
           clientEventMismatches.isEmpty, unrecognizedNodes.isEmpty, mismatched.isEmpty, unhashed.isEmpty, decimals.isEmpty {
            do {
                _ = try ReevaluationSchemaFingerprint.cached(for: self)
            } catch let error as SchemaFingerprintError {
                fingerprint = error
            } catch let error as SchemaTypeNameCollisionError {
                // The fingerprint's walk, which adds the server inputs, found them (#602).
                typeNameCollisions = error.collisions
            }
        }
        // EV8 (#521 PR 1b): a replay decodes every recorded server event through its
        // descriptor, so a descriptor without a decoder can't replay.
        let undecodable = context.recordsForReplay == true ? serverEventsWithoutDecoder() : []
        if payload != nil || sync != nil || !duplicateHandlers.isEmpty || !clientEventMismatches.isEmpty
            || !unrecognizedNodes.isEmpty || fingerprint != nil || !undecodable.isEmpty
            || !mismatched.isEmpty || !unhashed.isEmpty || !typeNameCollisions.isEmpty || !decimals.isEmpty {
            throw LandRegistrationError(
                landType: id, payload: payload, sync: sync,
                duplicateHandlers: duplicateHandlers, clientEventMismatches: clientEventMismatches,
                unrecognizedNodes: unrecognizedNodes, schemaFingerprint: fingerprint,
                serverEventsWithoutDecoder: undecodable,
                wireNameMismatches: mismatched, serverEventsWithoutHash: unhashed,
                typeNameCollisions: typeNameCollisions, decimalFields: decimals
            )
        }
    }

    /// #597: the payload fields that hold a `Decimal`, by role: client and server events,
    /// actions and their responses, server inputs (recorded and replayed, so on the record's
    /// wire). Sorted within each role for a stable message.
    func payloadDecimalFields() -> [String] {
        var fields: [String] = []
        func add(_ role: String, _ type: Any.Type, suffix: String = "") {
            let root = "\(role) \(type)\(suffix)"
            fields += DecimalFields.payloadPaths(in: type, root: root)
        }
        for descriptor in clientEventRegistry.registered { add("client event", descriptor.type) }
        for descriptor in serverEventRegistry.registered { add("server event", descriptor.type) }
        for handler in actionHandlers {
            let action = handler.getActionType()
            add("action", action)
            if let response = handler.getResponseType() {
                fields += DecimalFields.payloadPaths(in: response, root: "response \(response) of action \(action)")
            }
        }
        for name in serverInputHandlers.keys.sorted() {
            if let handler = serverInputHandlers[name] { add("server input", handler.inputType) }
        }
        return fields
    }

    /// EV2: the registered types whose `_payloadWireName` differs from the schema's ID, the rule
    /// `SchemaExtractor` names them by (`payloadEventName`, `payloadActionName`): the last dotted
    /// component of the type's name, minus a trailing `Event` or `Action`. A hand-written
    /// `_payloadWireName` that keeps an old name after a rename is refused here.
    func wireNameMismatches() -> [String] {
        var mismatched: [String] = []
        func check(_ type: Any.Type, kind: String, schemaID: String) {
            guard let payload = type as? any PayloadCompression.Type else { return }
            let wireName = payload._payloadWireName
            guard wireName != schemaID else { return }
            mismatched.append("\(kind) \(String(reflecting: type)) (wire name \(wireName), schema name \(schemaID))")
        }
        for descriptor in serverEventRegistry.registered {
            check(descriptor.type, kind: "server event", schemaID: payloadEventName(for: descriptor.type))
        }
        for descriptor in clientEventRegistry.registered {
            check(descriptor.type, kind: "client event", schemaID: payloadEventName(for: descriptor.type))
        }
        for handler in actionHandlers {
            let type = handler.getActionType()
            check(type, kind: "action", schemaID: payloadActionName(for: type))
        }
        return mismatched
    }

    /// EV3: the registered server events with no entry in `eventHashes`, by event name. It checks
    /// that the table is complete, not that its opcodes are the schema's.
    func serverEventsWithoutHash(in eventHashes: [String: Int]) -> [String] {
        serverEventRegistry.registered
            .filter { eventHashes[$0.eventName] == nil }
            .map { "\($0.eventName) (\(String(reflecting: $0.type)))" }
    }

    /// EV8: the server event types whose descriptor has no `decodeServerEvent`, by event name.
    func serverEventsWithoutDecoder() -> [String] {
        serverEventRegistry.registered
            .filter { $0.decodeServerEvent == nil }
            .map { "\($0.eventName) (\(String(reflecting: $0.type)))" }
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
