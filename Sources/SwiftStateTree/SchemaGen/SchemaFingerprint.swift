import Foundation

// The record's schema fingerprint (#521 D15): a stable hash of what a record's payloads and
// snapshots are decoded against, compared before replay's first step. Derived from SchemaGen's
// extraction, with its input made canonical; SchemaGen's own output is unchanged.

/// A land definition the fingerprint can't describe.
public enum SchemaFingerprintError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A type whose fields the fingerprint can't list: SchemaGen reads it from a sample instance
    /// and no sample could be built (neither `{}` nor an empty snapshot object decoded into it),
    /// or it is a payload without `@Payload` that has fields. Its schema would be an empty
    /// object, which can't tell its fields apart, so it isn't hashed.
    case unbuildableType(String)
    /// Two stored properties of a `@Payload` type that the fingerprint names by one wire key: a
    /// `CodingKeys` raw value that is another property's name. The fingerprint can't tell them
    /// apart, so it isn't hashed.
    case wireKeyCollision(type: String, key: String)

    public var description: String {
        switch self {
        case .unbuildableType(let type):
            return "the record schema fingerprint can't list the fields of \(type): give it @Payload "
                + "(a payload or server input) or @SnapshotConvertible (a value in one)"
        case let .wireKeyCollision(type, key):
            return "the record schema fingerprint can't tell two fields of \(type) apart: both are named "
                + "\"\(key)\"; give each its own CodingKeys raw value"
        }
    }
}

/// The fingerprint a record carries (`ReevaluationRecordMetadata.schemaFingerprint`).
public enum ReevaluationSchemaFingerprint {
    /// Part of the hashed input: a change to the rule bumps it, so a new value never equals an old one.
    public static let formatTag = "fp1"

    /// The fingerprint of `definition`: 16 hex digits.
    ///
    /// It covers the shapes on the wire and in the record: the state tree (fields, types, sync
    /// policies, and whether a field has a default), the actions, which response each returns,
    /// the client and server events, the server inputs, a `Set`'s element type and a
    /// `CaseIterable` raw-value enum's raw values. It doesn't cover behavior (handler and tick
    /// logic, the tick interval, services, configuration, the environment, a default's value).
    /// `ReevaluationEngine.run` and the monitor's runner check those by the state hash per tick;
    /// keeper-mode replay (`LandManager`'s `.reevaluation`) compares none. It is strict: an added
    /// action, event or field changes it too.
    ///
    /// Canonical input: every `description` and the root wire form are left out, `required` lists
    /// are sorted, a `@Payload` type's fields are named by their wire key (`_payloadWireKeys`),
    /// and a default is hashed as present, not by its value, which a macro computes when the
    /// process runs (`UUID()`, `Date()`).
    ///
    /// What it doesn't see: a field of a type read through the `Codable` sample fallback, or of
    /// a `@Payload` type whose `CodingKeys` are in an extension or that encodes itself, is named
    /// by its Swift property name, so a rename changes it and a change of the key alone isn't
    /// seen; the cases of a raw-value enum that isn't `CaseIterable`; and a `let` with an initial
    /// value in a `@Payload` type, which a synthesized `Decodable` doesn't decode (#611).
    ///
    /// - Throws: `SchemaFingerprintError` for a type whose fields it can't list or tell apart,
    ///   and what `SchemaExtractor.extract(from:)` throws for a land that can't be registered.
    public static func compute<State: StateNodeProtocol>(for definition: LandDefinition<State>) throws -> String {
        try compute(for: definition, keyedAs: nil)
    }

