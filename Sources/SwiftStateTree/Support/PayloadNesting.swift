import Foundation
import Logging

/// How deep a client's data may nest, in every encoding (#362).
///
/// A parser's own depth limit isn't the pipeline's. Every stage after the parse that walks the
/// value recurses once per level too: `AnyCodable`'s decode, the payload's re-encode in
/// `InboundPayloadDecoding`, the payload type's decode, the recorder's conversion. Swift
/// Concurrency's cooperative threads on Darwin have 524 KiB of stack (`pthread_get_stacksize_np`,
/// down to the guard page; a crash report names the 544 KiB VM region, which also holds 20 KiB
/// above the stack's top, #936), and at Foundation's JSON limit (512 levels) the re-encode
/// overflows it, in debug and in release. So:
/// - a client frame that may reach a JSON parser is checked once per decode, before the parse
///   (`checkClientJSON`): a frame the router forwards is checked by the router and again by the
///   adapter's pipeline. MessagePack from a client unpacks at the same limit;
/// - a 2.x JSON record is checked the same way, at the record limit;
/// - a payload is walked once more before it reaches its type: an `AnyCodable` one by `check`,
///   before its re-encode; a MessagePack one by its decode source, which also checks the keys and
///   numbers a record needs (`MessagePackPayloadSource`, #521). Either way, once per input.
///
/// Two limits; a test pins both and their relation:
/// - `clientFrameMaxDepth` (32) bounds what a client sends, in every encoding. Measured on macOS
///   (Swift 6.3.x, debug, a 524 KiB cooperative-pool stack), the whole client-frame decode chain
///   survives JSON nested 112 deep and overflows at 128, so 32 leaves about 3.5× headroom. The
///   deepest real frame is 7 levels: a 4-level payload in 3 levels of frame.
/// - `serverFrameMaxDepth` (64) is the MessagePack unpacker's default, for frames the server
///   builds from the developer's own state. It is the unpacker's limit from before #362 and
///   passed on Darwin's pool stack; a lower one would limit what a game's state can model.
package enum PayloadNesting {
    package static let clientFrameMaxDepth = 32
    package static let serverFrameMaxDepth = 64
    /// The containers a state conversion may descend below a root field (#716). Provisional:
    /// S0 measures each recursive stage's stack per level, and this becomes the largest value
    /// that leaves about 2x headroom on the smallest stack, capped by `serverFrameMaxDepth` minus
    /// the deepest state frame's overhead. A test pins the cap.
    package static let stateMaxDepth = 32
    /// The recursive steps without a container a state conversion may take on one path (#716).
    /// Provisional, sized by S0's wrapper-only measurement. An `Optional<Node>` at every level up
    /// to `stateMaxDepth` takes one hop a level, so this must stay at least `stateMaxDepth`. Until
    /// S0 measures the unwrap loop, the placeholder is the smallest value that rule allows.
    package static let stateMaxHops = 32

    /// Data nested deeper than `limit`.
    package struct TooDeep: Error, CustomStringConvertible, Sendable {
        package let limit: Int
        package init(limit: Int) { self.limit = limit }
        package var description: String { "Nesting deeper than \(limit)" }
    }

    /// JSON the depth check can't read as UTF-8 JSON: another encoding (UTF-16 or UTF-32, which
    /// Foundation would decode), or a closer with nothing open.
    package struct NotCheckableJSON: Error, CustomStringConvertible, Sendable {
        package let reason: String
        package var description: String { "Not UTF-8 JSON the nesting check can read: \(reason)" }
    }

    /// Checks a client frame that may reach a JSON parser, before the parse. Foundation
    /// reads JSON after leading whitespace and a BOM, and in UTF-16 or UTF-32 too; so:
    /// - leading ASCII whitespace and a UTF-8 BOM are skipped, as the parser does;
    /// - a frame that then starts like UTF-16 or UTF-32 (a 0x00, 0xFE or 0xFF byte) is refused,
    ///   since client JSON is UTF-8;
    /// - one that starts with `[` or `{` is scanned (`checkJSON`);
    /// - anything else holds no container a parser could open first, and is the decoder's to
    ///   refuse.
    /// A MessagePack frame that decodes to a message never starts with any of these bytes (it is
    /// a map or an array), so a pipeline that tries JSON first (the legacy join) can run this on
    /// every frame.
    package static func checkClientJSON(_ data: Data, limit: Int = clientFrameMaxDepth) throws {
        let first = data.withUnsafeBytes { raw -> UInt8? in
            var index = 0
            if raw.count >= 3, raw[0] == 0xEF, raw[1] == 0xBB, raw[2] == 0xBF { index = 3 }
            while index < raw.count {
                switch raw[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return raw[index]
                }
            }
            return nil
        }
        switch first {
        case 0x00, 0xFE, 0xFF:
            throw NotCheckableJSON(reason: "it starts like UTF-16 or UTF-32")
        case UInt8(ascii: "["), UInt8(ascii: "{"):
            try checkJSON(data, limit: limit)
        default:
            return
        }
    }

    /// Throws `TooDeep` when `data`, read as UTF-8 JSON, has arrays or objects nested deeper
    /// than `limit`: one pass over the bytes, counting `[` and `{` outside strings (where a
    /// backslash escapes the next byte), with no recursion and no allocation. A NUL byte (never
    /// in UTF-8 JSON, always in UTF-16 or UTF-32 JSON, whose escapes this count would misread)
    /// and a closer with nothing open throw `NotCheckableJSON`. Nothing else is judged; malformed
    /// JSON is the parser's to refuse.
    package static func checkJSON(_ data: Data, limit: Int = clientFrameMaxDepth) throws {
        enum Outcome { case fits, tooDeep, notUTF8, unbalanced }
        let outcome = data.withUnsafeBytes { raw -> Outcome in
            var depth = 0
            var inString = false
            var escaped = false
            for byte in raw {
                if byte == 0 { return .notUTF8 }
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
                    if depth > limit { return .tooDeep }
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    if depth < 0 { return .unbalanced }
                default:
                    break
                }
            }
            return .fits
        }
        switch outcome {
        case .fits: return
        case .tooDeep: throw TooDeep(limit: limit)
        case .notUTF8: throw NotCheckableJSON(reason: "a NUL byte")
        case .unbalanced: throw NotCheckableJSON(reason: "a closer with nothing open")
        }
    }

    /// Throws `TooDeep` when `value` (an `AnyCodable`'s `base`: arrays, string-keyed
    /// dictionaries, `AnyCodable`s and leaves) has containers nested deeper than `limit`. It
    /// recurses once per container level and once per `AnyCodable` wrapper, which counts as its
    /// base, at the same depth. A client's decoded data wraps each element at most once, so on it
    /// the recursion stays within about twice the limit and can't overflow on the value it
    /// refuses; only server code builds longer chains of wrappers. It builds no intermediate
    /// values; a Foundation container bridged to `[Any]` or `[String: Any]` may still allocate.
    package static func check(_ value: Any, limit: Int = clientFrameMaxDepth) throws {
        walks?.add()
        if !fits(value, depth: 0, limit: limit) { throw TooDeep(limit: limit) }
    }

    /// Counts the depth and recordability walks (`check`, and a MessagePack decode source's walk)
    /// made in the task that binds it, and in the tasks that inherit it. A traversal that checks
    /// nothing (a re-encode, a record's tree build) isn't counted. Tests only: unbound (nil)
    /// everywhere else, where a walk reads the task-local and does nothing more.
    @TaskLocal package static var walks: WalkCounter?

    /// The count `walks` keeps.
    package final class WalkCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        package init() {}

        package var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        package func add() {
            lock.lock(); value += 1; lock.unlock()
        }
    }

    /// Whether `value`, a container's element at `depth`, fits under `limit`.
    private static func fits(_ value: Any, depth: Int, limit: Int) -> Bool {
        if let wrapped = value as? AnyCodable {
            return fits(wrapped.base, depth: depth, limit: limit)
        }
        if let array = value as? [Any] {
            guard depth < limit else { return false }
            for element in array where !fits(element, depth: depth + 1, limit: limit) { return false }
            return true
        }
        if let object = value as? [String: Any] {
            guard depth < limit else { return false }
            for element in object.values where !fits(element, depth: depth + 1, limit: limit) { return false }
            return true
        }
        return true
    }

    // MARK: - Client events dropped for their depth

    private static let logger = Logger(label: "com.swiftstatetree.payload-nesting")
    private static let droppedLock = NSLock()
    nonisolated(unsafe) private static var dropped = 0

    /// Client events dropped because their payload nested deeper than the limit, in this process.
    /// A live client event whose payload doesn't decode is refused at intake (#537), unless its
    /// descriptor has no decode (the public descriptor init's): that one, and a replayed one, is
    /// dropped at apply (#700 K1b-1). One too deep is also logged and counted here.
    package static var droppedClientEventCount: Int {
        droppedLock.withLock { dropped }
    }

    /// Counts the drops noted in the task that binds it, and in the tasks that inherit it. Tests
    /// only: `droppedClientEventCount` is process-wide, so tests running in parallel move it too.
    @TaskLocal package static var droppedForTesting: WalkCounter?

    /// Logs and counts a client event of `type` dropped for its depth.
    package static func noteDroppedClientEvent(type: String, _ error: TooDeep) {
        droppedForTesting?.add()
        let total = droppedLock.withLock { () -> Int in
            dropped += 1
            return dropped
        }
        logger.warning("Client event dropped: its payload nests too deep", metadata: [
            "eventType": .string(type),
            "limit": .stringConvertible(error.limit),
            "droppedTotal": .stringConvertible(total),
        ])
    }
}
