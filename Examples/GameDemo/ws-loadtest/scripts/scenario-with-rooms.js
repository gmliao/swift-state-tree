#!/usr/bin/env node
// Writes a copy of the scenario JSON with all phase room counts set to the given value.
// Usage: node scenario-with-rooms.js <input-scenario.json> <output-scenario.json> <rooms>

const fs = require("fs");
const path = require("path");

const inputPath = process.argv[2];
const outputPath = process.argv[3];
const rooms = parseInt(process.argv[4], 10);

if (!inputPath || !outputPath || !Number.isFinite(rooms) || rooms < 1) {
  process.exit(1);
}

const data = JSON.parse(fs.readFileSync(inputPath, "utf8"));
if (data.phases && typeof data.phases === "object") {
  for (const key of Object.keys(data.phases)) {
    if (data.phases[key] && typeof data.phases[key] === "object") {
      data.phases[key].rooms = rooms;
    }
  }
}
fs.writeFileSync(outputPath, JSON.stringify(data, null, 2));
