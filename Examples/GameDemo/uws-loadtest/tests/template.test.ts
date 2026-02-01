import { describe, it, expect } from "vitest";
import { renderTemplate } from "../src/template";

describe("renderTemplate", () => {
    it("replaces simple placeholders", () => {
        const out = renderTemplate("p-{playerId}", { playerId: "abc" });
        expect(out).toBe("p-abc");
    });

    it("supports randInt", () => {
        const out = renderTemplate("r-{randInt:1:2}", {});
        expect(["r-1", "r-2"]).toContain(out);
    });
});
