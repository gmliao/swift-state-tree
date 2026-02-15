// Sources/SwiftStateTreeNIOProvisioning/ProvisioningHTTPClient.swift
//
// Cross-platform HTTP client using AsyncHTTPClient (no FoundationNetworking / #if).
// Used by ProvisioningMiddleware for control plane register/deregister.

import Foundation
import AsyncHTTPClient
import NIOHTTP1
import NIOCore

/// HTTP response with status code and body. Cross-platform (macOS + Linux).
struct ProvisioningHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data

    var isSuccess: Bool { (200...299).contains(statusCode) }
}

/// Errors for provisioning HTTP operations.
enum ProvisioningHTTPError: Error, Sendable {
    case invalidInput(String)
    case jsonEncodingFailed(underlying: Error)
    case networkError(underlying: Error)
}

/// HTTP fetch using AsyncHTTPClient. Cross-platform, no URLSession.
enum ProvisioningHTTPClient: Sendable {

    private static let shared = HTTPClient(eventLoopGroupProvider: .singleton)

    static func fetch(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, ProvisioningHTTPResponse) {
        let methodTrimmed = method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !methodTrimmed.isEmpty else {
            throw ProvisioningHTTPError.invalidInput("HTTP method cannot be empty")
        }

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = HTTPMethod(rawValue: methodTrimmed)
        if let body {
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: body))
        }
        for (key, value) in headers {
            request.headers.add(name: key, value: value)
        }

        do {
            let response = try await shared.execute(request, timeout: .seconds(30))
            let statusCode = Int(response.status.code)
            let buffer = try await response.body.collect(upTo: 1024 * 1024)
            let bodyData = Data(buffer.readableBytesView)
            return (bodyData, ProvisioningHTTPResponse(statusCode: statusCode, body: bodyData))
        } catch {
            throw ProvisioningHTTPError.networkError(underlying: error)
        }
    }

    static func fetch<T: Encodable>(
        url: URL,
        method: String = "POST",
        jsonBody: T,
        encoder: JSONEncoder = JSONEncoder()
    ) async throws -> (Data, ProvisioningHTTPResponse) {
        let body: Data
        do {
            body = try encoder.encode(jsonBody)
        } catch {
            throw ProvisioningHTTPError.jsonEncodingFailed(underlying: error)
        }
        return try await fetch(url: url, method: method, body: body)
    }
}
