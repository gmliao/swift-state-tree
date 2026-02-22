import { Injectable, Inject } from '@nestjs/common';
import { AssignmentResult } from '../../infra/contracts/assignment.dto';
import { SERVER_ID_DIRECTORY } from '../../infra/cluster-directory/server-id-directory.interface';
import type { ServerIdDirectory } from '../../infra/cluster-directory/server-id-directory.interface';
import {
  ProvisioningAllocateRequest,
  ProvisioningClientPort,
} from './provisioning-client.port';
import { NoServerAvailableError } from './provisioning-errors';

/**
 * In-memory provisioning client.
 * Uses ServerIdDirectory to pick a server and generate connectUrl.
 * No external HTTP call.
 */
@Injectable()
export class InMemoryProvisioningClient implements ProvisioningClientPort {
  constructor(
    @Inject(SERVER_ID_DIRECTORY)
    private readonly serverIdDirectory: ServerIdDirectory,
  ) {}

  async allocate(request: ProvisioningAllocateRequest): Promise<AssignmentResult> {
    // Derive landType from queueKey (e.g. "hero-defense:asia" -> "hero-defense").
    // region is a geographic hint, not the server selector; servers register by landType.
    const landType =
      request.queueKey.includes(':')
        ? request.queueKey.split(':')[0]
        : request.queueKey || 'hero-defense';
    const server = await this.serverIdDirectory.pickServer(landType);
    if (!server) {
      throw new NoServerAvailableError(landType);
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
