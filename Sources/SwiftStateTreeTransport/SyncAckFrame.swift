import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

/// A client's sync ack (#332): `[108, seq]`, the latest sync sequence the client has applied.
///
/// The same array in every message encoding: JSON text for `json` and `opcodeJsonArray`, a
/// MessagePack array for `messagepack`. It isn't a `TransportMessage`: the transport reads it
/// before any message decoding, and it never reaches the keeper, so it is never a turn input and
/// never recorded.
public enum SyncAckFrame {
    /// The frame's opcode, after the message kinds (101–106) and the merged state frame (107).
    public static let opcode: Int64 = 108

    /// The frame for `seq`, as JSON text (`binary` false) or MessagePack.
    public static func encode(seq: UInt64, binary: Bool) -> Data {
        if !binary {
            return Data("[\(opcode),\(seq)]".utf8)
        }
        var data = Data([0x92, UInt8(opcode)])
        switch seq {
        case 0..<0x80:
            data.append(UInt8(seq))
        case 0x80...0xFF:
            data.append(0xCC)
            data.append(UInt8(seq))
        case 0x100...0xFFFF:
            data.append(0xCD)
            appendBigEndian(UInt16(seq), to: &data)
        case 0x1_0000...0xFFFF_FFFF:
            data.append(0xCE)
            appendBigEndian(UInt32(seq), to: &data)
        default:
            data.append(0xCF)
            appendBigEndian(seq, to: &data)
        }
        return data
    }

    /// The acked sequence when `data` is a sync ack in either form, else nil (any other frame).
    /// Only the first bytes are looked at for any other frame.
    public static func parse(_ data: Data) -> UInt64? {
        guard let first = data.first else { return nil }
        if first == 0x92 {
            return parseMessagePack(data)
        }
        return parseJSON(data)
    }

    private static func parseMessagePack(_ data: Data) -> UInt64? {
        let bytes = [UInt8](data.prefix(10))
        guard bytes.count >= 3, bytes[1] == UInt8(opcode) else { return nil }
        guard case .array(let array) = try? unpack(data), array.count == 2 else { return nil }
        switch array[1] {
        case .uint(let value): return value
        case .int(let value) where value >= 0: return UInt64(value)
        default: return nil
        }
    }

    private static func parseJSON(_ data: Data) -> UInt64? {
        // A cheap prefix test first: every other text frame is an object or another opcode.
        let head = data.prefix(16).filter { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }
        guard head.starts(with: Array("[\(opcode),".utf8)) else { return nil }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any], array.count == 2 else { return nil }
        return syncSequence(array[1])
    }

    /// A JSON sync sequence: a non-negative integer (never a boolean or a fraction).
    package static func syncSequence(_ value: Any) -> UInt64? {
        switch JSONSerializationNumber(value) {
        case .int(let n) where n >= 0: return UInt64(n)
        case .unsigned(let n): return n
        default: return nil
        }
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
