import SwiftStateTree

// The math types' typed payload forms (#521): each writes the value its `Codable` form gives a
// payload field today, an object of `Int32` fields, keys in byte order (`Position2` →
// `{"v": {"x", "y"}}`, `Angle` → `{"degrees"}`). JSON encodings write these types with their own
// `Codable`. The payload frame goldens pin every one.

extension IVec2: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        writer.object(count: 2)
        writer.key("x")
        writer.int(Int64(x))
        writer.key("y")
        writer.int(Int64(y))
    }
}

extension IVec3: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        writer.object(count: 3)
        writer.key("x")
        writer.int(Int64(x))
        writer.key("y")
        writer.int(Int64(y))
        writer.key("z")
        writer.int(Int64(z))
    }
}

extension Position2: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        writer.object(count: 1)
        writer.key("v")
        v._writeWire(into: &writer)
    }
}

extension Velocity2: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        writer.object(count: 1)
        writer.key("v")
        v._writeWire(into: &writer)
    }
}

extension Acceleration2: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        writer.object(count: 1)
        writer.key("v")
        v._writeWire(into: &writer)
    }
}

extension Angle: _PayloadWireLeaf {
    public func _writeWire<P: _PayloadPrimitiveWriter>(into writer: inout P) {
        writer.object(count: 1)
        writer.key("degrees")
        writer.int(Int64(degrees))
    }
}
