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
import { MatchStoragePort, QueuedTicket } from '../storage/match-storage.port';
import { MatchStrategyPort } from './match-strategy.port';

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
    @Inject('MatchStoragePort') private readonly storage: MatchStoragePort,
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
    const ticket = await this.storage.enqueue(group);
    return {
      ticketId: ticket.ticketId,
      status: 'queued',
    };
  }

  /** Cancels a queued ticket. Fails if already assigned or cancelled. */
  async cancel(ticketId: string): Promise<{ cancelled: boolean }> {
    const ok = await this.storage.cancel(ticketId);
    return { cancelled: ok };
  }

  /** Returns ticket status. Includes assignment when status is "assigned". */
  async getStatus(ticketId: string): Promise<StatusResponse> {
    const ticket = await this.storage.getStatus(ticketId);
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
   * Called by setInterval. Processes each queue and assigns matchable tickets.
   */
  async runMatchmakingTick(): Promise<void> {
    const queueKeys = await this.storage.listQueueKeysWithQueued();
    for (const queueKey of queueKeys) {
      const queued = await this.storage.listQueuedByQueue(queueKey);
      const matchable = this.strategy.findMatchableTickets(
        queued,
        this.config.minWaitMs,
      );
      for (const ticket of matchable) {
        const current = await this.storage.getStatus(ticket.ticketId);
        if (!current || current.status !== 'queued') continue;
        try {
          const assignment = await this.processMatch(current);
          await this.storage.updateAssignment(current.ticketId, assignment);
          this.realtimeGateway.pushMatchAssigned(
            current.ticketId,
            buildMatchAssignedEnvelope(current.ticketId, assignment),
          );
        } catch (err) {
          console.error(
            `[Matchmaking] failed to assign ticket ${ticket.ticketId}:`,
            err,
          );
        }
      }
    }
  }

  /** Allocates land via provisioning client and issues JWT for the ticket. */
  async processMatch(ticket: QueuedTicket): Promise<AssignmentResult> {
    const result = await this.provisioning.allocate({
      queueKey: ticket.queueKey,
      groupId: ticket.groupId,
      groupSize: ticket.groupSize,
      region: ticket.region,
    });
    const assignmentId = `assign-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const playerId = ticket.members[0] ?? 'unknown';
    const matchToken = await this.jwtIssuer.issue({
      assignmentId,
      playerId,
      landId: result.landId,
      exp: Math.floor(Date.now() / 1000) + 3600,
      jti: assignmentId,
    });
    return {
      ...result,
      assignmentId,
      matchToken,
    };
  }
}
