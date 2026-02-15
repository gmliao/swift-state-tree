import { Processor, WorkerHost } from '@nestjs/bullmq';
import { Job } from 'bullmq';
import { MatchmakingService } from './matchmaking.service';

@Processor('matchmaking-tick')
export class MatchmakingTickProcessor extends WorkerHost {
  constructor(private readonly matchmakingService: MatchmakingService) {
    super();
  }

  async process(job: Job): Promise<void> {
    if (job.name === 'tick') {
      await this.matchmakingService.runMatchmakingTick();
    }
  }
}
