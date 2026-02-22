import { Module } from '@nestjs/common';
import { USER_ID_DIRECTORY } from './user-id-directory.interface';
import { SERVER_ID_DIRECTORY } from './server-id-directory.interface';
import { RedisUserIdDirectoryService } from './redis-user-id-directory.service';
import { RedisServerIdDirectoryService } from './redis-server-id-directory.service';

@Module({
  providers: [
    { provide: USER_ID_DIRECTORY, useClass: RedisUserIdDirectoryService },
    { provide: SERVER_ID_DIRECTORY, useClass: RedisServerIdDirectoryService },
  ],
  exports: [USER_ID_DIRECTORY, SERVER_ID_DIRECTORY],
})
export class ClusterDirectoryModule {}
