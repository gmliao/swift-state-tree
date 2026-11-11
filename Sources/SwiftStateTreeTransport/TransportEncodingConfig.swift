import Foundation
import SwiftStateTree

/// How the opcode state-update encodings send an atomic value (`AtomicSnapshotValue`).
public enum AtomicValueEncoding: String, Sendable {
    /// The array of its leaves in `atomicLeafPaths` order (`Position2` → `[x, y]`).
    case positional
    /// The keyed object, as before positional encoding. Kept for one release for clients that
    /// don't decode the positional form yet. The schema declares `x-stateTree.atomicEncoding:
    /// "positional"` in both modes, so their schema hash differs from the server's: keep
    /// `expectedSchemaHash` off while they are connected.
    case keyed
}

/// Defines the encoding combination used by the transport layer.
public struct TransportEncodingConfig: Sendable {
    public let message: TransportEncoding
    public let stateUpdate: StateUpdateEncoding
    /// Opcode state updates with path hashes: send dynamic keys as table slots after their first
    /// use (true, the default) or always as full key strings (false). Independent of path hashing,
    /// so each technique's byte contribution can be measured on its own (#59). Decoders accept
    /// both forms.
    public let dynamicKeyCompression: Bool
    /// Opcode state updates: atomic values positional (the default) or keyed. `json` state
    /// updates are always keyed.
    public let atomicValues: AtomicValueEncoding
    /// Opcode state updates with path hashes: send a pattern's path index (its rank among the
    /// land's sorted schema path hashes) instead of its 32-bit hash. On by default. A path outside
    /// the schema has no index: the encoder throws `pathNotInSchema`, and the adapter drops that
    /// patch and counts it (`TransportAdapter.unmappedPathPatches`). A client must declare the
    /// `pathIndex` feature to join (`stateUpdateFeatures`).
    public let pathIndex: Bool
    /// Opcode state updates with path hashes: send patches that set (or add) fields of one
    /// parent with the same dynamic keys as one merged entry (`MergedPatchOpcode`,
    /// `FieldMergeTable`). On by default. A client must declare the `fieldMerge` feature to join.
    public let fieldMerge: Bool
    /// Every state-update frame carries the land's sync sequence (`[opcode, seq, patch...]` in
    /// the opcode encodings, a `seq` key in the JSON object), which clients ack (#332); a client
    /// must declare the `syncSequence` feature to join, whatever the encoding. A hosted land
    /// always has it (`NIOLandServerConfiguration`); off here, the old frame shape, only for
    /// in-package tests and benchmarks that build encodings directly.
    package let syncSequence: Bool
    /// Opcode state updates with path hashes: a row of a root node map is sent as row entries
    /// (`RowPatchOpcode`: create, delete, column set, column clear), named by its table slot,
    /// instead of path entries with its key. Off by default. It requires `pathIndex` and
    /// `syncSequence` (`effective(pathHashes:)` turns it off without them), and it takes effect
    /// only on a land where every join completes in a turn: a `.live` keeper with in-turn sync,
    /// and joins through the router. Elsewhere the land runs without it and logs that once. A
    /// client must declare the `rowAddressing` feature to join a land that has it in effect.
    public let rowAddressing: Bool

    /// Automatically determine if payload should be encoded as an array (compressed format) instead of an object.
    /// - Returns: true if message encoding is .opcodeJsonArray or .messagepack
    var shouldEncodePayloadAsArray: Bool {
        switch message {
        case .opcodeJsonArray, .messagepack:
            return true
        default:
            return false
        }
    }

    public init(
        message: TransportEncoding = .json,
        stateUpdate: StateUpdateEncoding = .opcodeJsonArray,
        dynamicKeyCompression: Bool = true,
        atomicValues: AtomicValueEncoding = .positional,
        pathIndex: Bool = true,
        fieldMerge: Bool = true,
        rowAddressing: Bool = false
    ) {
        self.init(
            message: message, stateUpdate: stateUpdate, dynamicKeyCompression: dynamicKeyCompression,
            atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: fieldMerge, syncSequence: false,
            rowAddressing: rowAddressing
        )
    }

    package init(
        message: TransportEncoding = .json,
        stateUpdate: StateUpdateEncoding = .opcodeJsonArray,
        dynamicKeyCompression: Bool = true,
        atomicValues: AtomicValueEncoding = .positional,
        pathIndex: Bool = true,
        fieldMerge: Bool = true,
        syncSequence: Bool,
        rowAddressing: Bool = false
    ) {
        self.message = message
        self.stateUpdate = stateUpdate
        self.dynamicKeyCompression = dynamicKeyCompression
        self.atomicValues = atomicValues
        self.pathIndex = pathIndex
        self.fieldMerge = fieldMerge
        self.syncSequence = syncSequence
        self.rowAddressing = rowAddressing
    }

