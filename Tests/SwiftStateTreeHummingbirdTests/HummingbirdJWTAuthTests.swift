// Tests/SwiftStateTreeHummingbirdTests/HummingbirdJWTAuthTests.swift
//
// Tests for JWT authentication and guest mode in HummingbirdStateTreeAdapter

import Foundation
import Testing
import Hummingbird
import HummingbirdWebSocket
import NIOWebSocket
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeHummingbird

// MARK: - Test Doubles

actor MockWebSocketOutbound {
    private(set) var closed = false
    private(set) var closeCode: WebSocketErrorCode?
    private(set) var closeReason: String?
    private(set) var writtenMessages: [WebSocketOutboundWriter.OutboundFrame] = []
    
    func write(_ frame: WebSocketOutboundWriter.OutboundFrame) async throws {
        writtenMessages.append(frame)
    }
    
    func close(_ code: WebSocketErrorCode, reason: String?) async throws {
        closed = true
        closeCode = code
        closeReason = reason
    }
}

// Mock WebSocketRouterContext for testing
// Note: This is a simplified mock - in real tests, you might need to use actual Hummingbird types
actor MockWebSocketRouterContext {
    let uri: String
    let headers: [String: String]
    
    init(uri: String, headers: [String: String] = [:]) {
        self.uri = uri
        self.headers = headers
    }
    
    // Simulate WebSocketRouterContext behavior
    var request: MockHTTPRequest {
        MockHTTPRequest(uri: uri, headers: headers)
    }
}

struct MockHTTPRequest {
    let uri: String
    let headers: [String: String]
}

struct MockWebSocketInbound: AsyncSequence {
    typealias Element = WebSocketFrame
    typealias Failure = any Error
    
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
    
    struct AsyncIterator: AsyncIteratorProtocol {
        typealias Element = WebSocketFrame
        typealias Failure = any Error
        
        mutating func next() async throws -> WebSocketFrame? {
            return nil  // Empty stream
        }
    }
}

// MARK: - Mock JWT Validator

struct MockJWTAuthValidator: JWTAuthValidator {
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
        } else {
            throw JWTValidationError.invalidSignature
        }
    }
}

// MARK: - Tests

// Note: These tests require actual Hummingbird WebSocketRouterContext which is complex to mock
// For now, we test the logic at TransportAdapter level instead
// Full integration tests would require running an actual Hummingbird server

@Test("JWT validator accepts valid tokens")
func testJWTValidatorAcceptsValidTokens() async throws {
    // Arrange
    let validator = MockJWTAuthValidator(validTokens: ["valid-token-123"])
    
    // Act
    let authInfo = try await validator.validate(token: "valid-token-123")
    
    // Assert
    #expect(authInfo.playerID.hasPrefix("player-"), "Should extract playerID from token")
    #expect(authInfo.deviceID?.hasPrefix("device-") == true, "Should extract deviceID from token")
    #expect(authInfo.metadata["token"] == "valid-token-123", "Should include token in metadata")
}

@Test("JWT validator rejects invalid tokens")
func testJWTValidatorRejectsInvalidTokens() async throws {
    // Arrange
    let validator = MockJWTAuthValidator(validTokens: ["valid-token-123"])
    
    // Act & Assert
    do {
        _ = try await validator.validate(token: "invalid-token-456")
        Issue.record("Should have thrown error for invalid token")
    } catch {
        #expect(error is JWTValidationError, "Should throw JWTValidationError")
    }
}

// Note: Full HummingbirdStateTreeAdapter tests require actual WebSocketRouterContext
// which is complex to mock. The adapter logic is tested indirectly through
// TransportAdapter tests and integration tests.
