// Sources/SwiftStateTreeNIO/ReplayTicket.swift
//
// A replay or monitor land's instance ID is a ticket an admin reevaluation route signs: only an
// ID this process issued can create such a land, so creating one needs the admin key, not just a
// record's path.

import Crypto
import Foundation
import Logging
import SwiftStateTree

/// Signs and verifies the tickets the admin reevaluation routes issue as land instance IDs:
/// - a replay ticket, `r1-<nonce>-<expiry>-<mac>.<pathToken>`, for a replay land;
/// - a monitor ticket, `m1-<nonce>-<expiry>-<liveLandType>-<mac>.<pathToken>`, for a
///   reevaluation monitor land, where `liveLandType` (hex of its UTF-8) names the land type the
///   record was taken from, which picks the run's projector.
///
/// `pathToken` is the record path in base64url (the part `ReevaluationReplaySessionDescriptor
/// .decode` reads for a replay ticket). `mac` is an HMAC-SHA256 over the ticket's kind, the land
/// type it opens, the nonce, the expiry, the live land type (monitor) and the path token, so a
/// ticket opens only the land type and kind it was issued for: a replay ticket never opens a
/// monitor land, nor the other way round.
///
/// The key is random per process and held only in memory (`process`): a restart invalidates
/// every ticket, as it ends every replay and monitor land. It is never derived from another
/// secret.
struct ReplayTicketSigner: Sendable {
    /// The process's signer: the admin routes issue with it, and the replay and monitor lands'
    /// creation paths verify with it.
    static let process = ReplayTicketSigner(key: SymmetricKey(size: .bits256))

    /// How long an issued ticket can create its land. A land already created stays joinable
    /// with the same ticket for its lifetime (its ID is the ticket).
    static let defaultLifetime: Duration = .seconds(300)

    enum Verdict: Equatable, Sendable {
        case valid
        case expired
        case invalid
    }

    /// What `inspect` found, in the order it checks: the length first, before any parsing.
    enum Inspection: Equatable, Sendable {
        case tooLong
        case malformed
        case badMAC
        case expired(Fields)
        case valid(Fields)

        var verdict: Verdict {
            switch self {
            case .valid: return .valid
            case .expired: return .expired
            case .tooLong, .malformed, .badMAC: return .invalid
            }
        }

        /// The signed fields of a ticket whose MAC verified (expired or not).
        var fields: Fields? {
            switch self {
            case .valid(let fields), .expired(let fields): return fields
            case .tooLong, .malformed, .badMAC: return nil
            }
        }
    }

    struct Fields: Equatable, Sendable {
        /// The record's live land type (monitor tickets only).
        let liveLandType: String?
        let pathToken: String
    }

    enum Kind: String, Sendable {
        case replay = "r1"
        case monitor = "m1"
    }

    /// The longest instance ID `inspect` reads: the ticket fields and a path token for a record
    /// path of up to 3 KB.
    static let maxInstanceIDLength = 4_096
    /// The longest live land type a monitor ticket carries.
    static let maxLiveLandTypeLength = 256

    let key: SymmetricKey
    let lifetime: Duration
    let now: @Sendable () -> Date

    init(
        key: SymmetricKey,
        lifetime: Duration = ReplayTicketSigner.defaultLifetime,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.key = key
        self.lifetime = lifetime
        self.now = now
    }

    /// The instance ID for a replay of `pathToken` on `replayLandType`.
    func issue(replayLandType: String, pathToken: String) -> String {
        issue(kind: .replay, landType: replayLandType, liveLandType: nil, pathToken: pathToken)
    }

    /// The instance ID for a monitor land on `monitorLandType` that verifies `pathToken`'s record,
    /// taken from `liveLandType`.
    func issueMonitor(monitorLandType: String, liveLandType: String, pathToken: String) -> String {
        issue(kind: .monitor, landType: monitorLandType, liveLandType: liveLandType, pathToken: pathToken)
    }

    /// Whether `instanceId` is a replay ticket this signer issued for `replayLandType`, and
    /// whether it can still create its land. The MAC is compared in constant time.
    func verify(instanceId: String, replayLandType: String) -> Verdict {
        inspect(instanceId: instanceId, kind: .replay, landType: replayLandType).verdict
    }

