import { AssignmentResult } from '../../infra/contracts/assignment.dto';
import { httpStatusCodeFrom } from '../../infra/contracts/http-status';
import {
  ProvisioningAllocateRequest,
  ProvisioningClientPort,
} from './provisioning-client.port';

/** Configuration for HTTP provisioning client. */
export interface HttpProvisioningClientConfig {
  baseUrl: string;
}

/**
 * HTTP client for the Land Provisioning API.
 * Calls POST /v1/provisioning/allocate.
 */
export class HttpProvisioningClient implements ProvisioningClientPort {
  constructor(private readonly config: HttpProvisioningClientConfig) {}

  /** Allocates a land via provisioning API. */
  async allocate(request: ProvisioningAllocateRequest): Promise<AssignmentResult> {
    const url = `${this.config.baseUrl.replace(/\/$/, '')}/v1/provisioning/allocate`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
    });
    if (!res.ok) {
      const code = httpStatusCodeFrom(res.status) ?? res.status;
      throw new Error(`Provisioning failed: ${code} ${res.statusText}`);
    }
    const data = (await res.json()) as {
      serverId: string;
      landId: string;
      connectUrl: string;
      expiresAt?: string;
    };
    const expiresAt =
      data.expiresAt ?? new Date(Date.now() + 3600 * 1000).toISOString();
    return {
      assignmentId: `assign-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      matchToken: '', // Will be set by JWT issuer
      connectUrl: data.connectUrl,
      landId: data.landId,
      serverId: data.serverId,
      expiresAt,
    };
  }
}
