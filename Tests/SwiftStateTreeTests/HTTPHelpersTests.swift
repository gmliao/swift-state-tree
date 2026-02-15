// Tests/SwiftStateTreeTests/HTTPHelpersTests.swift
//
// Unit tests for HTTPHelpers (fetch API, error handling).
// Network error propagation is covered by integration/E2E tests.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Tests

@Suite("HTTPHelpers")
struct HTTPHelpersTests {

    @Test("Invalid Encodable throws jsonEncodingFailed")
    func invalidEncodableThrows() async throws {
        // Struct that fails to encode (contains non-Encodable type)
        struct BadEncodable: Encodable {
            let value: Int
            func encode(to encoder: Encoder) throws {
                throw NSError(domain: "Test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Encode failed"])
            }
        }

        do {
            _ = try await HTTPHelpers.fetch(
                url: URL(string: "https://example.com")!,
                method: "POST",
                jsonBody: BadEncodable(value: 1)
            )
            Issue.record("Expected jsonEncodingFailed to throw")
        } catch let error as HTTPHelpersError {
            switch error {
            case .jsonEncodingFailed:
                return // Expected
            default:
                Issue.record("Expected jsonEncodingFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected HTTPHelpersError, got \(error)")
        }
    }

    @Test("Empty HTTP method throws invalidInput")
    func emptyMethodThrows() async throws {
        do {
            _ = try await HTTPHelpers.fetch(
                url: URL(string: "https://example.com")!,
                method: "",
                body: nil
            )
            Issue.record("Expected invalidInput to throw")
        } catch let error as HTTPHelpersError {
            switch error {
            case .invalidInput:
                return
            default:
                Issue.record("Expected invalidInput, got \(error)")
            }
        } catch {
            Issue.record("Expected HTTPHelpersError, got \(error)")
        }
    }

    @Test("Whitespace-only HTTP method throws invalidInput")
    func whitespaceMethodThrows() async throws {
        do {
            _ = try await HTTPHelpers.fetch(
                url: URL(string: "https://example.com")!,
                method: "   ",
                body: nil
            )
            Issue.record("Expected invalidInput to throw")
        } catch let error as HTTPHelpersError {
            switch error {
            case .invalidInput:
                return
            default:
                Issue.record("Expected invalidInput, got \(error)")
            }
        } catch {
            Issue.record("Expected HTTPHelpersError, got \(error)")
        }
    }

    @Test("Valid JSON object serializes without throwing")
    func validJsonObjectSerializes() async throws {
        // Valid JSON object should not throw jsonEncodingFailed during serialization.
        // Use connection-refused URL so we get networkError (proves serialization succeeded).
        let body: [String: Any] = ["serverId": "s1", "host": "localhost", "port": 8080, "landType": "game"]
        do {
            _ = try await HTTPHelpers.fetch(
                url: URL(string: "http://127.0.0.1:17999/")!, // Unlikely to be listening
                method: "POST",
                jsonObject: body
            )
        } catch let error as HTTPHelpersError {
            switch error {
            case .jsonEncodingFailed:
                Issue.record("Valid JSON should not throw jsonEncodingFailed")
            case .invalidInput:
                Issue.record("Valid input should not throw invalidInput")
            case .networkError:
                return // Serialization OK, network failed as expected
            }
        } catch {
            return // Connection refused or similar
        }
    }
}
