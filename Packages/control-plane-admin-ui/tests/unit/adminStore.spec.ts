import { describe, it, expect, vi, beforeEach } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { useAdminStore } from '../../src/stores/admin'
import * as adminApi from '../../src/api/adminApi'

vi.mock('../../src/api/adminApi')

describe('adminStore', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.mocked(adminApi.getServers).mockResolvedValue({ servers: [] })
    vi.mocked(adminApi.getQueueSummary).mockResolvedValue({
      queueKeys: [],
      byQueueKey: {},
    })
  })

  it('fetchServers populates servers', async () => {
    vi.mocked(adminApi.getServers).mockResolvedValue({
      servers: [{ serverId: 's1', host: '127.0.0.1', port: 8080, landType: 'hero-defense', registeredAt: '', lastSeenAt: '', isStale: false }],
    })
    const store = useAdminStore()
    await store.fetchServers()
    expect(store.servers).toHaveLength(1)
    expect(store.servers[0].serverId).toBe('s1')
  })

  it('fetchQueueSummary populates queueSummary', async () => {
    vi.mocked(adminApi.getQueueSummary).mockResolvedValue({
      queueKeys: ['standard:asia'],
      byQueueKey: { 'standard:asia': { queuedCount: 3 } },
    })
    const store = useAdminStore()
    await store.fetchQueueSummary()
    expect(store.queueSummary?.queueKeys).toEqual(['standard:asia'])
    expect(store.queueSummary?.byQueueKey['standard:asia'].queuedCount).toBe(3)
  })

  it('fetchAll populates both', async () => {
    vi.mocked(adminApi.getServers).mockResolvedValue({
      servers: [{ serverId: 's1', host: 'x', port: 80, landType: 'l', registeredAt: '', lastSeenAt: '', isStale: false }],
    })
    vi.mocked(adminApi.getQueueSummary).mockResolvedValue({
      queueKeys: ['k1'],
      byQueueKey: { k1: { queuedCount: 1 } },
    })
    const store = useAdminStore()
    await store.fetchAll()
    expect(store.servers).toHaveLength(1)
    expect(store.queueSummary?.queueKeys).toEqual(['k1'])
  })
})
