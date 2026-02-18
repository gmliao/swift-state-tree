import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { MatchmakingModule } from './matchmaking/matchmaking.module';
import { BullMQModule } from './bullmq/bullmq.module';
import { RealtimeModule } from './realtime/realtime.module';
import { PubSubModule } from './pubsub/pubsub.module';

/** Root application module. Imports MatchmakingModule (which includes ProvisioningModule), exposes health. */
@Module({
  imports: [BullMQModule, PubSubModule, RealtimeModule, MatchmakingModule],
  controllers: [AppController],
  providers: [],
})
export class AppModule {}
