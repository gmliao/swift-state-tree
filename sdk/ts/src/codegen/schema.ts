// Schema model and loader utilities for TypeScript codegen.
// NOTE: This mirrors docs/protocol/SCHEMA_DEFINITION.md (TS section) and adds minimal helpers.

export interface LandDefinition {
  stateType: string
  actions?: Record<string, { $ref: string }>
  clientEvents?: Record<string, { $ref: string }>
  events?: Record<string, { $ref: string }>
  sync?: {
    snapshot?: { $ref: string }
    diff?: { $ref: string }
  }
}

export interface SchemaDef {
  type?: string
  properties?: Record<string, SchemaProperty>
  required?: readonly string[]
  items?: SchemaDef
  additionalProperties?: SchemaDef | boolean
  $ref?: string
  'x-stateTree'?: {
    nodeKind?: string
    sync?: {
      policy?: string
    }
  }
  // Extra fields from JSON Schema that we do not care about for v1 are ignored.
}

export interface SchemaProperty {
  type?: string
  properties?: Record<string, SchemaProperty>
  items?: SchemaDef
  additionalProperties?: SchemaDef | boolean
  $ref?: string
  'x-stateTree'?: {
    nodeKind?: string
    sync?: {
      policy?: string
    }
  }
}

export interface ProtocolSchema {
  version: string
  defs: Record<string, SchemaDef>
  lands: Record<string, LandDefinition>
}

export type SchemaSource = string

export interface LoadedSchema {
  schema: ProtocolSchema
  /**
   * Original input, used only for error messages or diagnostics.
   */
  source: SchemaSource
}

/**
 * Determine whether a given input should be treated as an HTTP(S) URL.
 */
export function isHttpUrl(input: string): boolean {
  return input.startsWith('http://') || input.startsWith('https://')
}

/**
 * Load a ProtocolSchema from either a local JSON file path or an HTTP(S) URL.
 *
 * This function is intentionally very small and synchronous in typing (returns Promise)
 * so that callers can easily plug it into a CLI or other async workflows.
 */
export async function loadSchema(input: SchemaSource): Promise<LoadedSchema> {
  const raw = isHttpUrl(input) ? await loadSchemaFromHttp(input) : await loadSchemaFromFile(input)
  let parsed: unknown

  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    throw new Error(`Failed to parse schema JSON from "${input}": ${(error as Error).message}`)
  }

  if (!isProtocolSchema(parsed)) {
    throw new Error(`Invalid schema format from "${input}": missing required fields "version", "defs", or "lands"`)
  }

  return {
    schema: parsed,
    source: input
  }
}

async function loadSchemaFromFile(path: string): Promise<string> {
  // Node.js dynamic import keeps browser bundle clean.
  const fs = await import('node:fs/promises')
  try {
    const buffer = await fs.readFile(path)
    return buffer.toString('utf8')
  } catch (error) {
    throw new Error(`Failed to read schema file "${path}": ${(error as Error).message}`)
  }
}

async function loadSchemaFromHttp(url: string): Promise<string> {
  // Node 18+ has global fetch; for older runtimes user should polyfill fetch.
  if (typeof fetch !== 'function') {
    throw new Error('Global "fetch" is not available. Please run codegen on Node 18+ or provide a fetch polyfill.')
  }

  const response = await fetch(url, {
    method: 'GET',
    headers: {
      accept: 'application/json'
    }
  })

  if (!response.ok) {
    throw new Error(`Failed to fetch schema from "${url}": ${response.status} ${response.statusText}`)
  }

  return await response.text()
}

function isProtocolSchema(value: unknown): value is ProtocolSchema {
  if (!value || typeof value !== 'object') return false
  const v = value as any
  return typeof v.version === 'string' && typeof v.defs === 'object' && typeof v.lands === 'object'
}
