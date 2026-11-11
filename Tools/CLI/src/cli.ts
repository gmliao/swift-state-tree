#!/usr/bin/env node

import { Command } from "commander";
import { readFileSync, statSync, readdirSync } from "fs";
import { join, basename } from "path";
import chalk from "chalk";
import {
  StateTreeRuntime,
  StateTreeView,
  Position2,
  Velocity2,
  Acceleration2,
  Angle,
  IVec2,
  IVec3,
  rowPatchIndicesOf,
} from "@swiftstatetree/sdk/core";
import type { StateUpdate } from "@swiftstatetree/sdk/core";
import { ChalkLogger } from "./logger";
import { joinWithTimeout } from "./join-timeout";
import { fetchSchema, printSchema } from "./schema";
import { formatViolations, watchSchemaConformance, type ConformanceSchema, type ConformanceViolation } from "./schema-conformance.js";
import * as admin from "./admin";
import { evaluateAssertion } from "./scenarioAssertions.js";
import {
  checkConvergence,
  ConvergenceClient,
  ConvergenceInconclusiveError,
  ConvergenceStepResult,
  DebugStateClient,
  formatConvergence,
  formatInconclusiveAttempt,
  injectDropOnePatch,
  runConvergenceAttempts,
} from "./convergence.js";

/**
 * Per `assertConverged` step (`checks`, `converged`, `mismatches`, `inconclusive`: steps that
 * ended inconclusive), plus `retried` (steps that needed more than one attempt) and `attempts`
 * (checks run, #226).
 */
type ConvergenceStats = {
  checks: number;
  converged: number;
  mismatches: number;
  inconclusive: number;
  retried: number;
  attempts: number;
};

const zeroConvergenceStats = (): ConvergenceStats => ({
  checks: 0,
  converged: 0,
  mismatches: 0,
  inconclusive: 0,
  retried: 0,
  attempts: 0,
});

/** Context for `assertConverged` steps: the land, every client in it, the debug routes. */
type ConvergenceContext = {
  landID: string;
  clients: ConvergenceClient[];
  debug?: DebugStateClient;
  /** Mismatches fail the script (CLI default: report-only; the E2E scripts turn it on). */
  gating: boolean;
  stats: ConvergenceStats;
  /**
   * Joins one more client to the land (`addClient` steps). With `samePlayerAs`, it joins as
   * that client's player: the server supersedes the older session (newest wins, #92), so the
   * older client must be closed by the server, and it leaves `clients`.
   */
  addClient?: (options?: { samePlayerAs?: string }) => Promise<void>;
  /** Closes a client's connection; it leaves `clients` until reconnected (`disconnectClient`). */
  disconnectClient?: (name: string) => void;
  /**
   * Connects a disconnected client again on a new runtime and view, joining as the same player
   * (`reconnectClient`): its state is rebuilt from that join's firstSync (#219).
   */
  reconnectClient?: (name: string) => Promise<void>;
};

/** Every runtime a `script` run created, for the decode error summary (#191). */
const scriptRuntimes: StateTreeRuntime[] = [];
/**
 * Patches from row entries (`rowAddressing`) the script views applied, over the whole run: a CI
 * run with row addressing on requires some, so a server that stops sending row entries fails it.
 */
let rowPatchesApplied = 0;
const countRowPatches = (update: StateUpdate) => {
  rowPatchesApplied += rowPatchIndicesOf(update).length;
};

/** Decode errors of `runtimes` before they started leaving, with a few samples. */
function decodeErrorsBeforeLeave(runtimes: StateTreeRuntime[]): { count: number; samples: string[] } {
  let count = 0;
  const samples: string[] = [];
  runtimes.forEach((runtime, index) => {
    const stats = runtime.decodeErrorStats();
    count += stats.beforeLeave;
    for (const sample of stats.samples) {
      if (sample.startsWith("before leave") && samples.length < 5) samples.push(`client-${index}: ${sample}`);
    }
  });
  return { count, samples };
}

/**
 * One summary line for the whole run. Errors after a client started leaving are reported but
 * don't fail the run until #190 (the SDK clears its key maps before in-flight frames) is fixed.
 */
function printDecodeErrorSummary() {
  let before = 0;
  let after = 0;
  for (const runtime of scriptRuntimes) {
    const stats = runtime.decodeErrorStats();
    before += stats.beforeLeave;
    after += stats.afterLeave;
  }
  console.log(`DECODE ERRORS before-leave=${before} after-leave=${after}`);
  console.log(`Row patches applied: ${rowPatchesApplied}`);
}

const program = new Command();

program
  .name("swiftstatetree-cli")
  .description("SwiftStateTree WebSocket CLI testing tool")
  .version("1.0.0");

