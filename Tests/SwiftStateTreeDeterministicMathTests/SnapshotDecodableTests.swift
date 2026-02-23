// Tests/SwiftStateTreeDeterministicMathTests/SnapshotDecodableTests.swift
//
// Tests for SnapshotValueDecodable conformances on DeterministicMath types.

import Testing
@testable import SwiftStateTreeDeterministicMath
@testable import SwiftStateTree

@Suite("DeterministicMath SnapshotValueDecodable")
struct DeterministicMathSnapshotDecodableTests {

    // MARK: - IVec2

    @Test("IVec2 decodes from object snapshot")
    func ivec2Decode() throws {
        let v = SnapshotValue.object(["x": .int(64000), "y": .int(36000)])
        let ivec = try IVec2(fromSnapshotValue: v)
        #expect(ivec.x == 64000)
        #expect(ivec.y == 36000)
    }

    @Test("IVec2 decodes zero vector")
    func ivec2DecodeZero() throws {
        let v = SnapshotValue.object(["x": .int(0), "y": .int(0)])
        let ivec = try IVec2(fromSnapshotValue: v)
        #expect(ivec == IVec2.zero)
    }

    @Test("IVec2 decodes negative values")
    func ivec2DecodeNegative() throws {
        let v = SnapshotValue.object(["x": .int(-1000), "y": .int(-2000)])
        let ivec = try IVec2(fromSnapshotValue: v)
        #expect(ivec.x == -1000)
        #expect(ivec.y == -2000)
    }

    @Test("IVec2 throws on wrong type")
    func ivec2ThrowsOnWrongType() {
        #expect(throws: (any Error).self) {
            _ = try IVec2(fromSnapshotValue: .string("bad"))
        }
    }

    @Test("IVec2 throws on missing x key")
    func ivec2ThrowsOnMissingX() {
        #expect(throws: (any Error).self) {
            _ = try IVec2(fromSnapshotValue: .object(["y": .int(1000)]))
        }
    }

    @Test("IVec2 throws on missing y key")
    func ivec2ThrowsOnMissingY() {
        #expect(throws: (any Error).self) {
            _ = try IVec2(fromSnapshotValue: .object(["x": .int(1000)]))
        }
    }

    @Test("IVec2 throws on non-int x value")
    func ivec2ThrowsOnNonIntX() {
        #expect(throws: (any Error).self) {
            _ = try IVec2(fromSnapshotValue: .object(["x": .string("foo"), "y": .int(1000)]))
        }
    }

    @Test("IVec2 round-trip through SnapshotValue")
    func ivec2RoundTrip() throws {
        // IVec2 stores raw fixed-point values; use the internal fixedPointX/Y init indirectly
        // via the toSnapshotValue() + fromSnapshotValue round-trip
        let original = IVec2(x: 64.0, y: 36.0)  // quantized to (64000, 36000)
        let snapshotValue = try original.toSnapshotValue()
        let decoded = try IVec2(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
        #expect(decoded.x == 64000)
        #expect(decoded.y == 36000)
    }

    @Test("IVec2 round-trip with zero vector")
    func ivec2RoundTripZero() throws {
        let original = IVec2.zero
        let snapshotValue = try original.toSnapshotValue()
        let decoded = try IVec2(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
    }

    @Test("IVec2 round-trip with negative vector")
    func ivec2RoundTripNegative() throws {
        let original = IVec2(x: -1.5, y: -2.5)
        let snapshotValue = try original.toSnapshotValue()
        let decoded = try IVec2(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
    }

    // MARK: - Angle

    @Test("Angle decodes from object snapshot")
    func angleDecode() throws {
        // Angle stores fixed-point degrees: 90.0 degrees = 90000 in fixed-point
        let v = SnapshotValue.object(["degrees": .int(90000)])
        let angle = try Angle(fromSnapshotValue: v)
        #expect(angle.floatDegrees == 90.0)
    }

    @Test("Angle decodes zero angle")
    func angleDecodeZero() throws {
        let v = SnapshotValue.object(["degrees": .int(0)])
        let angle = try Angle(fromSnapshotValue: v)
        #expect(angle == Angle.zero)
    }

    @Test("Angle decodes negative angle")
    func angleDecodeNegative() throws {
        let v = SnapshotValue.object(["degrees": .int(-45000)])
        let angle = try Angle(fromSnapshotValue: v)
        #expect(angle.floatDegrees == -45.0)
    }

    @Test("Angle throws on wrong type")
    func angleThrowsOnWrongType() {
        #expect(throws: (any Error).self) {
            _ = try Angle(fromSnapshotValue: .string("bad"))
        }
    }

    @Test("Angle uses default zero when degrees key is missing")
    func angleUsesDefaultWhenDegreesMissing() throws {
        // The macro-generated init(fromSnapshotValue:) is lenient: missing keys keep
        // the default value from self.init() (zero angle) rather than throwing.
        let angle = try Angle(fromSnapshotValue: .object(["radians": .int(1000)]))
        #expect(angle == Angle.zero)
    }

    @Test("Angle round-trip through SnapshotValue")
    func angleRoundTrip() throws {
        let original = Angle(degrees: 90.0)
        let snapshotValue = try original.toSnapshotValue()
        let decoded = try Angle(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
    }

    @Test("Angle round-trip zero")
    func angleRoundTripZero() throws {
        let original = Angle.zero
        let snapshotValue = try original.toSnapshotValue()
        let decoded = try Angle(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
    }

    @Test("Angle round-trip negative")
    func angleRoundTripNegative() throws {
        let original = Angle(degrees: -180.0)
        let snapshotValue = try original.toSnapshotValue()
        let decoded = try Angle(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
    }

    @Test("Angle round-trip full circle")
    func angleRoundTripFullCircle() throws {
        let original = Angle(degrees: 360.0)
        let snapshotValue = try original.toSnapshotValue()
        let decoded = try Angle(fromSnapshotValue: snapshotValue)
        #expect(decoded == original)
    }

    // MARK: - Position2

    @Test("Position2 round-trip through SnapshotValue (via @SnapshotConvertible)")
    func position2RoundTrip() throws {
        let pos = Position2(x: 10.0, y: 20.0)
        let snapshotValue = try pos.toSnapshotValue()
        let decoded = try Position2(fromSnapshotValue: snapshotValue)
        #expect(decoded == pos)
    }

    @Test("Position2 round-trip zero position")
    func position2RoundTripZero() throws {
        let pos = Position2()
        let snapshotValue = try pos.toSnapshotValue()
        let decoded = try Position2(fromSnapshotValue: snapshotValue)
        #expect(decoded == pos)
        #expect(decoded.v == IVec2.zero)
    }

    @Test("Position2 round-trip negative coordinates")
    func position2RoundTripNegative() throws {
        let pos = Position2(x: -5.0, y: -3.5)
        let snapshotValue = try pos.toSnapshotValue()
        let decoded = try Position2(fromSnapshotValue: snapshotValue)
        #expect(decoded == pos)
    }

    @Test("Position2 throws on wrong snapshot type")
    func position2ThrowsOnWrongType() {
        #expect(throws: (any Error).self) {
            _ = try Position2(fromSnapshotValue: .string("bad"))
        }
    }
}
