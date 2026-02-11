// Sources/SwiftStateTreeNIO/NIOJWT.swift
//
// JWT validation for NIO WebSocket handshake.
// Client must include `token` query parameter: ws://host:port/path?token=<jwt-token>

import Crypto
import Foundation
import Logging
import SwiftStateTreeTransport

// MARK: - JWT Payload

/// Standard JWT Payload structure with custom claims for SwiftStateTree.
/// Automatically captures all unknown fields (e.g., username, schoolId) into metadata.
public struct JWTPayload: Codable, Sendable {
    // Standard JWT Claims
    public let iss: String?
    public let sub: String?
    public let aud: String?
    public let exp: Int64?
    public let iat: Int64?
    public let nbf: Int64?

    /// Resolved player ID: from `playerID` claim if present, otherwise from standard `sub` claim.
    public let playerID: String
    public let deviceID: String?
    public let metadata: [String: String]?

    private let customFields: [String: String]

    private static let knownFields: Set<String> = [
        "iss", "sub", "aud", "exp", "iat", "nbf",
        "playerID", "deviceID", "metadata",
    ]

    public func isValid(now: Date = Date()) -> Bool {
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        if let exp = exp, exp < nowTimestamp { return false }
        if let nbf = nbf, nbf > nowTimestamp { return false }
        return true
    }

    public func toAuthenticatedInfo() -> AuthenticatedInfo {
        var mergedMetadata = metadata ?? [:]
        for (key, value) in customFields {
            mergedMetadata[key] = value
        }
        return AuthenticatedInfo(
            playerID: playerID,
            deviceID: deviceID,
            metadata: mergedMetadata
        )
    }

    enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, nbf
        case playerID, deviceID, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iss = try container.decodeIfPresent(String.self, forKey: .iss)
        sub = try container.decodeIfPresent(String.self, forKey: .sub)
        aud = try container.decodeIfPresent(String.self, forKey: .aud)
        exp = try container.decodeIfPresent(Int64.self, forKey: .exp)
        iat = try container.decodeIfPresent(Int64.self, forKey: .iat)
        nbf = try container.decodeIfPresent(Int64.self, forKey: .nbf)
        let decodedPlayerID = try container.decodeIfPresent(String.self, forKey: .playerID)
        let decodedSub = sub
        guard let resolved = decodedPlayerID ?? decodedSub, !resolved.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .playerID,
                in: container,
                debugDescription: "JWT payload must contain non-empty 'playerID' or 'sub' claim"
            )
        }
        playerID = resolved
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)

        let allKeysContainer = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var customFieldsDict: [String: String] = [:]
        for key in allKeysContainer.allKeys {
            let keyString = key.stringValue
            if Self.knownFields.contains(keyString) { continue }
            if let stringValue = try? allKeysContainer.decode(String.self, forKey: key) {
                customFieldsDict[keyString] = stringValue
            } else if let intValue = try? allKeysContainer.decode(Int.self, forKey: key) {
                customFieldsDict[keyString] = String(intValue)
            } else if let int64Value = try? allKeysContainer.decode(Int64.self, forKey: key) {
                customFieldsDict[keyString] = String(int64Value)
            } else if let doubleValue = try? allKeysContainer.decode(Double.self, forKey: key) {
                customFieldsDict[keyString] = String(doubleValue)
            } else if let boolValue = try? allKeysContainer.decode(Bool.self, forKey: key) {
                customFieldsDict[keyString] = String(boolValue)
            } else if let jsonValue = try? allKeysContainer.decode(JSONValue.self, forKey: key),
                      let jsonData = try? JSONEncoder().encode(jsonValue),
                      let jsonString = String(data: jsonData, encoding: .utf8) {
                customFieldsDict[keyString] = jsonString
            }
        }
        self.customFields = customFieldsDict
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(iss, forKey: .iss)
        try container.encodeIfPresent(sub, forKey: .sub)
        try container.encodeIfPresent(aud, forKey: .aud)
        try container.encodeIfPresent(exp, forKey: .exp)
        try container.encodeIfPresent(iat, forKey: .iat)
        try container.encodeIfPresent(nbf, forKey: .nbf)
        try container.encode(playerID, forKey: .playerID)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        var allKeysContainer = encoder.container(keyedBy: DynamicCodingKeys.self)
        for (key, value) in customFields {
            let codingKey = DynamicCodingKeys(stringValue: key)!
            try allKeysContainer.encode(value, forKey: codingKey)
        }
    }
}

private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
}

