import Foundation

public enum MessagePackValue: Sendable, Equatable, Hashable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Float)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MessagePackValue])
    case map([MessagePackValue: MessagePackValue])
    case extended(type: Int8, data: Data)

    public static func == (lhs: MessagePackValue, rhs: MessagePackValue) -> Bool {
        switch (lhs, rhs) {
        case (.nil, .nil):
            return true
        case let (.bool(lhs), .bool(rhs)):
            return lhs == rhs
        case let (.int(lhs), .int(rhs)):
            return lhs == rhs
        case let (.uint(lhs), .uint(rhs)):
            return lhs == rhs
        case let (.float(lhs), .float(rhs)):
            return lhs.bitPattern == rhs.bitPattern
        case let (.double(lhs), .double(rhs)):
            return lhs.bitPattern == rhs.bitPattern
        case let (.string(lhs), .string(rhs)):
            return lhs == rhs
        case let (.binary(lhs), .binary(rhs)):
            return lhs == rhs
        case let (.array(lhs), .array(rhs)):
            return lhs == rhs
        case let (.map(lhs), .map(rhs)):
            return lhs == rhs
        case let (.extended(lhsType, lhsData), .extended(rhsType, rhsData)):
            return lhsType == rhsType && lhsData == rhsData
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .nil:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .int(let value):
            hasher.combine(2)
            hasher.combine(value)
        case .uint(let value):
            hasher.combine(3)
            hasher.combine(value)
        case .float(let value):
            hasher.combine(4)
            hasher.combine(value.bitPattern)
        case .double(let value):
            hasher.combine(5)
            hasher.combine(value.bitPattern)
        case .string(let value):
            hasher.combine(6)
            hasher.combine(value)
        case .binary(let data):
            hasher.combine(7)
            hasher.combine(data)
        case .array(let values):
            hasher.combine(8)
            hasher.combine(values.count)
            for value in values {
                hasher.combine(value)
            }
        case .map(let values):
            hasher.combine(9)
            var aggregate = 0
            for (key, value) in values {
                var pairHasher = Hasher()
                pairHasher.combine(key)
                pairHasher.combine(value)
                aggregate ^= pairHasher.finalize()
            }
            hasher.combine(aggregate)
        case .extended(let type, let data):
            hasher.combine(10)
            hasher.combine(type)
            hasher.combine(data)
        }
    }
}

public enum MessagePackError: Error {
    case unexpectedEOF
    case invalidUTF8
    case invalidData(String)
}

public func pack(_ value: MessagePackValue) throws -> Data {
    var data = Data()
    var packer = MessagePackPacker()
    try packer.pack(value, into: &data)
    return data
}

public func unpack(_ data: Data) throws -> MessagePackValue {
    var unpacker = MessagePackUnpacker(data: data)
    return try unpacker.unpackValue()
}

private struct MessagePackPacker {
    mutating func pack(_ value: MessagePackValue, into data: inout Data) throws {
        switch value {
        case .nil:
            data.appendByte(0xc0)
        case .bool(let value):
            data.appendByte(value ? 0xc3 : 0xc2)
        case .int(let value):
            try packSigned(value, into: &data)
        case .uint(let value):
            try packUnsigned(value, into: &data)
        case .float(let value):
            data.appendByte(0xca)
            data.appendUInt32(value.bitPattern)
        case .double(let value):
            data.appendByte(0xcb)
            data.appendUInt64(value.bitPattern)
        case .string(let value):
            let bytes = Data(value.utf8)
            try packString(bytes, into: &data)
        case .binary(let value):
            try packBinary(value, into: &data)
        case .array(let values):
            try packArray(values, into: &data)
        case .map(let values):
            try packMap(values, into: &data)
        case .extended(let type, let payload):
            try packExtended(type: type, payload: payload, into: &data)
        }
    }

    private func packSigned(_ value: Int64, into data: inout Data) throws {
        if value >= 0 {
            try packUnsigned(UInt64(value), into: &data)
            return
        }
        if value >= -32 {
            data.appendByte(UInt8(bitPattern: Int8(value)))
        } else if value >= Int64(Int8.min) {
            data.appendByte(0xd0)
            data.appendInt8(Int8(value))
        } else if value >= Int64(Int16.min) {
            data.appendByte(0xd1)
            data.appendInt16(Int16(value))
        } else if value >= Int64(Int32.min) {
            data.appendByte(0xd2)
            data.appendInt32(Int32(value))
        } else {
            data.appendByte(0xd3)
            data.appendInt64(value)
        }
    }

