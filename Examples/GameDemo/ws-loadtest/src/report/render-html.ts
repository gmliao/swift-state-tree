import fs from "node:fs";
import path from "node:path";
import { percentile, evaluateThresholds } from "../metrics";
import type { RunResult, PhaseResult } from "../run";
import type { Thresholds } from "../types";
import type { SystemMetrics } from "../system-metrics";

export interface PhaseSummary {
    name: string;
    connections: number;
    actionsSent: number;
    errorRate: number;
    disconnectRate: number;
    rtt: { p50: number; p95: number; p99: number };
    update: { p50: number; p95: number; p99: number };
    thresholds?: Thresholds;
    passed: boolean;
    failures: string[];
}

export interface Report {
    meta: {
        scenarioName: string;
        generatedAt: string;
        /** Server StateSync interval in ms; used for client-jitter hint. */
        syncIntervalMs?: number;
    };
    phases: PhaseSummary[];
    system: SystemMetrics["system"];
}

export function buildReport(run: RunResult, systemMetrics: SystemMetrics): Report {
    const phases = run.phases.map((phase) => summarizePhase(phase));
    return {
        meta: {
            scenarioName: run.scenarioName,
            generatedAt: new Date().toISOString(),
            syncIntervalMs: run.syncIntervalMs
        },
        phases,
        system: systemMetrics.system
    };
}

function summarizePhase(phase: PhaseResult): PhaseSummary {
    const connections = phase.config.rooms * phase.config.playersPerRoom;
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

    return {
        name: phase.name,
        connections,
        actionsSent,
        errorRate,
        disconnectRate,
        rtt: { p50: rttP50, p95: rttP95, p99: rttP99 },
        update: { p50: updateP50, p95: updateP95, p99: updateP99 },
        thresholds: phase.config.thresholds,
        passed,
        failures
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

export function renderHtml(report: Report): string {
    const json = JSON.stringify(report, null, 2).replace(/<\/script>/g, "<\\/script>");
    const hintHtml = clientJitterHint(report);
    const phasesRows = report.phases
        .map(
            (phase) => `
                  <tr class="hover:bg-white/5 transition-colors">
                    <td class="px-4 py-2 font-medium text-slate-200">${phase.name}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.connections}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.actionsSent}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.errorRate.toFixed(4)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.disconnectRate.toFixed(4)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.rtt.p95.toFixed(2)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.rtt.p99.toFixed(2)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.update.p95.toFixed(2)}</td>
                    <td class="px-4 py-2 text-slate-300">${phase.update.p99.toFixed(2)}</td>
                    <td class="px-4 py-2"><span class="${phase.passed ? "text-green-500 font-medium" : "text-red-500 font-medium"}">${phase.passed ? "PASS" : "FAIL"}</span></td>
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
              <th class="px-4 py-3 font-semibold">Actions Sent</th>
              <th class="px-4 py-3 font-semibold">Error Rate</th>
              <th class="px-4 py-3 font-semibold">Disconnect Rate</th>
              <th class="px-4 py-3 font-semibold">RTT p95</th>
              <th class="px-4 py-3 font-semibold">RTT p99</th>
              <th class="px-4 py-3 font-semibold">Update p95</th>
              <th class="px-4 py-3 font-semibold">Update p99</th>
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
