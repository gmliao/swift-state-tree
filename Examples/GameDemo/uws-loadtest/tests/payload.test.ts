import { describe, it, expect } from "vitest";
import { renderTemplateObject } from "../src/payload";

describe("renderTemplateObject", () => {
    it("renders templates recursively", () => {
        const template = { name: "p-{playerId}", stats: { lane: "{randInt:1:2}" } };
        const rendered = renderTemplateObject(template, { playerId: "abc" });
        expect(rendered.name).toBe("p-abc");
        expect(["1", "2"]).toContain(rendered.stats.lane);
    });
});
