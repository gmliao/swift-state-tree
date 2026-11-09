// Sources/SwiftStateTreeNIO/ReplayTicket.swift
//
// A replay land's instance ID is a ticket the admin replay start signs: only an ID this process
// issued can create a replay land, so creating one needs the admin key, not just a record's path.

import Crypto
import Foundation
import Logging
import SwiftStateTree

/// Signs and verifies replay tickets: replay land instance IDs of the form
/// `r1-<nonce>-<expiry>-<mac>.<pathToken>`, where `pathToken` is the record path in base64url
/// (the part `ReevaluationReplaySessionDescriptor.decode` reads) and `mac` is an HMAC-SHA256
/// over the replay land type, nonce, expiry and path token.
///
/// The key is random per process and held only in memory (`process`): a restart invalidates
/// every ticket, as it ends every replay land. It is never derived from another secret.
struct ReplayTicketSigner: Sendable {
    /// The process's signer: the admin replay start issues with it, and the replay land's
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

    private static let prefix = "r1"

    /// The longest instance ID `verify` reads: the ticket fields and a path token for a record
    /// path of up to 3 KB.
    static let maxInstanceIDLength = 4_096

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
        let nonce = Self.hex(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        let expiry = Int64(now().timeIntervalSince1970) + lifetime.components.seconds
        let mac = HMAC<SHA256>.authenticationCode(
            for: Self.message(replayLandType: replayLandType, nonce: nonce, expiry: expiry, pathToken: pathToken),
            using: key
        )
        return "\(Self.prefix)-\(nonce)-\(expiry)-\(Self.hex(Data(mac))).\(pathToken)"
    }

    /// Whether `instanceId` is a ticket this signer issued for `replayLandType`, and whether it
    /// can still create its land. The MAC is compared in constant time.
    func verify(instanceId: String, replayLandType: String) -> Verdict {
        // Bounded before any parsing or hashing: the ID comes from a client.
        guard instanceId.utf8.count <= Self.maxInstanceIDLength else { return .invalid }
        let parts = instanceId.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return .invalid }
        let fields = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        // One spelling per ticket: digits without a leading zero and lowercase hex only, so no
        // second ID (a sign, a leading zero, an uppercase digit) passes for the same ticket and
        // names a second land.
        guard fields.count == 4, fields[0] == Self.prefix,
              fields[1].count == 32, fields[1].allSatisfy(Self.isLowerHex),
              !fields[2].isEmpty, fields[2].first != "0", fields[2].allSatisfy({ $0.isASCII && $0.isNumber }),
              let expiry = Int64(fields[2]),
              fields[3].utf8.count == SHA256.byteCount * 2,
              let mac = Self.bytes(fromHex: fields[3]), mac.count == SHA256.byteCount
        else { return .invalid }
        let message = Self.message(
            replayLandType: replayLandType, nonce: String(fields[1]), expiry: expiry, pathToken: String(parts[1])
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: message, using: key) else {
            return .invalid
        }
        return Int64(now().timeIntervalSince1970) < expiry ? .valid : .expired
    }

    private static func message(replayLandType: String, nonce: String, expiry: Int64, pathToken: String) -> Data {
        Data("sst-replay-ticket-v1\n\(replayLandType)\n\(nonce)\n\(expiry)\n\(pathToken)".utf8)
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

/// Replay tickets refused at land creation, by verdict: a flood of forged or stale IDs shows
/// here and in the debug log.
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
