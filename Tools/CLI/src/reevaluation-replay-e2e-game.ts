import { mkdirSync, writeFileSync } from "fs";
import { join, resolve } from "path";
import { execFileSync } from "child_process";
import chalk from "chalk";
import { StateTreeRuntime } from "@swiftstatetree/sdk/core";
import { ChalkLogger } from "./logger";
import { fetchSchema } from "./schema";
import { downloadReevaluationRecord } from "./admin";

type Args = Record<string, string | boolean>;

function parseArgs(argv: string[]): Args {
  const out: Args = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      out[key] = true;
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

function deriveSchemaBaseUrl(urlString: string): string {
  const url = new URL(urlString);
  const protocol = url.protocol === "wss:" ? "https:" : "http:";
  return `${protocol}//${url.host}`;
}

function buildTransportEncoding(stateUpdateEncoding?: string) {
  const normalized = (stateUpdateEncoding ?? "messagepack").toLowerCase();

  if (normalized === "jsonobject") {
    return {
      message: "json",
      stateUpdate: "jsonObject",
      stateUpdateDecoding: "jsonObject",
    } as const;
  }

  if (normalized === "opcodejsonarray") {
    return {
      message: "json",
      stateUpdate: "opcodeJsonArray",
      stateUpdateDecoding: "opcodeJsonArray",
    } as const;
  }

  return {
    message: "messagepack",
    stateUpdate: "opcodeJsonArray",
    stateUpdateDecoding: "auto",
  } as const;
}

async function startReplaySession(params: {
  adminUrl: string;
  apiKey: string;
  landType: string;
  recordFilePath: string;
}): Promise<{ replayLandID: string; webSocketPath: string }> {
  const response = await fetch(`${params.adminUrl.replace(/\/$/, "")}/admin/reevaluation/replay/start`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-API-Key": params.apiKey,
    },
    body: JSON.stringify({
      landType: params.landType,
      recordFilePath: params.recordFilePath,
    }),
  });

  if (!response.ok) {
    throw new Error(`Failed to start replay session: HTTP ${response.status}`);
  }

  const body = (await response.json()) as {
    data?: { replayLandID?: string; webSocketPath?: string };
  };

  const replayLandID = body?.data?.replayLandID;
  const webSocketPath = body?.data?.webSocketPath;
  if (!replayLandID || !webSocketPath) {
    throw new Error("Replay session response missing replayLandID or webSocketPath");
  }

  return { replayLandID, webSocketPath };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const wsUrl = (args["ws-url"] as string) ?? "ws://localhost:8080/game/hero-defense";
  const adminUrl = (args["admin-url"] as string) ?? "http://localhost:8080";
  const stateUpdateEncoding = (args["state-update-encoding"] as string) ?? "messagepack";
  const timeoutMs = Number(args["timeout-ms"] ?? 30000);

  const apiKey = (process.env.HERO_DEFENSE_ADMIN_KEY || process.env.ADMIN_API_KEY || "hero-defense-admin-key").trim();

  const landInstanceId = `replay-e2e-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const gameLandID = `hero-defense:${landInstanceId}`;

  console.log(chalk.blue(`🏠 HeroDefense land: ${gameLandID}`));
  console.log(chalk.blue(`🔌 Game WS: ${wsUrl}`));
  console.log(chalk.blue(`🛠️  Admin: ${adminUrl}`));

  console.log(chalk.blue("🎮 Running Hero Defense scenario to produce reevaluation record..."));
  execFileSync(
    "npx",
    [
      "tsx",
      "src/cli.ts",
      "script",
      "-u",
      wsUrl,
      "-l",
      gameLandID,
      "-s",
      "scenarios/game/test-demo-game.json",
      "--state-update-encoding",
      stateUpdateEncoding,
    ],
    { cwd: resolve(process.cwd()), stdio: "inherit" },
  );

  const record = await downloadReevaluationRecord({
    url: adminUrl,
    apiKey,
    landID: gameLandID,
  });

  const projectRoot = resolve(process.cwd(), "..", "..");
  const recordsDir = join(projectRoot, "Examples", "GameDemo", "reevaluation-records");
  mkdirSync(recordsDir, { recursive: true });
  const recordPath = join(recordsDir, `hero-defense-${landInstanceId}.reeval.json`);
  writeFileSync(recordPath, JSON.stringify(record, null, 2), "utf-8");
  console.log(chalk.green(`✅ Saved reevaluation record: ${recordPath}`));

  const replaySession = await startReplaySession({
    adminUrl,
    apiKey,
    landType: "hero-defense",
    recordFilePath: recordPath,
  });

  const replayWsUrl = `${adminUrl.replace(/^http/, "ws").replace(/\/$/, "")}${replaySession.webSocketPath}`;
  const schemaBaseUrl = deriveSchemaBaseUrl(replayWsUrl);
  const schema = await fetchSchema(schemaBaseUrl);

  const logger = new ChalkLogger();
  const transportEncoding = buildTransportEncoding(stateUpdateEncoding);
  const runtime = new StateTreeRuntime({ logger, transportEncoding });
  await runtime.connect(replayWsUrl);

  const view = runtime.createView(replaySession.replayLandID, {
    schema: schema as any,
    logger,
  });

  const joinResult = await view.join();
  if (!joinResult.success) {
    await runtime.disconnect();
    throw new Error(`Failed to join replay land: ${joinResult.reason || "unknown reason"}`);
  }

  const start = Date.now();
  let completed = false;
  let failedMessage: string | null = null;
  let hasStatePayload = false;
  const observedTicks = new Set<number>();

  while (Date.now() - start < timeoutMs) {
    const state = view.getState() as any;
    const status = state?.status;
    const tick = state?.currentTickId;

    if (typeof tick === "number" && tick >= 0) {
      observedTicks.add(tick);
    }

    if (typeof state?.currentStateJSON === "string" && state.currentStateJSON.length > 2) {
      hasStatePayload = true;
    }

    if (status === "completed") {
      completed = true;
      break;
    }

    if (status === "failed") {
      failedMessage = state?.errorMessage ?? "unknown error";
      break;
    }

    await new Promise((resolveTimer) => setTimeout(resolveTimer, 100));
  }

  await runtime.disconnect();

  if (failedMessage) {
    throw new Error(`Replay stream reported failure: ${failedMessage}`);
  }
  if (!completed) {
    throw new Error(`Timed out waiting for replay completion (${timeoutMs}ms)`);
  }
  if (observedTicks.size < 3) {
    throw new Error(`Expected at least 3 replay ticks, got ${observedTicks.size}`);
  }
  if (!hasStatePayload) {
    throw new Error("Expected replay state payload updates, got none");
  }

  console.log(chalk.green(`✅ Replay stream completed; observedTicks=${observedTicks.size}`));
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(chalk.red(`❌ Reevaluation replay E2E failed: ${message}`));
  process.exit(1);
});
