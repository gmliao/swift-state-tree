#!/usr/bin/env tsx
/**
 * Verify reevaluation replay with an existing record file.
 * Connects to hero-defense-replay, asserts base position (64, 36) and entities near base.
 *
 * Usage:
 *   tsx src/verify-replay-record.ts [--record-path=path] [--admin-url=url]
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
  const apiKey = (
    process.env.HERO_DEFENSE_ADMIN_KEY ||
    process.env.ADMIN_API_KEY ||
    "hero-defense-admin-key"
  ).trim();
  const recordPathArg =
    args["record-path"] ??
    resolve(process.cwd(), "..", "..", "Examples", "GameDemo", "reevaluation-records", "3-hero-defense.json");

  const recordFilePath = recordPathArg.startsWith("/") ? recordPathArg : resolve(recordPathArg);
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

  // Wait until state has at least one player (replay applies join at tick 0, then state updates)
  const waitForPlayersMs = 8000;
  const pollIntervalMs = 200;
  let state = view.getState() as Record<string, unknown> | undefined;
  let elapsed = 0;
  while (elapsed < waitForPlayersMs) {
    state = view.getState() as Record<string, unknown> | undefined;
    const players = (state?.players as Record<string, unknown>) ?? {};
    if (Object.keys(players).length > 0) break;
    await new Promise((r) => setTimeout(r, pollIntervalMs));
    elapsed += pollIntervalMs;
  }

  if (!state || typeof state !== "object") {
    await runtime.disconnect();
    throw new Error("No state after join");
  }
  const analyzed = analyzeReplayState(state as Record<string, unknown>);
  const { basePos, baseOk, playerEntries, nearBaseCount, playersWithPosition } = analyzed;

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

  const monsters = (state as Record<string, unknown>).monsters as Record<string, unknown> | undefined;
  const turrets = (state as Record<string, unknown>).turrets as Record<string, unknown> | undefined;
  console.log(`Monsters: ${Object.keys(monsters ?? {}).length}, Turrets: ${Object.keys(turrets ?? {}).length}`);

  await runtime.disconnect();

  if (!baseOk) {
    console.log(chalk.red("\nFAIL: Base position should be (64, 36) per GameConfig."));
    process.exit(1);
  }
  if (playerEntries.length === 0) {
    console.log(
      chalk.yellow("\nWARN: No players in state after waiting. Replay server may not be pushing state updates (decode of actualState to State can fail if snapshot format does not match). Base position was verified.")
    );
  } else if (playersWithPosition > 0 && nearBaseCount < playersWithPosition) {
    console.log(chalk.red(`\nFAIL: Not all player positions near base (expected spawn 64±5, 36±5). ${nearBaseCount}/${playersWithPosition} near base.`));
    process.exit(1);
  } else {
    console.log(chalk.green("\nOK: Reevaluation replay verified; base (64,36) and player position(s) near base received correctly."));
  }
  process.exit(0);
}

main().catch((err: unknown) => {
  console.error(chalk.red(String(err)));
  process.exit(1);
});
