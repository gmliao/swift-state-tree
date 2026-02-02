import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runScenario } from "./run";
import { buildReport, writeReportFiles } from "./report/render-html";
import { readSystemMetrics } from "./system-metrics";

export interface CliArgs {
    scenarioPath: string;
    workers: number;
    systemMetricsPath?: string;
    outputDir?: string;
    outputName?: string;
}

export function parseArgs(argv: string[]): CliArgs {
    const args = argv.slice(2);
    let scenarioPath = "scenarios/hero-defense/default.json";
    let workers = Math.max(1, os.cpus().length);
    let systemMetricsPath: string | undefined;
    let outputDir: string | undefined;
    let outputName: string | undefined;

    for (let i = 0; i < args.length; i += 1) {
        const arg = args[i];
        if (arg === "--scenario") {
            scenarioPath = args[i + 1];
            i += 1;
        } else if (arg === "--workers") {
            workers = Number(args[i + 1]);
            i += 1;
        } else if (arg === "--system-metrics") {
            systemMetricsPath = args[i + 1];
            i += 1;
        } else if (arg === "--output-dir") {
            outputDir = args[i + 1];
            i += 1;
        } else if (arg === "--output-name") {
            outputName = args[i + 1];
            i += 1;
        }
    }

    return { scenarioPath, workers, systemMetricsPath, outputDir, outputName };
}

export async function main(): Promise<void> {
    const { scenarioPath, workers, systemMetricsPath, outputDir, outputName } = parseArgs(process.argv);
    const resolvedPath = path.resolve(process.cwd(), scenarioPath);
    if (!fs.existsSync(resolvedPath)) {
        throw new Error(`Scenario not found: ${resolvedPath}`);
    }
    const result = await runScenario(resolvedPath, workers);
    const metricsPath = systemMetricsPath ? path.resolve(process.cwd(), systemMetricsPath) : undefined;
    const systemMetrics = metricsPath && fs.existsSync(metricsPath) ? readSystemMetrics(metricsPath) : { system: [] };
    const report = buildReport(result, systemMetrics);
    const outputDirectory = outputDir ? path.resolve(process.cwd(), outputDir) : path.resolve(process.cwd(), "results");
    const baseName = outputName ?? `ws-loadtest-${Date.now()}`;
    writeReportFiles(report, outputDirectory, baseName);
    console.log(`Report written to ${outputDirectory}/${baseName}.{json,html}`);
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error);
        process.exit(1);
    });
}
