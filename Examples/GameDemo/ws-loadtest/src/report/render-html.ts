import fs from "node:fs";
import path from "node:path";
import { percentile, evaluateThresholds } from "../metrics";
import type {
    RunResult,
    PhaseResult,
    RunConfig,
    PhaseConnections,
    CloseSummary,
    PhaseMeasurement,
    ListenQueueDeltas,
    PhaseTotals
} from "../run";
import type { LayoutSummary } from "../layout";
import type { ListenCounters } from "../net-stats";
import type { Thresholds } from "../types";
import type { PermessageDeflateCounts } from "../worker";
import type { SystemMetrics } from "../system-metrics";
import { SERVER_SYNC_FIELDS, type ServerSyncSummary } from "../server-sync";

export interface PhaseSummary {
    name: string;
    connections: number;
    /** Lands and players per land this phase actually used. */
    layout?: LayoutSummary;
    /** Opened, reused and closed connections, and every close seen in the phase. */
    connectionLifecycle?: PhaseConnections;
    /** Warm-up, measured window, send rate and per-window samples. RTT and update use the measured window. */
    measurement?: PhaseMeasurement;
    /**
     * Kernel listen-queue overflow and drop increase, host- or netns-wide (Linux only): over the
     * whole phase and over the measured window.
     */
    listenQueue?: ListenQueueDeltas;
    /** Actions, error rate and disconnect rate below are for the measured window. */
    actionsSent: number;
    /** Whole-phase counts, including the warm-up and the transition. */
    phaseTotals?: PhaseTotals;
    /**
     * Error frames and socket errors received in the measured window divided by the actions sent
     * in it (0 when none were sent). Join failures are not errors here; they fail the phase on
     * their own (`connectionLifecycle.joinFailures`), so a large action count can't dilute them.
     */
    errorRate: number;
    disconnectRate: number;
    rtt: { p50: number; p95: number; p99: number };
    update: { p50: number; p95: number; p99: number };
    thresholds?: Thresholds;
    passed: boolean;
    failures: string[];
    /** Problems that don't fail the phase but make a metric meaningless (see `phaseWarningsOf`). */
    warnings: string[];
}

export interface Report {
    meta: {
        scenarioName: string;
        generatedAt: string;
        /** Server StateSync interval in ms; used for client-jitter hint. */
        syncIntervalMs?: number;
        /** The resolved run configuration (layout, connect mode and rate, workers, phase sizes). */
        runConfig?: RunConfig;
        /** Closes when the run ended. */
        shutdownCloses?: CloseSummary;
        /** Connections opened with and without permessage-deflate negotiated. */
        permessageDeflate?: PermessageDeflateCounts;
        /** Kernel listen-queue overflow and drop increase over the run, host- or netns-wide (Linux only). */
        listenQueue?: { scope: "host-or-netns"; run?: ListenCounters };
    };
    phases: PhaseSummary[];
    system: SystemMetrics["system"];
    /**
     * Server-side sync counters from the transport profile (`--transport-profile`); null when
     * the run had no profile or the server predates the counters ("n/a" in the HTML).
     */
    serverSync: ServerSyncSummary | null;
}

export function buildReport(run: RunResult, systemMetrics: SystemMetrics, serverSync: ServerSyncSummary | null = null): Report {
    const phases = run.phases.map((phase) => summarizePhase(phase, run.runConfig));
    return {
        meta: {
            scenarioName: run.scenarioName,
            generatedAt: new Date().toISOString(),
            syncIntervalMs: run.syncIntervalMs,
            runConfig: run.runConfig,
            shutdownCloses: run.shutdownCloses,
            permessageDeflate: run.permessageDeflate,
            listenQueue: run.listenQueue
        },
        phases,
        system: systemMetrics.system,
        serverSync
    };
}

/**
 * Join checks, independent of the scenario's thresholds. A phase fails when any join failed,
 * when fewer connections than the target are joined at the phase end, or, when the warm-up is
 * longer than the connect ramp, at the measured-window start (`measurement.joined
 * .atMeasuredStart`). The time-weighted `joined.average` is reported only.
 * `--allow-join-failures` turns all of these off. With `--allow-partial-ramp`, which opens fewer
 * connections than the target by design, the joined counts are compared with the connections
 * the phase held (kept or started).
 */
