import { Module } from '@nestjs/common';
import { CLUSTER_DIRECTORY } from './cluster-directory.interface';
import { RedisClusterDirectoryService } from './redis-cluster-directory.service';

@Module({
  providers: [
    {
      provide: CLUSTER_DIRECTORY,
      useClass: RedisClusterDirectoryService,
    },
  ],
  exports: [CLUSTER_DIRECTORY],
})
export class ClusterDirectoryModule {}
