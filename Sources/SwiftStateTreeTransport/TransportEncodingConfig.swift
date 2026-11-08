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
    /// land's sorted schema path hashes) instead of its 32-bit hash. Off by default until paths
    /// below optionals have schema hashes (#287): with it on, a path outside the schema fails its
    /// frame. A client must declare the `pathIndex` feature to join (`stateUpdateFeatures`).
    public let pathIndex: Bool
    /// Opcode state updates with path hashes: send patches that set (or add) fields of one
    /// parent with the same dynamic keys as one merged entry (`MergedPatchOpcode`,
    /// `FieldMergeTable`). On by default. A client must declare the `fieldMerge` feature to join.
    public let fieldMerge: Bool

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
        fieldMerge: Bool = true
    ) {
        self.message = message
        self.stateUpdate = stateUpdate
        self.dynamicKeyCompression = dynamicKeyCompression
        self.atomicValues = atomicValues
        self.pathIndex = pathIndex
        self.fieldMerge = fieldMerge
    }

    /// The state-update features a client must decode (and declare in its join metadata as
    /// `stateUpdateFeatures`) for this config: `pathIndex` and `fieldMerge`, each when on, with
    /// an opcode state-update encoding.
    public var stateUpdateFeatures: [String] {
        guard stateUpdate == .opcodeJsonArray || stateUpdate == .opcodeMessagePack else { return [] }
        var features: [String] = []
        if pathIndex { features.append(StateUpdateFeature.pathIndex) }
        if fieldMerge { features.append(StateUpdateFeature.fieldMerge) }
        return features
    }

    /// The config the encoder actually runs with: without path hashes the opcode encoders send
    /// string paths, so `pathIndex` and `fieldMerge` are off and aren't required of clients.
    public func effective(pathHashes: [String: UInt32]?) -> TransportEncodingConfig {
        pathHashes == nil && (pathIndex || fieldMerge) ? withPathIndex(false).withFieldMerge(false) : self
    }

    /// This config with `dynamicKeyCompression` set.
    public func withDynamicKeyCompression(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: enabled, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: fieldMerge
        )
    }

    /// This config with `atomicValues` set.
    public func withAtomicValues(_ atomicValues: AtomicValueEncoding) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: fieldMerge
        )
    }

    /// This config with `pathIndex` set.
    public func withPathIndex(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: enabled, fieldMerge: fieldMerge
        )
    }

    /// This config with `fieldMerge` set.
    public func withFieldMerge(_ enabled: Bool) -> TransportEncodingConfig {
        TransportEncodingConfig(
            message: message, stateUpdate: stateUpdate,
            dynamicKeyCompression: dynamicKeyCompression, atomicValues: atomicValues, pathIndex: pathIndex, fieldMerge: enabled
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
        stateUpdate.makeEncoder(
            pathHashes: pathHashes,
            warnIfMissingPathHashes: warnIfMissingPathHashes,
            dynamicKeyCompression: dynamicKeyCompression,
            atomicLayout: atomicValues == .positional ? atomicLayout : nil,
            pathIndex: pathIndex,
            unmappedPaths: unmappedPaths,
            fieldMerge: fieldMerge
        )
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
    /// The join metadata key and the `joinResponse` field.
    public static let metadataKey = "stateUpdateFeatures"
    /// Every feature `StateUpdateDecoder` reads: what a Swift client declares at join.
    public static let supported = [pathIndex, fieldMerge]
    /// Join metadata declaring `supported`.
    public static var joinMetadata: [String: AnyCodable] { [metadataKey: AnyCodable(supported)] }
}