export function joinFailuresOf(phase: PhaseResult, runConfig?: Pick<RunConfig, "allowJoinFailures" | "allowPartialRamp">): string[] {
    if (runConfig?.allowJoinFailures) {
        return [];
    }
    const failures: string[] = [];
    const connections = phase.connections;
    const joinFailures = connections?.joinFailures?.phase ?? 0;
    if (joinFailures > 0) {
        const reasons = Object.entries(connections.joinFailures.byReason)
            .map(([reason, count]) => `${reason} ${count}`)
            .join(", ");
        failures.push(`joinFailures ${joinFailures} > 0 (${reasons})`);
    }
    if (!connections) {
        return failures;
    }
    // A partial ramp opens fewer connections than the target by design: compare with the
    // connections the phase held (kept or started by the ramp).
    const partial = runConfig?.allowPartialRamp === true;
    const expected = partial ? connections.reused + connections.started : connections.target;
    const expectedLabel = partial ? `opened ${expected}` : `target ${expected}`;
    if (connections.joinedAtEnd < expected) {
        failures.push(`joined ${connections.joinedAtEnd} < ${expectedLabel} (at the phase end${partial ? ", partial ramp" : ""})`);
    }
    // Slow joins: with a warm-up longer than the ramp, everything must be joined when the
    // measured window starts, or the window ran partly unloaded.
    const atStart = phase.measurement?.joined?.atMeasuredStart;
    if (typeof atStart === "number" && atStart < expected) {
        failures.push(`joined ${atStart} < ${expectedLabel} (at the measured-window start)`);
    }
    return failures;
}

/**
 * Warnings that don't fail the phase. Joined clients with no state-update samples in the
 * measured window mean the update metrics are empty (update p50/p95/p99 report 0), as when a
 * frame kind isn't recognized (#138), not that updates were fast.
 */
export function phaseWarningsOf(phase: PhaseResult): string[] {
    const warnings: string[] = [];
    const joined = phase.connections?.joinedAtEnd ?? 0;
    if (joined > 0 && phase.report.stateUpdateIntervalsMs.length === 0) {
        warnings.push(`no state-update samples with ${joined} joined clients: update percentiles are empty`);
    }
    return warnings;
}

function summarizePhase(phase: PhaseResult, runConfig?: RunConfig): PhaseSummary {
    const connections = phase.layout?.connections ?? phase.config.rooms * phase.config.playersPerRoom;
    const actionsSent = phase.report.actionsSent;
    const errorRate = actionsSent > 0 ? phase.report.errorCount / actionsSent : 0;
    const disconnectRate = connections > 0 ? phase.report.disconnectCount / connections : 0;

    const rttP50 = percentile(phase.report.rttMs, 0.5);
    const rttP95 = percentile(phase.report.rttMs, 0.95);
    const rttP99 = percentile(phase.report.rttMs, 0.99);
    const updateP50 = percentile(phase.report.stateUpdateIntervalsMs, 0.5);
    const updateP95 = percentile(phase.report.stateUpdateIntervalsMs, 0.95);
    const updateP99 = percentile(phase.report.stateUpdateIntervalsMs, 0.99);

    let passed = true;
    let failures: string[] = [];
    if (phase.config.thresholds) {
        const evaluated = evaluateThresholds(
            {
                errorRate,
                disconnectRate,
                rttP95,
                rttP99,
                updateP95,
                updateP99
            },
            phase.config.thresholds
        );
        passed = evaluated.passed;
        failures = evaluated.failures;
    }
    const joinFailures = joinFailuresOf(phase, runConfig);
    if (joinFailures.length > 0) {
        passed = false;
        failures = [...failures, ...joinFailures];
    }

    return {
        name: phase.name,
        connections,
        layout: phase.layout,
        connectionLifecycle: phase.connections,
        measurement: phase.measurement,
        listenQueue: phase.listenQueue,
        actionsSent,
        phaseTotals: phase.phaseTotals,
        errorRate,
        disconnectRate,
        rtt: { p50: rttP50, p95: rttP95, p99: rttP99 },
        update: { p50: updateP50, p95: updateP95, p99: updateP99 },
        thresholds: phase.config.thresholds,
        passed,
        failures,
        warnings: phaseWarningsOf(phase)
    };
}

