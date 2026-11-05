import { mkdtemp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { generateStateTreeFiles } from './generateStateTreeFiles'
import type { ProtocolSchema } from './schema'

function schemaWithEvents(events: ProtocolSchema['lands'][string]['events']): ProtocolSchema {
  return {
    version: '1.0.0',
    schemaHash: 'test-hash',
    defs: {
      TestState: { type: 'object', properties: {} },
      PingEvent: { type: 'object', properties: {} }
    },
    lands: {
      'test-land': { stateType: 'TestState', actions: {}, clientEvents: {}, events }
    }
  }
}

async function indexSource(schema: ProtocolSchema): Promise<string> {
  const outputDir = await mkdtemp(join(tmpdir(), 'sst-codegen-event-imports-'))
  await generateStateTreeFiles(schema, outputDir, 'vue')
  return readFile(join(outputDir, 'test-land', 'index.ts'), 'utf8')
}

describe('generateStateTreeFiles event type imports', () => {
  it('does not import the event subscription types for a land without server events', async () => {
    // Unused type imports fail a client build with noUnusedLocals.
    const source = await indexSource(schemaWithEvents({}))
    expect(source).not.toMatch(/\bEventSubscription\b/)
    expect(source).not.toMatch(/\bEventHandler\b/)
  })

  it('imports and uses them when the land has server events', async () => {
    const source = await indexSource(schemaWithEvents({ Ping: { $ref: '#/defs/PingEvent' } }))
    expect(source).toMatch(/import type \{[^}]*EventSubscription, EventHandler[^}]*\} from '.\/bindings'/)
    expect(source).toContain('EventSubscription<')
  })
})
