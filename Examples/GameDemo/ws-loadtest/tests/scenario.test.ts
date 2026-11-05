import { describe, it, expect } from "vitest";
import { parseScenario } from "../src/scenario";

describe("parseScenario", () => {
    it("fills defaults when rooms missing", () => {
        const scenario = parseScenario({ phases: { steady: { durationSeconds: 10 } } });
        expect(scenario.phases.steady.rooms).toBe(500);
    });
});

describe("scenario landType", () => {
    it("takes landType from the scenario when given", () => {
        const s = parseScenario({ serverUrl: "ws://h:8080/game/hero-defense", landType: "visibility-test" });
        expect(s.landType).toBe("visibility-test");
    });

    it("infers landType from a /game/<landType> server URL", () => {
        expect(parseScenario({ serverUrl: "ws://localhost:8080/game/visibility-test" }).landType).toBe("visibility-test");
        expect(parseScenario({ serverUrl: "ws://localhost:8080/game/hero-defense/" }).landType).toBe("hero-defense");
    });

    it("falls back to hero-defense, as before", () => {
        expect(parseScenario({}).landType).toBe("hero-defense");
        expect(parseScenario({ serverUrl: "ws://localhost:8080/ws" }).landType).toBe("hero-defense");
    });

    it("rejects an empty or non-string landType", () => {
        expect(() => parseScenario({ landType: "" })).toThrow(/landType/);
        expect(() => parseScenario({ landType: 3 })).toThrow(/landType/);
    });
});
