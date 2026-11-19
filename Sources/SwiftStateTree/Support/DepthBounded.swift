import Foundation

/// A value taken from a client frame whose decode refused nesting deeper than
/// `PayloadNesting.clientFrameMaxDepth`: the proof that the value is no deeper (#362).
///
/// The payload decode (`InboundPayloadDecoding`) walks a payload's depth before its recursive
/// re-encode. A payload in a frame the decoder already bounded can't be deeper than that frame,
/// so its walk is skipped when the payload comes with this proof. A payload without it (a
/// recorded action replayed, a direct call of the keeper's public API) is walked.
///
/// Build one only where this package's own code enforced the client limit on the exact bytes the
/// value came from: the adapter's decode pipeline (`MessageDecodingPipeline`). The proof is a type,
/// not a flag, so a caller can't claim the bound by passing `true`; a value can only be narrowed to
/// a part of itself (`map`). Both rules are kept by review, not by the compiler:
/// - the initializer is `package`. A test (`BoundedPayloadDecodeTests`) fails on a call outside
///   the pipeline and this file, but it matches text, so a call split across lines gets past it;
/// - `map` and `compactMap` wrap whatever their closure returns, so `bounded.map { _ in other }`
///   would prove a value never bounded. Call them only to project a part of the value (a
///   message's envelope, an envelope's payload), as the adapter's decode sites do.
///
/// It is on every live input's path, built in the transport module and read in this one, so its
/// members are `@inlinable`: across a module, a generic that isn't runs unspecialized, through
/// value witnesses and boxed existentials, and costs more than the walk it saves (#616's A/B).
package struct DepthBounded<Value: Sendable>: Sendable {
    package let value: Value

    /// `value` was decoded from a frame refused past `PayloadNesting.clientFrameMaxDepth`.
    @inlinable
    package init(decodedFromBoundedFrame value: Value) {
        self.value = value
    }

    /// A part of the value (a message's envelope, an envelope's payload), bounded as the whole
    /// is: `part` must return a value contained in its argument, never a new one.
    @inlinable
    package func map<Part: Sendable>(_ part: (Value) throws -> Part) rethrows -> DepthBounded<Part> {
        DepthBounded<Part>(decodedFromBoundedFrame: try part(value))
    }

    /// `map` for a part that may be absent.
    @inlinable
    package func compactMap<Part: Sendable>(_ part: (Value) throws -> Part?) rethrows -> DepthBounded<Part>? {
        try part(value).map { DepthBounded<Part>(decodedFromBoundedFrame: $0) }
    }
}

/// A value with its depth bound (`DepthBounded`) or without it: one stored value either way, so
/// an item that carries it holds the value once.
package enum MaybeDepthBounded<Value: Sendable>: Sendable {
    case bounded(DepthBounded<Value>)
    case unchecked(Value)

    @inlinable
    package var value: Value {
        switch self {
        case .bounded(let bounded): return bounded.value
        case .unchecked(let value): return value
        }
    }

    @inlinable
    package var bounded: DepthBounded<Value>? {
        if case .bounded(let bounded) = self { return bounded }
        return nil
    }
}
