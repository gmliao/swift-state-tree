import { Module } from '@nestjs/common';
import { MATCH_ASSIGNED_CHANNEL } from './match-assigned-channel.interface';
import { RedisMatchAssignedChannelService } from './redis-match-assigned-channel.service';

@Module({
  providers: [
    {
      provide: MATCH_ASSIGNED_CHANNEL,
      useClass: RedisMatchAssignedChannelService,
    },
  ],
  exports: [MATCH_ASSIGNED_CHANNEL],
})
export class PubSubModule {}
