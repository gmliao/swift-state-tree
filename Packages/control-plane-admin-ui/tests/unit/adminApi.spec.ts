import { describe, it, expect, vi, beforeEach } from 'vitest'
import { getServers, getQueueSummary } from '../../src/api/adminApi'

describe('adminApi', () => {
  beforeEach(() => {
    vi.stubGlobal('fetch', vi.fn())
  })

  it('getServers returns servers on 200', async () => {
    const mock = vi.mocked(fetch)
    mock.mockResolvedValueOnce({
      ok: true,
      json: () => Promise.resolve({ servers: [{ serverId: 's1' }] }),
    } as Response)

    const res = await getServers()
    expect(res.servers).toHaveLength(1)
    expect(res.servers[0].serverId).toBe('s1')
    expect(mock).toHaveBeenCalledWith(expect.stringContaining('/v1/admin/servers'))
  })

  it('getServers throws on non-ok', async () => {
    vi.mocked(fetch).mockResolvedValueOnce({ ok: false, status: 500 } as Response)
    await expect(getServers()).rejects.toThrow('getServers failed: 500')
  })

  it('getQueueSummary returns summary on 200', async () => {
    vi.mocked(fetch).mockResolvedValueOnce({
      ok: true,
      json: () =>
        Promise.resolve({
          queueKeys: ['k1'],
          byQueueKey: { k1: { queuedCount: 2 } },
        }),
    } as Response)

    const res = await getQueueSummary()
    expect(res.queueKeys).toEqual(['k1'])
    expect(res.byQueueKey.k1.queuedCount).toBe(2)
  })
})
