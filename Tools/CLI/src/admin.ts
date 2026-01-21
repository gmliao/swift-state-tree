import chalk from "chalk";
import { StateTreeRuntime } from "@swiftstatetree/sdk/core";
import { ChalkLogger } from "./logger";
import { fetchSchema } from "./schema";

export interface AdminOptions {
  url: string;
  apiKey?: string;
  token?: string;
  landID?: string;
}

export interface LandInfo {
  landID: string;
  playerCount: number;
  createdAt?: string;
  lastActivityAt?: string; // Match server field name
}

export interface SystemStats {
  totalLands: number;
  totalPlayers: number;
}

export interface AdminAPIResponse<T = any> {
  success: boolean;
  data?: T;
  error?: {
    code: string;
    message: string;
    details?: Record<string, any>;
  };
}

/**
 * Make an authenticated admin API request
 */
async function adminRequest(
  url: string,
  method: string,
  options: AdminOptions,
): Promise<Response> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };

  // Add authentication
  if (options.apiKey) {
    headers["X-API-Key"] = options.apiKey;
  } else if (options.token) {
    headers["Authorization"] = `Bearer ${options.token}`;
  }

  const response = await fetch(url, {
    method,
    headers,
  });

  // Try to parse as unified response format first
  if (!response.ok) {
    try {
      const errorResponse = (await response.json()) as AdminAPIResponse;
      if (errorResponse.error) {
        throw new Error(
          errorResponse.error.message || `HTTP ${response.status}`,
        );
      }
    } catch {
      // If parsing fails, fall back to status code
    }

    if (response.status === 401) {
      throw new Error("Unauthorized: Invalid API key or token");
    } else if (response.status === 403) {
      throw new Error("Forbidden: Insufficient permissions");
    } else if (response.status === 404) {
      throw new Error("Not found: Resource does not exist");
    } else {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }
  }

  return response;
}

/**
 * List all lands
 */
export async function listLands(options: AdminOptions): Promise<string[]> {
  const baseUrl = options.url.replace(/\/$/, "");
  const url = `${baseUrl}/admin/lands`;

  const response = await adminRequest(url, "GET", options);
  const json = await response.json();

  // Support both unified format and legacy format (backward compatibility)
  if (json && typeof json === "object" && "success" in json) {
    const apiResponse = json as AdminAPIResponse<string[]>;
    if (!apiResponse.success || !apiResponse.data) {
      throw new Error(apiResponse.error?.message || "Failed to list lands");
    }
    return apiResponse.data;
  } else {
    // Legacy format: direct array
    return json as string[];
  }
}

/**
 * Get land statistics
 */
export async function getLandStats(
  options: AdminOptions,
): Promise<LandInfo | null> {
  if (!options.landID) {
    throw new Error("landID is required");
  }

  const baseUrl = options.url.replace(/\/$/, "");
  const url = `${baseUrl}/admin/lands/${encodeURIComponent(options.landID)}`;

  const response = await adminRequest(url, "GET", options);
  const json = await response.json();

  // Support both unified format and legacy format (backward compatibility)
  if (json && typeof json === "object" && "success" in json) {
    const apiResponse = json as AdminAPIResponse<LandInfo>;
    if (!apiResponse.success) {
      if (apiResponse.error?.code === "NOT_FOUND") {
        return null;
      }
      throw new Error(apiResponse.error?.message || "Failed to get land stats");
    }
    return apiResponse.data || null;
  } else {
    // Legacy format: direct object
    return json as LandInfo;
  }
}

/**
 * Get system statistics
 */
export async function getSystemStats(
  options: AdminOptions,
): Promise<SystemStats> {
  const baseUrl = options.url.replace(/\/$/, "");
  const url = `${baseUrl}/admin/stats`;

  const response = await adminRequest(url, "GET", options);
  const json = await response.json();

  // Support both unified format and legacy format (backward compatibility)
  if (json && typeof json === "object" && "success" in json) {
    const apiResponse = json as AdminAPIResponse<SystemStats>;
    if (!apiResponse.success || !apiResponse.data) {
      throw new Error(
        apiResponse.error?.message || "Failed to get system stats",
      );
    }
    return apiResponse.data;
  } else {
    // Legacy format: direct object
    return json as SystemStats;
  }
}

