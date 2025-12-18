#!/usr/bin/env node

// Lightweight CLI entry for @swiftstatetree/sdk codegen.

import { resolve } from 'node:path'
import { runCodegen } from './codegen/index.js'

function printHelp(): void {
  // Intentionally minimal help text to avoid localization issues.
  console.log('Usage:')
  console.log('  swiftstatetree-codegen codegen --input <schema.json|url> --output <dir> [--framework vue|react]')
  console.log('')
  console.log('Examples:')
  console.log('  npx @swiftstatetree/sdk codegen --input ./schema.json --output ./src/generated')
  console.log('  npx @swiftstatetree/sdk codegen --input https://example.com/schema --output ./src/generated --framework vue')
}

async function main(argv: string[]): Promise<void> {
  const [, , command, ...rest] = argv

  if (!command || command === '--help' || command === '-h') {
    printHelp()
    return
  }

  if (command !== 'codegen') {
    console.error(`Unknown command: ${command}`)
    printHelp()
    process.exitCode = 1
    return
  }

  let input: string | undefined
  let output: string | undefined
  let framework: 'vue' | 'react' | undefined

  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i]
    if (arg === '--input' && rest[i + 1]) {
      input = rest[++i]
    } else if (arg === '--output' && rest[i + 1]) {
      output = rest[++i]
    } else if (arg === '--framework' && rest[i + 1]) {
      const fw = rest[++i]
      if (fw === 'vue' || fw === 'react') {
        framework = fw
      } else {
        console.error(`Unknown framework: ${fw}. Supported: vue, react`)
        process.exitCode = 1
        return
      }
    }
  }

  if (!input || !output) {
    console.error('Missing required arguments: --input and --output are required.')
    printHelp()
    process.exitCode = 1
    return
  }

  const resolvedOutput = resolve(process.cwd(), output)

  try {
    await runCodegen({
      input,
      outputDir: resolvedOutput,
      framework
    })
  } catch (error) {
    console.error('Codegen failed:', (error as Error).message)
    process.exitCode = 1
  }
}

// eslint-disable-next-line @typescript-eslint/no-floating-promises
main(process.argv)