    /// Whether the state-update encoding is an opcode one (`opcodeJsonArray`, `opcodeMessagePack`).
    private var hasOpcodeStateUpdates: Bool {
        stateUpdate == .opcodeJsonArray || stateUpdate == .opcodeMessagePack
    }

    /// The state-update features a client must decode (and declare in its join metadata as
    /// `stateUpdateFeatures`) for this config: `pathIndex`, `fieldMerge` and `rowAddressing`,
    /// each when on, with an opcode state-update encoding; `syncSequence` when on, with any
    /// encoding. Read it from an effective config (`effective(pathHashes:)`).
    public var stateUpdateFeatures: [String] {
        var features: [String] = []
        if hasOpcodeStateUpdates {
            if pathIndex { features.append(StateUpdateFeature.pathIndex) }
            if fieldMerge { features.append(StateUpdateFeature.fieldMerge) }
            if rowAddressing { features.append(StateUpdateFeature.rowAddressing) }
        }
        if syncSequence { features.append(StateUpdateFeature.syncSequence) }
        return features
    }

    /// The config the encoder actually runs with: without path hashes the opcode encoders send
    /// string paths, so `pathIndex`, `fieldMerge` and `rowAddressing` are off and aren't
    /// required of clients. `rowAddressing` is also off without `pathIndex` or `syncSequence`,
    /// or without an opcode state-update encoding. Where the land itself allows
    /// `rowAddressing` (a join completing in a turn) is the adapter's to decide, after this.
    public func effective(pathHashes: [String: UInt32]?) -> TransportEncodingConfig {
        var config = self
        if pathHashes == nil && (pathIndex || fieldMerge) {
            config = config.withPathIndex(false).withFieldMerge(false)
        }
        if config.rowAddressing && !config.rowAddressingRequirementsHold(hasPathHashes: pathHashes != nil) {
            config = config.withRowAddressing(false)
        }
        return config
    }

    /// `rowAddressing`'s requirements on the other features: path hashes, `pathIndex`,
    /// `syncSequence` and an opcode state-update encoding. The one place they are stated.
    private func rowAddressingRequirementsHold(hasPathHashes: Bool) -> Bool {
        hasPathHashes && hasOpcodeStateUpdates && pathIndex && syncSequence
    }