program
  .command("connect")
  .description("Connect to a SwiftStateTree server")
  .requiredOption(
    "-u, --url <url>",
    "WebSocket URL (e.g., ws://localhost:8080/ws)",
  )
  .requiredOption("-l, --land <landID>", "Land ID to join")
  .option(
    "-p, --player <playerID>",
    "Player ID (optional, server will generate if not provided)",
  )
  .option("-d, --device <deviceID>", "Device ID")
  .option("-m, --metadata <json>", "Metadata as JSON string")
  .option("-t, --token <token>", "JWT token for authentication")
  .option("--schema-url <url>", "Schema base URL (defaults to WebSocket host)")
  .option(
    "--state-update-encoding <mode>",
    "State update decoding mode (auto|jsonObject|opcodeJsonArray|messagepack)",
    "auto",
  )
  .option(
    "-s, --script <file_or_dir>",
    "Script file or directory of scripts to execute after joining",
  )
  .option(
    "--once",
    "Exit after successful connection and join (non-interactive mode)",
  )
  .option(
    "--timeout <seconds>",
    "Auto-exit timeout in seconds after script completion (default: 10)",
    "10",
  )
  .action(async (options) => {
    try {
      // Parse metadata if provided
      let metadata: Record<string, any> | undefined;
      if (options.metadata) {
        try {
          metadata = JSON.parse(options.metadata);
        } catch (e) {
          console.error(chalk.red(`Invalid metadata JSON: ${e}`));
          process.exit(1);
        }
      }

      // Build WebSocket URL with token if provided
      let wsUrl = options.url;
      if (options.token) {
        const separator = wsUrl.includes("?") ? "&" : "?";
        wsUrl = `${wsUrl}${separator}token=${encodeURIComponent(options.token)}`;
      }

      // Fetch schema (required by StateTreeView)
      const schemaBaseUrl = options.schemaUrl ?? deriveSchemaBaseUrl(wsUrl);
      const schema = await fetchSchema(schemaBaseUrl);

      // Create runtime and view
      const logger = new ChalkLogger();
      const transportEncoding = buildTransportEncoding(
        options.stateUpdateEncoding,
      );
      const runtime = new StateTreeRuntime({ logger, transportEncoding });
      await runtime.connect(wsUrl);

      const view = runtime.createView(options.land, {
        schema: schema as any,
        playerID: options.player,
        deviceID: options.device,
        metadata,
        logger,
      });

      // Join
      const joinResult = await joinWithTimeout(view, options.land);
      if (!joinResult.success) {
        console.error(
          chalk.red(`Failed to join: ${joinResult.reason || "Unknown reason"}`),
        );
        runtime.disconnect();
        process.exit(1);
      } else {
        console.log(
          chalk.green(
            `✅ Successfully joined as ${joinResult.playerID || "unknown"}`,
          ),
        );
      }

      // Execute script if provided
      if (options.script) {
        const stats = statSync(options.script);
        const scripts = stats.isDirectory()
          ? readdirSync(options.script)
              .filter((f) => f.endsWith(".json"))
              .map((f) => join(options.script, f))
          : [options.script];

        console.log(
          chalk.blue(`📂 Found ${scripts.length} script(s) to execute.`),
        );

        let allPassed = true;
        for (const scriptPath of scripts) {
          try {
            await executeScript(view, scriptPath);
          } catch (scriptError) {
            console.error(
              chalk.red(
                `\n❌ Script execution error in ${basename(scriptPath)}: ${scriptError}`,
              ),
            );
            allPassed = false;
            // Fail fast: if one script in directory fails, stop
            break;
          }
        }

        if (!allPassed) {
          console.error(chalk.red("\n❌ Some tests failed. Halting."));
          process.exit(1);
        }

        // Wait for responses and then auto-exit
        const timeoutSeconds = parseInt(options.timeout || "10", 10);
        console.log(
          chalk.gray(
            `\n⏳ Waiting ${timeoutSeconds}s for final responses, then auto-exit...`,
          ),
        );

        try {
          for (let i = timeoutSeconds; i > 0; i--) {
            await new Promise((resolve) => setTimeout(resolve, 1000));
            process.stdout.write(chalk.gray(`\r⏳ ${i}s remaining...`));
          }
          console.log();
        } catch (countdownError) {
          console.log();
        }

        console.log(chalk.yellow("\n👋 Disconnecting..."));
        await runtime.disconnect();
        process.exit(0);
      } else if (options.once) {
        console.log(chalk.green("\n✅ Connected and joined successfully!"));
        runtime.disconnect();
        process.exit(0);
      } else {
        console.log(chalk.green("\n✅ Connected and joined successfully!"));
        console.log(chalk.yellow("Use Ctrl+C to exit\n"));
        console.log(
          chalk.cyan("Note: Interactive command input is not yet implemented."),
        );

        process.on("SIGINT", async () => {
          console.log(chalk.yellow("\n👋 Disconnecting..."));
          await runtime.disconnect();
          process.exit(0);
        });

        await new Promise(() => {});
      }
    } catch (error) {
      console.error(chalk.red(`Error: ${error}`));
      process.exit(1);
    }
  });

program
  .command("schema")
  .description("Fetch and display the protocol schema from the server")
  .requiredOption(
    "-u, --url <url>",
    "Server URL (e.g., http://localhost:8080 or ws://localhost:8080)",
  )
  .action(async (options) => {
    try {
      console.log(chalk.blue(`📥 Fetching schema from ${options.url}...`));
      const schema = await fetchSchema(options.url);
      printSchema(schema);
    } catch (error) {
      console.error(chalk.red(`Error: ${error}`));
      process.exit(1);
    }
  });

