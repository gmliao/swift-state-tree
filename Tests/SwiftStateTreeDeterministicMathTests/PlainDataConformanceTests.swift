// Tests/SwiftStateTreeDeterministicMathTests/PlainDataConformanceTests.swift
//
// The DeterministicMath value types are PlainData, so a land's State and payloads can hold them.
// This file compiles only while each one conforms.

import SwiftStateTreeDeterministicMath
import SwiftStateTurns
import Testing

/// Compiles only when `T` is `PlainData`.
private func requirePlainData<T: PlainData>(_: T.Type) {}

@Suite("DeterministicMath types are PlainData")
struct PlainDataConformanceTests {
    @Test("Each value type with stored fields conforms")
    func conforms() {
        requirePlainData(IVec2.self)
        requirePlainData(IVec3.self)
        requirePlainData(Position2.self)
        requirePlainData(Velocity2.self)
        requirePlainData(Acceleration2.self)
        requirePlainData(Angle.self)
        requirePlainData(IAABB2.self)
        requirePlainData(ICircle.self)
        requirePlainData(ILineSegment.self)
        requirePlainData(IRay.self)
        requirePlainData(Grid2.self)
        requirePlainData(OverflowPolicy.self)
    }
}
