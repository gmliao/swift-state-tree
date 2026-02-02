#!/usr/bin/env node
// Prints a console table of each run's data from scalability summary.json.
// Usage: node print-summary-table.js <summary.json>

const fs = require("fs");
const path = require("path");

const summaryPath = process.argv[2];
if (!summaryPath || !fs.existsSync(summaryPath)) {
  process.exit(1);
}

const data = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
const runs = data.runs || [];
if (runs.length === 0) {
  console.log("  (no runs)");
  process.exit(0);
}

const hasRooms = runs.some((r) => r.rooms != null);
const colRun = 4;
const colRooms = hasRooms ? 6 : 0;
const colStatus = 6;
const colDuration = 10;
const colPhases = 12;

let header = "  Run  ";
if (hasRooms) header += "Rooms  ";
header += "Status   Duration  ";
header += "Preflight (pass err% rtt upd)  Steady (pass err% rtt upd)  Postflight (pass err% rtt upd)";
console.log(header);
console.log("  " + "-".repeat(Math.max(80, header.length - 2)));

for (const r of runs) {
  const status = r.success ? "PASS" : "FAIL";
  const duration = (r.durationSeconds != null ? r.durationSeconds : 0) + "s";
  let line = "  " + String(r.runIndex).padEnd(colRun);
  if (hasRooms) line += String(r.rooms != null ? r.rooms : "-").padEnd(colRooms);
  line += status.padEnd(colStatus) + duration.padEnd(colDuration);
  const phases = r.phases || [];
  for (const p of phases) {
    const pass = p.passed ? "ok" : "FAIL";
    const err = p.errorRate != null ? (p.errorRate * 100).toFixed(2) + "%" : "-";
    const rtt = p.rttP95 != null ? p.rttP95.toFixed(0) : "-";
    const upd = p.updateP95 != null ? p.updateP95.toFixed(0) : "-";
    line += "  " + p.name + ": " + pass + " " + err + " rtt" + rtt + " upd" + upd;
  }
  console.log(line);
}
