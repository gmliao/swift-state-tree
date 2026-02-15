/**
 * Provisioning API contract - shared between NestJS control plane and Swift stub.
 * See docs/contracts/provisioning-api.md for full specification.
 */

/** Standard response envelope for provisioning endpoints. */
export interface ProvisioningResponseEnvelope<T = unknown> {
  success: boolean;
  result?: T;
  error?: {
    code: string;
    message: string;
    retryable?: boolean;
  };
}

/** Request body for POST /v1/provisioning/allocate. */
export interface ProvisioningAllocateRequest {
  queueKey: string;
  groupId: string;
  groupSize: number;
  region?: string;
  constraints?: Record<string, unknown>;
}

/** Response body from successful allocate. */
export interface ProvisioningAllocateResponse {
  serverId: string;
  landId: string;
  connectUrl: string;
  expiresAt?: string;
  assignmentHints?: Record<string, unknown>;
}

/** Error response from provisioning API. */
export interface ProvisioningError {
  code: string;
  message: string;
  retryable: boolean;
}
