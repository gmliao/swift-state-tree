// Sources/SwiftStateTreeNIOProvisioning/ProvisioningEnvKeys.swift
//
// Environment variable keys for provisioning (matchmaking control plane registration).
// Use these constants with EnvHelpers / getEnvStringOptional to avoid scattered string literals.

import Foundation

/// Environment variable keys for SwiftStateTreeNIOProvisioning.
public enum ProvisioningEnvKeys: Sendable {
    /// Control plane base URL (e.g. http://127.0.0.1:3000). When set, enables provisioning middleware.
    /// May include path prefix (e.g. http://host:3000/api) for reverse-proxy setups.
    /// API paths appended: /v1/provisioning/servers/register, /v1/provisioning/servers/{serverId}
    public static let baseUrl = "PROVISIONING_BASE_URL"

    /// Server ID for registration (optional; app may use a fixed or derived value).
    public static let serverId = "PROVISIONING_SERVER_ID"

    /// Heartbeat interval in seconds (default 30). Control plane TTL is typically 90s.
    public static let heartbeatIntervalSeconds = "PROVISIONING_HEARTBEAT_INTERVAL_SECONDS"

    /// Client-facing host for connectUrl. Use when behind K8s Ingress, nginx LB, etc.
    /// When set, overrides bound host in the URL returned to clients.
    public static let connectHost = "PROVISIONING_CONNECT_HOST"

    /// Client-facing port for connectUrl. Use with connectHost when behind LB.
    public static let connectPort = "PROVISIONING_CONNECT_PORT"

    /// WebSocket scheme for connectUrl: "ws" or "wss". Default: "wss" when connectPort is 443, else "ws".
    public static let connectScheme = "PROVISIONING_CONNECT_SCHEME"
}