/**
 * Delete a land
 */
export async function deleteLand(options: AdminOptions): Promise<void> {
  if (!options.landID) {
    throw new Error("landID is required");
  }

  const baseUrl = options.url.replace(/\/$/, "");
  const url = `${baseUrl}/admin/lands/${encodeURIComponent(options.landID)}`;

  const response = await adminRequest(url, "DELETE", options);

  // DELETE may return empty body or unified format
  try {
    const text = await response.text();
    if (text) {
      const json = JSON.parse(text);
      if (json && typeof json === "object" && "success" in json) {
        const apiResponse = json as AdminAPIResponse;
        if (!apiResponse.success) {
          throw new Error(
            apiResponse.error?.message || "Failed to delete land",
          );
        }
      }
    }
  } catch {
    // Empty response or non-JSON is fine for DELETE
  }
}

/**
 * Download a land's re-evaluation record (JSON).
 */
export async function downloadReevaluationRecord(
  options: AdminOptions,
): Promise<any> {
  if (!options.landID) {
    throw new Error("landID is required");
  }

  const baseUrl = options.url.replace(/\/$/, "");
  const url = `${baseUrl}/admin/lands/${encodeURIComponent(options.landID)}/reevaluation-record`;

  const response = await adminRequest(url, "GET", options);
  return await response.json();
}

/**
 * Print formatted land list
 */
export function printLandList(lands: string[]): void {
  if (lands.length === 0) {
    console.log(chalk.yellow("  No lands found"));
    return;
  }

  console.log(chalk.blue(`  Found ${lands.length} land(s):\n`));
  lands.forEach((landID, index) => {
    console.log(chalk.cyan(`  ${index + 1}. ${landID}`));
  });
}

/**
 * Print formatted land statistics
 */
export function printLandStats(stats: LandInfo): void {
  console.log(chalk.blue(`\n  Land: ${chalk.bold(stats.landID)}`));
  console.log(chalk.gray(`  ──────────────────────────`));
  console.log(chalk.white(`  Players: ${chalk.bold(stats.playerCount)}`));
  if (stats.createdAt) {
    console.log(chalk.white(`  Created: ${chalk.bold(stats.createdAt)}`));
  }
  if (stats.lastActivityAt) {
    console.log(
      chalk.white(`  Last Activity: ${chalk.bold(stats.lastActivityAt)}`),
    );
  }
}

/**
 * Print formatted system statistics
 */
export function printSystemStats(stats: SystemStats): void {
  console.log(chalk.blue(`\n  System Statistics`));
  console.log(chalk.gray(`  ──────────────────────────`));
  console.log(chalk.white(`  Total Lands: ${chalk.bold(stats.totalLands)}`));
  console.log(
    chalk.white(`  Total Players: ${chalk.bold(stats.totalPlayers)}`),
  );
}

/**
 * List all reevaluation records
 */
export async function listReevaluationRecords(
  options: AdminOptions,
): Promise<string[]> {
  const baseUrl = options.url.replace(/\/$/, "");
  const url = `${baseUrl}/admin/reevaluation/records`;

  const response = await adminRequest(url, "GET", options);
  const json = await response.json();

  if (json && typeof json === "object" && "success" in json) {
    const apiResponse = json as AdminAPIResponse<string[]>;
    if (!apiResponse.success || !apiResponse.data) {
      throw new Error(
        apiResponse.error?.message || "Failed to list reevaluation records",
      );
    }
    return apiResponse.data;
  } else {
    return json as string[];
  }
}

/**
 * Print reevaluation records list
 */