    /// This config with `rowAddressing` set.
    public func withRowAddressing(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: fieldMerge, syncSequence: syncSequence, rowAddressing: enabled
        )
    }

    /// `ROW_ADDRESSING` (default false), for servers that build their config from the
    /// environment. It takes effect only where every join completes in a turn (in-turn sync,
    /// the default, and joins through the router).
    public static let rowAddressingEnvironmentKey = TransportEnvKeys.rowAddressing

    public static func rowAddressingFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        EnvHelpers.getEnvBool(key: TransportEnvKeys.rowAddressing, defaultValue: false, environment: environment)
    }

    /// This config with `dynamicKeyCompression` set.
    public func withDynamicKeyCompression(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: enabled, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: fieldMerge, syncSequence: syncSequence, rowAddressing: rowAddressing
        )
    }

    /// This config with `atomicValues` set.
    public func withAtomicValues(_ atomicValues: AtomicValueEncoding) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: fieldMerge, syncSequence: syncSequence, rowAddressing: rowAddressing
        )
    }

    /// This config with `pathIndex` set.
    public func withPathIndex(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: enabled, fieldMerge: fieldMerge, syncSequence: syncSequence, rowAddressing: rowAddressing
        )
    }

    /// The encoding a hosted land runs (`NIOLandHost`, and `LandManager` with a sync-lag
    /// policy): this config with `syncSequence` on, since a hosted land always tracks sync lag.
    package var forHostedLand: TransportEncodingConfig {
        withSyncSequence(true)
    }

    /// This config with `syncSequence` set.
    package func withSyncSequence(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: fieldMerge, syncSequence: enabled, rowAddressing: rowAddressing
        )
    }

    /// This config with `fieldMerge` set.
    public func withFieldMerge(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: enabled, syncSequence: syncSequence, rowAddressing: rowAddressing
        )
    }

    /// `FIELD_MERGE` (default true), for servers that build their config from the environment.
    public static let fieldMergeEnvironmentKey = TransportEnvKeys.fieldMerge

    public static func fieldMergeFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        EnvHelpers.getEnvBool(key: TransportEnvKeys.fieldMerge, defaultValue: true, environment: environment)
    }

    /// `PATH_INDEX` (default true), for servers that build their config from the environment.
    public static let pathIndexEnvironmentKey = TransportEnvKeys.pathIndex

    public static func pathIndexFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        EnvHelpers.getEnvBool(key: TransportEnvKeys.pathIndex, defaultValue: true, environment: environment)
    }

    /// `DYNAMIC_KEY_COMPRESSION` (default true), for servers that build their config from the
    /// environment: `config.withDynamicKeyCompression(TransportEncodingConfig.dynamicKeyCompressionFromEnvironment())`.
    /// The environment key `dynamicKeyCompressionFromEnvironment` reads (`DYNAMIC_KEY_COMPRESSION`).
    public static let dynamicKeyCompressionEnvironmentKey = TransportEnvKeys.dynamicKeyCompression

    public static func dynamicKeyCompressionFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        EnvHelpers.getEnvBool(key: TransportEnvKeys.dynamicKeyCompression, defaultValue: true, environment: environment)
    }

    /// JSON mode: human-readable JSON object format for both messages and state updates
    /// - message: json (e.g., {"kind": "action", "payload": {...}})
    /// - stateUpdate: jsonObject (full JSON patches)
    /// - compression: disabled (JSON text doesn't compress well)
    /// - Use case: debugging, development, maximum compatibility
    public static let json = TransportEncodingConfig(
        message: .json,
        stateUpdate: .jsonObject
    )
    
    /// Hybrid mode: JSON messages with opcode state updates
    /// - message: json (readable action/event messages)
    /// - stateUpdate: opcodeJsonArray (compact state patches with path hashing)
    /// - compression: disabled for payload (message is json), enabled for state (opcode)
    /// - Use case: debugging messages while optimizing state sync, gradual migration
    public static let jsonOpcode = TransportEncodingConfig(
        message: .json,
        stateUpdate: .opcodeJsonArray
    )
    
    /// Opcode JSON Array mode: compact JSON array format for both messages and state updates
    /// - message: opcodeJsonArray (e.g., [101, requestID, ...])
    /// - stateUpdate: opcodeJsonArray (compact state patches)
    /// - compression: enabled (array format compresses well)
    public static let opcode = TransportEncodingConfig(
        message: .opcodeJsonArray,
        stateUpdate: .opcodeJsonArray
    )
    
    /// MessagePack mode: binary encoding for both messages and state updates
    /// - message: messagepack (binary encoded messages)
    /// - stateUpdate: opcodeMessagePack (opcode array structure in MessagePack binary)
    /// - compression: enabled (binary format compresses very well)
    public static let messagepack = TransportEncodingConfig(
        message: .messagepack,
        stateUpdate: .opcodeMessagePack
    )

    public func makeCodec() -> any TransportCodec {
        message.makeCodec()
    }

    public func makeMessageEncoder(
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil
    ) -> any TransportMessageEncoder {
        message.makeMessageEncoder(
            eventHashes: eventHashes,
            clientEventHashes: clientEventHashes,
            enablePayloadCompression: shouldEncodePayloadAsArray
        )
    }

    /// The state-update encoder. `atomicLayout` is the state's table
    /// (`AtomicLayoutTable.forState(State.self)`); it is used only with `atomicValues == .positional`.
    public func makeStateUpdateEncoder(
        pathHashes: [String: UInt32]? = nil,
        warnIfMissingPathHashes: Bool = true,
        atomicLayout: AtomicLayoutTable? = nil,
        unmappedPaths: UnmappedPathCounter? = nil
    ) -> any StateUpdateEncoder {
        let encoder = stateUpdate.makeEncoder(
            pathHashes: pathHashes,
            warnIfMissingPathHashes: warnIfMissingPathHashes,
            dynamicKeyCompression: dynamicKeyCompression,
            atomicLayout: atomicValues == .positional ? atomicLayout : nil,
            pathIndex: pathIndex,
            unmappedPaths: unmappedPaths,
            fieldMerge: fieldMerge
        )
        // Row entries need path indices and a path table: only an effective config asks for them.
        guard rowAddressing, pathIndex, pathHashes != nil else { return encoder }
        switch encoder {
        case let encoder as OpcodeMessagePackStateUpdateEncoder: return encoder.withRowAddressing()
        case let encoder as OpcodeJSONStateUpdateEncoder: return encoder.withRowAddressing()
        default: return encoder
        }
    }
}

