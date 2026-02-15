import {
  ProvisioningAllocateRequest,
  ProvisioningAllocateResponse,
  ProvisioningError,
} from '../src/provisioning/provisioning.contract';

describe('Provisioning API Contract', () => {
  it('request has required fields: queueKey, groupId, groupSize', () => {
    const req: ProvisioningAllocateRequest = {
      queueKey: 'standard:asia',
      groupId: 'g1',
      groupSize: 1,
    };
    expect(req.queueKey).toBeDefined();
    expect(req.groupId).toBeDefined();
    expect(req.groupSize).toBeDefined();
  });

  it('request allows optional region and constraints', () => {
    const req: ProvisioningAllocateRequest = {
      queueKey: 'standard:asia',
      groupId: 'g1',
      groupSize: 1,
      region: 'asia',
      constraints: { minPlayers: 2 },
    };
    expect(req.region).toBe('asia');
    expect(req.constraints).toEqual({ minPlayers: 2 });
  });

  it('response has required fields: serverId, landId, connectUrl', () => {
    const res: ProvisioningAllocateResponse = {
      serverId: 's1',
      landId: 'hero-defense:room-1',
      connectUrl: 'ws://127.0.0.1:8080/game/hero-defense?landId=hero-defense:room-1',
    };
    expect(res.serverId).toBeDefined();
    expect(res.landId).toBeDefined();
    expect(res.connectUrl).toBeDefined();
  });

  it('response allows optional expiresAt and assignmentHints', () => {
    const res: ProvisioningAllocateResponse = {
      serverId: 's1',
      landId: 'hero-defense:room-1',
      connectUrl: 'ws://127.0.0.1:8080/game/hero-defense',
      expiresAt: new Date().toISOString(),
      assignmentHints: { region: 'asia' },
    };
    expect(res.expiresAt).toBeDefined();
    expect(res.assignmentHints).toEqual({ region: 'asia' });
  });

  it('error has required fields: code, message, retryable', () => {
    const err: ProvisioningError = {
      code: 'PROVISIONING_FAILED',
      message: 'No capacity',
      retryable: true,
    };
    expect(err.code).toBeDefined();
    expect(err.message).toBeDefined();
    expect(typeof err.retryable).toBe('boolean');
  });
});
