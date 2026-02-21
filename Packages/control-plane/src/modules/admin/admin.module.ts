import { Module } from '@nestjs/common';
import { AdminController } from './admin.controller';
import { AdminQueueService } from './admin-queue.service';
import { MatchmakingModule } from '../matchmaking/matchmaking.module';
import { ProvisioningModule } from '../provisioning/provisioning.module';

@Module({
  imports: [ProvisioningModule, MatchmakingModule],
  controllers: [AdminController],
  providers: [AdminQueueService],
})
export class AdminModule {}
