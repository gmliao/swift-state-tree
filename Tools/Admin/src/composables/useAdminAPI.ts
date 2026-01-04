import { ref } from 'vue'
import type { AdminConfig, AdminAPIResponse, LandInfo, SystemStats } from '../types/admin'

export function useAdminAPI() {
  const loading = ref(false)
  const error = ref<string | null>(null)

  /**
   * Make an authenticated admin API request
   */
  async function adminRequest<T>(
    url: string,
    method: string = 'GET',
    config: AdminConfig
  ): Promise<AdminAPIResponse<T>> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    }

    // Add authentication (prefer API Key over token)
    if (config.apiKey && config.apiKey.trim()) {
      headers['X-API-Key'] = config.apiKey.trim()
    } else if (config.token && config.token.trim()) {
      headers['Authorization'] = `Bearer ${config.token.trim()}`
    }

    // Debug: log request details in development
    if (import.meta.env.DEV) {
      console.log('[AdminAPI] Request:', { 
        method, 
        url, 
        hasApiKey: !!config.apiKey, 
        hasToken: !!config.token,
        apiKey: config.apiKey,
        headers: Object.keys(headers).reduce((acc, key) => {
          acc[key] = headers[key]
          return acc
        }, {} as Record<string, string>)
      })
    }

    try {
      const response = await fetch(url, {
        method,
        headers,
      })
      
      // Debug: log response in development
      if (import.meta.env.DEV) {
        console.log('[AdminAPI] Response:', { status: response.status, statusText: response.statusText, url: response.url })
      }

      const json = await response.json() as AdminAPIResponse<T>

      if (!response.ok) {
        if (json.error) {
          throw new Error(json.error.message || `HTTP ${response.status}`)
        }
        
        if (response.status === 401) {
          throw new Error('Unauthorized: Invalid API key or token')
        } else if (response.status === 403) {
          throw new Error('Forbidden: Insufficient permissions')
        } else if (response.status === 404) {
          throw new Error('Not found: Resource does not exist')
        } else {
          throw new Error(`HTTP ${response.status}: ${response.statusText}`)
        }
      }

      return json
    } catch (err: any) {
      throw new Error(err.message || 'Request failed')
    }
  }

  /**
   * Get API base URL
   */
  function getApiBaseUrl(config: AdminConfig): string {
    return config.baseUrl.replace(/\/$/, '')
  }

  /**
   * List all lands
   */
  async function listLands(config: AdminConfig): Promise<string[]> {
    loading.value = true
    error.value = null
    
    try {
      const baseUrl = getApiBaseUrl(config)
      const url = `${baseUrl}/admin/lands`
      
      const response = await adminRequest<string[]>(url, 'GET', config)
      
      if (!response.success || !response.data) {
        throw new Error(response.error?.message || 'Failed to list lands')
      }
      
      return response.data
    } catch (err: any) {
      error.value = err.message
      throw err
    } finally {
      loading.value = false
    }
  }

  /**
   * Get land statistics
   */
  async function getLandStats(landID: string, config: AdminConfig): Promise<LandInfo | null> {
    loading.value = true
    error.value = null
    
    try {
      const baseUrl = getApiBaseUrl(config)
      // URL encode the landID for the path parameter
      const url = `${baseUrl}/admin/lands/${encodeURIComponent(landID)}`
      
      if (import.meta.env.DEV) {
        console.log('[AdminAPI] getLandStats:', { landID, url })
      }
      
      const response = await adminRequest<LandInfo>(url, 'GET', config)
      
      if (!response.success) {
        if (response.error?.code === 'NOT_FOUND') {
          return null
        }
        throw new Error(response.error?.message || 'Failed to get land stats')
      }
      
      return response.data || null
    } catch (err: any) {
      error.value = err.message
      throw err
    } finally {
      loading.value = false
    }
  }

  /**
   * Get system statistics
   */
  async function getSystemStats(config: AdminConfig): Promise<SystemStats> {
    loading.value = true
    error.value = null
    
    try {
      const baseUrl = getApiBaseUrl(config)
      const url = `${baseUrl}/admin/stats`
      
      const response = await adminRequest<SystemStats>(url, 'GET', config)
      
      if (!response.success || !response.data) {
        throw new Error(response.error?.message || 'Failed to get system stats')
      }
      
      return response.data
    } catch (err: any) {
      error.value = err.message
      throw err
    } finally {
      loading.value = false
    }
  }

  /**
   * Delete a land
   */
  async function deleteLand(landID: string, config: AdminConfig): Promise<void> {
    loading.value = true
    error.value = null
    
    try {
      const baseUrl = getApiBaseUrl(config)
      // URL encode the landID for the path parameter
      const url = `${baseUrl}/admin/lands/${encodeURIComponent(landID)}`
      
      const response = await adminRequest(url, 'DELETE', config)
      
      if (!response.success) {
        throw new Error(response.error?.message || 'Failed to delete land')
      }
    } catch (err: any) {
      error.value = err.message
      throw err
    } finally {
      loading.value = false
    }
  }

  return {
    loading,
    error,
    listLands,
    getLandStats,
    getSystemStats,
    deleteLand,
  }
}
