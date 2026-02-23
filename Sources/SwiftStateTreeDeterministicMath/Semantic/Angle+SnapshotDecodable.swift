// Sources/SwiftStateTreeDeterministicMath/Semantic/Angle+SnapshotDecodable.swift
//
// SnapshotValueDecodable conformance for Angle.
// Reverses the encoding produced by the @SnapshotConvertible macro on Angle:
//   .object(["degrees": .int(Int(degrees))])
// where degrees is the raw fixed-point Int32 value (1000 = 1.0 degree).

import SwiftStateTree

extension Angle: SnapshotValueDecodable {
    /// Decodes an Angle from a SnapshotValue.
    ///
    /// Expects `.object(["degrees": .int(...)])` with raw fixed-point Int32 degrees
    /// (1000 = 1.0 degree), which is the format produced by `toSnapshotValue()`.
    ///
    /// - Parameter value: The snapshot value to decode.
    /// - Throws: `SnapshotDecodeError.typeMismatch` if the value is not the expected format.
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .object(let dict) = value,
              let degreesVal = dict["degrees"], case .int(let degrees) = degreesVal
        else {
            throw SnapshotDecodeError.typeMismatch(
                expected: "Angle (.object with \"degrees\": .int)",
                got: value
            )
        }
        self = Angle(degrees: Int32(degrees))
    }
}
