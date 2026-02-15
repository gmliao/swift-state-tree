import { BullModule } from '@nestjs/bullmq';
import { Module } from '@nestjs/common';

const redisHost = process.env.REDIS_HOST ?? 'localhost';
const redisPort = parseInt(process.env.REDIS_PORT ?? '6379', 10);

@Module({
  imports: [
    BullModule.forRoot({
      connection: {
        host: redisHost,
        port: redisPort,
      },
    }),
    BullModule.registerQueue(
      { name: 'matchmaking-tick' },
      { name: 'matchmaking-tickets' },
    ),
  ],
  exports: [BullModule],
})
export class QueueModule {}
