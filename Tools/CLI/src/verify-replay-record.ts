#!/usr/bin/env tsx
/**
 * Verify reevaluation replay with an existing record file.
 * Connects to hero-defense-replay, asserts base position (64, 36) and entities near base.
 *
 * Usage:
 *   tsx src/verify-replay-record.ts [--record-path=path] [--admin-url=url]
 *     [--wait-ms=8000] [--min-players=1] [--min-monsters=1] [--min-turrets=0]
 *     [--min-events=0]
 *
 * Requires: GameServer running (e.g. from Examples/GameDemo with REEVALUATION_RECORDS_DIR).
 */

import { resolve } from "path";
import chalk from "chalk";
import { StateTreeRuntime } from "@swiftstatetree/sdk/core";
import { ChalkLogger } from "./logger";
import { fetchSchema } from "./schema";
import {
  BASE_X,
  BASE_Y,
  NEAR_BASE_RADIUS,
  parseArgs,
  getPositionXY,
  distance,
  analyzeReplayState,
  getEntityCounts,
  updateMaxEntityCounts,
  evaluateEntityThresholds,
} from "./verify-replay-helpers";

async function startReplaySession(params: {
  adminUrl: string;
  apiKey: string;
  landType: string;
  recordFilePath: string;
}): Promise<{ replayLandID: string; webSocketPath: string }> {
  const response = await fetch(
    `${params.adminUrl.replace(/\/$/, "")}/admin/reevaluation/replay/start`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": params.apiKey,
      },
      body: JSON.stringify({
        landType: params.landType,
        recordFilePath: params.recordFilePath,
      }),
    }
  );

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Replay start failed: HTTP ${response.status} ${text}`);
  }

  const body = (await response.json()) as {
    data?: { replayLandID?: string; webSocketPath?: string };
  };
  const replayLandID = body?.data?.replayLandID;
  const webSocketPath = body?.data?.webSocketPath;
  if (!replayLandID || !webSocketPath) {
    throw new Error("Response missing replayLandID or webSocketPath");
  }
  return { replayLandID, webSocketPath };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const adminUrl = args["admin-url"] ?? "http://localhost:8080";
  const waitMs = parseUIntOption(args["wait-ms"], "wait-ms", 8000);
  const minPlayers = parseUIntOption(args["min-players"], "min-players", 1);
  const minMonsters = parseUIntOption(args["min-monsters"], "min-monsters", 1);
  const minTurrets = parseUIntOption(args["min-turrets"], "min-turrets", 0);
  const minEvents = parseUIntOption(args["min-events"], "min-events", 0);
  const apiKey = (
    process.env.HERO_DEFENSE_ADMIN_KEY ||
    process.env.ADMIN_API_KEY ||
    "hero-defense-admin-key"
  ).trim();
  const recordPathArg =
    args["record-path"] ??
    resolve(process.cwd(), "..", "..", "Examples", "GameDemo", "reevaluation-records", "3-hero-defense.json");

  const recordFilePath = recordPathArg.startsWith("/") ? recordPathArg : resolve(process.cwd(), recordPathArg);
  console.log(chalk.blue(`Record file: ${recordFilePath}`));
  console.log(chalk.blue(`Admin: ${adminUrl}`));

  const { replayLandID, webSocketPath } = await startReplaySession({
    adminUrl,
    apiKey,
    landType: "hero-defense",
    recordFilePath,
  });

  const replayWsUrl = `${adminUrl.replace(/^http/, "ws").replace(/\/$/, "")}${webSocketPath}`;
  const schemaBaseUrl = adminUrl.replace(/\/$/, "");
  const schema = await fetchSchema(schemaBaseUrl);
  const logger = new ChalkLogger();
  const runtime = new StateTreeRuntime({
    logger,
    transportEncoding: {
      message: "messagepack",
      stateUpdate: "opcodeJsonArray",
      stateUpdateDecoding: "auto",
    },
  });

  await runtime.connect(replayWsUrl);
  const view = runtime.createView(replayLandID, { schema: schema as any, logger });
  const joinResult = await view.join();
  if (!joinResult.success) {
    await runtime.disconnect();
    throw new Error(`Join failed: ${joinResult.reason ?? "unknown"}`);
  }

  // Count server events (e.g. PlayerShoot, TurretFire) during replay
  let serverEventCount = 0;
  const eventTypesToCount = ["PlayerShoot", "TurretFire"];
  const unsubs: (() => void)[] = [];
  for (const eventType of eventTypesToCount) {
    unsubs.push(
      view.onServerEvent(eventType, () => {
        serverEventCount += 1;
      })
    );
  }

  // Observe replay state for a fixed window and track max entity counts seen during replay.
  const pollIntervalMs = 200;
  let state = view.getState() as Record<string, unknown> | undefined;
  let latestAnalyzed = analyzeReplayState(state);
  let maxEntityCounts = getEntityCounts(state);
  let elapsed = 0;
  while (elapsed < waitMs) {
    state = view.getState() as Record<string, unknown> | undefined;
    latestAnalyzed = analyzeReplayState(state);
    maxEntityCounts = updateMaxEntityCounts(maxEntityCounts, getEntityCounts(state));
    await new Promise((r) => setTimeout(r, pollIntervalMs));
    elapsed += pollIntervalMs;
  }

  for (const unsub of unsubs) unsub();

  if (!state || typeof state !== "object") {
    await runtime.disconnect();
    throw new Error("No state after join");
  }
  const { basePos, baseOk, playerEntries, nearBaseCount, playersWithPosition } = latestAnalyzed;

  console.log(chalk.cyan("\n=== Replay state (client-received) ==="));
  console.log(`Base position: ${basePos ? `(${basePos.x.toFixed(2)}, ${basePos.y.toFixed(2)})` : "N/A"} (expected ${BASE_X}, ${BASE_Y})`);

  if (basePos && !baseOk) {
    const dist = distance(basePos.x, basePos.y, BASE_X, BASE_Y);
    console.log(chalk.red(`  Base position mismatch: distance=${dist.toFixed(2)}`));
  } else if (baseOk) {
    console.log(chalk.green("  Base position OK"));
  } else {
    console.log(chalk.red("  Base position missing"));
  }

  console.log(`Players: ${playerEntries.length}`);
  for (const [id, p] of playerEntries) {
    const pos = getPositionXY(p);
    if (pos) {
      const d = distance(pos.x, pos.y, BASE_X, BASE_Y);
      const near = d <= NEAR_BASE_RADIUS;
      const ok = near ? chalk.green("near base ✓") : chalk.red("far from base (expected ±5 of 64,36)");
      console.log(`  ${id}: (${pos.x.toFixed(2)}, ${pos.y.toFixed(2)}) dist=${d.toFixed(2)} ${ok}`);
    } else {
      console.log(`  ${id}: position N/A`);
    }
  }

  console.log(
    `Entity max seen within ${waitMs}ms: Players=${maxEntityCounts.players}, Monsters=${maxEntityCounts.monsters}, Turrets=${maxEntityCounts.turrets}`
  );
  console.log(
    `Entity minimum required: Players>=${minPlayers}, Monsters>=${minMonsters}, Turrets>=${minTurrets}`
  );
  console.log(
    `Server events received (PlayerShoot/TurretFire): ${serverEventCount} (min required: ${minEvents})`
  );

  await runtime.disconnect();

  if (!baseOk) {
    console.log(chalk.red("\nFAIL: Base position should be (64, 36) per GameConfig."));
    process.exit(1);
  }
  const thresholdResult = evaluateEntityThresholds(
    maxEntityCounts,
    { minPlayers, minMonsters, minTurrets }
  );
  if (!thresholdResult.ok) {
    for (const failure of thresholdResult.failures) {
      console.log(chalk.red(`FAIL: ${failure}`));
    }
    process.exit(1);
  }

  if (playerEntries.length > 0 && playersWithPosition > 0 && nearBaseCount < playersWithPosition) {
    console.log(chalk.red(`\nFAIL: Not all player positions near base (expected spawn 64±5, 36±5). ${nearBaseCount}/${playersWithPosition} near base.`));
    process.exit(1);
  }
  if (serverEventCount < minEvents) {
    console.log(chalk.red(`\nFAIL: Server events received ${serverEventCount} < min-events ${minEvents}.`));
    process.exit(1);
  }
  console.log(chalk.green("\nOK: Reevaluation replay verified; base position, entity thresholds and event count are satisfied."));
  process.exit(0);
}

main().catch((err: unknown) => {
  console.error(chalk.red(String(err)));
  process.exit(1);
});

function parseUIntOption(raw: string | undefined, key: string, defaultValue: number): number {
  if (raw == null || raw.trim().length === 0) {
    return defaultValue;
  }

  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || Number.isNaN(parsed) || parsed < 0) {
    throw new Error(`Invalid --${key} value: ${raw}`);
  }
  return parsed;
}