/** RTT p95 below this (ms) is considered "low" for client-jitter hint. */
const RTT_LOW_MS = 15;
/** update p50 within ±this fraction of sync interval is "≈ sync interval". */
const UPDATE_P50_TOLERANCE = 0.15;

function clientJitterHint(report: Report): string {
    const syncMs = report.meta.syncIntervalMs;
    if (syncMs == null || syncMs <= 0) {
        return "";
    }
    const phasesWithEvidence = report.phases.filter((p) => {
        const rttLow = p.rtt.p95 < RTT_LOW_MS;
        const updateP50NearSync = Math.abs(p.update.p50 - syncMs) <= syncMs * UPDATE_P50_TOLERANCE;
        return rttLow && updateP50NearSync;
    });
    if (phasesWithEvidence.length === 0) {
        return "";
    }
    const phaseNames = phasesWithEvidence.map((p) => p.name).join(", ");
    return `
  <h3>Client delay (indirect)</h3>
  <p>No direct metric for client processing delay (Node.js <code>ws</code> does not expose packet arrival time). For phases <strong>${phaseNames}</strong>: RTT p95 is low (&lt; ${RTT_LOW_MS}ms) and update p50 ≈ sync interval (${syncMs}ms) → server is on time; update p95 above ${syncMs}ms is consistent with client event-loop jitter, not systematic client delay.</p>`;
}