    /// Checks `instanceId` as a ticket of `kind` for `landType`, in order: the length, then the
    /// spelling, then the MAC (constant time), then the expiry.
    func inspect(instanceId: String, kind: Kind, landType: String) -> Inspection {
        // Bounded before any parsing or hashing: the ID comes from a client.
        guard instanceId.utf8.count <= Self.maxInstanceIDLength else { return .tooLong }
        let parts = instanceId.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return .malformed }
        let fields = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        let fieldCount = kind == .monitor ? 5 : 4
        // One spelling per ticket: digits without a leading zero and lowercase hex only, so no
        // second ID (a sign, a leading zero, an uppercase digit) passes for the same ticket and
        // names a second land.
        guard fields.count == fieldCount, fields[0] == kind.rawValue,
              fields[1].count == 32, fields[1].allSatisfy(Self.isLowerHex),
              !fields[2].isEmpty, fields[2].first != "0", fields[2].allSatisfy({ $0.isASCII && $0.isNumber }),
              let expiry = Int64(fields[2])
        else { return .malformed }
        let macField = fields[fieldCount - 1]
        var liveLandType: String?
        if kind == .monitor {
            let liveField = fields[3]
            guard !liveField.isEmpty, liveField.utf8.count <= Self.maxLiveLandTypeLength * 2,
                  let bytes = Self.bytes(fromHex: liveField),
                  let text = String(data: bytes, encoding: .utf8)
            else { return .malformed }
            liveLandType = text
        }
        guard macField.utf8.count == SHA256.byteCount * 2,
              let mac = Self.bytes(fromHex: macField), mac.count == SHA256.byteCount
        else { return .malformed }
        let pathToken = String(parts[1])
        let message = Self.message(
            kind: kind, landType: landType, nonce: String(fields[1]), expiry: expiry,
            liveLandType: liveLandType, pathToken: pathToken
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: key) else {
            return .badMAC
        }
        let signed = Fields(liveLandType: liveLandType, pathToken: pathToken)
        return Int64(now().timeIntervalSince1970) < expiry ? .valid(signed) : .expired(signed)
    }

    private func issue(kind: Kind, landType: String, liveLandType: String?, pathToken: String) -> String {
        let nonce = Self.hex(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        let expiry = Int64(now().timeIntervalSince1970) + lifetime.components.seconds
        let mac = HMAC<SHA256>.authenticationCode(
            for: Self.message(
                kind: kind, landType: landType, nonce: nonce, expiry: expiry,
                liveLandType: liveLandType, pathToken: pathToken
            ),
            using: key
        )
        let live = liveLandType.map { "-\(Self.hex(Data($0.utf8)))" } ?? ""
        return "\(kind.rawValue)-\(nonce)-\(expiry)\(live)-\(Self.hex(Data(mac))).\(pathToken)"
    }

    private static func message(
        kind: Kind, landType: String, nonce: String, expiry: Int64, liveLandType: String?, pathToken: String
    ) -> Data {
        Data("sst-ticket-v1\n\(kind.rawValue)\n\(landType)\n\(nonce)\n\(expiry)\n\(liveLandType ?? "")\n\(pathToken)".utf8)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowerHex(_ c: Character) -> Bool {
        ("0"..."9").contains(c) || ("a"..."f").contains(c)
    }

    private static func bytes(fromHex text: Substring) -> Data? {
        guard text.count % 2 == 0, text.allSatisfy(isLowerHex) else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// Replay and monitor tickets refused at land creation, by verdict: a flood of forged or stale
/// IDs shows here and in the debug log.
final class ReplayTicketRejections: @unchecked Sendable {
    static let shared = ReplayTicketRejections()

    private let lock = NSLock()
    private var expiredCount = 0
    private var invalidCount = 0
    private let logger = Logger(label: "com.swiftstatetree.nio.replay-ticket")

    var expired: Int { lock.withLock { expiredCount } }
    var invalid: Int { lock.withLock { invalidCount } }

    func record(_ verdict: ReplayTicketSigner.Verdict, landID: LandID) {
        lock.withLock {
            switch verdict {
            case .expired: expiredCount += 1
            case .invalid: invalidCount += 1
            case .valid: return
            }
        }
        logger.debug("Replay ticket refused", metadata: [
            "landType": .string(landID.landType),
            "verdict": .string(verdict == .expired ? "expired" : "invalid"),
        ])
    }
}
