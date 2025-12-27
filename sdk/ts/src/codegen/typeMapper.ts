// JSON Schema → TypeScript type mapper used by codegen.
// This focuses on the subset described in docs/protocol/SCHEMA_DEFINITION.md.

import type { SchemaDef, SchemaProperty } from './schema.js'

export interface TypeMapperContext {
  /**
   * Known definition names from schema.defs (e.g. "DemoGameState").
   * Used only for validation and nicer error messages in v1.
   */
  readonly knownDefs: ReadonlySet<string>
}

/**
 * Map a top-level SchemaDef (from defs) to a TypeScript type expression.
 */
export function mapSchemaDefToTsType(def: SchemaDef, ctx: TypeMapperContext): string {
  return mapSchemaLikeToTsType(def, ctx)
}

function mapSchemaLikeToTsType(node: SchemaDef | SchemaProperty, ctx: TypeMapperContext): string {
  // Handle $ref first
  if (node.$ref) {
    const refName = resolveRefName(node.$ref)
    // In v1 we do not fail if refName is unknown, but we keep the name as is.
    return refName
  }

  const type = node.type

  if (!type) {
    // No explicit type and no $ref. This is outside of the supported subset.
    // We fallback to any to keep codegen practical for v1.
    return 'any'
  }

  switch (type) {
    case 'string':
      return 'string'
    case 'integer':
      return 'number'
    case 'number':
      return 'number'
    case 'boolean':
      return 'boolean'
    case 'null':
      return 'null'
    case 'array':
      return mapArrayToTsType(node, ctx)
    case 'object':
      return mapObjectToTsType(node, ctx)
    default:
      // Unknown or unsupported type, fall back to any.
      return 'any'
  }
}

function mapArrayToTsType(node: SchemaDef | SchemaProperty, ctx: TypeMapperContext): string {
  if (!node.items) {
    return 'any[]'
  }
  const itemType = mapSchemaLikeToTsType(node.items, ctx)
  return `${itemType}[]`
}

function mapObjectToTsType(node: SchemaDef | SchemaProperty, ctx: TypeMapperContext): string {
  const properties = node.properties ?? {}
  // `required` is only defined on SchemaDef in the formal model, but for our
  // purposes treating it as an optional field on both is sufficient.
  const requiredNames = (node as SchemaDef).required ?? []
  const required = new Set(requiredNames)

  const entries: string[] = []

  for (const [name, propSchema] of Object.entries(properties)) {
    const tsType = mapSchemaLikeToTsType(propSchema, ctx)
    const optional = required.has(name) ? '' : '?'
    entries.push(`${escapePropertyName(name)}${optional}: ${tsType}`)
  }

  let additionalPart = ''

  if (node.additionalProperties) {
    if (node.additionalProperties === true) {
      additionalPart = '[key: string]: any'
    } else if (typeof node.additionalProperties === 'object') {
      const valueType = mapSchemaLikeToTsType(node.additionalProperties, ctx)
      additionalPart = `[key: string]: ${valueType}`
    }
  }

  const allEntries = [...entries]
  if (additionalPart) {
    allEntries.push(additionalPart)
  }

  if (allEntries.length === 0) {
    return '{ [key: string]: any }'
  }

  return `{ ${allEntries.join('; ')} }`
}

/**
 * Extract the definition name from a $ref string like "#/defs/PlayerState".
 */
export function resolveRefName(ref: string): string {
  // Very small, schema-specific resolver: we only care about "#/defs/<Name>".
  const prefix = '#/defs/'
  if (ref.startsWith(prefix)) {
    return ref.slice(prefix.length)
  }
  // Fallback: return the raw string with non-identifier characters replaced.
  return ref.replace(/[^a-zA-Z0-9_$]/g, '_')
}

function escapePropertyName(name: string): string {
  // Use identifier directly if it is a simple JS identifier, otherwise quote it.
  if (/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(name)) {
    return name
  }
  return JSON.stringify(name)
}