    private func packUnsigned(_ value: UInt64, into data: inout Data) throws {
        if value <= 0x7f {
            data.appendByte(UInt8(value))
        } else if value <= UInt64(UInt8.max) {
            data.appendByte(0xcc)
            data.appendUInt8(UInt8(value))
        } else if value <= UInt64(UInt16.max) {
            data.appendByte(0xcd)
            data.appendUInt16(UInt16(value))
        } else if value <= UInt64(UInt32.max) {
            data.appendByte(0xce)
            data.appendUInt32(UInt32(value))
        } else {
            data.appendByte(0xcf)
            data.appendUInt64(value)
        }
    }

    private func packString(_ bytes: Data, into data: inout Data) throws {
        let count = bytes.count
        if count <= 31 {
            data.appendByte(0xa0 | UInt8(count))
        } else if count <= Int(UInt8.max) {
            data.appendByte(0xd9)
            data.appendUInt8(UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.appendByte(0xda)
            data.appendUInt16(UInt16(count))
        } else if count <= Int(UInt32.max) {
            data.appendByte(0xdb)
            data.appendUInt32(UInt32(count))
        } else {
            throw MessagePackError.invalidData("String too large")
        }
        data.append(bytes)
    }

    private func packBinary(_ bytes: Data, into data: inout Data) throws {
        let count = bytes.count
        if count <= Int(UInt8.max) {
            data.appendByte(0xc4)
            data.appendUInt8(UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.appendByte(0xc5)
            data.appendUInt16(UInt16(count))
        } else if count <= Int(UInt32.max) {
            data.appendByte(0xc6)
            data.appendUInt32(UInt32(count))
        } else {
            throw MessagePackError.invalidData("Binary too large")
        }
        data.append(bytes)
    }

    private mutating func packArray(_ values: [MessagePackValue], into data: inout Data) throws {
        let count = values.count
        if count <= 15 {
            data.appendByte(0x90 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.appendByte(0xdc)
            data.appendUInt16(UInt16(count))
        } else if count <= Int(UInt32.max) {
            data.appendByte(0xdd)
            data.appendUInt32(UInt32(count))
        } else {
            throw MessagePackError.invalidData("Array too large")
        }
        for value in values {
            try pack(value, into: &data)
        }
    }

    private mutating func packMap(_ values: [MessagePackValue: MessagePackValue], into data: inout Data) throws {
        let count = values.count
        if count <= 15 {
            data.appendByte(0x80 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            data.appendByte(0xde)
            data.appendUInt16(UInt16(count))
        } else if count <= Int(UInt32.max) {
            data.appendByte(0xdf)
            data.appendUInt32(UInt32(count))
        } else {
            throw MessagePackError.invalidData("Map too large")
        }
        for (key, value) in values {
            try pack(key, into: &data)
            try pack(value, into: &data)
        }
    }

    private func packExtended(type: Int8, payload: Data, into data: inout Data) throws {
        switch payload.count {
        case 1:
            data.appendByte(0xd4)
        case 2:
            data.appendByte(0xd5)
        case 4:
            data.appendByte(0xd6)
        case 8:
            data.appendByte(0xd7)
        case 16:
            data.appendByte(0xd8)
        default:
            if payload.count <= Int(UInt8.max) {
                data.appendByte(0xc7)
                data.appendUInt8(UInt8(payload.count))
            } else if payload.count <= Int(UInt16.max) {
                data.appendByte(0xc8)
                data.appendUInt16(UInt16(payload.count))
            } else if payload.count <= Int(UInt32.max) {
                data.appendByte(0xc9)
                data.appendUInt32(UInt32(payload.count))
            } else {
                throw MessagePackError.invalidData("Ext too large")
            }
        }
        data.appendInt8(type)
        data.append(payload)
    }
}

private struct MessagePackUnpacker {
    let data: Data
    var offset: Int = 0

    mutating func unpackValue() throws -> MessagePackValue {
        let byte = try readByte()
        switch byte {
        case 0x00...0x7f:
            return .int(Int64(byte))
        case 0x80...0x8f:
            let count = Int(byte & 0x0f)
            return try unpackMap(count)
        case 0x90...0x9f:
            let count = Int(byte & 0x0f)
            return try unpackArray(count)
        case 0xa0...0xbf:
            let count = Int(byte & 0x1f)
            return try unpackString(count)
        case 0xc0:
            return .nil
        case 0xc2:
            return .bool(false)
        case 0xc3:
            return .bool(true)
        case 0xc4:
            let count = Int(try readUInt8())
            return .binary(try readData(count: count))
        case 0xc5:
            let count = Int(try readUInt16())
            return .binary(try readData(count: count))
        case 0xc6:
            let count = Int(try readUInt32())
            return .binary(try readData(count: count))
        case 0xc7:
            let count = Int(try readUInt8())
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: count))
        case 0xc8:
            let count = Int(try readUInt16())
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: count))
        case 0xc9:
            let count = Int(try readUInt32())
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: count))
        case 0xca:
            let bits = try readUInt32()
            return .float(Float(bitPattern: bits))
        case 0xcb:
            let bits = try readUInt64()
            return .double(Double(bitPattern: bits))
        case 0xcc:
            return .uint(UInt64(try readUInt8()))
        case 0xcd:
            return .uint(UInt64(try readUInt16()))
        case 0xce:
            return .uint(UInt64(try readUInt32()))
        case 0xcf:
            return .uint(try readUInt64())
        case 0xd0:
            return .int(Int64(try readInt8()))
        case 0xd1:
            return .int(Int64(try readInt16()))
        case 0xd2:
            return .int(Int64(try readInt32()))
        case 0xd3:
            return .int(try readInt64())
        case 0xd4:
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: 1))
        case 0xd5:
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: 2))
        case 0xd6:
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: 4))
        case 0xd7:
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: 8))
        case 0xd8:
            let type = try readInt8()
            return .extended(type: type, data: try readData(count: 16))
        case 0xd9:
            let count = Int(try readUInt8())
            return try unpackString(count)
        case 0xda:
            let count = Int(try readUInt16())
            return try unpackString(count)
        case 0xdb:
            let count = Int(try readUInt32())
            return try unpackString(count)
        case 0xdc:
            let count = Int(try readUInt16())
            return try unpackArray(count)
        case 0xdd:
            let count = Int(try readUInt32())
            return try unpackArray(count)
        case 0xde:
            let count = Int(try readUInt16())
            return try unpackMap(count)
        case 0xdf:
            let count = Int(try readUInt32())
            return try unpackMap(count)
        case 0xe0...0xff:
            return .int(Int64(Int8(bitPattern: byte)))
        default:
            throw MessagePackError.invalidData("Unknown byte: \(byte)")
        }
    }

    private mutating func unpackArray(_ count: Int) throws -> MessagePackValue {
        var values: [MessagePackValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try unpackValue())
        }
        return .array(values)
    }

    private mutating func unpackMap(_ count: Int) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map.reserveCapacity(count)
        for _ in 0..<count {
            let key = try unpackValue()
            let value = try unpackValue()
            map[key] = value
        }
        return .map(map)
    }

    private mutating func unpackString(_ count: Int) throws -> MessagePackValue {
        let data = try readData(count: count)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MessagePackError.invalidUTF8
        }
        return .string(string)
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw MessagePackError.unexpectedEOF
        }
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    private mutating func readUInt8() throws -> UInt8 {
        try readByte()
    }

    private mutating func readUInt16() throws -> UInt16 {
        try readInteger(UInt16.self)
    }

    private mutating func readUInt32() throws -> UInt32 {
        try readInteger(UInt32.self)
    }

    private mutating func readUInt64() throws -> UInt64 {
        try readInteger(UInt64.self)
    }

    private mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readByte())
    }

    private mutating func readInt16() throws -> Int16 {
        try readInteger(Int16.self)
    }

    private mutating func readInt32() throws -> Int32 {
        try readInteger(Int32.self)
    }

    private mutating func readInt64() throws -> Int64 {
        try readInteger(Int64.self)
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else {
            throw MessagePackError.unexpectedEOF
        }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + size)
        var value = T.zero
        _ = withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer, from: range)
        }
        offset += size
        return T(bigEndian: value)
    }

    private mutating func readData(count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw MessagePackError.unexpectedEOF
        }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + count)
        offset += count
        return data[range]
    }
}


private extension Data {
    mutating func appendByte(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendInt8(_ value: Int8) {
        append(UInt8(bitPattern: value))
    }

    mutating func appendInt16(_ value: Int16) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendInt32(_ value: Int32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendInt64(_ value: Int64) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
