import fs from "node:fs";
import { loadSdkCore } from "./reconstruction";
import { verifyCapture } from "./verify-views";

/**
 * `node dist/verify-views-main.js --capture <dir> --out <report.json>`: the snapshot/delta
 * baseline's reconstruction-equals-projection gate over an `EncodingBenchmark --capture-views`
 * directory (`verify-views.ts`). Exits 1 when any recipient's rebuilt state differs from its
 * projection after any sync, any frame fails to decode, or the capture is empty.
 */
async function main(): Promise<void> {
    const argv = process.argv.slice(2);
    const value = (flag: string) => {
        const i = argv.indexOf(flag);
        return i >= 0 ? argv[i + 1] : undefined;
    };
    const dir = value("--capture");
    const out = value("--out");
    if (!dir || !out) throw new Error("Usage: node dist/verify-views-main.js --capture <dir> --out <report.json>");
    const sdk = await loadSdkCore();
    // The SDK logs every compressed payload it decodes at debug level; keep the output to the verdict.
    const log = console.log;
    console.log = () => {};
    let report;
    try {
        report = verifyCapture(sdk, dir);
    } finally {
        console.log = log;
    }
    fs.writeFileSync(out, `${JSON.stringify(report, null, 2)}\n`);
    const t = report.totals;
    console.log(`verify-views: ${report.passed ? "PASS" : "FAIL"} rooms=${t.rooms} syncs=${t.syncs} comparisons=${t.comparisons} differences=${t.differences} decodeErrors=${t.decodeErrors} -> ${out}`);
    if (!report.passed) process.exit(1);
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error instanceof Error ? error.message : String(error));
        process.exit(1);
    });
}