program
  .command("script")
  .description("Execute a test script or directory of scripts")
  .requiredOption("-u, --url <url>", "WebSocket URL")
  .requiredOption("-l, --land <landID>", "Land ID to join")
  .requiredOption(
    "-s, --script <file_or_dir>",
    "Script file or directory to execute",
  )
  .option("-p, --player <playerID>", "Player ID")
  .option("-d, --device <deviceID>", "Device ID")
  .option("-m, --metadata <json>", "Metadata as JSON string")
  .option("-t, --token <token>", "JWT token for authentication")
  .option("--schema-url <url>", "Schema base URL (defaults to WebSocket host)")
  .option(
    "--state-update-encoding <mode>",
    "State update decoding mode (auto|jsonObject|opcodeJsonArray|messagepack)",
    "auto",
  )
  .option(
    "--admin-url <url>",
    "Admin base URL for assertConverged (defaults to the WebSocket host)",
  )
  .option(
    "--admin-key <key>",
    "Admin API key for assertConverged (or E2E_ADMIN_KEY)",
  )
  .option(
    "--clients <n>",
    "Clients joining each scenario's land; steps send from client 0, assertConverged checks all",
    "1",
  )
  .option(
    "--rooms <n>",
    "Run each scenario in n lands in parallel (each with --clients clients)",
    "1",
  )
  .option(
    "--convergence-gating",
    "Fail the script on a convergence mismatch (or E2E_CONVERGENCE_GATING=true); default report-only",
  )
  .option(
    "--conformance-schema <file>",
    "Check received state against this schema file instead of the server's (e.g. a newer schema against an older server)",
  )
  .option(
    "--fault-drop-patch <pathPrefix>",
    "Fault injection: client 0 drops the next patch whose path starts with this prefix",
  )
  .action(async (options) => {
    try {
      const clientCount = Math.max(1, parseInt(options.clients ?? "1", 10) || 1);
      const rooms = Math.max(1, parseInt(options.rooms ?? "1", 10) || 1);
      const adminKey = options.adminKey ?? process.env.E2E_ADMIN_KEY;
      const debug = adminKey
        ? new DebugStateClient({
            adminUrl: options.adminUrl ?? deriveSchemaBaseUrl(options.url),
            apiKey: adminKey,
          })
        : undefined;
      const gating =
        options.convergenceGating === true ||
        ["1", "true", "yes", "on"].includes((process.env.E2E_CONVERGENCE_GATING ?? "").toLowerCase());
      const convergenceStats = zeroConvergenceStats();

      let metadata: Record<string, any> | undefined;
      if (options.metadata) {
        try {
          metadata = JSON.parse(options.metadata);
        } catch (e) {
          console.error(chalk.red(`Invalid metadata JSON: ${e}`));
          process.exit(1);
        }
      }

      let wsUrl = options.url;
      if (options.token) {
        const separator = wsUrl.includes("?") ? "&" : "?";
        wsUrl = `${wsUrl}${separator}token=${encodeURIComponent(options.token)}`;
      }

      const schemaBaseUrl = options.schemaUrl ?? deriveSchemaBaseUrl(wsUrl);
      const schema = await fetchSchema(schemaBaseUrl);
      const conformanceSchema = (options.conformanceSchema
        ? JSON.parse(readFileSync(options.conformanceSchema, "utf-8"))
        : schema) as ConformanceSchema;
      // Every client's received state is checked against the schema; any violation fails the run.
      const conformanceViolations: string[] = [];

      const stats = statSync(options.script);
      const scripts = stats.isDirectory()
        ? readdirSync(options.script)
            .filter((f) => f.endsWith(".json"))
            .map((f) => join(options.script, f))
        : [options.script];

      console.log(chalk.blue(`📂 Executing ${scripts.length} script(s).`));

      const runScenarioInRoom = async (scriptPath: string, room: number) => {
        // Create a new runtime connection for each script to avoid "Already joined a land" error
        const logger = new ChalkLogger();
        const transportEncoding = buildTransportEncoding(
          options.stateUpdateEncoding,
        );
        const runtime = new StateTreeRuntime({ logger, transportEncoding });
        const extraRuntimes: StateTreeRuntime[] = [];
        scriptRuntimes.push(runtime);

        try {
          await runtime.connect(wsUrl);

          // Read script to check for landID override
          const scriptContent = readFileSync(scriptPath, "utf-8");
          const script = JSON.parse(scriptContent);

          // Determine land ID: respect full land IDs, only append random instance for bare land types
          // If options.land already contains ':', it's a full land ID - use it as-is
          // Otherwise, it's a bare land type - append instance ID
          let landID: string;
          if (options.land.includes(":")) {
            // Full land ID provided (e.g., "cookie:room-123") - use it directly
            landID = options.land;
          } else {
            // Bare land type provided (e.g., "cookie") - append instance ID
            // Use script.landID if specified, otherwise generate unique instance ID
            const uniqueInstanceId = script.landID
              ? script.landID.includes(":")
                ? script.landID.split(":")[1]
                : script.landID
              : `test-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
            landID = `${options.land}:${uniqueInstanceId}`;
          }

          // Several rooms of one scenario need distinct instances.
          if (rooms > 1 && (options.land.includes(":") || script.landID)) {
            landID = `${landID}-room${room}`;
          }
          console.log(chalk.cyan(`🏠 Using land ID: ${landID}${rooms > 1 ? ` (room ${room})` : ""}`));

          // Create a new view with unique land ID for each script
          const view = runtime.createView(landID, {
            schema: schema as any,
            playerID: options.player,
            deviceID: options.device,
            metadata,
            logger,
            onStateUpdateMessage: countRowPatches,
          });
          // Installed before the join, so the joiner's firstSync is checked too.
          const conformanceLandType = landID.split(":")[0];
          const conformanceReports: Array<[string, () => ConformanceViolation[]]> = [
            ["client-0", watchSchemaConformance(view, conformanceSchema, conformanceLandType)],
          ];

          const joinResult = await joinWithTimeout(view, landID);
          if (!joinResult.success) {
            throw new Error(
              `Failed to join land ${landID}: ${joinResult.reason || "Unknown reason"}`,
            );
          }
          const joinedLandID = joinResult.landID || landID;
          console.log(chalk.green(`✅ Joined land: ${joinedLandID}`));

          let droppedPatch: (() => string | undefined) | undefined;
          if (options.faultDropPatch) {
            droppedPatch = injectDropOnePatch(view, options.faultDropPatch);
            console.log(
              chalk.yellow(`⚠️  Fault injection: client-0 drops the next patch under ${options.faultDropPatch}`),
            );
          }

          const clients: ConvergenceClient[] = [
            { name: "client-0", view, playerID: joinResult.playerID ?? options.player ?? "" },
          ];
          const clientRuntimes = new Map<string, StateTreeRuntime>();
          const offlineClients = new Map<string, string>(); // name -> playerID
          let nextClientIndex = clients.length;
          const joinClient = async (name: string, playerID?: string) => {
            const extra = new StateTreeRuntime({
              logger: new ChalkLogger(),
              transportEncoding: buildTransportEncoding(options.stateUpdateEncoding),
            });
            extraRuntimes.push(extra);
            scriptRuntimes.push(extra);
            await extra.connect(wsUrl);
            const extraView = extra.createView(joinedLandID, { schema: schema as any, logger, playerID, onStateUpdateMessage: countRowPatches });
            conformanceReports.push([name, watchSchemaConformance(extraView, conformanceSchema, conformanceLandType)]);
            const extraJoin = await joinWithTimeout(extraView, joinedLandID);
            if (!extraJoin.success || !extraJoin.playerID) {
              throw new Error(`${name} failed to join ${joinedLandID}: ${extraJoin.reason || "Unknown reason"}`);
            }
            clientRuntimes.set(name, extra);
            clients.push({ name, view: extraView, playerID: extraJoin.playerID });
          };
          const addClient = async (options?: { samePlayerAs?: string }) => {
            const name = `client-${nextClientIndex}`;
            nextClientIndex += 1;
            const replacedName = options?.samePlayerAs;
            if (replacedName === undefined) {
              await joinClient(name);
              return;
            }
            const index = clients.findIndex((client) => client.name === replacedName);
            const replaced = clientRuntimes.get(replacedName);
            if (index < 0 || !replaced) {
              throw new Error(`addClient: no connected client ${replacedName} to join as (client-0 can't be replaced)`);
            }
            // Armed before the join: the server closes the older session in the join's segment.
            const closed = new Promise<void>((resolve) => replaced.onDisconnect(() => resolve()));
            await joinClient(name, clients[index].playerID);
            const timeoutMs = 5000;
            const outcome = await Promise.race([
              closed.then(() => "closed" as const),
              new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), timeoutMs)),
            ]);
            if (outcome !== "closed") {
              throw new Error(`addClient: ${replacedName} was not closed within ${timeoutMs} ms after ${name} joined as its player`);
            }
            // The replaced client's view is gone with its socket: it leaves the convergence set.
            const replacedIndex = clients.findIndex((client) => client.name === replacedName);
            if (replacedIndex >= 0) clients.splice(replacedIndex, 1);
            clientRuntimes.delete(replacedName);
            console.log(chalk.green(`✅ ${replacedName} was closed by the server; ${name} holds its player`));
          };
          const disconnectClient = (name: string) => {
            const index = clients.findIndex((client) => client.name === name);
            const extra = clientRuntimes.get(name);
            if (index < 0 || !extra) {
              throw new Error(`disconnectClient: no connected client ${name} (client-0 can't be disconnected)`);
            }
            offlineClients.set(name, clients[index].playerID);
            clients.splice(index, 1);
            clientRuntimes.delete(name);
            extra.disconnect();
          };
          const reconnectClient = async (name: string) => {
            const playerID = offlineClients.get(name);
            if (playerID === undefined) {
              throw new Error(`reconnectClient: ${name} is not disconnected`);
            }
            offlineClients.delete(name);
            await joinClient(name, playerID);
          };
          for (let i = 1; i < clientCount; i += 1) {
            await addClient();
          }
          if (clientCount > 1) {
            console.log(chalk.green(`✅ ${clientCount} clients joined ${joinedLandID}`));
          }

          await executeScript(view, scriptPath, script, joinResult.playerID, {
            landID: joinedLandID,
            clients,
            debug,
            gating,
            stats: convergenceStats,
            addClient,
            disconnectClient,
            reconnectClient,
          });
          // A state update no client could decode is a wire bug (#90, #191): fail the
          // scenario. Checked before the clients leave; errors while leaving are counted apart.
          const decodeErrors = decodeErrorsBeforeLeave([runtime, ...extraRuntimes]);
          if (decodeErrors.count > 0) {
            throw new Error(
              `${decodeErrors.count} message(s) failed to decode before the clients left: ${decodeErrors.samples.join("; ")}`,
            );
          }
          if (droppedPatch) {
            console.log(chalk.yellow(`⚠️  Fault injection dropped: ${droppedPatch() ?? "<nothing>"}`));
          }
          for (const [name, report] of conformanceReports) {
            for (const line of formatViolations(name, report())) {
              if (!conformanceViolations.includes(line)) conformanceViolations.push(line);
            }
          }
        } finally {
          // Disconnect runtimes after the scenario completes or fails
          extraRuntimes.forEach((extra) => extra.disconnect());
          runtime.disconnect();
        }
      };

      for (const scriptPath of scripts) {
        const before = { ...convergenceStats };
        try {
          // Rooms run in parallel; each has its own land and clients. Wait for every room to
          // settle before failing, so no room exits while its freeze is still held.
          const results = await Promise.allSettled(
            Array.from({ length: rooms }, (_, room) => runScenarioInRoom(scriptPath, room)),
          );
          printConvergenceSummary(convergenceStats, basename(scriptPath), before);
          const failed = results.filter((r): r is PromiseRejectedResult => r.status === "rejected");
          if (failed.length > 0) {
            throw rooms > 1
              ? new Error(`${failed.length}/${rooms} room(s) failed; first: ${failed[0].reason}`)
              : failed[0].reason;
          }
        } catch (scriptError) {
          console.error(
            chalk.red(
              `\n❌ Script execution error in ${basename(scriptPath)}: ${scriptError}`,
            ),
          );
          printConvergenceSummary(convergenceStats);
          printDecodeErrorSummary();
          process.exit(1);
        }
      }

      printConvergenceSummary(convergenceStats);
      printDecodeErrorSummary();
      if (conformanceViolations.length > 0) {
        conformanceViolations.forEach((line) => console.error(chalk.red(line)));
        console.error(chalk.red(`\n❌ ${conformanceViolations.length} schema conformance violation(s)`));
        process.exit(1);
      }
      console.log("SCHEMA CONFORMANCE OK");
      console.log(chalk.yellow("\n👋 All scripts completed successfully"));
      process.exit(0);
    } catch (error) {
      console.error(chalk.red(`Error: ${error}`));
      process.exit(1);
    }
  });

