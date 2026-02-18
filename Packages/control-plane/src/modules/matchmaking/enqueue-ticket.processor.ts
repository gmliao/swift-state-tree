import { Inject } from '@nestjs/common';
import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Job } from 'bullmq';
import { MatchQueue, QueuedTicket } from './match-queue';
import { MatchmakingService } from './matchmaking.service';
import {
  CancelJobPayload,
  EnqueueJobPayload,
  ENQUEUE_JOB,
  CANCEL_JOB,
} from './storage/api-match-queue';

/**
 * Consumes enqueueTicket jobs.
 * - enqueue: Add ticket from payload to LocalMatchQueue (Option A), then tryMatch.
 * - cancel: Remove ticket from LocalMatchQueue.
 */
@Processor('enqueueTicket')
export class EnqueueTicketProcessor extends WorkerHost {
  constructor(
    @Inject('MatchQueue') private readonly queue: MatchQueue,
    private readonly matchmakingService: MatchmakingService,
  ) {
    super();
  }

  async process(job: Job<EnqueueJobPayload | CancelJobPayload>): Promise<void> {
    if (job.name === ENQUEUE_JOB && job.data) {
      const payload = job.data as EnqueueJobPayload & { queueKey?: string };
      if ('ticketId' in payload && payload.ticketId) {
        const ticket: QueuedTicket = {
          ticketId: payload.ticketId,
          groupId: payload.groupId,
          queueKey: payload.queueKey,
          members: payload.members,
          groupSize: payload.groupSize,
          region: payload.region,
          status: 'queued',
          createdAt: new Date(),
        };
        const added = await this.queue.addTicketFromJob?.(ticket);
        if (added !== false) {
          await this.matchmakingService.tryMatch(payload.queueKey);
        }
      } else if (payload.queueKey) {
        await this.matchmakingService.tryMatch(payload.queueKey);
      }
    } else if (job.name === CANCEL_JOB && job.data) {
      const { ticketId } = job.data as CancelJobPayload;
      await this.queue.cancel(ticketId);
    }
  }
}
