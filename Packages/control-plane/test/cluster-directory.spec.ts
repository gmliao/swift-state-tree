import { Test, TestingModule } from '@nestjs/testing';
import { InMemoryClusterDirectoryService } from '../src/infra/cluster-directory/inmemory-cluster-directory.service';

describe('InMemoryClusterDirectoryService', () => {
  let service: InMemoryClusterDirectoryService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [InMemoryClusterDirectoryService],
    }).compile();
    service = module.get(InMemoryClusterDirectoryService);
    service.setTtlMs(5000);
  });

  it('registers session and returns nodeId', async () => {
    await service.registerSession('u1', 'node-a');
    expect(await service.getNodeId('u1')).toBe('node-a');
  });

  it('returns null for unknown userId', async () => {
    expect(await service.getNodeId('unknown')).toBeNull();
  });

  it('unregisters only when nodeId matches', async () => {
    await service.registerSession('u1', 'node-a');
    await service.unregisterSession('u1', 'node-b');
    expect(await service.getNodeId('u1')).toBe('node-a');
    await service.unregisterSession('u1', 'node-a');
    expect(await service.getNodeId('u1')).toBeNull();
  });

  it('refreshLease extends expiry only when nodeId matches', async () => {
    await service.registerSession('u1', 'node-a');
    await service.refreshLease('u1', 'node-a');
    expect(await service.getNodeId('u1')).toBe('node-a');
    await service.refreshLease('u1', 'node-b');
    expect(await service.getNodeId('u1')).toBe('node-a');
  });

  it('overwrites previous session for same userId', async () => {
    await service.registerSession('u1', 'node-a');
    await service.registerSession('u1', 'node-b');
    expect(await service.getNodeId('u1')).toBe('node-b');
  });
});