/**
 * The run's `CONVERGENCE SUMMARY` line, or with `scenario` the line for one scenario (the
 * difference from `before`), so a retry shows which scenario it came from.
 */
function printConvergenceSummary(stats: ConvergenceStats, scenario?: string, before?: ConvergenceStats) {
  const s = { ...stats };
  if (before) {
    for (const key of Object.keys(s) as (keyof ConvergenceStats)[]) s[key] -= before[key];
  }
  if (s.checks === 0) return;
  const head = scenario ? `CONVERGENCE SCENARIO ${scenario}` : "CONVERGENCE SUMMARY";
  console.log(
    `${head} checks=${s.checks} converged=${s.converged} mismatches=${s.mismatches} inconclusive=${s.inconclusive} retried=${s.retried} attempts=${s.attempts}`,
  );
}

async function runAssertConverged(step: any, convergence: ConvergenceContext | undefined) {
  if (!convergence) {
    throw new Error("assertConverged needs the `script` command (land and clients unknown here)");
  }
  if (!convergence.debug) {
    throw new Error("assertConverged needs an admin key (--admin-key or E2E_ADMIN_KEY)");
  }
  const config = step.assertConverged ?? {};
  const label = config.label ?? "assertConverged";
  console.log(chalk.magenta(`🔍 Checking state convergence (${label}, ${convergence.clients.length} client(s))...`));
  const debug = convergence.debug;
  const maxAttempts = Math.max(1, Math.floor(config.maxAttempts ?? 3));
  let attempt = 0;
  convergence.stats.checks += 1;
  let outcome: ConvergenceStepResult;
  try {
    outcome = await runConvergenceAttempts(
      async () => {
        attempt += 1;
        convergence.stats.attempts += 1;
        // Clients are read per attempt: a client the server closed in between has left.
        const result = await checkConvergence(debug, convergence.landID, convergence.clients, {
          label,
          quietMs: config.quietMs,
          settleTimeoutMs: config.settleTimeoutMs,
        });
        if (result.membershipChanged) {
          console.log(chalk.yellow(formatInconclusiveAttempt(result, attempt, maxAttempts)));
        }
        return result;
      },
      { maxAttempts, retryDelayMs: config.retryDelayMs, gating: convergence.gating },
    );
  } catch (error) {
    if (attempt > 1) convergence.stats.retried += 1;
    if (error instanceof ConvergenceInconclusiveError) convergence.stats.inconclusive += 1;
    throw error;
  }
  if (outcome.attempts.length > 1) convergence.stats.retried += 1;
  const result = outcome.result;
  if (outcome.outcome === "inconclusive") {
    convergence.stats.inconclusive += 1;
    return;
  }
  const lines = formatConvergence(result, config.maxPaths ?? 10, convergence.gating);
  if (result.converged) {
    convergence.stats.converged += 1;
    console.log(chalk.green(`✅ State converged (${label}, tick ${result.tickId})`));
    return;
  }
  convergence.stats.mismatches += 1;
  lines.forEach((line) => console.log(chalk.red(line)));
  if (convergence.gating) {
    throw new Error(`State did not converge (${label}); see the paths above`);
  }
}

