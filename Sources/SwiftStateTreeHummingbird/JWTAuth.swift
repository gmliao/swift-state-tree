import Foundation
import CryptoKit
import Logging
import SwiftStateTreeTransport

// MARK: - JWT Payload

/// Standard JWT Payload structure with custom claims for SwiftStateTree
/// Automatically captures all unknown fields (e.g., username, schoolid) into metadata
public struct JWTPayload: Codable, Sendable {
    // Standard JWT Claims
    /// Issuer - who issued the token
    public let iss: String?
    /// Subject - typically the playerID
    public let sub: String?
    /// Audience - who the token is intended for
    public let aud: String?
    /// Expiration Time (Unix timestamp)
    public let exp: Int64?
    /// Issued At (Unix timestamp)
    public let iat: Int64?
    /// Not Before (Unix timestamp)
    public let nbf: Int64?
    
    // Custom Claims for SwiftStateTree
    /// Player ID (can also be in 'sub')
    public let playerID: String
    /// Device ID
    public let deviceID: String?
    /// Additional metadata (explicitly provided in JWT)
    public let metadata: [String: String]?
    
    /// All custom fields from JWT payload (username, schoolid, etc.)
    /// This is populated during decoding with any fields not in the standard structure
    private let customFields: [String: String]
    
    /// Known field names that should not be included in customFields
    private static let knownFields: Set<String> = [
        "iss", "sub", "aud", "exp", "iat", "nbf",
        "playerID", "deviceID", "metadata"
    ]
    
    /// Validate standard claims
    /// - Parameter now: Current time (defaults to Date())
    /// - Returns: true if token is valid (not expired, not before nbf)
    public func isValid(now: Date = Date()) -> Bool {
        let nowTimestamp = Int64(now.timeIntervalSince1970)
        
        // Check expiration
        if let exp = exp, exp < nowTimestamp {
            return false
        }
        
        // Check not before
        if let nbf = nbf, nbf > nowTimestamp {
            return false
        }
        
        return true
    }
    
    /// Convert to AuthenticatedInfo
    /// Merges explicit metadata with custom fields from JWT payload
    public func toAuthenticatedInfo() -> AuthenticatedInfo {
        // Merge explicit metadata with custom fields
        // Custom fields take precedence if there are conflicts
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
    
    // MARK: - Custom Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case iss, sub, aud, exp, iat, nbf
        case playerID, deviceID, metadata
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode known fields
        iss = try container.decodeIfPresent(String.self, forKey: .iss)
        sub = try container.decodeIfPresent(String.self, forKey: .sub)
        aud = try container.decodeIfPresent(String.self, forKey: .aud)
        exp = try container.decodeIfPresent(Int64.self, forKey: .exp)
        iat = try container.decodeIfPresent(Int64.self, forKey: .iat)
        nbf = try container.decodeIfPresent(Int64.self, forKey: .nbf)
        playerID = try container.decode(String.self, forKey: .playerID)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
        
        // Decode all fields and extract custom ones
        let allKeysContainer = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var customFieldsDict: [String: String] = [:]
        
        for key in allKeysContainer.allKeys {
            let keyString = key.stringValue
            // Skip known fields
            if Self.knownFields.contains(keyString) {
                continue
            }
            
            // Try to decode as different types and convert to String
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
            } else {
                // For complex types (arrays, objects), try to decode as JSON string
                // This is a best-effort approach for non-primitive types
                if let jsonValue = try? allKeysContainer.decode(JSONValue.self, forKey: key),
                   let jsonData = try? JSONEncoder().encode(jsonValue),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    customFieldsDict[keyString] = jsonString
                }
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
        
        // Encode custom fields
        var allKeysContainer = encoder.container(keyedBy: DynamicCodingKeys.self)
        for (key, value) in customFields {
            let codingKey = DynamicCodingKeys(stringValue: key)!
            try allKeysContainer.encode(value, forKey: codingKey)
        }
    }
}

// MARK: - Dynamic Coding Keys

/// Helper for decoding unknown keys from JWT payload
private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?
    
    init?(stringValue: String) {
        self.stringValue = stringValue
    }
    
    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }
}

// MARK: - JSONValue Helper

/// Helper to decode arbitrary JSON values for custom JWT fields
private enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value type")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

// MARK: - JWT Configuration

/// Configuration for JWT validation
public struct JWTConfiguration: Sendable {
    /// Secret Key (for HMAC algorithms: HS256, HS384, HS512)
    public let secretKey: String?
    
    /// Public Key (for RSA/ECDSA algorithms: RS256, ES256, etc.)
    public let publicKey: Data?
    
    /// Algorithm type
    public let algorithm: JWTAlgorithm
    
    /// Payload validation options
    public let validateExpiration: Bool
    public let validateIssuer: Bool
    public let expectedIssuer: String?
    public let validateAudience: Bool
    public let expectedAudience: String?
    
    public enum JWTAlgorithm: String, Codable, Sendable {
        case HS256, HS384, HS512  // HMAC
        case RS256, RS384, RS512  // RSA
        case ES256, ES384, ES512  // ECDSA
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
    
