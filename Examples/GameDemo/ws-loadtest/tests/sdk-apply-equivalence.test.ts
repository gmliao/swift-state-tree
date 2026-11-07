import { describe, expect, it } from "vitest";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import zlib from "node:zlib";
import { ConnectionReconstruction, loadSdkCore } from "../src/reconstruction";
import { captureStreams } from "../src/time-decode";

// The SDK's patch apply (#303: no second decode without a patch callback, type lookups cached by
// path pattern, the path split once) must build the same state as before. Each fixture is one
// recipient's frames of a hero-defense capture (`EncodingBenchmark --capture-views`, 1 room,
// monster cap 4, active players, delta, messagepack-pathhash, server events off): the joins and
// warm-up, then 59 syncs, with the projections dropped. The hashes are of the final state,
// normalized as convergence compares it, built by the SDK before #303.
const pinned: Record<string, string> = {
    p10: "0be1dbb888a29cfd7d6492f01d88514e7cdd6a77416f5bc35b58c2d5621e4932",
    p50: "67953d5e80e1936b2ee5c04da67bff204f79b64c750e138dff7996fb301bb83f",
};

describe("SDK patch apply", () => {
    for (const [players, hash] of Object.entries(pinned)) {
        it(`hero-defense ${players}: the final state hashes as the SDK before #303 built it`, async () => {
            const sdk = await loadSdkCore();
            const dir = fs.mkdtempSync(path.join(os.tmpdir(), "apply-"));
            const file = path.join(dir, "room-0.ndjson");
            fs.writeFileSync(file, zlib.gunzipSync(fs.readFileSync(path.join(__dirname, "fixtures", `hero-defense-apply-${players}.ndjson.gz`))));
            const [stream] = captureStreams(file);
            const view = new ConnectionReconstruction(sdk, stream.schema, stream.landID, { playerID: stream.playerID, encoding: stream.encoding });
            for (const frame of stream.frames) view.feed(frame);
            expect(view.decodeErrors).toBe(0);
            const normalized = JSON.stringify(sdk.normalizeForConvergence(view.view.getState()));
            expect(crypto.createHash("sha256").update(normalized).digest("hex")).toBe(hash);
        });
    }
});