type BurstStep = { action?: string; event?: string; payload?: any };

/**
 * Send `steps` back-to-back for `rounds` rounds without waiting between them, from every
 * client when `allClients` is set (load variant), then wait for all action responses.
 */
async function runBurst(
  config: { rounds?: number; allClients?: boolean; steps?: BurstStep[] },
  view: StateTreeView,
  convergence: ConvergenceContext | undefined,
) {
  const rounds = Math.max(1, config.rounds ?? 1);
  const steps = config.steps ?? [];
  const views =
    config.allClients && convergence ? convergence.clients.map((client) => client.view) : [view];
  console.log(
    chalk.blue(`📤 Burst: ${rounds} round(s) x ${steps.length} step(s) from ${views.length} client(s)...`),
  );
  const pending: Promise<unknown>[] = [];
  for (let round = 0; round < rounds; round += 1) {
    for (const sender of views) {
      for (const burstStep of steps) {
        const payload = hydratePayload(burstStep.payload || {});
        if (burstStep.action) {
          pending.push(sender.sendAction(burstStep.action, payload));
        } else if (burstStep.event) {
          sender.sendEvent(burstStep.event, payload);
        }
      }
    }
  }
  const results = await Promise.allSettled(pending);
  const failures = results.filter((r) => r.status === "rejected");
  if (failures.length > 0) {
    throw new Error(
      `Burst: ${failures.length}/${results.length} action(s) failed: ${String((failures[0] as PromiseRejectedResult).reason)}`,
    );
  }
  console.log(chalk.green(`✅ Burst sent; ${results.length} action response(s) received`));
}

