import { ServerRegistryService, SERVER_TTL_MS } from '../src/modules/provisioning/server-registry.service';

describe('ServerRegistryService', () => {
  let registry: ServerRegistryService;

  beforeEach(() => {
    registry = new ServerRegistryService();
  });

  describe('register', () => {
    it('registers a server for a land type', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      const entry = registry.pickServer('hero-defense');
      expect(entry).not.toBeNull();
      expect(entry!.serverId).toBe('s1');
      expect(entry!.host).toBe('127.0.0.1');
      expect(entry!.port).toBe(8080);
    });

    it('updates existing entry on heartbeat', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      registry.register('s1', '127.0.0.2', 9090, 'hero-defense');
      const entry = registry.pickServer('hero-defense');
      expect(entry!.host).toBe('127.0.0.2');
      expect(entry!.port).toBe(9090);
    });
  });

  describe('deregister', () => {
    it('removes server from single land type', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      registry.deregister('s1');
      expect(registry.pickServer('hero-defense')).toBeNull();
    });

    it('removes serverId from all land-type buckets when registered for multiple land types', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      registry.register('s1', '127.0.0.1', 8080, 'counter');
      registry.register('s1', '127.0.0.1', 8080, 'cookie');
      registry.register('s2', '127.0.0.2', 8081, 'hero-defense');

      registry.deregister('s1');

      expect(registry.pickServer('hero-defense')).not.toBeNull();
      expect(registry.pickServer('hero-defense')!.serverId).toBe('s2');
      expect(registry.pickServer('counter')).toBeNull();
      expect(registry.pickServer('cookie')).toBeNull();
    });

    it('leaves other servers unchanged when deregistering one', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      registry.register('s2', '127.0.0.2', 8081, 'hero-defense');
      registry.deregister('s1');
      const entry = registry.pickServer('hero-defense');
      expect(entry!.serverId).toBe('s2');
    });

    it('is idempotent when serverId not found', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      registry.deregister('unknown');
      expect(registry.pickServer('hero-defense')).not.toBeNull();
    });
  });

  describe('listAllServers', () => {
    it('returns all entries with isStale', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      registry.register('s2', '127.0.0.1', 8081, 'hero-defense');
      const list = registry.listAllServers();
      expect(list).toHaveLength(2);
      expect(list[0]).toMatchObject({ serverId: 's1', landType: 'hero-defense', isStale: false });
      expect(list[1]).toMatchObject({ serverId: 's2', landType: 'hero-defense', isStale: false });
    });

    it('marks stale servers when lastSeenAt exceeds TTL', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      const cutoff = Date.now() - SERVER_TTL_MS - 1000;
      (registry as any).serversByLandType.get('hero-defense')![0].lastSeenAt = new Date(cutoff);
      const list = registry.listAllServers();
      expect(list).toHaveLength(1);
      expect(list[0].isStale).toBe(true);
    });

    it('returns empty array when no servers registered', () => {
      expect(registry.listAllServers()).toEqual([]);
    });
  });

  describe('pickServer', () => {
    it('returns null when no servers registered', () => {
      expect(registry.pickServer('hero-defense')).toBeNull();
    });

    it('excludes stale servers beyond TTL', () => {
      registry.register('s1', '127.0.0.1', 8080, 'hero-defense');
      const cutoff = Date.now() - SERVER_TTL_MS - 1000;
      (registry as any).serversByLandType.get('hero-defense')![0].lastSeenAt = new Date(cutoff);
      expect(registry.pickServer('hero-defense')).toBeNull();
    });
  });
});
