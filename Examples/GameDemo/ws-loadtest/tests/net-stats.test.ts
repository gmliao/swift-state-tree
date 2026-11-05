import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { counterDelta, parseListenCounters, readListenCounters } from "../src/net-stats";

const SAMPLE = [
    "TcpExt: SyncookiesSent SyncookiesRecv ListenOverflows ListenDrops TCPHPHits",
    "TcpExt: 0 0 2777 2780 123",
    "IpExt: InNoRoutes InTruncatedPkts",
    "IpExt: 0 0",
    ""
].join("\n");

describe("listen counters", () => {
    it("parses ListenOverflows and ListenDrops from the TcpExt section", () => {
        expect(parseListenCounters(SAMPLE)).toEqual({ listenOverflows: 2777, listenDrops: 2780 });
        expect(parseListenCounters("IpExt: A\nIpExt: 1\n")).toBeUndefined();
    });

    it("reads a file and reports undefined when it is missing", () => {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "netstat-"));
        const file = path.join(dir, "netstat");
        fs.writeFileSync(file, SAMPLE);
        expect(readListenCounters(file)).toEqual({ listenOverflows: 2777, listenDrops: 2780 });
        expect(readListenCounters(path.join(dir, "missing"))).toBeUndefined();
    });

    it("computes the delta, or undefined without both readings", () => {
        expect(counterDelta({ listenOverflows: 10, listenDrops: 12 }, { listenOverflows: 15, listenDrops: 20 })).toEqual({
            listenOverflows: 5,
            listenDrops: 8
        });
        expect(counterDelta(undefined, { listenOverflows: 1, listenDrops: 1 })).toBeUndefined();
    });
});
