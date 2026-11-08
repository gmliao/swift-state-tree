import fs from "node:fs";
import { convertCapture, TYPINGS, type Typing } from "./colyseus-baseline";

/**
 * `node dist/colyseus-baseline-main.js --capture <src> --out <dir> --report <report.json> [--typing number|int32]`
 *
 * Converts an `EncodingBenchmark --capture-views` directory into a capture of the
 * `@colyseus/schema` baseline (`colyseus-baseline.ts`), which `verify-views` and `time-decode`
 * read like any other. The report holds the package version, the typing, and per run the
 * first-sync bytes and the Node encode time per room per sync.
 */
function main(): void {
    const argv = process.argv.slice(2);
    const value = (flag: string) => {
        const i = argv.indexOf(flag);
        return i >= 0 ? argv[i + 1] : undefined;
    };
    const source = value("--capture");
    const out = value("--out");
    const reportPath = value("--report");
    const typing = (value("--typing") ?? "number") as Typing;
    if (!source || !out || !reportPath || !TYPINGS.includes(typing)) {
        throw new Error("Usage: node dist/colyseus-baseline-main.js --capture <src> --out <dir> --report <file> [--typing number|int32]");
    }
    if (fs.existsSync(out) && fs.readdirSync(out).length > 0) throw new Error(`${out} exists and isn't empty`);
    const report = convertCapture(source, out, typing);
    fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
    console.log(`colyseus-baseline: ${Object.keys(report.runs).length} run(s), @colyseus/schema ${report.version} (${typing}) -> ${out}`);
}

if (require.main === module) {
    try {
        main();
    } catch (error) {
        console.error(error instanceof Error ? error.message : String(error));
        process.exit(1);
    }
}
