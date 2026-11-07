import { describe, expect, it } from "vitest";
// @ts-expect-error: a plain .mjs script without types
import { compareNetem, parseNetem, shownNetem } from "../scripts/netem-check.mjs";

describe("netem-check", () => {
    it("reads what tc is given and what it shows into the same form", () => {
        expect(parseNetem("delay 40ms 10ms loss 1% rate 134907bit limit 168")).toEqual({ limit: 168, delayUs: 40000, jitterUs: 10000, lossPct: 1, rateBytes: 16863 });
        expect(parseNetem(" limit 168 delay 40ms  10ms loss 1% rate 134904bit")).toEqual({ limit: 168, delayUs: 40000, jitterUs: 10000, lossPct: 1, rateBytes: 16863 });
        // tc shows nothing for a zero delay, loss or rate.
        expect(parseNetem("delay 0ms loss 0% rate 0bit limit 10000")).toEqual(parseNetem(" limit 10000"));
        expect(parseNetem("rate 1Mbit").rateBytes).toBe(125000);
    });

    it("names every parameter that differs, and accepts tc's rate rounding", () => {
        expect(compareNetem("d", "delay 40ms 10ms loss 1% rate 134907bit limit 168", " limit 168 delay 40ms  10ms loss 1% rate 134904bit")).toEqual([]);
        // tc shows a calibrated rate in its own units: 4047216bit as 4047Kbit.
        expect(compareNetem("d", "delay 40ms 10ms loss 1% rate 4047216bit limit 168", " limit 168 delay 40ms  10ms loss 1% rate 4047Kbit")).toEqual([])
        expect(compareNetem("d", "delay 0ms loss 0% rate 0bit limit 168", " limit 168 rate 134904bit")).toEqual(["d: rate 134904 bit/s, wanted none"]);
        expect(compareNetem("d", "delay 0ms loss 0% rate 0bit limit 168", " limit 1000")).toEqual(["d: limit 1000, wanted 168"]);
        expect(compareNetem("d", "delay 40ms loss 1% rate 0bit limit 168", " limit 168 delay 40ms")).toEqual(["d: lossPct 0, wanted 1"]);
    });

    it("finds each shaped netem's line in a dump, and refuses a dump without it", () => {
        const dump = "== tc -s qdisc show dev veth-c1\nqdisc netem 1: root refcnt 13 limit 168 rate 134904bit\n Sent 1 bytes\n== tc -s qdisc show dev veth-s1\nqdisc prio 1: root\nqdisc netem 20: parent 1:2 limit 10000\n";
        expect(shownNetem(dump, "veth-c1", "1:")).toBe(" limit 168 rate 134904bit");
        expect(shownNetem(dump, "veth-s1", "20:")).toBe(" limit 10000");
        expect(() => shownNetem("(dry run)", "veth-c1", "1:")).toThrow(/no qdisc section for veth-c1/);
    });
});