    /// `compute(for:)` with the land's schema keyed by `landType` instead of `definition.id`: a
    /// replay definition named by the replay alias, checked against a live recording.
    static func compute<State: StateNodeProtocol>(
        for definition: LandDefinition<State>,
        keyedAs landType: String?
    ) throws -> String {
        let probe = SchemaExtractionProbe()
        let (lands, defs, serverInputs) = try SchemaExtractionProbe.$current.withValue(probe) {
            let schema = try SchemaExtractor.extract(from: definition, version: formatTag)
            var definitions = schema.defs
            var visited = Set(definitions.keys)
            var inputs: [String: JSONSchema] = [:]
            // In key order: a def met twice keeps one form, and which depends on the order.
            for (name, handler) in definition.serverInputHandlers.sorted(by: { $0.key < $1.key }) {
                inputs[name] = ActionEventExtractor.extractEvent(
                    handler.inputType,
                    definitions: &definitions,
                    visitedTypes: &visited
                )
            }
            return (schema.lands, definitions, inputs)
        }
        if let unbuildable = probe.unbuildableTypes.sorted().first {
            throw SchemaFingerprintError.unbuildableType(unbuildable)
        }
        let wireKeys = probe.wireKeys
        let leaves = probe.leaves
        var canonicalDefs: [String: JSONSchema] = [:]
        for (name, def) in defs {
            var def = def
            if let element = leaves.setElements[name] { def.items = Box(element) }
            if let cases = leaves.enumCases[name] { def.enumValues = cases.sorted() }
            canonicalDefs[name] = try canonical(def, wireKeys: wireKeys[name] ?? [:], typeName: name)
        }
        // Which response each action returns: a def per type doesn't say.
        var actionResponses: [String: String] = [:]
        for handler in definition.actionHandlers {
            let action = String(describing: handler.getActionType())
            actionResponses[action] = actionResponses[action]
                ?? handler.getResponseType().map { String(describing: $0) } ?? ""
        }
        let input = FingerprintInput(
            format: formatTag,
            lands: try Dictionary(
                lands.map { (landType != nil && $0.key == definition.id ? landType! : $0.key, try canonical($0.value)) },
                uniquingKeysWith: { first, _ in first }
            ),
            defs: canonicalDefs,
            serverInputs: try serverInputs.mapValues { try canonical($0) },
            actionResponses: actionResponses
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(input)
        return DeterministicHash.toHex64(DeterministicHash.fnv1a64(data))
    }

    /// `compute(for:)`, once per definition: registration computes it, and the land's keepers,
    /// built from the same definition value, read it from there, off the tick path. A failure
    /// is kept too.
    public static func cached<State: StateNodeProtocol>(for definition: LandDefinition<State>) throws -> String {
        try definition.schemaFingerprintCache.value { try compute(for: definition) }.get()
    }

    private struct FingerprintInput: Encodable {
        let format: String
        let lands: [String: LandSchema]
        let defs: [String: JSONSchema]
        let serverInputs: [String: JSONSchema]
        let actionResponses: [String: String]
    }

    private static func canonical(_ land: LandSchema) throws -> LandSchema {
        LandSchema(
            stateType: land.stateType,
            actions: try land.actions.mapValues { try canonical($0) },
            clientEvents: try land.clientEvents.mapValues { try canonical($0) },
            events: try land.events.mapValues { try canonical($0) },
            sync: SyncSchema(snapshot: try canonical(land.sync.snapshot), diff: try canonical(land.sync.diff)),
            pathHashes: land.pathHashes,
            eventHashes: land.eventHashes,
            clientEventHashes: land.clientEventHashes
        )
    }

    /// `schema` without descriptions, with `required` sorted, a default as present only, and its
    /// own properties renamed to their wire keys (`wireKeys`: property name to key).
    ///
    /// - Throws: `SchemaFingerprintError.wireKeyCollision` when two properties of `typeName` get
    ///   one key.
    private static func canonical(
        _ schema: JSONSchema,
        wireKeys: [String: String] = [:],
        typeName: String = ""
    ) throws -> JSONSchema {
        var result = schema
        result.description = nil
        if let properties = schema.properties {
            var renamed: [String: JSONSchema] = [:]
            for (name, value) in properties {
                let key = wireKeys[name] ?? name
                guard renamed[key] == nil else {
                    throw SchemaFingerprintError.wireKeyCollision(type: typeName, key: key)
                }
                renamed[key] = try canonical(value)
            }
            result.properties = renamed
        }
        result.required = schema.required.map { $0.map { wireKeys[$0] ?? $0 }.sorted() }
        result.items = try schema.items.map { Box(try canonical($0.value)) }
        result.additionalProperties = try schema.additionalProperties.map { Box(try canonical($0.value)) }
        // A default's value is computed when the process runs (`UUID()`, `Date()`, config): only
        // whether there is one is part of the shape. `ReevaluationEngine.run` and the monitor's
        // runner compare the state hash per tick, which covers the value; keeper-mode replay
        // compares none, so there a changed static default isn't caught.
        if schema.defaultValue != nil {
            result.defaultValue = .bool(true)
        }
        return result
    }
}

/// A definition's fingerprint, computed on first use and kept: a reference, so copies of the
/// definition share it.
final class SchemaFingerprintCache: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, any Error>?

    func value(_ compute: () throws -> String) -> Result<String, any Error> {
        if let result = lock.withLock({ result }) { return result }
        let computed = Result { try compute() }
        return lock.withLock {
            if let result { return result }
            result = computed
            return computed
        }
    }
}

/// What an extraction under the fingerprint saw that its schema doesn't show: the types no sample
/// could be built of, and each `@Payload` type's wire keys. SchemaGen doesn't set it, so its
/// output is unchanged.
final class SchemaExtractionProbe: @unchecked Sendable {
    @TaskLocal static var current: SchemaExtractionProbe?

    /// What a leaf def doesn't hold: a `Set`'s element schema and an enum's raw values, by def name.
    struct Leaves {
        var setElements: [String: JSONSchema] = [:]
        var enumCases: [String: [String]] = [:]
    }