async function executeScript(
  view: StateTreeView,
  scriptPath: string,
  script?: any,
  playerID?: string,
  convergence?: ConvergenceContext,
) {
  const patchHistory: Array<{ op: string; path: string }> = [];
  let lastPatchCheckIndex = 0;
  const unsubscribePatch = view.onPatch((patch) => {
    patchHistory.push({ op: patch.op, path: patch.path });
  });
  // Server events counted from the scenario start, for `waitForEvent` steps.
  const eventCounts = new Map<string, number>();
  const unsubscribeEvents: Array<() => void> = [];

  try {
    // If script is already parsed, use it; otherwise read from file
    if (!script) {
      const scriptContent = readFileSync(scriptPath, "utf-8");
      script = JSON.parse(scriptContent);
    }

    for (const step of script.steps || []) {
      const eventName = step.type === "waitForEvent" ? step.waitForEvent?.event : undefined;
      if (eventName && !eventCounts.has(eventName)) {
        eventCounts.set(eventName, 0);
        unsubscribeEvents.push(
          view.onServerEvent(eventName, () => {
            eventCounts.set(eventName, (eventCounts.get(eventName) ?? 0) + 1);
          }),
        );
      }
    }

    // Replace [PLAYER_ID] placeholder in steps
    if (playerID && script.steps) {
      script.steps = replacePlaceholder(script.steps, "[PLAYER_ID]", playerID);
    }

    console.log(chalk.blue(`📜 Executing scenario: ${basename(scriptPath)}`));

    // Default max duration if not specified
    const maxDuration = script.maxDuration || 60000; // 60 seconds default
    const startTime = Date.now();

    for (const step of script.steps || []) {
      // Check for global timeout
      if (Date.now() - startTime > maxDuration) {
        throw new Error(
          `Scenario exceeded maximum duration of ${maxDuration}ms`,
        );
      }

      const {
        type,
        action,
        event,
        payload,
        wait,
        assert,
        expectError,
        errorCode,
        errorMessage,
        waitForState,
        assertNoPatch,
      } = step;

      if (wait) {
        console.log(chalk.gray(`⏳ Waiting ${wait}ms...`));
        await new Promise((resolve) => setTimeout(resolve, wait));
      }

      if (type === "waitForState" && waitForState) {
        const timeout = waitForState.timeout || 3000; // Default 3 seconds
        const interval = waitForState.interval || 100; // Default 100ms
        const startWait = Date.now();
        
        console.log(chalk.gray(`⏳ Waiting for state condition (timeout: ${timeout}ms)...`));
        
        let conditionMet = false;
        while (Date.now() - startWait < timeout) {
          try {
            const state = view.getState();
            evaluateAssertion(state, waitForState);
            conditionMet = true;
            console.log(chalk.green(`✅ State condition met after ${Date.now() - startWait}ms`));
            break;
          } catch {
            // Condition not met yet, wait and retry
            await new Promise((resolve) => setTimeout(resolve, interval));
          }
        }
        
        if (!conditionMet) {
          const state = view.getState();
          throw new Error(
            `Timeout waiting for state condition: ${waitForState.message || JSON.stringify(waitForState)} (current state: ${JSON.stringify(state)})`,
          );
        }
      }

      if (type === "assertConverged") {
        await runAssertConverged(step, convergence);
      }

      if (type === "addClient") {
        if (!convergence?.addClient) {
          throw new Error("addClient needs the `script` command (land unknown here)");
        }
        const samePlayerAs = step.addClient?.samePlayerAs;
        if (samePlayerAs !== undefined && typeof samePlayerAs !== "string") {
          throw new Error('addClient needs { "samePlayerAs": "client-<n>" } or no options');
        }
        console.log(chalk.blue(
          samePlayerAs ? `➕ Adding a client to ${convergence.landID} as ${samePlayerAs}'s player...` : `➕ Adding a client to ${convergence.landID}...`,
        ));
        await convergence.addClient(samePlayerAs ? { samePlayerAs } : undefined);
        console.log(chalk.green(`✅ ${convergence.clients.length} clients in ${convergence.landID}`));
      }

      if (type === "disconnectClient" || type === "reconnectClient") {
        const name = step[type]?.client;
        if (typeof name !== "string") {
          throw new Error(`${type} needs { "client": "client-<n>" }`);
        }
        if (type === "disconnectClient") {
          if (!convergence?.disconnectClient) throw new Error("disconnectClient needs the `script` command");
          console.log(chalk.blue(`🔌 Disconnecting ${name}...`));
          convergence.disconnectClient(name);
        } else {
          if (!convergence?.reconnectClient) throw new Error("reconnectClient needs the `script` command");
          console.log(chalk.blue(`🔁 Reconnecting ${name} as the same player...`));
          await convergence.reconnectClient(name);
          console.log(chalk.green(`✅ ${name} rejoined; its state comes from the new firstSync`));
        }
      }

      if (type === "burst" && step.burst) {
        await runBurst(step.burst, view, convergence);
      }

      if (type === "waitForEvent" && step.waitForEvent) {
        const { event: eventName, timeout = 5000, minCount = 1, message } = step.waitForEvent;
        console.log(chalk.gray(`⏳ Waiting for server event [${eventName}] x${minCount} (timeout: ${timeout}ms)...`));
        const startWait = Date.now();
        while ((eventCounts.get(eventName) ?? 0) < minCount) {
          if (Date.now() - startWait > timeout) {
            throw new Error(
              message || `Timeout waiting for server event ${eventName}: got ${eventCounts.get(eventName) ?? 0}, expected >= ${minCount}`,
            );
          }
          await new Promise((resolve) => setTimeout(resolve, 50));
        }
        console.log(chalk.green(`✅ Server event [${eventName}] received x${eventCounts.get(eventName)}`));
      }

      if (type === "action" && action) {
        const isExpectedError = expectError === true;
        try {
          if (isExpectedError) {
            console.log(
              chalk.yellow(
                `📤 Sending action [${action}] (expecting error)...`,
              ),
            );
          } else {
            console.log(chalk.blue(`📤 Sending action [${action}]...`));
          }

          const response = await view.sendAction(
            action,
            hydratePayload(payload || {}),
          );

          if (isExpectedError) {
            throw new Error(
              `Expected action [${action}] to fail but it succeeded`,
            );
          } else {
            console.log(chalk.green(`✅ Action [${action}] response received`));
          }
        } catch (error: any) {
          if (isExpectedError) {
            const errorCodeMatch =
              !errorCode ||
              (error as any)?.code === errorCode ||
              error?.message?.includes(errorCode);
            const errorMessageMatch =
              !errorMessage || error?.message?.includes(errorMessage);

            if (errorCodeMatch && errorMessageMatch) {
              console.log(
                chalk.green(`✅ Action [${action}] failed as expected`),
              );
            } else {
              console.warn(
                chalk.yellow(
                  `⚠️  Action [${action}] failed but didn't match criteria. Continuing...`,
                ),
              );
            }
          } else {
            console.error(
              chalk.red(
                `❌ Action [${action}] failed unexpectedly: ${error?.message || error}`,
              ),
            );
            throw error; // In E2E, unexpected failures should stop the test
          }
        }
      } else if (type === "event" && event) {
        console.log(chalk.blue(`📤 Sending event [${event}]...`));
        view.sendEvent(event, hydratePayload(payload || {}));
      } else if (type === "assert") {
        const { path, equals } = assert;
        const state = view.getState();
        const { value } = evaluateAssertion(state, assert);

        console.log(chalk.magenta(`🔍 Asserting: ${path} ...`));
        console.log(
          chalk.gray(`   Value: ${JSON.stringify(value)} (${typeof value})`),
        );
        console.log(
          chalk.gray(
            `   Expected: ${JSON.stringify(equals)} (${typeof equals})`,
          ),
        );
        console.log(chalk.green(`✅ Assertion passed: ${path}`));
      } else if (type === "assertNoPatch" && assertNoPatch) {
        const {
          op,
          path,
          paths,
          pathStartsWith,
          sinceLastCheck = true,
          message,
        } = assertNoPatch as {
          op?: string;
          path?: string;
          paths?: string[];
          pathStartsWith?: string;
          sinceLastCheck?: boolean;
          message?: string;
        };

        const checkFrom = sinceLastCheck ? lastPatchCheckIndex : 0;
        const checkPatches = patchHistory.slice(checkFrom);

        const matchesRule = (seen: { op: string; path: string }) => {
          if (op !== undefined && seen.op !== op) {
            return false;
          }
          if (path !== undefined && seen.path !== path) {
            return false;
          }
          if (pathStartsWith !== undefined && !seen.path.startsWith(pathStartsWith)) {
            return false;
          }
          if (paths !== undefined && paths.length > 0 && !paths.includes(seen.path)) {
            return false;
          }
          return true;
        };

        const matched = checkPatches.find(matchesRule);
        if (matched) {
          throw new Error(
            message ||
              `Assertion failed: unexpected patch detected op=${matched.op}, path=${matched.path}`,
          );
        }

        const scopeLabel = sinceLastCheck ? "since last patch check" : "from scenario start";
        console.log(
          chalk.green(
            `✅ Patch assertion passed (${scopeLabel}): no matching patch found`,
          ),
        );
        lastPatchCheckIndex = patchHistory.length;
      } else if (type === "log") {
        console.log(chalk.cyan(`ℹ️  ${step.message || ""}`));
      } else if (type === "state") {
        const state = view.getState();
        console.log(
          chalk.yellow(`📊 Current state: ${JSON.stringify(state, null, 2)}`),
        );
      }
    }

    console.log(
      chalk.green(`✅ Scenario completed: ${basename(scriptPath)}\n`),
    );
  } catch (error) {
    console.error(
      chalk.red(`❌ Scenario failed: ${basename(scriptPath)}: ${error}`),
    );
    throw error;
  } finally {
    unsubscribePatch();
    unsubscribeEvents.forEach((unsubscribe) => unsubscribe());
  }
}

