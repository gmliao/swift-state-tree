export interface SchemaDef {
  type?: string
  properties?: Record<string, SchemaProperty>
  required?: string[]
  items?: SchemaDef
  additionalProperties?: SchemaDef | boolean
  'x-stateTree'?: {
    nodeKind?: string
    sync?: {
      policy?: string
    }
  }
}

export interface SchemaProperty {
  type?: string
  properties?: Record<string, SchemaProperty>
  items?: SchemaDef
  additionalProperties?: SchemaDef | boolean
  $ref?: string // For $ref types (e.g., deterministic math types)
  'x-stateTree'?: {
    nodeKind?: string
    sync?: {
      policy?: string
    }
  }
}

export interface LandDefinition {
  actions?: Record<string, { $ref: string }>
  clientEvents?: Record<string, { $ref: string }>
  events?: Record<string, { $ref: string }>
  stateType: string
  sync?: {
    snapshot?: { $ref: string }
    diff?: { $ref: string }
  }
}

export interface Schema {
  version: string
  defs: Record<string, SchemaDef>
  lands: Record<string, LandDefinition>
}

