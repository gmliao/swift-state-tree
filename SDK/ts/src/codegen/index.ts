import { join } from 'node:path'
import { loadSchema } from './schema.js'
import { generateSchemaTs } from './generateSchemaFile.js'
import { generateDefsTs } from './generateDefsFile.js'
import { generateStateTreeFiles } from './generateStateTreeFiles.js'
import { writeFileRecursive } from './writeFile.js'

export type Framework = 'vue' | 'react'
export type TestFramework = 'vitest' | 'jest'

export interface CodegenOptions {
  /**
   * Input schema source. Can be a file path or an HTTP(S) URL.
   */
  input: string
  /**
   * Output directory where generated files will be written.
   * Typically something like "./src/generated".
   */
  outputDir: string
  /**
   * Optional framework-specific helper generation.
   * If specified, generates framework-specific composable/hook helpers.
   * - 'vue': Generates Vue composable (useDemoGame.ts)
   * - 'react': Generates React hook (useDemoGame.ts) - future support
   * - undefined: Only generates framework-agnostic StateTree class
   */
  framework?: Framework
  /**
   * Optional test framework for generating test helpers.
   * If specified, generates test utilities and mock helpers.
   * - 'vitest': Generates Vitest-compatible test helpers
   * - 'jest': Generates Jest-compatible test helpers
   * - undefined: Only generates basic mock utilities (framework-agnostic)
   */
  testFramework?: TestFramework
}

export async function runCodegen(options: CodegenOptions): Promise<void> {
  const { input, outputDir } = options

  const loaded = await loadSchema(input)
  const schema = loaded.schema

  // Top-level files
  const schemaTs = generateSchemaTs(schema)
  const defsTs = generateDefsTs(schema)

  const schemaPath = join(outputDir, 'schema.ts')
  const defsPath = join(outputDir, 'defs.ts')

  await writeFileRecursive(schemaPath, schemaTs)
  await writeFileRecursive(defsPath, defsTs)

  // Per-land wrappers
  await generateStateTreeFiles(schema, outputDir, options.framework, options.testFramework)
}