function replacePlaceholder(obj: any, placeholder: string, value: string): any {
  if (typeof obj === "string") {
    return obj.replace(
      new RegExp(placeholder.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"),
      value,
    );
  }
  if (Array.isArray(obj)) {
    return obj.map((item) => replacePlaceholder(item, placeholder, value));
  }
  if (typeof obj === "object" && obj !== null) {
    const result: any = {};
    for (const [key, val] of Object.entries(obj)) {
      // Also replace in keys if needed (though less common)
      const newKey = key.replace(
        new RegExp(placeholder.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"),
        value,
      );
      result[newKey] = replacePlaceholder(val, placeholder, value);
    }
    return result;
  }
  return obj;
}


function hydratePayload(payload: any): any {
  if (payload === null || payload === undefined) return payload;

  if (Array.isArray(payload)) {
    return payload.map((item) => hydratePayload(item));
  }

  if (typeof payload === "object") {
    // Handle explicit type markers
    if ("__type" in payload && "value" in payload) {
      const type = payload.__type;
      const value = payload.value;

      switch (type) {
        case "Position2":
          // Expect value to be { x, y } or { v: { x, y } }
          // If value has v, use value.v, otherwise use value
          const posVal = value.v || value;
          return new Position2(posVal, true); // Assume fixed-point input from JSON
        case "Velocity2":
          const velVal = value.v || value;
          return new Velocity2(velVal, true);
        case "Acceleration2":
          const accVal = value.v || value;
          return new Acceleration2(accVal, true);
        case "Angle":
          // Expect value to be { degrees }
          return new Angle(value.degrees, true);
        case "IVec2":
          return new IVec2(value.x, value.y, true);
        case "IVec3":
          return new IVec3(value.x, value.y, value.z, true);
        default:
          console.warn(chalk.yellow(`⚠️  Unknown type marker: ${type}`));
      }
    }

    // Recursively hydrate object properties
    const result: any = {};
    for (const [key, value] of Object.entries(payload)) {
      result[key] = hydratePayload(value);
    }
    return result;
  }

  return payload;
}

// Admin commands
const adminCommand = program
  .command("admin")
  .description(
    "Admin commands for managing lands (requires admin authentication)",
  );

adminCommand
  .command("list")
  .description("List all lands")
  .requiredOption("-u, --url <url>", "Server URL (e.g., http://localhost:8080)")
  .option("-k, --api-key <key>", "Admin API key")
  .option("-t, --token <token>", "JWT token with admin role")
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(
          chalk.red("Error: Either --api-key or --token is required"),
        );
        process.exit(1);
      }

      console.log(chalk.blue(`📋 Fetching land list from ${options.url}...`));
      const lands = await admin.listLands({
        url: options.url,
        apiKey: options.apiKey,
        token: options.token,
      });
      admin.printLandList(lands);
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`));
      process.exit(1);
    }
  });

adminCommand
  .command("stats")
  .description("Get system statistics")
  .requiredOption("-u, --url <url>", "Server URL (e.g., http://localhost:8080)")
  .option("-k, --api-key <key>", "Admin API key")
  .option("-t, --token <token>", "JWT token with admin role")
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(
          chalk.red("Error: Either --api-key or --token is required"),
        );
        process.exit(1);
      }

      console.log(
        chalk.blue(`📊 Fetching system statistics from ${options.url}...`),
      );
      const stats = await admin.getSystemStats({
        url: options.url,
        apiKey: options.apiKey,
        token: options.token,
      });
      admin.printSystemStats(stats);
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`));
      process.exit(1);
    }
  });

