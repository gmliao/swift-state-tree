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
  /// Path hashes for state update compression (hash → path pattern)
  pathHashes?: Record<string, number>
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
    atomic?: boolean
    optional?: boolean
    innerType?: string
    keyType?: string
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
    atomic?: boolean
    optional?: boolean
    innerType?: string
    keyType?: string
  }
}

export interface ProtocolSchema {
  version: string
  /** Deterministic hash of schema content for version verification */
  schemaHash: string
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

/**
 * Check if a type name represents an Optional type (e.g., "Optional<Position2>").
 * 
 * This function can also check a SchemaDef for the optional marker.
 * 
 * @param typeName - The type name to check, or a SchemaDef object
 * @param def - Optional SchemaDef to check for x-stateTree.optional marker
 * @returns true if the type is Optional
 */
export function isOptionalType(typeName: string | SchemaDef, def?: SchemaDef): boolean {
  // If first argument is a SchemaDef, check its metadata
  if (typeof typeName === 'object' && typeName !== null) {
    return typeName['x-stateTree']?.optional === true
  }
  
  // If def is provided, check its metadata first (preferred method)
  if (def && def['x-stateTree']?.optional === true) {
    return true
  }
  
  // Fallback to string matching for backward compatibility
  if (typeof typeName === 'string') {
    return typeName.startsWith('Optional<') && typeName.endsWith('>')
  }
  
  return false
}

/**
 * Unwrap an Optional type to get the inner type.
 * Returns the inner type name if it's an Optional, otherwise returns the original type name.
 * 
 * This function prioritizes the structured marker (x-stateTree.innerType) over string parsing.
 * 
 * @param typeName - The type name to unwrap
 * @param def - Optional SchemaDef to check for x-stateTree.innerType marker
 * @returns The inner type name, or the original type name if not Optional
 * 
 * @example
 * unwrapOptionalType("Optional<Position2>") // returns "Position2"
 * unwrapOptionalType("Position2") // returns "Position2"
 * unwrapOptionalType("Optional<Position2>", { 'x-stateTree': { innerType: 'Position2' } }) // returns "Position2"
 */
export function unwrapOptionalType(typeName: string, def?: SchemaDef): string {
  // If def is provided, check its metadata first (preferred method)
  if (def && def['x-stateTree']?.innerType) {
    return def['x-stateTree'].innerType!
  }
  
  // Fallback to string parsing for backward compatibility
  if (isOptionalType(typeName)) {
    const match = typeName.match(/^Optional<(.+)>$/)
    if (match && match[1]) {
      return match[1]
    }
  }
  return typeName
}
