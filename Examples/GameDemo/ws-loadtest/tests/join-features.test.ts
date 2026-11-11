import { describe, expect, it } from "vitest";
import { buildJoinMessage, STATE_UPDATE_FEATURES } from "../src/worker";
import { loadSdkCore } from "../src/reconstruction";

// A server with a state-update feature on refuses a join that doesn't declare it, so every
// load-test join must declare what the SDK's decoder (which this client decodes through) reads.
describe("join features", () => {
    it("declares exactly the features the SDK decodes, except rowAddressing", async () => {
        const sdk = await loadSdkCore();
        // This is the measurement client: its declared features move in their own change, not
        // with the SDK's. `rowAddressing` joins its list in the load-test client's step of
        // row addressing (step D of #392), with its own check; until then it stays out.
        expect([...STATE_UPDATE_FEATURES]).toEqual(sdk.SUPPORTED_STATE_UPDATE_FEATURES.filter((f) => f !== "rowAddressing"));
        expect(STATE_UPDATE_FEATURES).toContain("pathIndex");
        expect(STATE_UPDATE_FEATURES).toContain("fieldMerge");
    });

    it("every join carries the declaration, next to a template's metadata", () => {
        const plain = buildJoinMessage("hero-defense", "room-1", "join-1");
        expect(plain.payload.join.metadata).toEqual({ stateUpdateFeatures: ["pathIndex", "fieldMerge", "syncSequence"] });
        const templated = buildJoinMessage("hero-defense", "room-1", "join-1", { token: "t" });
        expect(templated.payload.join.metadata).toEqual({ stateUpdateFeatures: ["pathIndex", "fieldMerge", "syncSequence"], token: "t" });
        // A template that declares its own list keeps it.
        const own = buildJoinMessage("hero-defense", "room-1", "join-1", { stateUpdateFeatures: [] });
        expect(own.payload.join.metadata).toEqual({ stateUpdateFeatures: [] });
    });
});