adminCommand
  .command("get")
  .description("Get information about a specific land")
  .requiredOption("-u, --url <url>", "Server URL (e.g., http://localhost:8080)")
  .requiredOption("-l, --land <landID>", "Land ID")
  .option("-k, --api-key <key>", "Admin API key")
  .option("-t, --token <token>", "JWT token with admin role")
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(
          chalk.red("Error: Either --api-key or --token is required"),
        );
        process.exit(1);
      }

      console.log(
        chalk.blue(
          `🔍 Fetching land info for ${options.land} from ${options.url}...`,
        ),
      );
      const stats = await admin.getLandStats({
        url: options.url,
        landID: options.land,
        apiKey: options.apiKey,
        token: options.token,
      });
      if (stats) {
        admin.printLandStats(stats);
      } else {
        console.log(chalk.yellow(`  Land not found: ${options.land}`));
      }
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`));
      process.exit(1);
    }
  });

adminCommand
  .command("delete")
  .description("Delete a land (requires admin role)")
  .requiredOption("-u, --url <url>", "Server URL (e.g., http://localhost:8080)")
  .requiredOption("-l, --land <landID>", "Land ID to delete")
  .option("-k, --api-key <key>", "Admin API key")
  .option("-t, --token <token>", "JWT token with admin role")
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(
          chalk.red("Error: Either --api-key or --token is required"),
        );
        process.exit(1);
      }

      console.log(
        chalk.yellow(
          `🗑️  Deleting land ${options.land} from ${options.url}...`,
        ),
      );
      await admin.deleteLand({
        url: options.url,
        landID: options.land,
        apiKey: options.apiKey,
        token: options.token,
      });
      console.log(chalk.green(`✅ Successfully deleted land: ${options.land}`));
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`));
      process.exit(1);
    }
  });

adminCommand
  .command("reevaluation-records")
  .description("List all reevaluation records")
  .requiredOption("-u, --url <url>", "Server URL (e.g., http://localhost:8080)")
  .option("-k, --api-key <key>", "Admin API key")
  .option("-t, --token <token>", "JWT token with admin role")
  .action(async (options) => {
    try {
      if (!options.apiKey && !options.token) {
        console.error(
          chalk.red("Error: Either --api-key or --token is required"),
        );
        process.exit(1);
      }

      console.log(
        chalk.blue(`📋 Fetching reevaluation records from ${options.url}...`),
      );
      const records = await admin.listReevaluationRecords({
        url: options.url,
        apiKey: options.apiKey,
        token: options.token,
      });
      admin.printReevaluationRecordsList(records);
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`));
      process.exit(1);
    }
  });

adminCommand
  .command("reevaluation-verify")
  .description("Verify a reevaluation record")
  .requiredOption("-u, --url <url>", "Server URL (e.g., http://localhost:8080)")
  .requiredOption("-r, --record <path>", "Record file path (from list output)")
  .option("-l, --land-type <type>", "Land type to verify", "hero-defense")
  .option("-k, --api-key <key>", "Admin API key (the monitor start needs admin access)")
  .option("-t, --token <token>", "JWT token (optional)")
  .action(async (options) => {
    try {
      await admin.verifyReevaluationRecord({
        url: options.url,
        landType: options.landType,
        recordPath: options.record,
        apiKey: options.apiKey,
        token: options.token,
      });
    } catch (error: any) {
      console.error(chalk.red(`Error: ${error.message}`));
      process.exit(1);
    }
  });

program.parse();

function deriveSchemaBaseUrl(wsUrl: string): string {
  const url = new URL(wsUrl);
  const schemaProtocol = url.protocol === "wss:" ? "https:" : "http:";
  return `${schemaProtocol}//${url.host}`;
}

function buildTransportEncoding(stateUpdateEncoding?: string) {
  const normalized = (stateUpdateEncoding ?? "auto").toLowerCase();

  // Handle messagepack mode
  // Note: When message is messagepack, stateUpdate is also messagepack format (opcodeMessagePack)
  // TypeScript types don't include opcodeMessagePack, so we use 'auto' decoding
  // The SDK will automatically detect binary format and decode correctly
  if (normalized === "messagepack" || normalized === "msgpack") {
    return {
      message: "messagepack",
      stateUpdate: "opcodeJsonArray", // Type doesn't support opcodeMessagePack, but decoding will handle it
      stateUpdateDecoding: "auto", // Auto-detect messagepack format from binary data
    } as const;
  }

  // Handle opcodeJsonArray mode
  if (normalized === "opcodejsonarray") {
    return {
      message: "opcodeJsonArray",
      stateUpdate: "opcodeJsonArray",
      stateUpdateDecoding: "opcodeJsonArray",
    } as const;
  }

  // Handle jsonObject mode (default)
  if (normalized === "jsonobject" || normalized === "auto") {
    return {
      message: "json",
      stateUpdate: "jsonObject",
      stateUpdateDecoding: "jsonObject",
    } as const;
  }

  // Default fallback
  return {
    message: "json",
    stateUpdate: "jsonObject",
    stateUpdateDecoding: "jsonObject",
  } as const;
}
