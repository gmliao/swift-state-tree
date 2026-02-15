import {
  Inject,
  Injectable,
  NotFoundException,
  OnModuleInit,
  OnModuleDestroy,
} from '@nestjs/common';
import { InjectQueue } from '@nestjs/bullmq';
import { Queue } from 'bullmq';
import { AssignmentResult } from '../contracts/assignment.dto';
import { EnqueueRequest, StatusResponse } from '../contracts/matchmaking.dto';
import { ProvisioningClientPort } from '../provisioning/provisioning-client.port';
import { buildMatchAssignedEnvelope } from '../realtime/ws-envelope.dto';
import { RealtimeGateway } from '../realtime/realtime.gateway';
import { JwtIssuerService } from '../security/jwt-issuer.service';
import { MatchQueuePort, QueuedTicket } from '../storage/match-queue.port';
import { MatchStrategyPort } from './match-strategy.port';
import { getQueueConfig } from './queue-config';

/** Configuration for the periodic matchmaking loop. */
export interface MatchmakingConfig {
  /** Interval in ms between matchmaking ticks. */
  intervalMs: number;
  /** Minimum time a ticket must wait before it can be matched. */
  minWaitMs: number;
}

const DEFAULT_CONFIG: MatchmakingConfig = {
  intervalMs: parseInt(process.env.MATCHMAKING_INTERVAL_MS ?? '3000', 10),
  minWaitMs: parseInt(process.env.MATCHMAKING_MIN_WAIT_MS ?? '3000', 10),
};

/**
 * Core matchmaking service.
 * Manages queue lifecycle, periodic matching, and assignment via provisioning client.
 */
@Injectable()
export class MatchmakingService implements OnModuleInit, OnModuleDestroy {
  private repeatOpts: { every: number } | null = null;

  constructor(
    @Inject('MatchQueuePort') private readonly queue: MatchQueuePort,
    @Inject('MatchStrategyPort') private readonly strategy: MatchStrategyPort,
    @Inject('ProvisioningClientPort')
    private readonly provisioning: ProvisioningClientPort,
    private readonly jwtIssuer: JwtIssuerService,
    @Inject('MatchmakingConfig') private readonly config: MatchmakingConfig,
    @InjectQueue('matchmaking-tick') private readonly tickQueue: Queue,
    private readonly realtimeGateway: RealtimeGateway,
  ) {}

  /** Starts the periodic matchmaking tick via BullMQ repeatable job. */
  async onModuleInit() {
    this.repeatOpts = { every: this.config.intervalMs };
    await this.tickQueue.add('tick', {}, { repeat: this.repeatOpts });
  }

  /** Cleans up the repeatable job on shutdown. */
  async onModuleDestroy() {
    if (this.repeatOpts) {
      await this.tickQueue.removeRepeatable('tick', this.repeatOpts);
      this.repeatOpts = null;
    }
  }

  /** Adds a group to the queue. Returns immediately with ticketId; assignment happens asynchronously. */
  async enqueue(dto: EnqueueRequest) {
    const group = {
      groupId: dto.groupId,
      queueKey: dto.queueKey,
      members: dto.members,
      groupSize: dto.groupSize,
      region: dto.region,
      constraints: dto.constraints,
    };
    const ticket = await this.queue.enqueue(group);
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
   * Runs periodically to match queued tickets that have waited long enough.
   * Uses findMatchableGroups to form groups; allocates once per group, issues one JWT per ticket.
   */
  async runMatchmakingTick(): Promise<void> {
    const queueKeys = await this.queue.listQueueKeysWithQueued();
    for (const queueKey of queueKeys) {
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
          for (let i = 0; i < group.tickets.length; i++) {
            const t = group.tickets[i];
            const assignment = assignments[i];
            await this.queue.updateAssignment(t.ticketId, assignment);
            this.realtimeGateway.pushMatchAssigned(
              t.ticketId,
              buildMatchAssignedEnvelope(t.ticketId, assignment),
            );
          }
        } catch (err) {
          console.error(`[Matchmaking] failed to assign group:`, err);
        }
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
