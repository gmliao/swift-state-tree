import { Module, type Provider } from '@nestjs/common';
import { MatchmakingController } from './matchmaking.controller';
import {
  MatchmakingService,
  MatchmakingConfig,
} from './matchmaking.service';
import { FillGroupStrategy } from './strategies/fill-group.strategy';
import { EnqueueTicketProcessor } from './enqueue-ticket.processor';
import {
  getMatchmakingRole,
  isApiEnabled,
  isWorkerEnabled,
} from './matchmaking-role';
import { ProvisioningModule } from '../provisioning/provisioning.module';
import { BullMQModule } from '../../infra/bullmq/bullmq.module';
import { ChannelsModule } from '../../infra/channels/channels.module';
import { ClusterDirectoryModule } from '../../infra/cluster-directory/cluster-directory.module';
import { SecurityModule } from '../../infra/security/security.module';
import { LocalMatchQueue } from './storage/local-match-queue';
import { ApiMatchQueue } from './storage/api-match-queue';
import { RedisMatchmakingStore } from './storage/redis-matchmaking-store';

import { getMatchmakingMinWaitMs } from '../../infra/config/env.config';

function buildProviders(): Provider[] {
  const role = getMatchmakingRole();
  const providers: Provider[] = [
    {
      provide: 'MatchmakingConfig',
      useFactory: () => ({ minWaitMs: getMatchmakingMinWaitMs() }),
    },
    MatchmakingService,
    {
      provide: 'MatchmakingStore',
      useClass: RedisMatchmakingStore,
    },
    {
      provide: 'MatchQueue',
      useClass: isApiEnabled(role) && !isWorkerEnabled(role)
        ? ApiMatchQueue
        : LocalMatchQueue,
    },
    {
      provide: 'MatchStrategy',
      useClass: FillGroupStrategy,
    },
  ];
  if (isWorkerEnabled(role)) {
    providers.push(EnqueueTicketProcessor);
  }
  return providers;
}

/** Matchmaking module: role-based queue (ApiMatchQueue vs LocalMatchQueue), optional queue-worker. */
@Module({
  imports: [BullMQModule, ChannelsModule, ClusterDirectoryModule, SecurityModule, ProvisioningModule],
  controllers: isApiEnabled(getMatchmakingRole()) ? [MatchmakingController] : [],
  providers: buildProviders(),
  exports: [MatchmakingService, 'MatchmakingStore'],
})
export class MatchmakingModule {}
