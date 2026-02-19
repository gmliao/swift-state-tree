import { mkdirSync, writeFileSync } from "fs";
import { join, resolve } from "path";
import { execFileSync } from "child_process";
import chalk from "chalk";
import { StateTreeRuntime } from "@swiftstatetree/sdk/core";
import { ChalkLogger } from "./logger";
import { fetchSchema } from "./schema";
import { downloadReevaluationRecord } from "./admin";
import { parseReplayE2EConfig } from "./reevaluation-replay-config";

type Args = Record<string, string | boolean>;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasNumericPositionXY(value: unknown): boolean {
  if (!isPlainObject(value)) return false;
  const position = value.position;
  if (!isPlainObject(position)) return false;
  if (typeof position.x === "number" && typeof position.y === "number") {
    return true;
  }

  if (isPlainObject(position.v)) {
    return typeof position.v.x === "number" && typeof position.v.y === "number";
  }

  return false;
}

function hasBaseWrapperArtifact(value: unknown): boolean {
  return isPlainObject(value) && Object.prototype.hasOwnProperty.call(value, "base");
}

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
  const { timeoutMs, replayIdleMs } = parseReplayE2EConfig(args);

  const apiKey = (process.env.HERO_DEFENSE_ADMIN_KEY || process.env.ADMIN_API_KEY || "hero-defense-admin-key").trim();

  const landInstanceId = `replay-e2e-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const gameLandID = `hero-defense:${landInstanceId}`;

  console.log(chalk.blue(`🏠 HeroDefense land: ${gameLandID}`));
  console.log(chalk.blue(`🔌 Game WS: ${wsUrl}`));
  console.log(chalk.blue(`🛠️  Admin: ${adminUrl}`));

  console.log(chalk.blue("🎮 Running Hero Defense scenario to produce reevaluation record..."));
  const replayProofScenarioPath = "scenarios/game/test-replay-near-base-shoot.json";

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
      replayProofScenarioPath,
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

  const expectedReplayTickIDs: number[] = Array.isArray(record?.tickFrames)
    ? record.tickFrames
        .map((frame: any) => frame?.tickId)
        .filter((tickId: unknown): tickId is number => typeof tickId === "number" && Number.isInteger(tickId))
    : [];
  const expectedReplayTickCount = expectedReplayTickIDs.length;
  const expectedReplayMaxTick = expectedReplayTickIDs.length > 0 ? Math.max(...expectedReplayTickIDs) : null;

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
  let lastReplayTickAt = 0;
  let hasLiveCompatibleState = false;
  let hasNonDefaultLiveEvidence = false;
  let legacyReplayFieldSeen = false;
  let replayWrapperArtifact: string | null = null;
  const nonEmptyEntityKinds = new Set<"players" | "monsters" | "turrets">();
  let sawMonsterRemoval = false;
  let previousMonsterIDs = new Set<string>();
  const liveNestedFieldKinds = new Set<"players" | "monsters" | "turrets">();
  const observedTicks = new Set<number>();
  const mismatchedReplayTicks: number[] = [];
  let replayPlayerShootEvents = 0;
  let replayTurretFireEvents = 0;
  const unsubscribeReplayTick = view.onServerEvent("HeroDefenseReplayTick", (payload: unknown) => {
    if (!isPlainObject(payload)) {
      return;
    }

    const tickId = payload.tickId;
    if (typeof tickId === "number" && Number.isFinite(tickId)) {
      observedTicks.add(tickId);
      lastReplayTickAt = Date.now();

      if (payload.isMatch === false) {
        mismatchedReplayTicks.push(tickId);
      }
    }
  });
  const unsubscribeReplayPlayerShoot = view.onServerEvent("PlayerShoot", () => {
    replayPlayerShootEvents += 1;
  });
  const unsubscribeReplayTurretFire = view.onServerEvent("TurretFire", () => {
    replayTurretFireEvents += 1;
  });

  while (Date.now() - start < timeoutMs) {
    const state = view.getState() as any;
    const status = state?.status;
    const tick = state?.currentTickId;

    if (typeof tick === "number" && tick >= 0) {
      observedTicks.add(tick);
    }

    if (isPlainObject(state) && Object.prototype.hasOwnProperty.call(state, "currentStateJSON")) {
      legacyReplayFieldSeen = true;
    }

    const hasLiveShape =
      isPlainObject(state) &&
      typeof state.score === "number" &&
      isPlainObject(state.players) &&
      isPlainObject(state.monsters) &&
      isPlainObject(state.turrets) &&
      isPlainObject(state.base);

    if (hasLiveShape) {
      hasLiveCompatibleState = true;

      const players = state.players as Record<string, unknown>;
      const monsters = state.monsters as Record<string, unknown>;
      const turrets = state.turrets as Record<string, unknown>;
      const base = state.base as Record<string, unknown>;
      const score = state.score as number;
      const currentMonsterIDs = new Set(Object.keys(monsters));

      if (previousMonsterIDs.size > 0) {
        for (const monsterID of previousMonsterIDs) {
          if (!currentMonsterIDs.has(monsterID)) {
            sawMonsterRemoval = true;
            break;
          }
        }
      }
      previousMonsterIDs = currentMonsterIDs;

      if (hasBaseWrapperArtifact(base)) {
        replayWrapperArtifact = "base.base";
      }

      const entityGroups: Array<["players" | "monsters" | "turrets", Record<string, unknown>]> = [
        ["players", players],
        ["monsters", monsters],
        ["turrets", turrets],
      ];

      for (const [kind, entities] of entityGroups) {
        const entries = Object.entries(entities);
        if (entries.length > 0) {
          nonEmptyEntityKinds.add(kind);
        }

        for (const [entityId, entityValue] of entries) {
          if (!isPlainObject(entityValue)) continue;

          if (Object.prototype.hasOwnProperty.call(entityValue, "base")) {
            replayWrapperArtifact = `${kind}.${entityId}.base`;
          }

          if (hasNumericPositionXY(entityValue)) {
            liveNestedFieldKinds.add(kind);
          }
        }
      }

      if (
        score !== 0 ||
        Object.keys(players).length > 0 ||
        Object.keys(monsters).length > 0 ||
        Object.keys(turrets).length > 0 ||
        Object.keys(base).length > 0
      ) {
        hasNonDefaultLiveEvidence = true;
      }
    }

    if (status === "completed") {
      completed = true;
      break;
    }

    if (status === "failed") {
      failedMessage = state?.errorMessage ?? "unknown error";
      break;
    }

    if (
      typeof status !== "string" &&
      lastReplayTickAt > 0 &&
      Date.now() - lastReplayTickAt >= replayIdleMs &&
      (expectedReplayMaxTick === null || observedTicks.has(expectedReplayMaxTick))
    ) {
      completed = true;
      break;
    }

    await new Promise((resolveTimer) => setTimeout(resolveTimer, 100));
  }

  unsubscribeReplayTick();
  unsubscribeReplayPlayerShoot();
  unsubscribeReplayTurretFire();
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
  if (mismatchedReplayTicks.length > 0) {
    throw new Error(`Expected all replay ticks to match hash, mismatches at ticks: ${mismatchedReplayTicks.join(",")}`);
  }
  if (expectedReplayTickCount > 0) {
    const observedCoverage = observedTicks.size / expectedReplayTickCount;
    const minimumCoverage = 0.8;
    if (observedCoverage < minimumCoverage) {
      const missingTicks = expectedReplayTickIDs.filter((tickId) => !observedTicks.has(tickId));
      throw new Error(
        `Expected replay tick coverage >= ${minimumCoverage}, got ${(observedCoverage * 100).toFixed(1)}% (${observedTicks.size}/${expectedReplayTickCount}); missing sample: ${missingTicks.slice(0, 10).join(",")}`,
      );
    }
  }
  if (expectedReplayMaxTick !== null && !observedTicks.has(expectedReplayMaxTick)) {
    throw new Error(
      `Expected to observe final replay tick ${expectedReplayMaxTick}, observed ${observedTicks.size} ticks`,
    );
  }
  if (!hasLiveCompatibleState) {
    throw new Error("Expected replay live-compatible state fields, got none");
  }
  if (!hasNonDefaultLiveEvidence) {
    throw new Error("Expected replay live-compatible state evidence, got only default values");
  }
  if (legacyReplayFieldSeen) {
    throw new Error("Expected no legacy replay field currentStateJSON in replay state");
  }
  if (replayWrapperArtifact) {
    throw new Error(`Expected no replay wrapper artifact, found ${replayWrapperArtifact}`);
  }
  if (nonEmptyEntityKinds.size === 0) {
    throw new Error("Expected at least one non-empty players/monsters/turrets sample during replay");
  }
  if (replayPlayerShootEvents + replayTurretFireEvents < 1) {
    throw new Error(
      `Expected replay shooting events, got PlayerShoot=${replayPlayerShootEvents}, TurretFire=${replayTurretFireEvents}`,
    );
  }
  if (!sawMonsterRemoval) {
    throw new Error("Expected at least one monster removal during replay, but none observed");
  }
  for (const kind of nonEmptyEntityKinds) {
    if (!liveNestedFieldKinds.has(kind)) {
      throw new Error(`Expected live nested position fields in ${kind} sample`);
    }
  }

  console.log(
    chalk.green(
      `✅ Replay stream completed; observedTicks=${observedTicks.size}, PlayerShoot=${replayPlayerShootEvents}, TurretFire=${replayTurretFireEvents}`,
    ),
  );
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(chalk.red(`❌ Reevaluation replay E2E failed: ${message}`));
  process.exit(1);
});