function escapeHtml(text: string): string {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Join failures over the phase, with their reasons, e.g. `80 (error 80)`. */
export function joinFailuresCell(connections?: PhaseConnections): string {
    const failures = connections?.joinFailures;
    if (!failures) {
        return "–";
    }
    if (failures.phase === 0) {
        return "0";
    }
    const reasons = Object.entries(failures.byReason)
        .map(([reason, count]) => `${reason} ${count}`)
        .join(", ");
    return `<span class="text-red-400">${failures.phase} (${escapeHtml(reasons)})</span>`;
}

/** The joined count at the measured-window start, or why it isn't checked. */
function joinedAtStartLine(measurement?: PhaseMeasurement): string {
    const joined = measurement?.joined;
    if (!joined) {
        return "";
    }
    const value = joined.atMeasuredStart ?? joined.atMeasuredStartNote ?? "–";
    return `<div class="text-xs text-slate-400">at window start: ${escapeHtml(String(value))}</div>`;
}

/** Why a phase failed, listed under its status. */
/** Warnings under the PASS/FAIL cell, in amber (they don't fail the phase). */
export function warningsList(warnings: string[] | undefined): string {
    if (!warnings || warnings.length === 0) {
        return "";
    }
    const items = warnings.map((w) => `<li>warning: ${escapeHtml(w)}</li>`).join("");
    return `<ul class="text-xs text-amber-400 list-disc ml-4 mt-1">${items}</ul>`;
}

export function failuresList(failures: string[]): string {
    if (failures.length === 0) {
        return "";
    }
    const items = failures.map((f) => `<li>${escapeHtml(f)}</li>`).join("");
    return `<ul class="mt-1 text-xs text-red-300 list-disc list-inside">${items}</ul>`;
}

function runConfigLine(report: Report): string {
    const config = report.meta.runConfig;
    if (!config) {
        return "";
    }
    const connect = config.connectMode === "ramp" ? `ramp ${config.connectRatePerSecond}/s` : "burst";
    const warmups = config.phases.map((p) => `${p.name} ${(p.warmupMs / 1000).toFixed(1)} s`).join(", ");
    return `<p class="text-sm text-slate-400 mb-6">Run <strong>${config.runId}</strong>: layout <strong>${config.layout}</strong>, connect <strong>${connect}</strong>, boundary <strong>${config.boundaryMode}</strong>, send <strong>${config.sendMode}</strong>, ${config.workers} workers, events <strong>${(config.events ?? []).length > 0 ? config.events.map((e) => `${e.name} ${e.ratePerSecond}/s`).join(", ") + ` (seed ${config.eventSeed})` : "none"}</strong>, Node ${config.nodeVersion ?? "?"}. RTT and update exclude the warm-up (${warmups}); per-${config.windowMs} ms windows are in the JSON report.</p>`;
}

/** Client events per player per second, achieved / target rate, by event name. */
function eventsCell(measurement?: PhaseMeasurement): string {
    const events = Object.entries(measurement?.events ?? {});
    if (events.length === 0) {
        return "–";
    }
    return events
        .map(([name, e]) => `${name} ${e.perPlayerPerSecond.toFixed(2)} / ${e.ratePerPlayerPerSecond}`)
        .join("<br/>");
}

/** The load client's CPU in the measured window: worker mean / max and all workers together, % of one core. */
export function clientCpuCell(measurement?: Pick<PhaseMeasurement, "clientCpu">): string {
    const cpu = measurement?.clientCpu;
    if (!cpu || cpu.workers === 0) {
        return "–";
    }
    const pct = cpu.perWorkerPct;
    const orchestrator = cpu.orchestratorPct == null ? "" : ` · orchestrator ${cpu.orchestratorPct.toFixed(0)}%`;
    return `${pct.mean.toFixed(0)}% / ${pct.max.toFixed(0)}%${orchestrator} · ${cpu.totalPct.toFixed(0)}% of ${cpu.cores} cores`;
}

/** The workers' event-loop delay in the measured window: the worst worker's p50 / p99, and the longest delay. */
export function loopDelayCell(measurement?: Pick<PhaseMeasurement, "clientLoopDelay">): string {
    const delay = measurement?.clientLoopDelay;
    if (!delay || delay.workers === 0) {
        return "–";
    }
    return `${delay.p50Ms.max.toFixed(1)} / ${delay.p99Ms.max.toFixed(1)} / ${delay.maxMs.toFixed(0)} ms`;
}

/** The server sync section: counters summed over the profile windows, or "n/a". */
export function serverSyncSection(sync: ServerSyncSummary | null): string {
    const rate = sync?.overdueFoldsPer1000Syncs;
    const headline = !sync
        ? "n/a (no transport profile, or a server without these counters)"
        : `overdue folds per 1000 syncs: ${rate === null || rate === undefined ? "n/a (no sync cycles)" : rate.toFixed(2)}; windows with an overdue fold: ${sync.windowsWithOverdueFold} of ${sync.windows}`;
    const rows = sync
        ? SERVER_SYNC_FIELDS.map((field) => `
            <tr><td class="px-4 py-1 text-slate-300">${field}</td><td class="px-4 py-1 text-slate-300">${sync.totals[field]}</td><td class="px-4 py-1 text-slate-300">${sync.maxWindow[field]}</td></tr>`).join("")
        : "";
    return `<section class="glass-panel rounded-xl p-6 mb-8">
      <h2 class="text-lg font-semibold text-white mb-2">Server sync (transport profile)</h2>
      <p class="text-slate-300 text-sm mb-2">${headline}</p>${sync ? `
      <table class="text-sm"><thead><tr><th class="px-4 py-1 text-left">counter</th><th class="px-4 py-1 text-left">total</th><th class="px-4 py-1 text-left">max per window</th></tr></thead>
        <tbody>${rows}
        </tbody></table>` : ""}
    </section>`;
}

export function renderHtml(report: Report): string {
    const json = JSON.stringify(report, null, 2).replace(/<\/script>/g, "<\\/script>");
    const hintHtml = clientJitterHint(report);
    const phasesRows = report.phases
        .map(
            (phase) => `
                  <tr class="hover:bg-white/5 transition-colors">
                    <td class="px-4 py-2 font-medium text-slate-200">${phase.name}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.connections}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.layout ? `${phase.layout.lands} × ${phase.layout.playersPerLand.min === phase.layout.playersPerLand.max ? phase.layout.playersPerLand.max : `${phase.layout.playersPerLand.min}–${phase.layout.playersPerLand.max}`}` : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.connectionLifecycle ? `${phase.connectionLifecycle.joinedAtEnd} / ${phase.connectionLifecycle.target}` : "–"}${joinedAtStartLine(phase.measurement)}</td>
                    <td class="px-4 py-2 text-slate-300">${joinFailuresCell(phase.connectionLifecycle)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.connectionLifecycle ? `${phase.connectionLifecycle.closes.clientInitiated} / ${phase.connectionLifecycle.closes.serverInitiated}` : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.connectionLifecycle?.transitionMs !== undefined ? `${phase.connectionLifecycle.transitionMs} ms` : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.actionsSent}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.measurement ? `${phase.measurement.sendRate.achievedPerSecond.toFixed(1)} / ${phase.measurement.sendRate.targetPerSecond}` : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.measurement ? phase.measurement.sendRate.lagMs.p99.toFixed(1) : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${listenCell(phase.listenQueue)}</td>
                    <td class="px-4 py-2 text-slate-300">${unansweredCell(phase.measurement)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.errorRate.toFixed(4)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.disconnectRate.toFixed(4)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.phaseTotals ? `${phase.phaseTotals.errorCount} / ${phase.phaseTotals.disconnectCount}` : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.rtt.p95.toFixed(2)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.rtt.p99.toFixed(2)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.update.p95.toFixed(2)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.update.p99.toFixed(2)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.measurement?.stateUpdates ? phase.measurement.stateUpdates.perPlayerPerSecond.toFixed(1) : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.measurement?.stateUpdates ? `${phase.measurement.stateUpdates.bytesMean.toFixed(0)} / ${phase.measurement.stateUpdates.bytes.p99}` : "–"}</td>
                    <td class="px-4 py-2 text-slate-300">${eventsCell(phase.measurement)}</td>
                    <td class="px-4 py-2 text-slate-300">${clientCpuCell(phase.measurement)}</td>
                    <td class="px-4 py-2 text-slate-300">${loopDelayCell(phase.measurement)}</td>
                    <td class="px-4 py-2"><span class="${phase.passed ? "text-green-500 font-medium" : "text-red-500 font-medium"}">${phase.passed ? "PASS" : "FAIL"}</span>${failuresList(phase.failures)}${warningsList(phase.warnings)}</td>
                  </tr>`
        )
        .join("");
    return `<!DOCTYPE html>
<html lang="en" class="dark">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>WS Load Test Report – ${report.meta.scenarioName}</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet" />
  <script>
    tailwind.config = { theme: { extend: { fontFamily: { sans: ["Inter", "sans-serif"] }, colors: { primary: "#3b82f6", success: "#10b981", danger: "#ef4444", surface: "#1e293b", background: "#0f172a" } } } };
  </script>
  <style>
    body { font-family: Inter, sans-serif; }
    .glass-panel { background: rgba(30, 41, 59, 0.7); backdrop-filter: blur(12px); border: 1px solid rgba(255, 255, 255, 0.08); }
    ::-webkit-scrollbar { width: 8px; height: 8px; }
    ::-webkit-scrollbar-track { background: #0f172a; }
    ::-webkit-scrollbar-thumb { background: #334155; border-radius: 4px; }
  </style>
</head>
<body class="bg-[#0f172a] text-slate-100 min-h-screen antialiased">
  <div class="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
    <header class="glass-panel rounded-xl px-6 py-4 mb-8 flex items-center justify-between">
      <div class="flex items-center space-x-3">
        <div class="w-8 h-8 rounded-lg bg-gradient-to-br from-primary to-violet-500 flex items-center justify-center text-white font-bold">WS</div>
        <h1 class="text-xl font-bold text-white">WS Load Test Report</h1>
      </div>
      <div class="text-sm text-slate-400">${report.meta.scenarioName}</div>
    </header>
    ${runConfigLine(report)}
    <section class="glass-panel rounded-xl overflow-hidden mb-8">
      <div class="px-6 py-4 border-b border-white/10 bg-white/[0.02]">
        <h2 class="text-lg font-semibold text-white">Phases</h2>
      </div>
      <div class="overflow-x-auto">
        <table class="w-full text-sm">
          <thead>
            <tr class="border-b border-white/10 bg-white/[0.02] text-slate-400 text-left">
              <th class="px-4 py-3 font-semibold">Phase</th>
              <th class="px-4 py-3 font-semibold">Connections</th>
              <th class="px-4 py-3 font-semibold">Lands × players</th>
              <th class="px-4 py-3 font-semibold">Joined / target</th>
              <th class="px-4 py-3 font-semibold">Join failures (phase)</th>
              <th class="px-4 py-3 font-semibold">Closes client / server</th>
              <th class="px-4 py-3 font-semibold">Transition</th>
              <th class="px-4 py-3 font-semibold">Actions Sent</th>
              <th class="px-4 py-3 font-semibold">Sent/s vs target</th>
              <th class="px-4 py-3 font-semibold">Send lag p99</th>
              <th class="px-4 py-3 font-semibold">Listen overflows / drops, host-wide (measured · phase)</th>
              <th class="px-4 py-3 font-semibold">Unanswered / timed out (measured)</th>
              <th class="px-4 py-3 font-semibold">Error Rate</th>
              <th class="px-4 py-3 font-semibold">Disconnect Rate</th>
              <th class="px-4 py-3 font-semibold">Errors / disconnects (whole phase)</th>
              <th class="px-4 py-3 font-semibold">RTT p95</th>
              <th class="px-4 py-3 font-semibold">RTT p99</th>
              <th class="px-4 py-3 font-semibold">Update p95</th>
              <th class="px-4 py-3 font-semibold">Update p99</th>
              <th class="px-4 py-3 font-semibold">Updates/s per player</th>
              <th class="px-4 py-3 font-semibold">Update payload bytes mean / p99</th>
              <th class="px-4 py-3 font-semibold">Events/s per player</th>
              <th class="px-4 py-3 font-semibold">Load client CPU, worker mean / max · total</th>
              <th class="px-4 py-3 font-semibold">Load client event-loop delay p50 / p99 / max (worst worker)</th>
              <th class="px-4 py-3 font-semibold">Status</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-white/5">${phasesRows}
          </tbody>
        </table>
      </div>
    </section>${hintHtml ? `
    <section class="glass-panel rounded-xl p-6 mb-8">
      <h2 class="text-lg font-semibold text-white mb-2">Client delay (indirect)</h2>
      <div class="text-slate-300 text-sm [&_code]:bg-slate-700 [&_code]:px-1 [&_code]:rounded [&_strong]:text-white [&_strong]:font-medium">${(hintHtml.match(/<p>([\s\S]*?)<\/p>/) ?? ["", hintHtml])[1]}</div>
    </section>` : ""}
    ${serverSyncSection(report.serverSync)}
    <section class="glass-panel rounded-xl p-6">
      <h2 class="text-lg font-semibold text-white mb-4">Raw JSON</h2>
      <pre class="bg-slate-900/80 rounded-lg p-4 text-xs text-slate-300 overflow-x-auto max-h-96">${json}</pre>
    </section>
  </div>
</body>
</html>`;
}

export function writeReportFiles(report: Report, outputDir: string, baseName: string): void {
    fs.mkdirSync(outputDir, { recursive: true });
    const jsonPath = path.join(outputDir, `${baseName}.json`);
    const htmlPath = path.join(outputDir, `${baseName}.html`);
    fs.writeFileSync(jsonPath, JSON.stringify(report, null, 2));
    fs.writeFileSync(htmlPath, renderHtml(report));
}

function listenCell(deltas?: ListenQueueDeltas): string {
    const pair = (c?: ListenCounters) => (c ? `${c.listenOverflows} / ${c.listenDrops}` : "n/a");
    if (!deltas || (!deltas.phase && !deltas.measured)) {
        return "n/a";
    }
    return `${pair(deltas.measured)} · ${pair(deltas.phase)}`;
}

function unansweredCell(measurement?: PhaseMeasurement): string {
    if (!measurement?.unanswered) {
        return "–";
    }
    const m = measurement.unanswered.measured;
    return `${m.pendingAtEnd} / ${m.timedOutAtEnd + m.lateResponses}`;
}
