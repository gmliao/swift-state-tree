// Small file utilities for codegen outputs.

import { dirname } from 'node:path'
import { mkdir, writeFile as fsWriteFile } from 'node:fs/promises'

/**
 * Ensure the parent directory of the given file path exists.
 */
export async function ensureDirectoryForFile(filePath: string): Promise<void> {
  const dir = dirname(filePath)
  await mkdir(dir, { recursive: true })
}

/**
 * Write a file, creating parent directories if needed.
 */
export async function writeFileRecursive(filePath: string, contents: string): Promise<void> {
  await ensureDirectoryForFile(filePath)
  await fsWriteFile(filePath, contents, 'utf8')
}

