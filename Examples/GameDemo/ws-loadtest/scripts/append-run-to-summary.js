#!/usr/bin/env node
// Appends one run entry to the scalability summary JSON. Called by run-scalability-test.sh.
// Usage: node append-run-to-summary.js <summary.json> <report.json> <rootDir> <runIndex> <exitCode> <success> <durationSeconds> [rooms]

const fs = require("fs");
const path = require("path");

const summaryPath = process.argv[2];
const reportPath = process.argv[3];
const rootDir = process.argv[4];
const runIndex = parseInt(process.argv[5], 10);
const exitCode = parseInt(process.argv[6], 10);
const success = process.argv[7] === "true";
const durationSeconds = parseInt(process.argv[8], 10);
const roomsArg = process.argv[9];
const rooms = roomsArg !== undefined && roomsArg !== "" ? parseInt(roomsArg, 10) : undefined;

if (!summaryPath || !fs.existsSync(summaryPath)) {
  process.exit(1);
}

const data = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
let phasesSummary = [];
let reportJsonRel = "";
if (reportPath && fs.existsSync(reportPath)) {
  const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
  phasesSummary = (report.phases || []).map((p) => ({
    name: p.name,
    passed: p.passed,
    errorRate: p.errorRate,
    disconnectRate: p.disconnectRate,
    rttP95: p.rtt && p.rtt.p95 != null ? p.rtt.p95 : null,
    updateP95: p.update && p.update.p95 != null ? p.update.p95 : null,
  }));
  reportJsonRel = rootDir ? path.relative(rootDir, reportPath) : reportPath;
}

const runEntry = {
  runIndex,
  exitCode,
  success,
  durationSeconds,
  reportJson: reportJsonRel,
  phases: phasesSummary,
};
if (Number.isFinite(rooms)) {
  runEntry.rooms = rooms;
}
data.runs.push(runEntry);

fs.writeFileSync(summaryPath, JSON.stringify(data, null, 2));
