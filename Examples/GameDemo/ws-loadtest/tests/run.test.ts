import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { loadScenario } from "../src/run";

describe("loadScenario", () => {
    it("loads scenario from file", () => {
        const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "ws-loadtest-"));
        const filePath = path.join(tempDir, "scenario.json");
        fs.writeFileSync(filePath, JSON.stringify({ name: "test-scenario", phases: { steady: { durationSeconds: 10 } } }));

        const scenario = loadScenario(filePath);
        expect(scenario.name).toBe("test-scenario");
    });
});
