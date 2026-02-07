import { writeFileSync, mkdtempSync, mkdirSync } from 'fs'
import { tmpdir } from 'os'
import { join, resolve } from 'path'
import { execFileSync } from 'child_process'
import chalk from 'chalk'
import { downloadReevaluationRecord } from './admin'

type Args = Record<string, string | boolean>

function parseArgs(argv: string[]): Args {
  const out: Args = {}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (!a.startsWith('--')) continue
    const key = a.slice(2)
    const next = argv[i + 1]
    if (!next || next.startsWith('--')) {
      out[key] = true
    } else {
      out[key] = next
      i++
    }
  }
  return out
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const wsUrl = (args['ws-url'] as string) ?? 'ws://localhost:8080/game/hero-defense'
  const adminUrl = (args['admin-url'] as string) ?? 'http://localhost:8080'
  const stateUpdateEncoding = (args['state-update-encoding'] as string) ?? 'messagepack'

  const apiKey = (process.env.HERO_DEFENSE_ADMIN_KEY || process.env.ADMIN_API_KEY || 'hero-defense-admin-key').trim()

  const landInstanceId = `reeval-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
  const landID = `hero-defense:${landInstanceId}`

  console.log(chalk.blue(`🏠 LandID: ${landID}`))
  console.log(chalk.blue(`🔌 WS: ${wsUrl}`))
  console.log(chalk.blue(`🛠️  Admin: ${adminUrl}`))

  // Drive a short live session using a specific scenario file.
  // We pass a full landID (contains ':') so the scenario runner uses it as-is.
  // NOTE: We use a single scenario file instead of the whole directory to avoid
  // a race condition where multiple clients join the same land in quick succession.
  // For lands with tick handlers, lifecycle events (OnJoin/OnLeave) are queued
  // and processed in the next tick, which can cause stale state in firstSync.
  console.log(chalk.blue('🎮 Running Hero Defense scenario...'))
  execFileSync(
    'npx',
    [
      'tsx',
      'src/cli.ts',
      'script',
      '-u',
      wsUrl,
      '-l',
      landID,
      '-s',
      'scenarios/game/test-hero-defense-shape-invariants.json',
      '--state-update-encoding',
      stateUpdateEncoding
    ],
    { cwd: resolve(process.cwd()), stdio: 'inherit' }
  )

  console.log(chalk.blue('📥 Downloading re-evaluation record...'))
  const record = await downloadReevaluationRecord({
    url: adminUrl,
    apiKey,
    landID
  })

  const projectRoot = resolve(process.cwd(), '..', '..')
  const parentDir = join(projectRoot, 'tmp', 'e2e')
  mkdirSync(parentDir, { recursive: true })
  const dir = mkdtempSync(join(parentDir, 'swiftstatetree-reeval-game-'))
  const recordPath = resolve(dir, `hero-defense-${landInstanceId}.reeval.json`)
  writeFileSync(recordPath, JSON.stringify(record, null, 2), 'utf-8')
  console.log(chalk.green(`✅ Saved record: ${recordPath}`))

  // Offline verify using the GameDemo reevaluation runner.
  const gameDemoDir = join(projectRoot, 'Examples', 'GameDemo')
  console.log(chalk.blue('🧪 Offline verify via GameDemo ReevaluationRunner...'))
  execFileSync('swift', ['run', 'ReevaluationRunner', '--input', recordPath, '--verify'], {
    cwd: gameDemoDir,
    stdio: 'inherit'
  })

  console.log(chalk.green('✅ Hero Defense re-evaluation record+verify passed (messagepack)'))
}

main().catch(err => {
  console.error(chalk.red(`❌ Hero Defense re-evaluation E2E failed: ${err?.message || err}`))
  process.exit(1)
})

