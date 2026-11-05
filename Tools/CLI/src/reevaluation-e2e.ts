import { writeFileSync, mkdtempSync } from 'fs'
import { tmpdir } from 'os'
import { join, resolve } from 'path'
import { execFileSync } from 'child_process'
import chalk from 'chalk'
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'
import { ChalkLogger } from './logger'
import { joinWithTimeout } from './join-timeout'
import { fetchSchema } from './schema'
import { downloadReevaluationRecord } from './admin'
import { assertSyncOutputCompared } from './sync-output-verdict'

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

function deriveSchemaBaseUrl(wsUrl: string): string {
  const url = new URL(wsUrl)
  const schemaProtocol = url.protocol === 'wss:' ? 'https:' : 'http:'
  return `${schemaProtocol}//${url.host}`
}

function buildTransportEncoding(stateUpdateEncoding?: string) {
  const normalized = (stateUpdateEncoding ?? 'auto').toLowerCase()

  if (normalized === 'messagepack' || normalized === 'msgpack') {
    return {
      message: 'messagepack',
      stateUpdate: 'opcodeJsonArray',
      stateUpdateDecoding: 'auto'
    } as const
  }

  if (normalized === 'opcodejsonarray') {
    return {
      message: 'opcodeJsonArray',
      stateUpdate: 'opcodeJsonArray',
      stateUpdateDecoding: 'opcodeJsonArray'
    } as const
  }

  return {
    message: 'json',
    stateUpdate: 'jsonObject',
    stateUpdateDecoding: 'jsonObject'
  } as const
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const wsUrl = (args['ws-url'] as string) ?? 'ws://localhost:8080/game/counter'
  const adminUrl = (args['admin-url'] as string) ?? 'http://localhost:8080'
  const landType = (args['land-type'] as string) ?? 'counter'
  const stateUpdateEncoding = (args['state-update-encoding'] as string) ?? 'auto'

  const apiKey = (process.env.DEMO_ADMIN_KEY || process.env.ADMIN_API_KEY || 'demo-admin-key').trim()

  const landInstanceId = `reeval-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
  const landID = `${landType}:${landInstanceId}`

  console.log(chalk.blue(`🏠 LandID: ${landID}`))
  console.log(chalk.blue(`🔌 WS: ${wsUrl}`))
  console.log(chalk.blue(`🛠️  Admin: ${adminUrl}`))

  const schemaBaseUrl = deriveSchemaBaseUrl(wsUrl)
  const schema = await fetchSchema(schemaBaseUrl)

  const logger = new ChalkLogger()
  const transportEncoding = buildTransportEncoding(stateUpdateEncoding)
  const runtime = new StateTreeRuntime({ logger, transportEncoding })

  await runtime.connect(wsUrl)
  const view = runtime.createView(landID, { schema: schema as any, logger })

  const joinResult = await joinWithTimeout(view, landID)
  if (!joinResult.success) {
    throw new Error(`Failed to join: ${joinResult.reason || 'Unknown reason'}`)
  }

  const joinedLandID = joinResult.landID || landID
  console.log(chalk.green(`✅ Joined: ${joinedLandID}`))

  // Drive a short live session: a few actions + time for ticks.
  for (let i = 0; i < 5; i++) {
    await view.sendAction('Increment', {})
    await new Promise(resolve => setTimeout(resolve, 150))
  }
  await new Promise(resolve => setTimeout(resolve, 500))

  await runtime.disconnect()

  console.log(chalk.blue(`📥 Downloading re-evaluation record...`))
  const record = await downloadReevaluationRecord({
    url: adminUrl,
    apiKey,
    landID: joinedLandID
  })

  const dir = mkdtempSync(join(tmpdir(), 'swiftstatetree-reeval-'))
  const recordPath = join(dir, `${landType}-${landInstanceId}.reeval.json`)
  writeFileSync(recordPath, JSON.stringify(record, null, 2), 'utf-8')
  console.log(chalk.green(`✅ Saved record: ${recordPath}`))

  // Run offline re-evaluation verify using the demo runner (Swift).
  const projectRoot = resolve(process.cwd(), '..', '..')
  const demoDir = join(projectRoot, 'Examples', 'Demo')
  console.log(chalk.blue(`🧪 Offline verify via ReevaluationRunner...`))
  const verifyOutput = execFileSync('swift', ['run', 'ReevaluationRunner', '--input', recordPath, '--verify'], {
    cwd: demoDir,
    stdio: ['inherit', 'pipe', 'inherit'],
    encoding: 'utf-8'
  })
  process.stdout.write(verifyOutput)
  // The replay must have compared sync outputs, not only found no mismatch.
  const syncOutput = assertSyncOutputCompared(verifyOutput)
  console.log(chalk.green(syncOutput.verdict === 'skipped'
    ? `✅ Sync output ${syncOutput.line} (expected with in-turn sync off)`
    : `✅ Sync output ${syncOutput.verdict}, every scope compared`))

  console.log(chalk.green('✅ Re-evaluation E2E record+verify passed'))
}

main().catch(err => {
  console.error(chalk.red(`❌ Re-evaluation E2E failed: ${err?.message || err}`))
  process.exit(1)
})

