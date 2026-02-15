// Sources/SwiftStateTreeNIOProvisioning/ProvisioningMiddleware.swift
//
// Provisioning middleware: registers with matchmaking control plane on start,
// runs heartbeat, deregisters on shutdown.

import Foundation
import Logging
import SwiftStateTreeNIO

// MARK: - DTO (aligned with matchmaking-control-plane contract)

/// Request payload for POST /v1/provisioning/servers/register.
private struct ServerRegisterRequest: Codable, Sendable {
    let serverId: String
    let host: String
    let port: Int
    let landType: String
    let connectHost: String?
    let connectPort: Int?
    let connectScheme: String?

    init(serverId: String, host: String, port: Int, landType: String, connectHost: String? = nil, connectPort: Int? = nil, connectScheme: String? = nil) {
        self.serverId = serverId
        self.host = host
        self.port = port
        self.landType = landType
        self.connectHost = connectHost
        self.connectPort = connectPort
        self.connectScheme = connectScheme
    }
}

/// Standard response envelope: { success, result?, error? }.
private struct ProvisioningResponseEnvelope<T: Codable & Sendable>: Codable, Sendable {
    let success: Bool
    let result: T?
    let error: ProvisioningErrorDetail?

    struct ProvisioningErrorDetail: Codable, Sendable {
        let code: String
        let message: String
        let retryable: Bool?
    }
}

/// Empty result for register/deregister (no payload).
private struct ProvisioningEmptyResult: Codable, Sendable {}

// MARK: - Provisioning Middleware

/// Middleware that registers the host with matchmaking control plane.
/// Runs heartbeat in background; deregisters on shutdown.
public struct ProvisioningMiddleware: HostMiddleware, Sendable {
    private let baseUrl: String
    private let serverId: String
    private let landType: String
    private let heartbeatIntervalSeconds: Int
    private let connectHost: String?
    private let connectPort: Int?
    private let connectScheme: String?

    public init(
        baseUrl: String,
        serverId: String,
        landType: String,
        heartbeatIntervalSeconds: Int = 30,
        connectHost: String? = nil,
        connectPort: Int? = nil,
        connectScheme: String? = nil
    ) {
        self.baseUrl = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        self.serverId = serverId
        self.landType = landType
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.connectHost = connectHost
        self.connectPort = connectPort
        self.connectScheme = connectScheme
    }

    public func onStart(context: HostContext) async throws -> Task<Void, Never>? {
        let baseUrl = self.baseUrl
        let serverId = self.serverId
        let landType = self.landType
        let intervalSeconds = self.heartbeatIntervalSeconds
        let connectHost = self.connectHost
        let connectPort = self.connectPort
        let connectScheme = self.connectScheme
        let host = context.host
        let port = Int(context.port)
        let logger = context.logger

        let task = Task {
            while !Task.isCancelled {
                await performRegister(baseUrl: baseUrl, serverId: serverId, host: host, port: port, landType: landType, connectHost: connectHost, connectPort: connectPort, connectScheme: connectScheme, logger: logger)
                try? await safeTaskSleep(for: .seconds(Int64(intervalSeconds)))
            }
        }

        logger.info(
            "Provisioning middleware: heartbeat started",
            metadata: [
                "baseUrl": .string(baseUrl),
                "serverId": .string(serverId),
                "landType": .string(landType),
            ]
        )
        return task
    }

    public func onShutdown(context: HostContext) async throws {
        await performDeregister(baseUrl: baseUrl, serverId: serverId, logger: context.logger)
        context.logger.info("Provisioning middleware: deregistered")
    }

    private func performRegister(baseUrl: String, serverId: String, host: String, port: Int, landType: String, connectHost: String?, connectPort: Int?, connectScheme: String?, logger: Logger) async {
        let urlString = "\(baseUrl)/v1/provisioning/servers/register"
        guard let url = URL(string: urlString) else {
            logger.warning("Invalid provisioning URL: \(urlString)")
            return
        }
        let body = ServerRegisterRequest(serverId: serverId, host: host, port: port, landType: landType, connectHost: connectHost, connectPort: connectPort, connectScheme: connectScheme)
        do {
            let (data, http) = try await ProvisioningHTTPClient.fetch(url: url, method: "POST", jsonBody: body)
            if http.isSuccess {
                logger.debug("Provisioning heartbeat OK")
            } else {
                let errorMsg = (!data.isEmpty ? (try? JSONDecoder().decode(ProvisioningResponseEnvelope<ProvisioningEmptyResult>.self, from: data))?.error?.message : nil) ?? ""
                logger.warning("Provisioning register returned \(http.statusCode) (control plane may not be ready)", metadata: errorMsg.isEmpty ? [:] : ["error": .string(errorMsg)])
            }
        } catch {
            logger.warning("Failed to register with provisioning: \(error)")
        }
    }

    private func performDeregister(baseUrl: String, serverId: String, logger: Logger) async {
        let urlString = "\(baseUrl)/v1/provisioning/servers/\(serverId)"
        guard let url = URL(string: urlString) else {
            logger.warning("Invalid provisioning deregister URL: \(urlString)")
            return
        }
        do {
            let (data, http) = try await ProvisioningHTTPClient.fetch(url: url, method: "DELETE")
            if http.isSuccess {
                logger.info("Deregistered from provisioning at \(baseUrl)")
            } else {
                let errorMsg = (!data.isEmpty ? (try? JSONDecoder().decode(ProvisioningResponseEnvelope<ProvisioningEmptyResult>.self, from: data))?.error?.message : nil) ?? ""
                logger.warning("Provisioning deregister returned \(http.statusCode)", metadata: errorMsg.isEmpty ? [:] : ["error": .string(errorMsg)])
            }
        } catch {
            logger.warning("Failed to deregister from provisioning: \(error)")
        }
    }
}

// MARK: - Convenience

extension NIOLandHostConfiguration {
    /// Creates a provisioning middleware for matchmaking control plane.
    /// - Parameters:
    ///   - connectHost: Client-facing host for connectUrl (e.g. K8s Ingress, nginx LB). When nil, uses bound host.
    ///   - connectPort: Client-facing port. When nil, uses bound port.
    ///   - connectScheme: "ws" or "wss". When nil, defaults to "wss" for port 443, else "ws".
    public static func provisioningMiddleware(
        baseUrl: String,
        serverId: String,
        landType: String,
        heartbeatIntervalSeconds: Int = 30,
        connectHost: String? = nil,
        connectPort: Int? = nil,
        connectScheme: String? = nil
    ) -> any HostMiddleware {
        ProvisioningMiddleware(
            baseUrl: baseUrl,
            serverId: serverId,
            landType: landType,
            heartbeatIntervalSeconds: heartbeatIntervalSeconds,
            connectHost: connectHost,
            connectPort: connectPort,
            connectScheme: connectScheme
        )
    }
}