    /// Create JWTConfiguration from environment variables
    /// Reads: JWT_SECRET_KEY, JWT_ALGORITHM, JWT_ISSUER, JWT_AUDIENCE
    public static func fromEnvironment() -> JWTConfiguration? {
        guard let secretKey = ProcessInfo.processInfo.environment["JWT_SECRET_KEY"],
              !secretKey.isEmpty else {
            return nil
        }
        
        let algorithmString = ProcessInfo.processInfo.environment["JWT_ALGORITHM"] ?? "HS256"
        guard let algorithm = JWTAlgorithm(rawValue: algorithmString) else {
            return nil
        }
        
        let expectedIssuer = ProcessInfo.processInfo.environment["JWT_ISSUER"]
        let expectedAudience = ProcessInfo.processInfo.environment["JWT_AUDIENCE"]
        
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

/// Protocol for JWT token validation
public protocol JWTAuthValidator: Sendable {
    /// Validate a JWT token and extract authenticated information
    /// - Parameter token: The JWT token string
    /// - Returns: AuthenticatedInfo if validation succeeds
    /// - Throws: JWTValidationError if validation fails
    func validate(token: String) async throws -> AuthenticatedInfo
}

// MARK: - Default JWT Validator

/// Default implementation of JWT validator using CryptoKit
/// Supports HS256, HS384, HS512 algorithms
public struct DefaultJWTAuthValidator: JWTAuthValidator {
    private let config: JWTConfiguration
    private let logger: Logger?
    
    public init(config: JWTConfiguration, logger: Logger? = nil) {
        self.config = config
        self.logger = logger
    }
    
    public func validate(token: String) async throws -> AuthenticatedInfo {
        // Split JWT into parts: header.payload.signature
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            throw JWTValidationError.invalidTokenFormat
        }
        
        let headerData = try base64URLDecode(String(parts[0]))
        let payloadData = try base64URLDecode(String(parts[1]))
        let signatureData = try base64URLDecode(String(parts[2]))
        
        // Decode header
        let header = try JSONDecoder().decode(JWTHeader.self, from: headerData)
        
        // Verify algorithm matches configuration
        guard header.alg == config.algorithm.rawValue else {
            throw JWTValidationError.custom("Algorithm mismatch: expected \(config.algorithm.rawValue), got \(header.alg)")
        }
        
        // Verify signature
        try verifySignature(
            header: String(parts[0]),
            payload: String(parts[1]),
            signature: signatureData,
            algorithm: config.algorithm
        )
        
        // Decode payload
        let payload = try JSONDecoder().decode(JWTPayload.self, from: payloadData)
        
        // Validate standard claims
        if config.validateExpiration {
            guard payload.isValid() else {
                let now = Date()
                let nowTimestamp = Int64(now.timeIntervalSince1970)
                if let exp = payload.exp, exp < nowTimestamp {
                    throw JWTValidationError.expiredToken
                }
                if let nbf = payload.nbf, nbf > nowTimestamp {
                    throw JWTValidationError.tokenNotYetValid
                }
                throw JWTValidationError.custom("Token validation failed")
            }
        }
        
        if config.validateIssuer, let expectedIssuer = config.expectedIssuer {
            guard payload.iss == expectedIssuer else {
                throw JWTValidationError.invalidIssuer
            }
        }
        
        if config.validateAudience, let expectedAudience = config.expectedAudience {
            guard payload.aud == expectedAudience else {
                throw JWTValidationError.invalidAudience
            }
        }
        
        // Return authenticated info
        return payload.toAuthenticatedInfo()
    }
    
    private func verifySignature(
        header: String,
        payload: String,
        signature: Data,
        algorithm: JWTConfiguration.JWTAlgorithm
    ) throws {
        guard let secretKey = config.secretKey else {
            throw JWTValidationError.custom("Secret key not configured")
        }
        
        let message = "\(header).\(payload)"
        guard let messageData = message.data(using: .utf8) else {
            throw JWTValidationError.invalidTokenFormat
        }
        
        let keyData = secretKey.data(using: .utf8) ?? Data(secretKey.utf8)
        
        switch algorithm {
        case .HS256:
            let symmetricKey = SymmetricKey(data: keyData)
            let computedSignature = HMAC<SHA256>.authenticationCode(for: messageData, using: symmetricKey)
            guard computedSignature.withUnsafeBytes({ Data($0) }) == signature else {
                throw JWTValidationError.invalidSignature
            }
        case .HS384:
            let symmetricKey = SymmetricKey(data: keyData)
            let computedSignature = HMAC<SHA384>.authenticationCode(for: messageData, using: symmetricKey)
            guard computedSignature.withUnsafeBytes({ Data($0) }) == signature else {
                throw JWTValidationError.invalidSignature
            }
        case .HS512:
            let symmetricKey = SymmetricKey(data: keyData)
            let computedSignature = HMAC<SHA512>.authenticationCode(for: messageData, using: symmetricKey)
            guard computedSignature.withUnsafeBytes({ Data($0) }) == signature else {
                throw JWTValidationError.invalidSignature
            }
        case .RS256, .RS384, .RS512, .ES256, .ES384, .ES512:
            // RSA and ECDSA require public key - not implemented yet
            throw JWTValidationError.custom("RSA/ECDSA algorithms not yet implemented. Use HS256/HS384/HS512.")
        }
    }
    
    private func base64URLDecode(_ string: String) throws -> Data {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        
        guard let data = Data(base64Encoded: base64) else {
            throw JWTValidationError.invalidTokenFormat
        }
        
        return data
    }
}

// MARK: - JWT Header

private struct JWTHeader: Codable {
    let alg: String
    let typ: String?
}

// MARK: - JWT Validation Errors

/// Errors that can occur during JWT validation
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
    
    public var description: String {
        switch self {
        case .invalidTokenFormat:
            return "Invalid JWT token format"
        case .invalidSignature:
            return "Invalid JWT signature"
        case .expiredToken:
            return "JWT token has expired"
        case .tokenNotYetValid:
            return "JWT token is not yet valid"
        case .invalidIssuer:
            return "Invalid JWT issuer"
        case .invalidAudience:
            return "Invalid JWT audience"
        case .missingRequiredClaim(let claim):
            return "Missing required claim: \(claim)"
        case .decodingError(let error):
            return "JWT decoding error: \(error)"
        case .custom(let message):
            return message
        }
    }
}

