/**
 * E2E test for api + queue-worker split deployment (external servers).
 * Auto-starts servers when E2E_API_PORT is not set (e.g. npm run test:e2e).
 * Or use ./test/scripts/e2e-split.sh for manual control.
 */
import { spawn, execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import { WebSocket } from 'ws';

const AUTO_API_PORT = '3020';
const AUTO_WORKER_PORT = '3021';

function getApiPort(): string {
  return process.env.E2E_API_PORT ?? AUTO_API_PORT;
}
function getWorkerPort(): string {
  return process.env.E2E_WORKER_PORT ?? AUTO_WORKER_PORT;
}
function getApiBase(): string {
  return `http://127.0.0.1:${getApiPort()}`;
}
function getWorkerBase(): string {
  return `http://127.0.0.1:${getWorkerPort()}`;
}
function getWsUrl(): string {
  return `ws://127.0.0.1:${getApiPort()}/realtime`;
}

async function httpPost(
  base: string,
  urlPath: string,
  body: object,
): Promise<{ status: number; data: unknown }> {
  const res = await fetch(`${base}${urlPath}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = res.ok ? await res.json().catch(() => ({})) : {};
  return { status: res.status, data };
}

async function httpGet(base: string, urlPath: string): Promise<{ status: number; data: unknown }> {
  const res = await fetch(`${base}${urlPath}`);
  const data = res.ok ? await res.json().catch(() => ({})) : {};
  return { status: res.status, data };
}

async function waitForAssignment(
  ticketId: string,
  maxAttempts = 120,
): Promise<{ status: string; assignment?: unknown }> {
  for (let i = 0; i < maxAttempts; i++) {
    const { data } = await httpGet(getApiBase(), `/v1/matchmaking/status/${ticketId}`);
    const status = (data as { status?: string }).status;
    const assignment = (data as { assignment?: unknown }).assignment;
    if (status === 'assigned') return { status: 'assigned', assignment };
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error('Timed out waiting for assignment');
}

function killPort(port: string): void {
  try {
    execSync(`lsof -ti:${port} | xargs kill -9 2>/dev/null || true`, { stdio: 'ignore' });
  } catch {
    // ignore
  }
}

describe('Matchmaking split roles (external processes) E2E', () => {
  let workerProc: ReturnType<typeof spawn> | null = null;
  let apiProc: ReturnType<typeof spawn> | null = null;
  let didSpawn = false;

  beforeAll(async () => {
    if (process.env.E2E_API_PORT) {
      return;
    }
    didSpawn = true;
    const projectRoot = path.join(__dirname, '..');
    const altPath = path.join(projectRoot, 'dist', 'src', 'main.js');
    const mainPath = path.join(projectRoot, 'dist', 'main.js');
    let nodePath = fs.existsSync(altPath) ? altPath : mainPath;
    if (!fs.existsSync(nodePath)) {
      try {
        execSync('npm run build --silent', { cwd: projectRoot, stdio: 'pipe' });
      } catch (e) {
        throw new Error(
          `Build failed. Run "npm run build" in Packages/control-plane first. ${e instanceof Error ? e.message : String(e)}`,
        );
      }
      nodePath = fs.existsSync(altPath) ? altPath : mainPath;
    }
    const env = {
      ...process.env,
      REDIS_HOST: '127.0.0.1',
      REDIS_PORT: '6379',
      MATCHMAKING_MIN_WAIT_MS: '0',
    };
    killPort(AUTO_WORKER_PORT);
    killPort(AUTO_API_PORT);
    await new Promise((r) => setTimeout(r, 500));
    workerProc = spawn('node', [nodePath], {
      cwd: projectRoot,
      env: { ...env, MATCHMAKING_ROLE: 'queue-worker', PORT: AUTO_WORKER_PORT },
      stdio: 'pipe',
    });
    await new Promise((r) => setTimeout(r, 2000));
    apiProc = spawn('node', [nodePath], {
      cwd: projectRoot,
      env: { ...env, MATCHMAKING_ROLE: 'api', PORT: AUTO_API_PORT },
      stdio: 'pipe',
    });
    process.env.E2E_API_PORT = AUTO_API_PORT;
    process.env.E2E_WORKER_PORT = AUTO_WORKER_PORT;
    for (let i = 0; i < 30; i++) {
      try {
        const [w, a] = await Promise.all([
          fetch(`http://127.0.0.1:${AUTO_WORKER_PORT}/health`).then((r) => r.ok),
          fetch(`http://127.0.0.1:${AUTO_API_PORT}/health`).then((r) => r.ok),
        ]);
        if (w && a) break;
      } catch {
        // retry
      }
      if (i === 29) throw new Error('Timeout waiting for servers');
      await new Promise((r) => setTimeout(r, 500));
    }
    await new Promise((r) => setTimeout(r, 5000));
  }, 30000);

  afterAll(async () => {
    if (!didSpawn) return;
    if (apiProc) apiProc.kill('SIGTERM');
    if (workerProc) workerProc.kill('SIGTERM');
    await new Promise((r) => setTimeout(r, 500));
  });

  it('enqueue via API, process by queue-worker, status via API', async () => {
    const { status: regStatus } = await httpPost(getWorkerBase(), '/v1/provisioning/servers/register', {
      serverId: 'game-split-ext-1',
      host: '127.0.0.1',
      port: 8080,
      landType: 'standard',
    });
    expect(regStatus).toBe(200);

    const { status: enqStatus, data: enqData } = await httpPost(
      getApiBase(),
      '/v1/matchmaking/enqueue',
      {
        groupId: 'solo-split-ext-p1',
        queueKey: 'standard:asia',
        members: ['p1'],
        groupSize: 1,
      },
    );
    expect(enqStatus).toBe(201);
    const ticketId = (enqData as { ticketId?: string }).ticketId;
    const status = (enqData as { status?: string }).status;
    expect(ticketId).toBeDefined();
    expect(status).toBe('queued');

    const { status: finalStatus, assignment } = await waitForAssignment(ticketId!);
    expect(finalStatus).toBe('assigned');
    expect(assignment).toBeDefined();
    expect((assignment as { connectUrl?: string }).connectUrl).toContain('ws');
    expect((assignment as { matchToken?: string }).matchToken).toBeDefined();
  }, 45000);

  it('two WebSocket clients receive match.assigned via node inbox when 2v2 matchmaking', async () => {
    const { status: regStatus } = await httpPost(getWorkerBase(), '/v1/provisioning/servers/register', {
      serverId: 'game-split-ext-2v2',
      host: '127.0.0.1',
      port: 8082,
      landType: 'standard',
    });
    expect(regStatus).toBe(200);

    const messages1: { type: string; v?: number; data?: unknown }[] = [];
    const messages2: { type: string; v?: number; data?: unknown }[] = [];

    const ws1 = new WebSocket(getWsUrl());
    const ws2 = new WebSocket(getWsUrl());

    const done1 = new Promise<void>((resolve, reject) => {
      ws1.on('message', (buf: Buffer | string) => {
        const msg = JSON.parse(buf.toString());
        messages1.push(msg);
        if (msg.type === 'error') reject(new Error(`Client 1: ${(msg as { message?: string }).message}`));
        if (msg.type === 'match.assigned') resolve();
      });
      ws1.on('error', reject);
    });
    const done2 = new Promise<void>((resolve, reject) => {
      ws2.on('message', (buf: Buffer | string) => {
        const msg = JSON.parse(buf.toString());
        messages2.push(msg);
        if (msg.type === 'error') reject(new Error(`Client 2: ${(msg as { message?: string }).message}`));
        if (msg.type === 'match.assigned') resolve();
      });
      ws2.on('error', reject);
    });

    await Promise.all([
      new Promise<void>((resolve, reject) => {
        ws1.on('open', () => resolve());
        ws1.on('error', reject);
      }),
      new Promise<void>((resolve, reject) => {
        ws2.on('open', () => resolve());
        ws2.on('error', reject);
      }),
    ]);

    ws1.send(
      JSON.stringify({
        action: 'enqueue',
        queueKey: 'standard:2v2',
        groupId: 'solo-inbox-p1',
        members: ['p1'],
        groupSize: 1,
      }),
    );
    ws2.send(
      JSON.stringify({
        action: 'enqueue',
        queueKey: 'standard:2v2',
        groupId: 'solo-inbox-p2',
        members: ['p2'],
        groupSize: 1,
      }),
    );

    await Promise.all([
      Promise.race([
        done1,
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error('Timeout waiting for client 1 match.assigned')), 20000),
        ),
      ]),
      Promise.race([
        done2,
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error('Timeout waiting for client 2 match.assigned')), 20000),
        ),
      ]),
    ]);

    ws1.close();
    ws2.close();

    const assigned1 = messages1.find((m) => m.type === 'match.assigned');
    const assigned2 = messages2.find((m) => m.type === 'match.assigned');
    expect(assigned1).toBeDefined();
    expect(assigned2).toBeDefined();
    expect(assigned1!.v).toBe(1);
    expect(assigned2!.v).toBe(1);

    const enqueued1 = messages1.find((m) => m.type === 'enqueued');
    const enqueued2 = messages2.find((m) => m.type === 'enqueued');
    const ticketId1 = (enqueued1?.data as { ticketId?: string })?.ticketId;
    const ticketId2 = (enqueued2?.data as { ticketId?: string })?.ticketId;
    expect(ticketId1).toBeDefined();
    expect(ticketId2).toBeDefined();
    expect(ticketId1).not.toBe(ticketId2);

    const data1 = assigned1!.data as {
      ticketId: string;
      assignment: { connectUrl: string; matchToken: string; landId: string };
    };
    const data2 = assigned2!.data as {
      ticketId: string;
      assignment: { connectUrl: string; matchToken: string; landId: string };
    };
    expect(data1.ticketId).toBe(ticketId1);
    expect(data2.ticketId).toBe(ticketId2);
    expect(data1.assignment.connectUrl).toContain('ws');
    expect(data2.assignment.connectUrl).toContain('ws');
    expect(data1.assignment.landId).toBe(data2.assignment.landId);
    expect(data1.assignment.matchToken).not.toBe(data2.assignment.matchToken);
  }, 45000);
});