public extension StateUpdateEncoding {
    func makeEncoder(
        pathHashes: [String: UInt32]? = nil,
        warnIfMissingPathHashes: Bool = true,
        dynamicKeyCompression: Bool = true,
        atomicLayout: AtomicLayoutTable? = nil,
        pathIndex: Bool = false,
        unmappedPaths: UnmappedPathCounter? = nil,
        fieldMerge: Bool = false
    ) -> any StateUpdateEncoder {
        // The merge table needs the atomic patterns: an atomic value is a mergeable field.
        let mergeTable = { (pathHashes: [String: UInt32]) -> FieldMergeTable? in
            guard fieldMerge else { return nil }
            return FieldMergeTable(pathHashes: pathHashes, atomicPatterns: Set(atomicLayout.map { Array($0.patterns.keys) } ?? []))
        }
        switch self {
        case .jsonObject:
            return JSONStateUpdateEncoder()
        case .opcodeJsonArray:
            // Validate configuration: opcodeJsonArray should have pathHashes for compression
            if warnIfMissingPathHashes, pathHashes == nil {
                // Log warning (using print as we don't have logger context here)
                print("⚠️ WARNING: opcodeJsonArray encoding is configured but pathHashes is nil.")
                print("   This will fall back to Legacy format (no PathHash compression).")
                print("   To enable full compression, provide pathHashes from your Land schema:")
                print("   Example: pathHashes: YourLand.schema.pathHashes")
            }
            
            // Create PathHasher if pathHashes available
            if let pathHashes = pathHashes {
                let pathHasher = PathHasher(pathHashes: pathHashes)
                return OpcodeJSONStateUpdateEncoder(
                    pathHasher: pathHasher, dynamicKeyCompression: dynamicKeyCompression, atomicLayout: atomicLayout,
                    pathIndex: pathIndex, unmappedPaths: unmappedPaths, fieldMerge: mergeTable(pathHashes)
                )
            }
            return OpcodeJSONStateUpdateEncoder(atomicLayout: atomicLayout)
        case .opcodeMessagePack:
            // Validate configuration: opcodeMessagePack should have pathHashes for compression (optional)
            if warnIfMissingPathHashes, pathHashes == nil {
                print("⚠️ WARNING: opcodeMessagePack encoding is configured but pathHashes is nil.")
                print("   This will use Legacy format (no PathHash compression).")
                print("   To enable full compression, provide pathHashes from your Land schema.")
            }
            if let pathHashes = pathHashes {
                let pathHasher = PathHasher(pathHashes: pathHashes)
                return OpcodeMessagePackStateUpdateEncoder(
                    pathHasher: pathHasher, dynamicKeyCompression: dynamicKeyCompression, atomicLayout: atomicLayout,
                    pathIndex: pathIndex, unmappedPaths: unmappedPaths, fieldMerge: mergeTable(pathHashes)
                )
            }
            return OpcodeMessagePackStateUpdateEncoder(atomicLayout: atomicLayout)
        case .opcodeJsonArrayLegacy:
            // Explicitly force legacy mode (no PathHasher)
            return OpcodeJSONStateUpdateEncoder(atomicLayout: atomicLayout)
        }
    }
}

/// Names of the state-update features a client declares in its join metadata
/// (`stateUpdateFeatures`) and the server echoes in `joinResponse`.
public enum StateUpdateFeature {
    /// Path ids are path indices (`TransportEncodingConfig.pathIndex`).
    public static let pathIndex = "pathIndex"
    /// Merged entries, ops 4 and 5 (`TransportEncodingConfig.fieldMerge`).
    public static let fieldMerge = "fieldMerge"
    /// The sync sequence after the opcode, or the JSON object's `seq` key
    /// (`TransportEncodingConfig.syncSequence`).
    public static let syncSequence = "syncSequence"
    /// Row entries, ops 6 to 9 (`TransportEncodingConfig.rowAddressing`).
    public static let rowAddressing = "rowAddressing"
    /// The join metadata key and the `joinResponse` field.
    public static let metadataKey = "stateUpdateFeatures"
    /// Every feature `StateUpdateDecoder` reads: what a Swift client declares at join.
    public static let supported = [pathIndex, fieldMerge, syncSequence, rowAddressing]
    /// Join metadata declaring `supported`.
    public static var joinMetadata: [String: AnyCodable] { [metadataKey: AnyCodable(supported)] }
}
