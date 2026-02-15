import { Module } from '@nestjs/common';
import { MatchmakingController } from './matchmaking.controller';
import {
  MatchmakingService,
  MatchmakingConfig,
} from './matchmaking.service';
import { FillGroupStrategy } from './strategies/fill-group.strategy';
import { MatchmakingTickProcessor } from './matchmaking-tick.processor';
import { ProvisioningModule } from '../provisioning/provisioning.module';
import { QueueModule } from '../queue/queue.module';
import { RealtimeModule } from '../realtime/realtime.module';
import { SecurityModule } from '../security/security.module';
import { BullMQMatchQueue } from '../storage/bullmq-match-queue';
import { RedisMatchQueueMetadata } from '../storage/redis-match-queue-metadata';

const matchmakingConfig: MatchmakingConfig = {
  intervalMs: parseInt(process.env.MATCHMAKING_INTERVAL_MS ?? '3000', 10),
  minWaitMs: parseInt(process.env.MATCHMAKING_MIN_WAIT_MS ?? '3000', 10),
};

/** Matchmaking module: queue, strategy, provisioning (internal registry), JWT. */
@Module({
  imports: [QueueModule, RealtimeModule, SecurityModule, ProvisioningModule],
  controllers: [MatchmakingController],
  providers: [
    { provide: 'MatchmakingConfig', useValue: matchmakingConfig },
    MatchmakingService,
    {
      provide: 'MatchQueueMetadataPort',
      useClass: RedisMatchQueueMetadata,
    },
    {
      provide: 'MatchQueuePort',
      useClass: BullMQMatchQueue,
    },
    {
      provide: 'MatchStrategyPort',
      useClass: FillGroupStrategy,
    },
    MatchmakingTickProcessor,
  ],
})
export class MatchmakingModule {}
