import Foundation

enum HexEncoding {
    /// Hex-encode bytes as lowercase, optionally separated.
    ///
    /// This intentionally avoids `String(format:)` (C varargs) to keep formatting type-safe.
    static func lowercaseHexString(_ data: Data, separator: String = " ") -> String {
        guard !data.isEmpty else { return "" }
        let digits: [UInt8] = Array("0123456789abcdef".utf8)

        var out = String()
        // Rough estimate: 2 chars per byte + separators.
        out.reserveCapacity(data.count * 3)

        for (i, byte) in data.enumerated() {
            if i > 0 {
                out.append(separator)
            }
            out.unicodeScalars.append(UnicodeScalar(UInt32(digits[Int(byte >> 4)]))!)
            out.unicodeScalars.append(UnicodeScalar(UInt32(digits[Int(byte & 0x0F)]))!)
        }

        return out
    }
}
