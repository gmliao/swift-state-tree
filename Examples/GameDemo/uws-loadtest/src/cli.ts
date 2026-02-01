import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { runScenario } from "./run";

export interface CliArgs {
    scenarioPath: string;
    workers: number;
}

export function parseArgs(argv: string[]): CliArgs {
    const args = argv.slice(2);
    let scenarioPath = "scenarios/hero-defense/default.json";
    let workers = Math.max(1, os.cpus().length);

    for (let i = 0; i < args.length; i += 1) {
        const arg = args[i];
        if (arg === "--scenario") {
            scenarioPath = args[i + 1];
            i += 1;
        } else if (arg === "--workers") {
            workers = Number(args[i + 1]);
            i += 1;
        }
    }

    return { scenarioPath, workers };
}

export async function main(): Promise<void> {
    const { scenarioPath, workers } = parseArgs(process.argv);
    const resolvedPath = path.resolve(process.cwd(), scenarioPath);
    if (!fs.existsSync(resolvedPath)) {
        throw new Error(`Scenario not found: ${resolvedPath}`);
    }
    await runScenario(resolvedPath, workers);
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error);
        process.exit(1);
    });
}
