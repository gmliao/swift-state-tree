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

    public var description: String {
        switch self {
        case .unbuildableType(let type):
            return "the record schema fingerprint can't list the fields of \(type): give it @Payload "
                + "(a payload or server input) or @SnapshotConvertible (a value in one)"
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
    /// policies, default values), the actions and their responses, the client and server events,
    /// and the server inputs. It doesn't cover behavior (handler and tick logic, the tick interval,
    /// services, configuration, the environment), which replay checks by the state hash per tick.
    /// It is strict: an added action, event or optional field changes it too.
    ///
    /// Canonical input: every `description` and the root wire form are left out, `required` lists
    /// are sorted, a `@Payload` type's fields are named by their wire key (`_payloadWireKeys`),
    /// and the elements of a default value that is a set are sorted. A field of a type read
    /// through the `Codable` sample fallback is named by its Swift property name, so a change of
    /// its key alone isn't seen here.
    ///
    /// - Throws: `SchemaFingerprintError.unbuildableType` for a type no sample can be built of, and
    ///   what `SchemaExtractor.extract(from:)` throws for a land that can't be registered.
    public static func compute<State: StateNodeProtocol>(for definition: LandDefinition<State>) throws -> String {
        let probe = SchemaExtractionProbe()
        let (lands, defs, serverInputs) = try SchemaExtractionProbe.$current.withValue(probe) {
            let schema = try SchemaExtractor.extract(from: definition, version: formatTag)
            var definitions = schema.defs
            var visited = Set(definitions.keys)
            var inputs: [String: JSONSchema] = [:]
            for (name, handlers) in definition.serverInputHandlers {
                guard let inputType = handlers.first?.inputType else { continue }
                inputs[name] = ActionEventExtractor.extractEvent(
                    inputType,
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
        let input = FingerprintInput(
            format: formatTag,
            lands: lands.mapValues { canonical($0) },
            defs: Dictionary(uniqueKeysWithValues: defs.map { name, def in
                (name, canonical(def, wireKeys: wireKeys[name] ?? [:]))
            }),
            serverInputs: serverInputs.mapValues { canonical($0) }
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
    }

    private static func canonical(_ land: LandSchema) -> LandSchema {
        LandSchema(
            stateType: land.stateType,
            actions: land.actions.mapValues { canonical($0) },
            clientEvents: land.clientEvents.mapValues { canonical($0) },
            events: land.events.mapValues { canonical($0) },
            sync: SyncSchema(snapshot: canonical(land.sync.snapshot), diff: canonical(land.sync.diff)),
            pathHashes: land.pathHashes,
            eventHashes: land.eventHashes,
            clientEventHashes: land.clientEventHashes
        )
    }

    /// `schema` without descriptions, with `required` sorted, set defaults sorted, and its own
    /// properties renamed to their wire keys (`wireKeys`: property name to key).
    private static func canonical(_ schema: JSONSchema, wireKeys: [String: String] = [:]) -> JSONSchema {
        var result = schema
        result.description = nil
        if let properties = schema.properties {
            result.properties = Dictionary(uniqueKeysWithValues: properties.map { name, value in
                (wireKeys[name] ?? name, canonical(value))
            })
        }
        result.required = schema.required.map { $0.map { wireKeys[$0] ?? $0 }.sorted() }
        result.items = schema.items.map { Box(canonical($0.value)) }
        result.additionalProperties = schema.additionalProperties.map { Box(canonical($0.value)) }
        if let defaultValue = schema.defaultValue {
            result.defaultValue = isSet(schema) ? sortedElements(defaultValue) : defaultValue
        }
        return result
    }

    /// A field of a `Set` type refers to its def, which is named after the type.
    private static func isSet(_ schema: JSONSchema) -> Bool {
        schema.ref?.hasPrefix("#/defs/Set<") == true
    }

    /// A set's default with its elements in the order of their canonical JSON.
    private static func sortedElements(_ value: SnapshotValue) -> SnapshotValue {
        guard case .array(let elements) = value else { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let keyed = elements.map { element in
            (String(decoding: (try? encoder.encode(element)) ?? Data(), as: UTF8.self), element)
        }
        return .array(keyed.sorted { $0.0 < $1.0 }.map(\.1))
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

    private let lock = NSLock()
    private var _unbuildable: Set<String> = []
    private var _wireKeys: [String: [String: String]] = [:]

    var unbuildableTypes: Set<String> { lock.withLock { _unbuildable } }
    var wireKeys: [String: [String: String]] { lock.withLock { _wireKeys } }

    func noteUnbuildable(_ typeName: String) {
        lock.withLock { _ = _unbuildable.insert(typeName) }
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
    /// The record's fingerprint differs from the current definition's: a field, a type, a policy
    /// or a default changed, or an action, an event or a server input was added or removed.
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
        let recorded = try recordedFingerprint(of: metadata)
        let current = try cached(for: definition)
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