private enum JSONValue: Codable {
    case string(String), int(Int), double(Double), bool(Bool)
    case array([JSONValue]), object([String: JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value type") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - JWT Configuration

/// Configuration for JWT validation (NIO).
public struct JWTConfiguration: Sendable {
    public let secretKey: String?
    public let publicKey: Data?
    public let algorithm: JWTAlgorithm
    public let validateExpiration: Bool
    public let validateIssuer: Bool
    public let expectedIssuer: String?
    public let validateAudience: Bool
    public let expectedAudience: String?

    public enum JWTAlgorithm: String, Codable, Sendable {
        case HS256, HS384, HS512
        case RS256, RS384, RS512, ES256, ES384, ES512
    }

    public init(
        secretKey: String? = nil,
        publicKey: Data? = nil,
        algorithm: JWTAlgorithm = .HS256,
        validateExpiration: Bool = true,
        validateIssuer: Bool = false,
        expectedIssuer: String? = nil,
        validateAudience: Bool = false,
        expectedAudience: String? = nil
    ) {
        self.secretKey = secretKey
        self.publicKey = publicKey
        self.algorithm = algorithm
        self.validateExpiration = validateExpiration
        self.validateIssuer = validateIssuer
        self.expectedIssuer = expectedIssuer
        self.validateAudience = validateAudience
        self.expectedAudience = expectedAudience
    }

    public static func fromEnvironment() -> JWTConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard let secretKey = env[NIOEnvKeys.JWT.secretKey], !secretKey.isEmpty else { return nil }
        let algorithmString = env[NIOEnvKeys.JWT.algorithm] ?? "HS256"
        guard let algorithm = JWTAlgorithm(rawValue: algorithmString) else { return nil }
        let expectedIssuer = env[NIOEnvKeys.JWT.issuer]
        let expectedAudience = env[NIOEnvKeys.JWT.audience]
        return JWTConfiguration(
            secretKey: secretKey,
            algorithm: algorithm,
            validateExpiration: true,
            validateIssuer: expectedIssuer != nil,
            expectedIssuer: expectedIssuer,
            validateAudience: expectedAudience != nil,
            expectedAudience: expectedAudience
        )
    }
}

// MARK: - JWT Auth Validator Protocol

/// Protocol for JWT token validation (NIO).
/// Conforms to Transport's `TokenValidatorProtocol` so other frameworks can use this implementation.
public protocol JWTAuthValidator: TokenValidatorProtocol {}

// MARK: - Default JWT Validator

/// Default JWT validator using swift-crypto (HS256/HS384/HS512).
/// Conforms to `TokenValidatorProtocol` from SwiftStateTreeTransport for framework-agnostic use.
public struct DefaultJWTAuthValidator: JWTAuthValidator {
    private let config: JWTConfiguration
    private let logger: Logger?

    public init(config: JWTConfiguration, logger: Logger? = nil) {
        self.config = config
        self.logger = logger
    }

    public func validate(token: String) async throws -> AuthenticatedInfo {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw JWTValidationError.invalidTokenFormat }

        let headerData = try base64URLDecode(String(parts[0]))
        let payloadData = try base64URLDecode(String(parts[1]))
        let signatureData = try base64URLDecode(String(parts[2]))

        let header = try JSONDecoder().decode(JWTHeader.self, from: headerData)
        guard header.alg == config.algorithm.rawValue else {
            throw JWTValidationError.custom("Algorithm mismatch: expected \(config.algorithm.rawValue), got \(header.alg)")
        }

        try verifySignature(
            header: String(parts[0]),
            payload: String(parts[1]),
            signature: signatureData,
            algorithm: config.algorithm
        )

        let payload = try JSONDecoder().decode(JWTPayload.self, from: payloadData)

        if config.validateExpiration {
            guard payload.isValid() else {
                let now = Int64(Date().timeIntervalSince1970)
                if let exp = payload.exp, exp < now { throw JWTValidationError.expiredToken }
                if let nbf = payload.nbf, nbf > now { throw JWTValidationError.tokenNotYetValid }
                throw JWTValidationError.custom("Token validation failed")
            }
        }
        if config.validateIssuer, let expected = config.expectedIssuer {
            guard payload.iss == expected else { throw JWTValidationError.invalidIssuer }
        }
        if config.validateAudience, let expected = config.expectedAudience {
            guard payload.aud == expected else { throw JWTValidationError.invalidAudience }
        }

        return payload.toAuthenticatedInfo()
    }

    private func verifySignature(header: String, payload: String, signature: Data, algorithm: JWTConfiguration.JWTAlgorithm) throws {
        guard let secretKey = config.secretKey else { throw JWTValidationError.custom("Secret key not configured") }
        let message = "\(header).\(payload)"
        guard let messageData = message.data(using: .utf8) else { throw JWTValidationError.invalidTokenFormat }
        let keyData = secretKey.data(using: .utf8) ?? Data(secretKey.utf8)

        switch algorithm {
        case .HS256:
            let key = SymmetricKey(data: keyData)
            let computed = HMAC<SHA256>.authenticationCode(for: messageData, using: key)
            guard Data(computed) == signature else { throw JWTValidationError.invalidSignature }
        case .HS384:
            let key = SymmetricKey(data: keyData)
            let computed = HMAC<SHA384>.authenticationCode(for: messageData, using: key)
            guard Data(computed) == signature else { throw JWTValidationError.invalidSignature }
        case .HS512:
            let key = SymmetricKey(data: keyData)
            let computed = HMAC<SHA512>.authenticationCode(for: messageData, using: key)
            guard Data(computed) == signature else { throw JWTValidationError.invalidSignature }
        case .RS256, .RS384, .RS512, .ES256, .ES384, .ES512:
            throw JWTValidationError.custom("RSA/ECDSA not implemented. Use HS256/HS384/HS512.")
        }
    }

    private func base64URLDecode(_ string: String) throws -> Data {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: base64) else { throw JWTValidationError.invalidTokenFormat }
        return data
    }
}

private struct JWTHeader: Codable {
    let alg: String
    let typ: String?
}

// MARK: - JWT Validation Errors

/// Extracts the `token` query parameter from a WebSocket URI (e.g. "/game/counter?token=xxx").
public func extractTokenFromURI(_ uri: String) -> String? {
    guard let qIndex = uri.firstIndex(of: "?") else { return nil }
    let query = uri[uri.index(after: qIndex)...]
    for part in query.split(separator: "&") {
        let partStr = String(part)
        if partStr.hasPrefix("token=") {
            let value = partStr.dropFirst(6)
            if value.isEmpty { return nil }
            return String(value).removingPercentEncoding ?? String(value)
        }
    }
    return nil
}

// MARK: - JWT Validation Errors

public enum JWTValidationError: Error, Sendable {
    case invalidTokenFormat
    case invalidSignature
    case expiredToken
    case tokenNotYetValid
    case invalidIssuer
    case invalidAudience
    case missingRequiredClaim(String)
    case decodingError(Error)
    case custom(String)
}
