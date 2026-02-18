import { Module } from '@nestjs/common';
import { MATCH_ASSIGNED_CHANNEL } from './match-assigned-channel.interface';
import { NODE_INBOX_CHANNEL } from './node-inbox-channel.interface';
import { RedisMatchAssignedChannelService } from './redis-match-assigned-channel.service';
import { RedisNodeInboxChannelService } from './redis-node-inbox-channel.service';

@Module({
  providers: [
    {
      provide: MATCH_ASSIGNED_CHANNEL,
      useClass: RedisMatchAssignedChannelService,
    },
    {
      provide: NODE_INBOX_CHANNEL,
      useClass: RedisNodeInboxChannelService,
    },
  ],
  exports: [MATCH_ASSIGNED_CHANNEL, NODE_INBOX_CHANNEL],
})
export class ChannelsModule {}
