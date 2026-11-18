import Foundation

/// How deep a client's data may nest, in every encoding (#362).
///
/// A parser's own depth limit isn't the pipeline's. Every stage after the parse that walks the
/// value recurses once per level too: `AnyCodable`'s decode, the payload's re-encode in
/// `InboundPayloadDecoding`, the payload type's decode, the recorder's conversion. Swift
/// Concurrency's cooperative threads on Darwin have a 544 KiB stack, and at Foundation's JSON
/// limit (512 levels) the re-encode overflows it, in debug and in release. So:
/// - JSON from a client (a frame, a 2.x record) is refused past `clientFrameMaxDepth` before it
///   is parsed (`checkJSON`), and MessagePack from a client unpacks at the same limit;
/// - every payload is checked again before its re-encode, whatever its source (`check`).
///
/// Two limits; a test pins both and their relation:
/// - `clientFrameMaxDepth` (32) bounds what a client sends, in every encoding. Measured on macOS
///   (Swift 6.3.x, debug, a 544 KiB cooperative-pool stack), the whole client-frame decode chain
///   survives JSON nested 112 deep and overflows at 128, so 32 leaves about 3.5× headroom. The
///   deepest real frame is 7 levels: a 4-level payload in 3 levels of frame.
/// - `serverFrameMaxDepth` (64) is the MessagePack unpacker's default, for frames the server
///   builds from the developer's own state. It is the unpacker's limit from before #362 and
///   passed on Darwin's pool stack; a lower one would limit what a game's state can model.
package enum PayloadNesting {
    package static let clientFrameMaxDepth = 32
    package static let serverFrameMaxDepth = 64

    /// Data nested deeper than `limit`.
    package struct TooDeep: Error, CustomStringConvertible, Sendable {
        package let limit: Int
        package var description: String { "Nesting deeper than \(limit)" }
    }

    /// Throws `TooDeep` when `data`, read as JSON, has arrays or objects nested deeper than
    /// `limit`: one pass over the bytes, counting `[` and `{` outside strings (where a backslash
    /// escapes the next byte), with no recursion and no allocation. Nothing else is judged;
    /// malformed JSON is the parser's to refuse.
    package static func checkJSON(_ data: Data, limit: Int = clientFrameMaxDepth) throws {
        let tooDeep = data.withUnsafeBytes { raw -> Bool in
            var depth = 0
            var inString = false
            var escaped = false
            for byte in raw {
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == UInt8(ascii: "\\") {
                        escaped = true
                    } else if byte == UInt8(ascii: "\"") {
                        inString = false
                    }
                    continue
                }
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    if depth > limit { return true }
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                default:
                    break
                }
            }
            return false
        }
        if tooDeep { throw TooDeep(limit: limit) }
    }

    /// Throws `TooDeep` when `value` (an `AnyCodable`'s `base`: arrays, string-keyed
    /// dictionaries and leaves) has containers nested deeper than `limit`. Iterative, so the
    /// check itself can't overflow on the value it refuses. A value of any other type is a leaf:
    /// only the server builds those, and a client's data decodes to arrays and dictionaries.
    package static func check(_ value: Any, limit: Int = clientFrameMaxDepth) throws {
        // Each entry: a value and the depth of the container holding it (0 at the top).
        var pending: [(value: Any, depth: Int)] = [(value, 0)]
        while let (current, depth) = pending.popLast() {
            if let array = current as? [Any] {
                guard depth < limit else { throw TooDeep(limit: limit) }
                for element in array { pending.append((element, depth + 1)) }
            } else if let object = current as? [String: Any] {
                guard depth < limit else { throw TooDeep(limit: limit) }
                for element in object.values { pending.append((element, depth + 1)) }
            }
        }
    }
}