    private let lock = NSLock()
    private var _unbuildable: Set<String> = []
    private var _wireKeys: [String: [String: String]] = [:]
    private var _leaves = Leaves()

    var unbuildableTypes: Set<String> { lock.withLock { _unbuildable } }
    var wireKeys: [String: [String: String]] { lock.withLock { _wireKeys } }
    var leaves: Leaves { lock.withLock { _leaves } }

    func noteUnbuildable(_ typeName: String) {
        lock.withLock { _ = _unbuildable.insert(typeName) }
    }

    func noteSetElement(of typeName: String, _ element: JSONSchema) {
        lock.withLock { _leaves.setElements[typeName] = element }
    }

    func noteEnumCases(of typeName: String, _ rawValues: [String]) {
        lock.withLock { _leaves.enumCases[typeName] = rawValues }
    }

    /// Notes `type`'s wire keys under its def name, when it renames any field. A type whose own
    /// field list is empty (`listed`) but which has fields (a payload without `@Payload`) is
    /// noted as unbuildable: its fields can't be listed.
    func noteFields(of type: Any.Type, listed: Int) {
        if listed == 0, !TypeToSchemaConverter.isFieldless(type) {
            noteUnbuildable(String(describing: type))
            return
        }
        guard let payload = type as? any PayloadCompression.Type else { return }
        let keys = payload._payloadWireKeys
        guard !keys.isEmpty else { return }
        lock.withLock { _wireKeys[String(describing: type)] = keys }
    }
}

/// A record replay refuses because it can't be shown to match the code (#521 D15).
public enum ReevaluationRecordFingerprintError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The record carries no schema fingerprint: it is older than
    /// `ReevaluationRecordVersion.minimumReplayable`, or its keeper had none. Re-record it.
    case missing(recordedVersion: String?)
    /// The record's fingerprint differs from the current definition's: a field, a type, a
    /// policy, whether a state field has a default or an action's response changed, or an
    /// action, an event or a server input was added or removed.
    case mismatch(recorded: String, current: String)

    public var description: String {
        switch self {
        case .missing(let version):
            return "the record (version \(version ?? "missing")) has no schema fingerprint, so it can't be "
                + "shown to match the code; replay reads records from \(ReevaluationRecordVersion.minimumReplayable) "
                + "on: re-record it with the current server"
        case .mismatch(let recorded, let current):
            return "the record's schema fingerprint \(recorded) differs from the current definition's \(current): "
                + "the land's types or fields changed since it was recorded"
        }
    }
}

extension ReevaluationSchemaFingerprint {
    /// Refuses a record whose schema fingerprint is missing, or differs from `definition`'s.
    /// Every replay entry point calls it before the first step.
    ///
    /// - Throws: `ReevaluationRecordFingerprintError`, or `SchemaFingerprintError` when the
    ///   current definition has no fingerprint.
    public static func checkRecord<State: StateNodeProtocol>(
        _ metadata: ReevaluationRecordMetadata,
        against definition: LandDefinition<State>
    ) throws {
        try checkRecord(metadata, against: definition, replayLandSuffix: nil)
    }

    /// `checkRecord(_:against:)` for a replay land (`LandManager`'s `.reevaluation` mode): a
    /// definition whose id is the recorded definition's (`landDefinitionID`) plus
    /// `replayLandSuffix` is checked under the recorded id, which a live recording's fingerprint
    /// holds. Any other definition, the live one reused among them, is checked under its own.
    package static func checkRecord<State: StateNodeProtocol>(
        _ metadata: ReevaluationRecordMetadata,
        against definition: LandDefinition<State>,
        replayLandSuffix: String?
    ) throws {
        let recorded = try recordedFingerprint(of: metadata)
        let current: String
        if let suffix = replayLandSuffix, !suffix.isEmpty, let recordedID = metadata.landDefinitionID,
           definition.id == recordedID + suffix {
            current = try compute(for: definition, keyedAs: recordedID)
        } else {
            current = try cached(for: definition)
        }
        guard recorded == current else {
            throw ReevaluationRecordFingerprintError.mismatch(recorded: recorded, current: current)
        }
    }

    /// The record's schema fingerprint.
    ///
    /// - Throws: `ReevaluationRecordFingerprintError.missing` for a record older than
    ///   `ReevaluationRecordVersion.minimumReplayable`, or one without the field.
    public static func recordedFingerprint(of metadata: ReevaluationRecordMetadata) throws -> String {
        guard !ReevaluationRecordVersion.isBefore3(
                metadata.version, minor: ReevaluationRecordVersion.fingerprintMinor
              ),
              let recorded = metadata.schemaFingerprint
        else {
            throw ReevaluationRecordFingerprintError.missing(recordedVersion: metadata.version)
        }
        return recorded
    }
}
