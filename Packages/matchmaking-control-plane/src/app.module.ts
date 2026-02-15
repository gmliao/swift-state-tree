import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { MatchmakingModule } from './matchmaking/matchmaking.module';
import { QueueModule } from './queue/queue.module';
import { RealtimeModule } from './realtime/realtime.module';

/** Root application module. Imports MatchmakingModule (which includes ProvisioningModule), exposes health. */
@Module({
  imports: [QueueModule, RealtimeModule, MatchmakingModule],
  controllers: [AppController],
  providers: [],
})
export class AppModule {}
