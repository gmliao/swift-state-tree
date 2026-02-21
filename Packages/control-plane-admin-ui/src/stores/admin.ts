import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { ServerEntry, QueueSummaryResponse } from '../api/adminApi'
import { getServers, getQueueSummary } from '../api/adminApi'

export const useAdminStore = defineStore('admin', () => {
  const servers = ref<ServerEntry[]>([])
  const queueSummary = ref<QueueSummaryResponse | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchServers() {
    loading.value = true
    error.value = null
    try {
      const res = await getServers()
      servers.value = res.servers
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  async function fetchQueueSummary() {
    loading.value = true
    error.value = null
    try {
      queueSummary.value = await getQueueSummary()
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      const [serversRes, queueRes] = await Promise.all([
        getServers(),
        getQueueSummary(),
      ])
      servers.value = serversRes.servers
      queueSummary.value = queueRes
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  return {
    servers,
    queueSummary,
    loading,
    error,
    fetchServers,
    fetchQueueSummary,
    fetchAll,
  }
})