export function printReevaluationRecordsList(records: string[]) {
  console.log(
    chalk.green(`\n📋 Found ${records.length} reevaluation record(s):\n`),
  );

  if (records.length === 0) {
    console.log("  No records found.");
  } else {
    records.forEach((record, index) => {
      console.log(`  [${index + 1}] ${record}`);
    });
  }
}

export async function verifyReevaluationRecord(params: {
  url: string;
  landType: string;
  recordPath: string;
  token?: string;
}) {
  const logger = new ChalkLogger();

  // 1. Fetch Schema
  const httpUrl = params.url.replace(/^ws/, "http").replace(/^wss/, "https");
  const schemaBaseUrl = httpUrl.replace(/\/$/, "");
  // fetchSchema automatically adds /schema if needed, or we pass base
  // cli.ts passes base url. `fetchSchema(base)` calls `${base}/schema`.
  const schema = await fetchSchema(schemaBaseUrl);

  // 2. Setup Runtime
  const transportEncoding = {
    message: "messagepack",
    stateUpdate: "opcodeJsonArray",
    stateUpdateDecoding: "auto",
  } as const;

  const runtime = new StateTreeRuntime({ logger, transportEncoding });

  // 3. Connect
  let wsUrl = params.url.replace(/^http/, "ws");
  // ensure no trailing slash before appending path
  wsUrl = wsUrl.replace(/\/$/, "");
  if (!wsUrl.endsWith("/reevaluation-monitor")) {
    wsUrl += "/reevaluation-monitor";
  }

  if (params.token) {
    wsUrl += (wsUrl.includes("?") ? "&" : "?") + `token=${params.token}`;
  }

  console.log(chalk.blue(`🔌 Connecting to ${wsUrl}...`));
  await runtime.connect(wsUrl);

  // 4. Create View & Join
  const view = runtime.createView("reevaluation-monitor", {
    schema: schema as any,
    logger,
  });

  console.log(chalk.blue("Joining..."));
  const joinResult = await view.join();

  if (!joinResult.success) {
    console.error(chalk.red(`Join failed: ${joinResult.reason}`));
    await runtime.disconnect();
    process.exit(1);
  }

  console.log(chalk.green("✅ Connected to Reevaluation Monitor"));

  // 5. Send Action
  await view.sendAction("StartVerificationAction", {
    landType: params.landType,
    recordFilePath: params.recordPath,
  });

  console.log(
    chalk.blue(`🚀 Starting verification for ${params.recordPath}...`),
  );

  // Monitor state
  let lastPercent = -1;

  const interval = setInterval(() => {
    const state = view.getState() as any;
    if (!state) return;

    // State is flattened in ReevaluationMonitorState
    const phase = state.status || "idle";
    const current = state.processedTicks || 0;
    const total = state.totalTicks || 1;
    const correct = state.correctTicks || 0;
    const mismatch = state.mismatchedTicks || 0;

    if (phase === "loading") {
      // console.log("⏳ Loading record...");
    } else if (phase === "verifying") {
      const percent = total > 0 ? Math.floor((current / total) * 100) : 0;
      if (percent > lastPercent || percent === 0) {
        process.stdout.write(
          `\r🔍 Verifying: [${percent}%] Tick: ${current}/${total} (✅ ${correct} ❌ ${mismatch})`,
        );
        lastPercent = percent;
      }
    } else if (phase === "completed") {
      clearInterval(interval);
      process.stdout.write(
        `\r🔍 Verifying: [100%] Tick: ${current}/${total} (✅ ${correct} ❌ ${mismatch})`,
      );
      console.log(`\n✅ Verification Completed!`);
      console.log(`Summary: correct=${correct}, mismatch=${mismatch}`);
      runtime.disconnect();
      process.exit(0);
    } else if (phase === "failed") {
      clearInterval(interval);
      console.log(`\n❌ Verification Failed: ${state.errorMessage}`);
      runtime.disconnect();
      process.exit(1);
    }
  }, 100);

  // Keep alive
  await new Promise<void>(() => {});
}
