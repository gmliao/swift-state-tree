import fs from "node:fs";
import path from "node:path";
import { percentile, evaluateThresholds } from "../metrics";
import type { RunResult, PhaseResult } from "../run";
import type { Thresholds } from "../types";

export interface SystemMetrics {
    system: Array<Record<string, unknown>>;
}

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
    };
    phases: PhaseSummary[];
    system: Array<Record<string, unknown>>;
}

export function buildReport(run: RunResult, systemMetrics: SystemMetrics): Report {
    const phases = run.phases.map((phase) => summarizePhase(phase));
    return {
        meta: {
            scenarioName: run.scenarioName,
            generatedAt: new Date().toISOString()
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

export function renderHtml(report: Report): string {
    const json = JSON.stringify(report, null, 2);
    return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8" />
  <title>UWS Load Test Report</title>
  <style>
    body { font-family: Arial, sans-serif; padding: 20px; }
    table { border-collapse: collapse; width: 100%; margin-top: 12px; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background: #f3f3f3; }
    .fail { color: #b00020; font-weight: bold; }
    .pass { color: #0a7a1f; font-weight: bold; }
    pre { background: #f8f8f8; padding: 12px; overflow: auto; }
  </style>
</head>
<body>
  <h1>UWS Load Test Report</h1>
  <h2>${report.meta.scenarioName}</h2>
  <table>
    <thead>
      <tr>
        <th>Phase</th>
        <th>Connections</th>
        <th>Actions Sent</th>
        <th>Error Rate</th>
        <th>Disconnect Rate</th>
        <th>RTT p95</th>
        <th>RTT p99</th>
        <th>Update p95</th>
        <th>Update p99</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
      ${report.phases
          .map(
              (phase) => `<tr>
          <td>${phase.name}</td>
          <td>${phase.connections}</td>
          <td>${phase.actionsSent}</td>
          <td>${phase.errorRate.toFixed(4)}</td>
          <td>${phase.disconnectRate.toFixed(4)}</td>
          <td>${phase.rtt.p95.toFixed(2)}</td>
          <td>${phase.rtt.p99.toFixed(2)}</td>
          <td>${phase.update.p95.toFixed(2)}</td>
          <td>${phase.update.p99.toFixed(2)}</td>
          <td class="${phase.passed ? "pass" : "fail"}">${phase.passed ? "PASS" : "FAIL"}</td>
        </tr>`
          )
          .join("")}
    </tbody>
  </table>

  <h3>Raw JSON</h3>
  <pre>${json}</pre>
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
