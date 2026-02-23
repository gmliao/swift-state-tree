// Sources/SwiftStateTreeDeterministicMath/Core/IVec2+SnapshotDecodable.swift
//
// SnapshotValueDecodable conformance for IVec2.
// Reverses the encoding produced by IVec2.toSnapshotValue():
//   .object(["x": .int(Int(x)), "y": .int(Int(y))])

import SwiftStateTree

extension IVec2: SnapshotValueDecodable {
    /// Decodes an IVec2 from a SnapshotValue.
    ///
    /// Expects `.object(["x": .int(...), "y": .int(...)])` with raw fixed-point Int32 values,
    /// which is the format produced by `toSnapshotValue()`.
    ///
    /// - Parameter value: The snapshot value to decode.
    /// - Throws: `SnapshotDecodeError.typeMismatch` if the value is not the expected format.
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .object(let dict) = value,
              let xVal = dict["x"], case .int(let x) = xVal,
              let yVal = dict["y"], case .int(let y) = yVal
        else {
            throw SnapshotDecodeError.typeMismatch(
                expected: "IVec2 (.object with \"x\": .int, \"y\": .int)",
                got: value
            )
        }
        self = IVec2(fixedPointX: Int32(x), fixedPointY: Int32(y))
    }
}
