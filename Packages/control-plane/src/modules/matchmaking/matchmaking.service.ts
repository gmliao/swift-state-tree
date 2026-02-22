import { Inject, Injectable, NotFoundException } from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { AssignmentResult } from '../../infra/contracts/assignment.dto';
import { EnqueueRequest, StatusResponse } from '../../infra/contracts/matchmaking.dto';
import { ProvisioningClientPort } from '../provisioning/provisioning-client.port';
import { buildMatchAssignedEnvelope } from '../realtime/ws-envelope.dto';
import {
  MATCH_ASSIGNED_CHANNEL,
  type MatchAssignedChannel,
} from '../../infra/channels/match-assigned-channel.interface';
import {
  NODE_INBOX_CHANNEL,
  type NodeInboxChannel,
} from '../../infra/channels/node-inbox-channel.interface';
import {
  CLUSTER_DIRECTORY,
  type ClusterDirectory,
} from '../../infra/cluster-directory/cluster-directory.interface';
import { JwtIssuerService } from '../../infra/security/jwt-issuer.service';
import { getUseNodeInboxForMatchAssigned } from '../../infra/config/env.config';
import {
  getMatchmakingRole,
  isWorkerEnabled,
} from './matchmaking-role';
import { MatchQueue, QueuedTicket } from './match-queue';
import { MatchStrategy } from './match-strategy';
import { getQueueConfig } from './queue-config';

/** Configuration for matchmaking. */
export interface MatchmakingConfig {
  /** Minimum time a ticket must wait before it can be matched. */
  minWaitMs: number;
}


/**
 * Core matchmaking service.
 * Queue is in-memory (LocalMatchQueue with Denque); enqueueTicket job triggers processing.
 * When USE_NODE_INBOX_FOR_MATCH_ASSIGNED=true, publishes match.assigned to target node's inbox
 * (lookup via ClusterDirectory.getNodeId) instead of broadcast.
 */
@Injectable()
export class MatchmakingService {
  constructor(
    @Inject('MatchQueue') private readonly queue: MatchQueue,
    @Inject('MatchStrategy') private readonly strategy: MatchStrategy,
    @Inject('ProvisioningClientPort')
    private readonly provisioning: ProvisioningClientPort,
    private readonly jwtIssuer: JwtIssuerService,
    @Inject('MatchmakingConfig') private readonly config: MatchmakingConfig,
    @InjectQueue('enqueueTicket') private readonly enqueueTicketQueue: Queue,
    @Inject(MATCH_ASSIGNED_CHANNEL)
    private readonly matchAssignedChannel: MatchAssignedChannel,
    @Inject(NODE_INBOX_CHANNEL)
    private readonly nodeInboxChannel: NodeInboxChannel,
    @Inject(CLUSTER_DIRECTORY)
    private readonly clusterDirectory: ClusterDirectory,
  ) {}

  /**
   * Adds a group to the queue.
   * @param onBeforeJob - Called with ticketId before adding BullMQ job. Use to subscribe WS client
   *   before worker can process (avoids race where push happens before client is subscribed).
   */
  async enqueue(dto: EnqueueRequest, onBeforeJob?: (ticketId: string) => void) {
    const groupId =
      dto.groupId ?? `group-${crypto.randomUUID().replace(/-/g, '').slice(0, 16)}`;
    const group = {
      groupId,
      queueKey: dto.queueKey,
      members: dto.members,
      groupSize: dto.groupSize,
      region: dto.region,
      constraints: dto.constraints,
    };
    const ticket = await this.queue.enqueue(group);
    onBeforeJob?.(ticket.ticketId);
    // Synchronous tryMatch: process immediately in same process. Workaround for BullMQ
    // sequential-enqueue bug where second job may not be processed (or processed before
    // ticket is in queue). BullMQ job still runs but will typically find nothing to match.
    await this.tryMatch(dto.queueKey);
    if (isWorkerEnabled(getMatchmakingRole())) {
      await this.enqueueTicketQueue.add(
        'enqueue',
        { queueKey: dto.queueKey },
        { jobId: ticket.ticketId },
      );
    }
    return {
      ticketId: ticket.ticketId,
      status: 'queued',
    };
  }

