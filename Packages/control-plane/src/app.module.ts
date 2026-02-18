import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { ConfigModule } from './infra/config/config.module';
import { MatchmakingModule } from './modules/matchmaking/matchmaking.module';
import { BullMQModule } from './infra/bullmq/bullmq.module';
import { RealtimeModule } from './modules/realtime/realtime.module';
import { ChannelsModule } from './infra/channels/channels.module';
import { ClusterDirectoryModule } from './infra/cluster-directory/cluster-directory.module';

/** Root application module. ConfigModule loads .env first; K8s injects env via ConfigMap/Secret. */
@Module({
  imports: [ConfigModule, BullMQModule, ChannelsModule, ClusterDirectoryModule, RealtimeModule, MatchmakingModule],
  controllers: [AppController],
  providers: [],
})
export class AppModule {}
