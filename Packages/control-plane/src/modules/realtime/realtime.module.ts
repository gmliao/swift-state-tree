import { Module, forwardRef } from '@nestjs/common';
import { RealtimeGateway } from './realtime.gateway';
import { MatchmakingModule } from '../matchmaking/matchmaking.module';
import { ConfigModule } from '../../infra/config/config.module';
import { ChannelsModule } from '../../infra/channels/channels.module';
import { ClusterDirectoryModule } from '../../infra/cluster-directory/cluster-directory.module';
import { UserSessionRegistryService } from './user-session-registry.service';
import { USER_SESSION_REGISTRY } from './user-session-registry.interface';

@Module({
  imports: [forwardRef(() => MatchmakingModule), ConfigModule, ChannelsModule, ClusterDirectoryModule],
  providers: [
    RealtimeGateway,
    { provide: USER_SESSION_REGISTRY, useClass: UserSessionRegistryService },
  ],
  exports: [RealtimeGateway],
})
export class RealtimeModule {}