  /** Cancels a queued ticket. Fails if already assigned or cancelled. */
  async cancel(ticketId: string): Promise<{ cancelled: boolean }> {
    const ok = await this.queue.cancel(ticketId);
    return { cancelled: ok };
  }

  /** Returns ticket status. Includes assignment when status is "assigned". */
  async getStatus(ticketId: string): Promise<StatusResponse> {
    const ticket = await this.queue.getStatus(ticketId);
    if (!ticket) {
      throw new NotFoundException('Ticket not found');
    }
    const response: StatusResponse = {
      ticketId: ticket.ticketId,
      status: ticket.status,
    };
    if (ticket.assignment) {
      response.assignment = ticket.assignment;
    }
    return response;
  }

  /**
   * Process all queues (for tests). Production uses tryMatch per enqueueTicket job.
   */
  async runMatchmakingTick(): Promise<void> {
    const queueKeys = await this.queue.listQueueKeysWithQueued();
    for (const queueKey of queueKeys) {
      await this.tryMatch(queueKey);
    }
  }

  /**
   * Try to form groups for a queueKey. Called by EnqueueTicketProcessor when job is consumed.
   * Publishes match.assigned to node inbox (if USE_NODE_INBOX_FOR_MATCH_ASSIGNED and getNodeId found)
   * or broadcast channel.
   * @param queueKey - Queue key (e.g. hero-defense:3v3)
   */
  async tryMatch(queueKey: string): Promise<void> {
    const queued = await this.queue.listQueuedByQueue(queueKey);
    const config = getQueueConfig(queueKey, {
      minWaitMs: this.config.minWaitMs,
    });
    const groups = this.strategy.findMatchableGroups(queued, config);
    for (const group of groups) {
      const stillQueued = await Promise.all(
        group.tickets.map((t) => this.queue.getStatus(t.ticketId)),
      );
      const valid = stillQueued.filter(
        (t): t is QueuedTicket =>
          t !== null && t.status === 'queued',
      );
      if (valid.length !== group.tickets.length) continue;

      try {
        const assignments = await this.processGroup(group.tickets);
        const useNodeInbox = getUseNodeInboxForMatchAssigned();
        for (let i = 0; i < group.tickets.length; i++) {
          const t = group.tickets[i];
          const assignment = assignments[i];
          await this.queue.updateAssignment(t.ticketId, assignment);
          const payload = {
            ticketId: t.ticketId,
            envelope: buildMatchAssignedEnvelope(t.ticketId, assignment),
          };
          if (useNodeInbox) {
            const primaryUserId = t.members[0];
            const nodeId = primaryUserId
              ? await this.clusterDirectory.getNodeId(primaryUserId)
              : null;
            if (nodeId) {
              await this.nodeInboxChannel.publish(nodeId, payload);
            } else {
              await this.matchAssignedChannel.publish(payload);
            }
          } else {
            await this.matchAssignedChannel.publish(payload);
          }
        }
      } catch (err) {
        console.error(`[Matchmaking] failed to assign group:`, err);
      }
    }
  }

  /** Allocates land once per group and issues one JWT per ticket. */
  async processGroup(tickets: QueuedTicket[]): Promise<AssignmentResult[]> {
    const first = tickets[0];
    const totalSize = tickets.reduce((s, t) => s + t.groupSize, 0);
    const syntheticGroupId = `group-${first.ticketId}-${Date.now()}`;

    const result = await this.provisioning.allocate({
      queueKey: first.queueKey,
      groupId: syntheticGroupId,
      groupSize: totalSize,
      region: first.region,
    });

    const assignments: AssignmentResult[] = [];
    for (let i = 0; i < tickets.length; i++) {
      const ticket = tickets[i];
      const assignmentId = `assign-${Date.now()}-${i}-${Math.random().toString(36).slice(2)}`;
      const playerId = ticket.members[0] ?? 'unknown';
      const matchToken = await this.jwtIssuer.issue({
        assignmentId,
        playerId,
        landId: result.landId,
        exp: Math.floor(Date.now() / 1000) + 3600,
        jti: assignmentId,
      });
      assignments.push({
        ...result,
        assignmentId,
        matchToken,
      });
    }
    return assignments;
  }
}
