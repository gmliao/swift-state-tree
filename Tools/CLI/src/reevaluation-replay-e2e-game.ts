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

  // Max concurrent player count from record (replay viewer must NOT be added as extra player).
  // We use max (not final) because we may check state before replay fully finishes.
  // Assertion: actualPlayerCount <= maxRecordedPlayers (viewer must not appear as extra).
  let maxRecordedPlayers = 0;
  const playersPresent = new Set<string>();
  const tickFrames = (record as { tickFrames?: Array<{ lifecycleEvents?: Array<{ kind?: string; playerID?: string }> }> })
    .tickFrames;
  if (Array.isArray(tickFrames)) {
    for (const frame of tickFrames) {
      for (const ev of frame.lifecycleEvents ?? []) {
        if (!ev.playerID) continue;
        if (ev.kind === "join") {
          playersPresent.add(ev.playerID);
          maxRecordedPlayers = Math.max(maxRecordedPlayers, playersPresent.size);
        } else if (ev.kind === "leave") {
          playersPresent.delete(ev.playerID);
        }
      }
    }
  }

  // Same-land replay: no HeroDefenseReplayTickEvent; completion based on state + shooting events + idle timeout

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
  let lastActivityAt = 0;
  let hasLiveCompatibleState = false;
  let hasNonDefaultLiveEvidence = false;
  let legacyReplayFieldSeen = false;
  let replayWrapperArtifact: string | null = null;
  const nonEmptyEntityKinds = new Set<"players" | "monsters" | "turrets">();
  let sawMonsterRemoval = false;
  let previousMonsterIDs = new Set<string>();
  const liveNestedFieldKinds = new Set<"players" | "monsters" | "turrets">();
  let replayPlayerShootEvents = 0;
  let replayTurretFireEvents = 0;
  const unsubscribeReplayPlayerShoot = view.onServerEvent("PlayerShoot", () => {
    replayPlayerShootEvents += 1;
    lastActivityAt = Date.now();
  });
  const unsubscribeReplayTurretFire = view.onServerEvent("TurretFire", () => {
    replayTurretFireEvents += 1;
    lastActivityAt = Date.now();
  });

  while (Date.now() - start < timeoutMs) {
    const state = view.getState() as any;

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
        // Do NOT update lastActivityAt here: state updates arrive every tick, so we would never
        // reach replayIdleMs. lastActivityAt is only updated by PlayerShoot/TurretFire events.
      }
    }

    if (
      hasLiveCompatibleState &&
      hasNonDefaultLiveEvidence &&
      replayPlayerShootEvents + replayTurretFireEvents >= 1 &&
      sawMonsterRemoval &&
      lastActivityAt > 0 &&
      Date.now() - lastActivityAt >= replayIdleMs
    ) {
      completed = true;
      break;
    }

    await new Promise((resolveTimer) => setTimeout(resolveTimer, 100));
  }

  unsubscribeReplayPlayerShoot();
  unsubscribeReplayTurretFire();

  if (!completed) {
    throw new Error(`Timed out waiting for replay completion (${timeoutMs}ms)`);
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

  // Replay viewer must NOT be added as extra player (actual must not exceed max from record)
  const finalState = view.getState() as { players?: Record<string, unknown> };
  const actualPlayerCount = isPlainObject(finalState?.players) ? Object.keys(finalState.players).length : 0;
  if (actualPlayerCount > maxRecordedPlayers) {
    throw new Error(
      `Replay viewer was incorrectly added as player: max ${maxRecordedPlayers} player(s) from record, got ${actualPlayerCount} (replay viewer must be observer-only)`,
    );
  }

  console.log(
    chalk.green(
      `✅ Replay stream completed; PlayerShoot=${replayPlayerShootEvents}, TurretFire=${replayTurretFireEvents}`,
    ),
  );

  await runtime.disconnect();
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(chalk.red(`❌ Reevaluation replay E2E failed: ${message}`));
  process.exit(1);
});
