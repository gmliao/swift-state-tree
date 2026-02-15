import { Injectable } from '@nestjs/common';
import { AssignmentResult } from '../contracts/assignment.dto';
import {
  ProvisioningAllocateRequest,
  ProvisioningClientPort,
} from './provisioning-client.port';
import { ServerRegistryService } from './server-registry.service';

/**
 * In-memory provisioning client.
 * Uses ServerRegistryService to pick a server and generate connectUrl.
 * No external HTTP call.
 */
@Injectable()
export class InMemoryProvisioningClient implements ProvisioningClientPort {
  constructor(private readonly registry: ServerRegistryService) {}

  async allocate(request: ProvisioningAllocateRequest): Promise<AssignmentResult> {
    // Derive landType from queueKey (e.g. "hero-defense:asia" -> "hero-defense").
    // region is a geographic hint, not the server selector; servers register by landType.
    const landType =
      request.queueKey.includes(':')
        ? request.queueKey.split(':')[0]
        : request.queueKey || 'hero-defense';
    const server = this.registry.pickServer(landType);
    if (!server) {
      throw new Error(`No server available for landType: ${landType}`);
    }
    const instanceId = crypto.randomUUID();
    const landId = `${server.landType}:${instanceId}`;
    const host = server.connectHost ?? server.host;
    const port = server.connectPort ?? server.port;
    const scheme = server.connectScheme ?? (port === 443 ? 'wss' : 'ws');
    const connectUrl = `${scheme}://${host}:${port}/game/${server.landType}?landId=${landId}`;
    const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString();
    return {
      assignmentId: `assign-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      matchToken: '', // Will be set by JWT issuer in MatchmakingService
      connectUrl,
      landId,
      serverId: server.serverId,
      expiresAt,
    };
  }
}
