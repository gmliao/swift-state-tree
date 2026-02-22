import { Test, TestingModule } from '@nestjs/testing';
import { WebSocket } from 'ws';
import { UserSessionRegistryService } from '../src/modules/realtime/user-session-registry.service';
import { USER_SESSION_REGISTRY } from '../src/modules/realtime/user-session-registry.interface';
import { USER_ID_DIRECTORY } from '../src/infra/cluster-directory/user-id-directory.interface';
import { NODE_INBOX_CHANNEL } from '../src/infra/channels/node-inbox-channel.interface';
import { NODE_ID } from '../src/infra/config/env.config';

const mockClusterDirectory = {
  registerSession: jest.fn().mockResolvedValue(undefined),
  refreshLease: jest.fn().mockResolvedValue(undefined),
  getNodeId: jest.fn().mockResolvedValue(null),
  unregisterSession: jest.fn().mockResolvedValue(undefined),
};
const mockNodeInboxChannel = {
  publish: jest.fn().mockResolvedValue(undefined),
  subscribe: jest.fn(),
};

describe('UserSessionRegistryService', () => {
  let registry: UserSessionRegistryService;

  beforeEach(async () => {
    jest.clearAllMocks();
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        {
          provide: USER_SESSION_REGISTRY,
          useClass: UserSessionRegistryService,
        },
        { provide: USER_ID_DIRECTORY, useValue: mockClusterDirectory },
        { provide: NODE_INBOX_CHANNEL, useValue: mockNodeInboxChannel },
        { provide: NODE_ID, useValue: 'node-1' },
      ],
    }).compile();
    registry = module.get(USER_SESSION_REGISTRY);
  });

  function mockSocket(): WebSocket {
    return { close: jest.fn() } as unknown as WebSocket;
  }

  it('calls registerSession only when first client binds for userId', async () => {
    const client1 = mockSocket();
    const client2 = mockSocket();
    await registry.bind(client1, 'u1');
    expect(mockClusterDirectory.registerSession).toHaveBeenCalledTimes(1);
    expect(mockClusterDirectory.registerSession).toHaveBeenCalledWith('u1', 'node-1');
    await registry.bind(client2, 'u1');
    expect(client1.close).toHaveBeenCalledWith(4000, 'Replaced by new session (multi-login prohibited)');
    expect(mockClusterDirectory.registerSession).toHaveBeenCalledTimes(1);
  });

  it('calls unregisterSession only when last client unbinds for userId', async () => {
    const client1 = mockSocket();
    const client2 = mockSocket();
    await registry.bind(client1, 'u1');
    await registry.bind(client2, 'u1');
    registry.unbind(client1);
    expect(mockClusterDirectory.unregisterSession).not.toHaveBeenCalled();
    registry.unbind(client2);
    expect(mockClusterDirectory.unregisterSession).toHaveBeenCalledTimes(1);
    expect(mockClusterDirectory.unregisterSession).toHaveBeenCalledWith('u1', 'node-1');
  });

  it('refreshLease calls clusterDirectory when client has userId', async () => {
    const client = mockSocket();
    await registry.bind(client, 'u1');
    registry.refreshLease(client);
    expect(mockClusterDirectory.refreshLease).toHaveBeenCalledWith('u1', 'node-1');
  });

  it('publishes kick to old node when binding from new node', async () => {
    mockClusterDirectory.getNodeId.mockResolvedValue('node-old');
    const client = mockSocket();
    await registry.bind(client, 'u1');
    expect(mockNodeInboxChannel.publish).toHaveBeenCalledWith('node-old', {
      type: 'kick',
      userId: 'u1',
    });
  });

  it('handleKick closes socket for userId', async () => {
    const client = mockSocket();
    await registry.bind(client, 'u1');
    registry.handleKick('u1');
    expect(client.close).toHaveBeenCalledWith(4000, 'Replaced by new session on another node (multi-login prohibited)');
  });
});
