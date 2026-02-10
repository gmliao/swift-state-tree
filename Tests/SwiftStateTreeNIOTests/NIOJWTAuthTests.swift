// Tests/SwiftStateTreeNIOTests/NIOJWTAuthTests.swift
//
// Tests for JWT auth and guest mode in NIO (validator, token extraction, auth resolver).
// Corresponds to Archive Hummingbird HummingbirdJWTAuthTests.

import Foundation
import Testing
import SwiftStateTreeTransport
@testable import SwiftStateTreeNIO

// MARK: - Mock JWT Validator

private struct MockJWTAuthValidator: JWTAuthValidator {
    let validTokens: Set<String>
    let shouldThrow: Bool

    init(validTokens: Set<String> = [], shouldThrow: Bool = false) {
        self.validTokens = validTokens
        self.shouldThrow = shouldThrow
    }

    func validate(token: String) async throws -> AuthenticatedInfo {
        if shouldThrow {
            throw JWTValidationError.invalidTokenFormat
        }
        if validTokens.contains(token) {
            return AuthenticatedInfo(
                playerID: "player-\(token.prefix(4))",
                deviceID: "device-\(token.prefix(4))",
                metadata: ["token": token]
            )
        }
        throw JWTValidationError.invalidSignature
    }
}

// MARK: - JWT Validator Tests

@Suite("NIO JWT Auth Validator Tests")
struct NIOJWTAuthValidatorTests {

    @Test("JWT validator accepts valid token")
    func testValidatorAcceptsValidToken() async throws {
        let validator = MockJWTAuthValidator(validTokens: ["valid-token-123"])

        let authInfo = try await validator.validate(token: "valid-token-123")

        #expect(authInfo.playerID.hasPrefix("player-"))
        #expect(authInfo.deviceID?.hasPrefix("device-") == true)
        #expect(authInfo.metadata["token"] == "valid-token-123")
    }

    @Test("JWT validator rejects invalid token")
    func testValidatorRejectsInvalidToken() async throws {
        let validator = MockJWTAuthValidator(validTokens: ["valid-token-123"])

        do {
            _ = try await validator.validate(token: "invalid-token-456")
            Issue.record("Should have thrown for invalid token")
        } catch {
            #expect(error is JWTValidationError)
        }
    }

    @Test("JWT validator throws when configured to throw")
    func testValidatorThrowsWhenConfigured() async throws {
        let validator = MockJWTAuthValidator(validTokens: ["ok"], shouldThrow: true)

        do {
            _ = try await validator.validate(token: "ok")
            Issue.record("Should have thrown")
        } catch {
            #expect(error is JWTValidationError)
        }
    }
}

// MARK: - JWTPayload Decoding Tests (sub fallback)

@Suite("NIO JWTPayload Decoding Tests")
struct NIOJWTPayloadDecodingTests {

    @Test("JWTPayload accepts sub claim when playerID is missing")
    func testSubClaimFallback() throws {
        let json = """
        {"sub": "user-123"}
        """
        let data = Data(json.utf8)
        let payload = try JSONDecoder().decode(JWTPayload.self, from: data)
        #expect(payload.playerID == "user-123")
    }

    @Test("JWTPayload prefers playerID over sub when both present")
    func testPlayerIDPreferred() throws {
        let json = """
        {"sub": "sub-id", "playerID": "player-id"}
        """
        let data = Data(json.utf8)
        let payload = try JSONDecoder().decode(JWTPayload.self, from: data)
        #expect(payload.playerID == "player-id")
    }

    @Test("JWTPayload throws when both playerID and sub are missing")
    func testMissingPlayerIDAndSub() throws {
        let json = "{}"
        let data = Data(json.utf8)
        do {
            _ = try JSONDecoder().decode(JWTPayload.self, from: data)
            Issue.record("Should have thrown")
        } catch {
            #expect(error is DecodingError)
        }
    }
}

// MARK: - Token Extraction Tests

@Suite("NIO Token Extraction Tests")
struct NIOTokenExtractionTests {

    @Test("extractTokenFromURI returns token from query")
    func testExtractTokenFromQuery() {
        #expect(extractTokenFromURI("/game/counter?token=abc123") == "abc123")
        #expect(extractTokenFromURI("/path?token=eyJhbGciOiJIUzI1NiJ9") == "eyJhbGciOiJIUzI1NiJ9")
    }

    @Test("extractTokenFromURI returns nil when no query")
    func testExtractTokenNoQuery() {
        #expect(extractTokenFromURI("/game/counter") == nil)
    }

    @Test("extractTokenFromURI returns nil when token param missing")
    func testExtractTokenMissingParam() {
        #expect(extractTokenFromURI("/game/counter?foo=bar") == nil)
    }

    @Test("extractTokenFromURI returns token when other params present")
    func testExtractTokenWithOtherParams() {
        #expect(extractTokenFromURI("/game/counter?token=jwt-here&other=value") == "jwt-here")
    }
}

// MARK: - Auth Resolver (ClosureAuthInfoResolver) Tests

@Suite("NIO Auth Resolver Tests")
struct NIOAuthResolverTests {

    @Test("Resolver with token in URI returns authInfo when validator accepts")
    func testResolverWithValidToken() async throws {
        let validator = MockJWTAuthValidator(validTokens: ["good-token"])
        let resolver = ClosureAuthInfoResolver { path, uri in
            guard let token = extractTokenFromURI(uri) else { return nil }
            return try await validator.validate(token: token)
        }

        let authInfo = try await resolver.resolve(path: "/game/counter", uri: "/game/counter?token=good-token")

        #expect(authInfo != nil)
        #expect(authInfo?.playerID.hasPrefix("player-") == true)
    }

    @Test("Resolver with token in URI throws when validator rejects")
    func testResolverWithInvalidToken() async throws {
        let validator = MockJWTAuthValidator(validTokens: ["good-only"])
        let resolver = ClosureAuthInfoResolver { path, uri in
            guard let token = extractTokenFromURI(uri) else { return nil }
            return try await validator.validate(token: token)
        }

        do {
            _ = try await resolver.resolve(path: "/game/counter", uri: "/game/counter?token=bad-token")
            Issue.record("Should have thrown for invalid token")
        } catch {
            #expect(error is JWTValidationError)
        }
    }

    @Test("Resolver returns nil for no token when guest allowed (guest mode)")
    func testResolverNoTokenGuestMode() async throws {
        let validator = MockJWTAuthValidator(validTokens: ["x"])
        let resolver = ClosureAuthInfoResolver { path, uri in
            if let token = extractTokenFromURI(uri) {
                return try await validator.validate(token: token)
            }
            return nil
        }

        let authInfo = try await resolver.resolve(path: "/game/counter", uri: "/game/counter")

        #expect(authInfo == nil)
    }
}
