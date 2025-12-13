import chalk from 'chalk'

export interface Schema {
  version: string
  defs: Record<string, any>
  lands: Record<string, LandDefinition>
}

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

export async function fetchSchema(baseUrl: string): Promise<Schema> {
  const url = baseUrl.replace(/^ws:/, 'http:').replace(/^wss:/, 'https:')
  const schemaUrl = `${url}/schema`
  
  try {
    const response = await fetch(schemaUrl)
    if (!response.ok) {
      throw new Error(`Failed to fetch schema: ${response.status} ${response.statusText}`)
    }
    const schema = await response.json() as Schema
    return schema
  } catch (error) {
    throw new Error(`Failed to fetch schema from ${schemaUrl}: ${error}`)
  }
}

export function printSchema(schema: Schema) {
  console.log(chalk.blue(`\n📋 Schema Version: ${schema.version}`))
  console.log(chalk.blue(`\n🏞️  Lands (${Object.keys(schema.lands).length}):`))
  
  for (const [landID, land] of Object.entries(schema.lands)) {
    console.log(chalk.cyan(`  - ${landID}`))
    console.log(chalk.gray(`    State Type: ${land.stateType}`))
    
    if (land.actions && Object.keys(land.actions).length > 0) {
      console.log(chalk.yellow(`    Actions (${Object.keys(land.actions).length}):`))
      for (const actionID of Object.keys(land.actions)) {
        console.log(chalk.gray(`      • ${actionID}`))
      }
    }
    
    if (land.clientEvents && Object.keys(land.clientEvents).length > 0) {
      console.log(chalk.magenta(`    Client Events (${Object.keys(land.clientEvents).length}):`))
      for (const eventID of Object.keys(land.clientEvents)) {
        console.log(chalk.gray(`      • ${eventID}`))
      }
    }
    
    if (land.events && Object.keys(land.events).length > 0) {
      console.log(chalk.green(`    Server Events (${Object.keys(land.events).length}):`))
      for (const eventID of Object.keys(land.events)) {
        console.log(chalk.gray(`      • ${eventID}`))
      }
    }
  }
  
  console.log(chalk.blue(`\n📚 Type Definitions (${Object.keys(schema.defs).length}):`))
  const defKeys = Object.keys(schema.defs).slice(0, 10)
  for (const defKey of defKeys) {
    console.log(chalk.gray(`  • ${defKey}`))
  }
  if (Object.keys(schema.defs).length > 10) {
    console.log(chalk.gray(`  ... and ${Object.keys(schema.defs).length - 10} more`))
  }
  console.log()
}

