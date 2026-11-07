import { describe, it, expect } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseSockstat, parseSsQueues, runSampler, sampleOnce } from "../src/sockstat";
import type { Runner } from "../src/sockstat";

const SOCKSTAT = (inuse: number, tw: number) => `sockets: used 300
TCP: inuse ${inuse} orphan 2 tw ${tw} alloc 1600 mem 4321
UDP: inuse 3 mem 1
UDPLITE: inuse 0
RAW: inuse 0
FRAG: inuse 0 memory 0
`;

describe("sockstat sampler", () => {
    it("parses the TCP line of /proc/net/sockstat", () => {
        expect(parseSockstat(SOCKSTAT(1500, 7))).toEqual({ inuse: 1500, orphan: 2, tw: 7, alloc: 1600, mem: 4321 });
        expect(() => parseSockstat("UDP: inuse 3 mem 1\n")).toThrow(/no TCP line/);
        expect(() => parseSockstat("TCP: inuse 1 orphan 0 tw 0 alloc 1\n")).toThrow(/no mem/);
    });

    it("sums established sockets' Recv-Q and Send-Q from ss", () => {
        const ss = [
            "0      0      10.200.0.1:8080  10.201.0.2:40000",
            "0      65536  10.200.0.1:8080  10.201.0.2:40001",
            "1200   131072 10.200.0.1:8080  10.201.0.2:40002",
            ""
        ].join("\n");
        expect(parseSsQueues(ss)).toEqual({
            established: 3, recvQBytes: 1200, sendQBytes: 196608, recvQMaxBytes: 1200, sendQMaxBytes: 131072
        });
        expect(parseSsQueues("")).toMatchObject({ established: 0, sendQBytes: 0 });
        expect(() => parseSsQueues("x y 1.2.3.4:1 5.6.7.8:2")).toThrow(/unexpected ss line/);
    });

    it("takes host-wide mem once and the per-namespace counts and queues from each namespace", async () => {
        const calls: string[] = [];
        const run: Runner = async (netns, command) => {
            calls.push(`${netns || "-"}:${command}`);
            if (netns === "broken") throw new Error("Cannot open network namespace");
            if (command === "cat") return SOCKSTAT(netns === "lt-client" ? 300 : 1200, 0);
            return netns === "lt-client" ? "0 9000 a:1 b:2\n" : "5 0 a:1 b:2\n5 0 a:1 b:3\n";
        };
        const sample = await sampleOnce(["", "lt-client", "broken"], run, () => 42);
        expect(sample).toMatchObject({ t: 42, hostTcpMemPages: 4321, hostTcpOrphan: 2 });
        expect(sample.namespaces).toEqual([
            { netns: "", tcpInuse: 1200, tcpTw: 0, established: 2, recvQBytes: 10, sendQBytes: 0, recvQMaxBytes: 5, sendQMaxBytes: 0 },
            { netns: "lt-client", tcpInuse: 300, tcpTw: 0, established: 1, recvQBytes: 0, sendQBytes: 9000, recvQMaxBytes: 0, sendQMaxBytes: 9000 }
        ]);
        expect(sample.errors).toEqual([{ netns: "broken", error: "Cannot open network namespace" }]);
        expect(calls.sort()).toEqual(["-:cat", "-:ss", "broken:cat", "broken:ss", "lt-client:cat", "lt-client:ss"]);
    });

    it("writes one line per interval until aborted", async () => {
        const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "sockstat-")), "s.jsonl");
        const run: Runner = async (_netns, command) => (command === "cat" ? SOCKSTAT(1, 0) : "");
        const controller = new AbortController();
        setTimeout(() => controller.abort(), 330);
        const count = await runSampler([""], file, 100, controller.signal, run);
        const lines = fs.readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
        expect(lines).toHaveLength(count);
        expect(count).toBeGreaterThanOrEqual(3);
        expect(count).toBeLessThanOrEqual(5);
        expect(lines[1].t - lines[0].t).toBeGreaterThanOrEqual(90);
    });
});
