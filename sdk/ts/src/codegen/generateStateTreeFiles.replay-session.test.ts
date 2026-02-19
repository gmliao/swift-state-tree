import { mkdtemp, readFile, access } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { generateStateTreeFiles } from './generateStateTreeFiles'
import type { ProtocolSchema } from './schema'

function makeSchema(withReplay: boolean): ProtocolSchema {
  const lands: ProtocolSchema['lands'] = {
    'hero-defense': {
      stateType: 'HeroDefenseState',
      actions: {},
      clientEvents: {},
      events: {}
    }
  }

  if (withReplay) {
    lands['hero-defense-replay'] = {
      stateType: 'HeroDefenseState',
      actions: {},
      clientEvents: {},
      events: {}
    }
  }

  return {
    version: '1.0.0',
    schemaHash: 'test-hash',
    defs: {
      HeroDefenseState: {
        type: 'object',
        properties: {}
      }
    },
    lands
  }
}

describe('generateStateTreeFiles replay session composable', () => {
  it('generates use<Land>Session composable when replay counterpart exists', async () => {
    const outputDir = await mkdtemp(join(tmpdir(), 'sst-codegen-replay-session-'))
    await generateStateTreeFiles(makeSchema(true), outputDir, 'vue')

    const sessionFile = join(outputDir, 'hero-defense', 'useHeroDefenseSession.ts')
    const sessionSource = await readFile(sessionFile, 'utf8')

    expect(sessionSource).toContain('export function useHeroDefenseSession()')
    expect(sessionSource).toContain('connectReplay')
    expect(sessionSource).toContain('switchToReplay')
    expect(sessionSource).toContain('switchToLive')
    expect(sessionSource).toContain("import { useHeroDefense } from './useHeroDefense.js'")
    expect(sessionSource).toContain("import { useHeroDefenseReplay } from '../hero-defense-replay/useHeroDefenseReplay.js'")

    // Backward compatibility: existing composable is still generated.
    const legacyComposable = join(outputDir, 'hero-defense', 'useHeroDefense.ts')
    const legacySource = await readFile(legacyComposable, 'utf8')
    expect(legacySource).toContain('export function useHeroDefense()')
  })

  it('does not generate session composable when replay counterpart is absent', async () => {
    const outputDir = await mkdtemp(join(tmpdir(), 'sst-codegen-replay-session-none-'))
    await generateStateTreeFiles(makeSchema(false), outputDir, 'vue')

    const sessionFile = join(outputDir, 'hero-defense', 'useHeroDefenseSession.ts')
    await expect(access(sessionFile)).rejects.toThrow()
  })
})
