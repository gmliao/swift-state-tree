// Tests/SwiftStateTreeNIOTests/NIOHTTPRouterTests.swift

import Foundation
import Testing
import NIOHTTP1
@testable import SwiftStateTreeNIO

@Suite("NIO HTTP Router Tests")
struct NIOHTTPRouterTests {
    
    // MARK: - Route Matching Tests
    
    @Test("Exact path matching")
    func testExactPathMatching() async throws {
        let router = NIOHTTPRouter()
        
        // Return the path in the response body to verify it was received
        await router.get("/health") { request in
            return .text("path:\(request.path)")
        }
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/health",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response != nil)
        #expect(response?.status == .ok)
        
        // Verify the path was correctly extracted
        if let body = response?.body {
            let text = String(data: body, encoding: .utf8)
            #expect(text == "path:/health")
        }
    }
    
    @Test("Path parameter extraction")
    func testPathParameterExtraction() async throws {
        let router = NIOHTTPRouter()
        
        // Return the extracted parameter in the response body
        await router.get("/admin/lands/:landID") { request in
            let landID = request.pathParam("landID") ?? "not-found"
            return .text("landID:\(landID)")
        }
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/admin/lands/test-land-123",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response != nil)
        
        if let body = response?.body {
            let text = String(data: body, encoding: .utf8)
            #expect(text == "landID:test-land-123")
        }
    }
    
    @Test("Multiple path parameters")
    func testMultiplePathParameters() async throws {
        let router = NIOHTTPRouter()
        
        await router.get("/api/:type/:id/stats") { request in
            let type = request.pathParam("type") ?? "none"
            let id = request.pathParam("id") ?? "none"
            return .text("type:\(type),id:\(id)")
        }
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/api/users/42/stats",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response != nil)
        
        if let body = response?.body {
            let text = String(data: body, encoding: .utf8)
            #expect(text == "type:users,id:42")
        }
    }
    
    @Test("Query parameter extraction")
    func testQueryParameterExtraction() async throws {
        let router = NIOHTTPRouter()
        
        await router.get("/api/data") { request in
            let apiKey = request.queryParam("apiKey") ?? "none"
            return .text("apiKey:\(apiKey)")
        }
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/api/data?apiKey=secret123&other=value",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response != nil)
        
        if let body = response?.body {
            let text = String(data: body, encoding: .utf8)
            #expect(text == "apiKey:secret123")
        }
    }
    
    @Test("No matching route returns nil")
    func testNoMatchingRoute() async throws {
        let router = NIOHTTPRouter()
        
        await router.get("/existing") { _ in .text("OK") }
        
        let request = NIOHTTPRequest(
            method: .GET,
            uri: "/nonexistent",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response == nil)
    }
    
    @Test("Method mismatch returns nil")
    func testMethodMismatch() async throws {
        let router = NIOHTTPRouter()
        
        await router.get("/api/data") { _ in .text("GET") }
        
        let request = NIOHTTPRequest(
            method: .POST,
            uri: "/api/data",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response == nil)
    }
    
    // MARK: - HTTP Method Tests
    
    @Test("POST route")
    func testPostRoute() async throws {
        let router = NIOHTTPRouter()
        
        await router.post("/api/create") { _ in
            .text("Created", status: .created)
        }
        
        let request = NIOHTTPRequest(
            method: .POST,
            uri: "/api/create",
            headers: HTTPHeaders(),
            body: Data("test".utf8)
        )
        
        let response = try await router.handle(request)
        
        #expect(response != nil)
        #expect(response?.status == .created)
    }
    
    @Test("DELETE route")
    func testDeleteRoute() async throws {
        let router = NIOHTTPRouter()
        
        await router.delete("/api/items/:id") { request in
            let id = request.pathParam("id") ?? "unknown"
            return .text("Deleted \(id)")
        }
        
        let request = NIOHTTPRequest(
            method: .DELETE,
            uri: "/api/items/123",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response != nil)
        #expect(response?.status == .ok)
        
        if let body = response?.body {
            let text = String(data: body, encoding: .utf8)
            #expect(text == "Deleted 123")
        }
    }
    
    @Test("OPTIONS route")
    func testOptionsRoute() async throws {
        let router = NIOHTTPRouter()
        
        await router.options("/api/data") { _ in
            .noContent().withCORS()
        }
        
        let request = NIOHTTPRequest(
            method: .OPTIONS,
            uri: "/api/data",
            headers: HTTPHeaders(),
            body: nil
        )
        
        let response = try await router.handle(request)
        
        #expect(response != nil)
        #expect(response?.status == .noContent)
    }
    
    // MARK: - Response Helper Tests
    
    @Test("JSON response encoding")
    func testJSONResponseEncoding() async throws {
        struct TestData: Codable {
            let message: String
            let count: Int
        }
        
        let data = TestData(message: "hello", count: 42)
        let response = try NIOHTTPResponse.json(data)
        
        #expect(response.status == .ok)
        #expect(response.body != nil)
        
        // Verify it's valid JSON
        if let body = response.body {
            let decoded = try JSONDecoder().decode(TestData.self, from: body)
            #expect(decoded.message == "hello")
            #expect(decoded.count == 42)
        }
    }
    
    @Test("CORS headers added correctly")
    func testCORSHeaders() async throws {
        let response = NIOHTTPResponse.text("OK").withCORS()
        
        #expect(response.headers["Access-Control-Allow-Origin"].first == "*")
        #expect(response.headers["Access-Control-Allow-Methods"].first?.contains("GET") == true)
    }
    
    @Test("Text response")
    func testTextResponse() async throws {
        let response = NIOHTTPResponse.text("Hello World", status: .ok)
        
        #expect(response.status == .ok)
        #expect(response.headers["Content-Type"].first?.contains("text/plain") == true)
        
        if let body = response.body {
            let text = String(data: body, encoding: .utf8)
            #expect(text == "Hello World")
        }
    }
    
    @Test("No content response")
    func testNoContentResponse() async throws {
        let response = NIOHTTPResponse.noContent()
        
        #expect(response.status == .noContent)
        #expect(response.body == nil)
    }
}
