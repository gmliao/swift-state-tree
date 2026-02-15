import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { MatchmakingModule } from './matchmaking/matchmaking.module';

/** Root application module. Imports MatchmakingModule (which includes ProvisioningModule), exposes health. */
@Module({
  imports: [MatchmakingModule],
  controllers: [AppController],
  providers: [],
})
export class AppModule {}
