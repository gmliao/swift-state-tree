// The compile-time shape of a synced field, for `@StateNodeBuilder`'s non-Equatable warning.
// Not for use outside the macro's expansion.

/// A field the typed diff compares or walks.
public struct _SyncTypedField: Sendable {
    init() {}
}

/// A field whose value isn't `Equatable`: it takes the snapshot diff.
public struct _SyncFallbackField: Sendable {
    init() {}
}

// The overloads mirror `SyncTableField.make`'s `read` parameter, so a field resolves here as it
// does there. Only "not Equatable" is visible to the compiler; the other reasons a field takes the
// fallback (a reference type, a node outside the walked shapes) are logged when a land of the
// state type first starts (`syncTableFallbackFields`).
//
// The macro doesn't emit the check for a field whose type names a generic parameter of its node:
// here such a field resolves on the unspecialized type, as a fallback, whatever the parameter is
// bound to, while `make` decides per specialization at run time.

@_disfavoredOverload
public func _syncFieldKind<Node, V: Equatable>(_: (Node) -> V?) -> _SyncTypedField { _SyncTypedField() }

@_disfavoredOverload
public func _syncFieldKind<Node, V>(_: (Node) -> V?) -> _SyncFallbackField { _SyncFallbackField() }

public func _syncFieldKind<Node, N: StateNodeProtocol>(_: (Node) -> N?) -> _SyncTypedField { _SyncTypedField() }

public func _syncFieldKind<Node, N: StateNodeProtocol>(_: (Node) -> N??) -> _SyncTypedField { _SyncTypedField() }

public func _syncFieldKind<Node, K: Hashable, N: StateNodeProtocol>(_: (Node) -> [K: N]?) -> _SyncTypedField { _SyncTypedField() }
