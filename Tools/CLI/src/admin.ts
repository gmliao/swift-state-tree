import chalk from 'chalk'

export interface AdminOptions {
  url: string
  apiKey?: string
  token?: string
  landID?: string
}

export interface LandInfo {
  landID: string
  playerCount: number
  createdAt?: string
  lastActivityAt?: string  // Match server field name
}

export interface SystemStats {
  totalLands: number
  totalPlayers: number
}

export interface AdminAPIResponse<T = any> {
  success: boolean
  data?: T
  error?: {
    code: string
    message: string
    details?: Record<string, any>
  }
}

/**
 * Make an authenticated admin API request
 */
async function adminRequest(
  url: string,
  method: string,
  options: AdminOptions
): Promise<Response> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  }

  // Add authentication
  if (options.apiKey) {
    headers['X-API-Key'] = options.apiKey
  } else if (options.token) {
    headers['Authorization'] = `Bearer ${options.token}`
  }

  const response = await fetch(url, {
    method,
    headers,
  })

  // Try to parse as unified response format first
  if (!response.ok) {
    try {
      const errorResponse = await response.json() as AdminAPIResponse
      if (errorResponse.error) {
        throw new Error(errorResponse.error.message || `HTTP ${response.status}`)
      }
    } catch {
      // If parsing fails, fall back to status code
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

  return response
}

/**
 * List all lands
 */
export async function listLands(options: AdminOptions): Promise<string[]> {
  const baseUrl = options.url.replace(/\/$/, '')
  const url = `${baseUrl}/admin/lands`

  const response = await adminRequest(url, 'GET', options)
  const json = await response.json()
  
  // Support both unified format and legacy format (backward compatibility)
  if (json && typeof json === 'object' && 'success' in json) {
    const apiResponse = json as AdminAPIResponse<string[]>
    if (!apiResponse.success || !apiResponse.data) {
      throw new Error(apiResponse.error?.message || 'Failed to list lands')
    }
    return apiResponse.data
  } else {
    // Legacy format: direct array
    return json as string[]
  }
}

/**
 * Get land statistics
 */
export async function getLandStats(
  options: AdminOptions
): Promise<LandInfo | null> {
  if (!options.landID) {
    throw new Error('landID is required')
  }

  const baseUrl = options.url.replace(/\/$/, '')
  const url = `${baseUrl}/admin/lands/${encodeURIComponent(options.landID)}`

  const response = await adminRequest(url, 'GET', options)
  const json = await response.json()
  
  // Support both unified format and legacy format (backward compatibility)
  if (json && typeof json === 'object' && 'success' in json) {
    const apiResponse = json as AdminAPIResponse<LandInfo>
    if (!apiResponse.success) {
      if (apiResponse.error?.code === 'NOT_FOUND') {
        return null
      }
      throw new Error(apiResponse.error?.message || 'Failed to get land stats')
    }
    return apiResponse.data || null
  } else {
    // Legacy format: direct object
    return json as LandInfo
  }
}

/**
 * Get system statistics
 */
export async function getSystemStats(
  options: AdminOptions
): Promise<SystemStats> {
  const baseUrl = options.url.replace(/\/$/, '')
  const url = `${baseUrl}/admin/stats`

  const response = await adminRequest(url, 'GET', options)
  const json = await response.json()
  
  // Support both unified format and legacy format (backward compatibility)
  if (json && typeof json === 'object' && 'success' in json) {
    const apiResponse = json as AdminAPIResponse<SystemStats>
    if (!apiResponse.success || !apiResponse.data) {
      throw new Error(apiResponse.error?.message || 'Failed to get system stats')
    }
    return apiResponse.data
  } else {
    // Legacy format: direct object
    return json as SystemStats
  }
}

/**
 * Delete a land
 */
export async function deleteLand(options: AdminOptions): Promise<void> {
  if (!options.landID) {
    throw new Error('landID is required')
  }

  const baseUrl = options.url.replace(/\/$/, '')
  const url = `${baseUrl}/admin/lands/${encodeURIComponent(options.landID)}`

  const response = await adminRequest(url, 'DELETE', options)
  
  // DELETE may return empty body or unified format
  try {
    const text = await response.text()
    if (text) {
      const json = JSON.parse(text)
      if (json && typeof json === 'object' && 'success' in json) {
        const apiResponse = json as AdminAPIResponse
        if (!apiResponse.success) {
          throw new Error(apiResponse.error?.message || 'Failed to delete land')
        }
      }
    }
  } catch {
    // Empty response or non-JSON is fine for DELETE
  }
}

/**
 * Download a land's re-evaluation record (JSON).
 */
export async function downloadReevaluationRecord(options: AdminOptions): Promise<any> {
  if (!options.landID) {
    throw new Error('landID is required')
  }

  const baseUrl = options.url.replace(/\/$/, '')
  const url = `${baseUrl}/admin/lands/${encodeURIComponent(options.landID)}/reevaluation-record`

  const response = await adminRequest(url, 'GET', options)
  return await response.json()
}

/**
 * Print formatted land list
 */
export function printLandList(lands: string[]): void {
  if (lands.length === 0) {
    console.log(chalk.yellow('  No lands found'))
    return
  }

  console.log(chalk.blue(`  Found ${lands.length} land(s):\n`))
  lands.forEach((landID, index) => {
    console.log(chalk.cyan(`  ${index + 1}. ${landID}`))
  })
}

/**
 * Print formatted land statistics
 */
export function printLandStats(stats: LandInfo): void {
  console.log(chalk.blue(`\n  Land: ${chalk.bold(stats.landID)}`))
  console.log(chalk.gray(`  ──────────────────────────`))
  console.log(chalk.white(`  Players: ${chalk.bold(stats.playerCount)}`))
  if (stats.createdAt) {
    console.log(chalk.white(`  Created: ${chalk.bold(stats.createdAt)}`))
  }
  if (stats.lastActivityAt) {
    console.log(chalk.white(`  Last Activity: ${chalk.bold(stats.lastActivityAt)}`))
  }
}

/**
 * Print formatted system statistics
 */
export function printSystemStats(stats: SystemStats): void {
  console.log(chalk.blue(`\n  System Statistics`))
  console.log(chalk.gray(`  ──────────────────────────`))
  console.log(chalk.white(`  Total Lands: ${chalk.bold(stats.totalLands)}`))
  console.log(chalk.white(`  Total Players: ${chalk.bold(stats.totalPlayers)}`))
}
