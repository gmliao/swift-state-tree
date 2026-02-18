import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';
import { getRedisConfig } from '../config/env.config';

/** BullMQ infrastructure: Redis connection and job queues. */
@Module({
  imports: [
    BullModule.forRoot({
      connection: getRedisConfig(),
    }),
    BullModule.registerQueue({ name: 'enqueueTicket' }),
  ],
  exports: [BullModule],
})
export class BullMQModule {}
