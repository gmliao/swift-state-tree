// Tests/SwiftStateTreeNIOTests/NIOAdminAuthTests.swift

import Foundation
import Testing
import NIOHTTP1
@testable import SwiftStateTreeNIO
@testable import SwiftStateTreeTransport

@Suite("NIO Admin Auth Tests")
struct NIOAdminAuthTests {
    
    // MARK: - API Key Authentication
    
    @Test("Valid API key in header returns admin role")
    func testValidAPIKeyHeader() async throws {
        let auth = NIOAdminAuth(apiKey: "test-secret-key")
        
        var headers = HTTPHeaders()
        headers.add(name: "X-API-Key", value: "test-secret-key")
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands",
            headers: headers,
            body: nil
        )
        
        let role = auth.extractAdminRole(from: request)
        
        #expect(role == .admin)
    }
    
    @Test("Valid API key in query returns admin role")
    func testValidAPIKeyQuery() async throws {
        let auth = NIOAdminAuth(apiKey: "test-secret-key")
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands?apiKey=test-secret-key",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let role = auth.extractAdminRole(from: request)
        
        #expect(role == .admin)
    }
    
    @Test("Invalid API key returns nil")
    func testInvalidAPIKey() async throws {
        let auth = NIOAdminAuth(apiKey: "correct-key")
        
        var headers = HTTPHeaders()
        headers.add(name: "X-API-Key", value: "wrong-key")
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands",
            headers: headers,
            body: nil
        )
        
        let role = auth.extractAdminRole(from: request)
        
        #expect(role == nil)
    }
    
    @Test("Missing API key returns nil")
    func testMissingAPIKey() async throws {
        let auth = NIOAdminAuth(apiKey: "test-key")
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let role = auth.extractAdminRole(from: request)
        
        #expect(role == nil)
    }
    
    @Test("No API key configured returns nil")
    func testNoAPIKeyConfigured() async throws {
        let auth = NIOAdminAuth(apiKey: nil)
        
        var headers = HTTPHeaders()
        headers.add(name: "X-API-Key", value: "any-key")
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands",
            headers: headers,
            body: nil
        )
        
        let role = auth.extractAdminRole(from: request)
        
        #expect(role == nil)
    }
    
    // MARK: - Role Permission Tests
    
    @Test("Admin has permission for all roles")
    func testAdminPermissions() async throws {
        let auth = NIOAdminAuth(apiKey: "test-key")
        
        var headers = HTTPHeaders()
        headers.add(name: "X-API-Key", value: "test-key")
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands",
            headers: headers,
            body: nil
        )
        
        #expect(auth.hasRequiredRole(from: request, requiredRole: .admin) == true)
        #expect(auth.hasRequiredRole(from: request, requiredRole: .operator) == true)
        #expect(auth.hasRequiredRole(from: request, requiredRole: .viewer) == true)
    }
    
    @Test("Unauthenticated has no permissions")
    func testUnauthenticatedNoPermissions() async throws {
        let auth = NIOAdminAuth(apiKey: "test-key")
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands",
            headers: HTTPHeaders(),
            body: nil
        )
        
        #expect(auth.hasRequiredRole(from: request, requiredRole: .admin) == false)
        #expect(auth.hasRequiredRole(from: request, requiredRole: .operator) == false)
        #expect(auth.hasRequiredRole(from: request, requiredRole: .viewer) == false)
    }
    
    // MARK: - AdminRole Permission Tests
    
    @Test("AdminRole hasPermission hierarchy")
    func testAdminRoleHierarchy() async throws {
        // Admin has all permissions
        #expect(AdminRole.admin.hasPermission(for: .admin) == true)
        #expect(AdminRole.admin.hasPermission(for: .operator) == true)
        #expect(AdminRole.admin.hasPermission(for: .viewer) == true)
        
        // Operator has operator and viewer
        #expect(AdminRole.operator.hasPermission(for: .admin) == false)
        #expect(AdminRole.operator.hasPermission(for: .operator) == true)
        #expect(AdminRole.operator.hasPermission(for: .viewer) == true)
        
        // Viewer only has viewer
        #expect(AdminRole.viewer.hasPermission(for: .admin) == false)
        #expect(AdminRole.viewer.hasPermission(for: .operator) == false)
        #expect(AdminRole.viewer.hasPermission(for: .viewer) == true)
    }
}
