import { Module } from '@nestjs/common';
import { MatchmakingController } from './matchmaking.controller';
import {
  MatchmakingService,
  MatchmakingConfig,
} from './matchmaking.service';
import { InMemoryMatchStorage } from '../storage/inmemory-match-storage';
import { DefaultMatchStrategy } from './strategies/default.strategy';
import { ProvisioningModule } from '../provisioning/provisioning.module';
import { SecurityModule } from '../security/security.module';

const matchmakingConfig: MatchmakingConfig = {
  intervalMs: parseInt(process.env.MATCHMAKING_INTERVAL_MS ?? '3000', 10),
  minWaitMs: parseInt(process.env.MATCHMAKING_MIN_WAIT_MS ?? '3000', 10),
};

/** Matchmaking module: queue, strategy, provisioning (internal registry), JWT. */
@Module({
  imports: [SecurityModule, ProvisioningModule],
  controllers: [MatchmakingController],
  providers: [
    { provide: 'MatchmakingConfig', useValue: matchmakingConfig },
    MatchmakingService,
    {
      provide: 'MatchStoragePort',
      useClass: InMemoryMatchStorage,
    },
    {
      provide: 'MatchStrategyPort',
      useClass: DefaultMatchStrategy,
    },
  ],
})
export class MatchmakingModule {}
