// StateFromSnapshotDecodable.swift
// Protocol for StateNodeProtocol types that support snapshot-based initialization.
// Automatically conformed to by @StateNodeBuilder macro for all @Sync(.broadcast) states.

/// A StateNodeProtocol type that can reconstruct itself from a broadcast StateSnapshot.
///
/// The @StateNodeBuilder macro automatically generates conformance for types that
/// have @Sync(.broadcast) properties whose value types conform to SnapshotValueDecodable.
public protocol StateFromSnapshotDecodable: StateNodeProtocol {
    init(fromBroadcastSnapshot snapshot: StateSnapshot) throws
}
