#!/usr/bin/env node
// Renders scalability summary JSON into a static HTML report (no runtime JS required).
// Same pattern as Examples/GameDemo/scripts/server-loadtest/parse_monitoring.py + monitoring_report_template.html
// Usage: node render-summary-html.js <summary.json> <rootDir> <output.html>

const fs = require("fs");
const path = require("path");

const summaryPath = process.argv[2];
const rootDir = process.argv[3];
const outputPath = process.argv[4];

if (!summaryPath || !fs.existsSync(summaryPath)) {
  process.exit(1);
}
if (!outputPath) {
  process.exit(1);
}

const scriptDir = path.dirname(__filename);
const templatePath = path.join(scriptDir, "scalability_summary_template.html");

let data;
try {
  data = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
} catch (e) {
  console.error("Failed to read summary JSON", e);
  process.exit(1);
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/\"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function fmtPct(x) {
  if (x == null || !Number.isFinite(x)) return "–";
  return (x * 100).toFixed(1) + "%";
}

const runs = Array.isArray(data.runs) ? data.runs : [];
const summary = data.summary || {};
const totalRuns = summary.totalRuns != null ? summary.totalRuns : runs.length;
const passed = summary.passed != null ? summary.passed : runs.filter((r) => r && r.success).length;
const failed = summary.failed != null ? summary.failed : runs.length - passed;
const passRate = summary.passRate != null ? fmtPct(summary.passRate) : runs.length ? fmtPct(passed / runs.length) : "0%";

const timestampLabel = data.timestamp ? new Date(data.timestamp).toLocaleString() : "";
const cfg = data.config || {};
const cfgScenario = cfg.scenario != null ? String(cfg.scenario) : "–";
const cfgRuns = cfg.runs != null ? String(cfg.runs) : "–";
const cfgRoomCounts = Array.isArray(cfg.roomCounts) ? cfg.roomCounts.join(", ") : "–";
const cfgStartupTimeout = cfg.startupTimeout != null ? String(cfg.startupTimeout) : "–";
const cfgDelayBetweenRuns = cfg.delayBetweenRuns != null ? String(cfg.delayBetweenRuns) : "–";

function getPhase(phases, name) {
  if (!Array.isArray(phases)) return null;
  return phases.find((p) => p && p.name === name) || null;
}

function renderPhaseCell(phase) {
  if (!phase) return `<span class="text-slate-500">–</span>`;
  const ok = phase.passed !== false;
  const icon = ok ? "✓" : "✗";
  const iconClass = ok ? "text-success" : "text-danger";
  const err = phase.errorRate != null ? (phase.errorRate * 100).toFixed(2) + "%" : "–";
  const rtt = phase.rttP95 != null ? Number(phase.rttP95).toFixed(0) : "–";
  const upd = phase.updateP95 != null ? Number(phase.updateP95).toFixed(0) : "–";
  return `<span><span class="${iconClass}">${icon}</span> err ${escapeHtml(err)} rtt ${escapeHtml(rtt)} upd ${escapeHtml(upd)}</span>`;
}

function reportHtmlHref(reportJson) {
  if (!reportJson) return "#";
  return String(reportJson).replace(/\.json$/, ".html");
}

const runsTbody = runs
  .map((r) => {
    const runIndex = r && r.runIndex != null ? String(r.runIndex) : "–";
    const rooms = r && r.rooms != null ? String(r.rooms) : "–";
    const ok = r && r.success;
    const status = ok ? "PASS" : "FAIL";
    const statusClass = ok ? "text-success font-medium" : "text-danger font-medium";
    const dur = r && r.durationSeconds != null ? String(r.durationSeconds) + "s" : "–";
    const reportJson = r && r.reportJson ? String(r.reportJson) : "";
    const reportLinks = reportJson
      ? `<a href="${escapeHtml(reportHtmlHref(reportJson))}" class="text-primary hover:underline" target="_blank">HTML</a>
         <a href="${escapeHtml(reportJson)}" class="text-slate-400 hover:underline ml-1" target="_blank">JSON</a>`
      : `<span class="text-slate-500">–</span>`;
    const pre = renderPhaseCell(getPhase(r && r.phases, "preflight"));
    const steady = renderPhaseCell(getPhase(r && r.phases, "steady"));
    const post = renderPhaseCell(getPhase(r && r.phases, "postflight"));
    return `<tr class="hover:bg-white/5 transition-colors">
      <td class="px-4 py-2 font-medium">${escapeHtml(runIndex)}</td>
      <td class="px-4 py-2">${escapeHtml(rooms)}</td>
      <td class="px-4 py-2"><span class="${statusClass}">${status}</span></td>
      <td class="px-4 py-2">${escapeHtml(dur)}</td>
      <td class="px-4 py-2">${reportLinks}</td>
      <td class="px-4 py-2 text-slate-300">${pre}</td>
      <td class="px-4 py-2 text-slate-300">${steady}</td>
      <td class="px-4 py-2 text-slate-300">${post}</td>
    </tr>`;
  })
  .join("\n");

let jsonStr = JSON.stringify(data, null, 2);
jsonStr = jsonStr.replace(/<\/script>/g, "<\\/script>");

let template;
try {
  template = fs.readFileSync(templatePath, "utf8");
} catch (e) {
  console.error("Failed to read template", e);
  process.exit(1);
}

let html = template;
html = html.replaceAll("{{REPORT_DATA}}", escapeHtml(jsonStr));
html = html.replaceAll("{{TIMESTAMP_LABEL}}", escapeHtml(timestampLabel || "–"));
html = html.replaceAll("{{SUMMARY_TOTAL_RUNS}}", escapeHtml(totalRuns));
html = html.replaceAll("{{SUMMARY_PASSED}}", escapeHtml(passed));
html = html.replaceAll("{{SUMMARY_FAILED}}", escapeHtml(failed));
html = html.replaceAll("{{SUMMARY_PASS_RATE}}", escapeHtml(passRate));
html = html.replaceAll("{{CFG_SCENARIO}}", escapeHtml(cfgScenario));
html = html.replaceAll("{{CFG_RUNS}}", escapeHtml(cfgRuns));
html = html.replaceAll("{{CFG_ROOM_COUNTS}}", escapeHtml(cfgRoomCounts));
html = html.replaceAll("{{CFG_STARTUP_TIMEOUT}}", escapeHtml(cfgStartupTimeout));
html = html.replaceAll("{{CFG_DELAY_BETWEEN_RUNS}}", escapeHtml(cfgDelayBetweenRuns));
html = html.replaceAll("{{RUNS_TBODY}}", runsTbody || `<tr><td class="px-4 py-2 text-slate-500" colspan="8">No runs</td></tr>`);

try {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, html);
} catch (e) {
  console.error("Failed to write HTML", e);
  process.exit(1);
}
