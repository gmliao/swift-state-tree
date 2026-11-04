/// <reference types="node" />
// Unit tests for the convergence check (#79): comparison semantics, fatal route errors,
// resume on failure, and the drop-one-patch fault injection. No server needed.

import assert from "assert";
import { createServer, IncomingMessage, ServerResponse } from "http";
import { AddressInfo } from "net";
import { IVec2, Position2, Angle } from "@swiftstatetree/sdk/core";
import {
  checkConvergence,
  compareStates,
  ConvergenceInfraError,
  DebugStateClient,
  formatConvergence,
  injectDropOnePatch,
  MISMATCH_MARKER,
  GATING_MISMATCH_MARKER,
  INCONCLUSIVE_MARKER,
  normalizeForConvergence,
} from "../../src/convergence.js";

const paths = (client: unknown, server: unknown) => compareStates(client, server).map((d) => d.path);

// MARK: Comparison semantics

// Absent vs null: a nil optional may arrive as an explicit null or as a removed key.
assert.deepEqual(paths({ a: 1, target: null }, { a: 1 }), [], "null equals absent (client null)");
assert.deepEqual(paths({ a: 1 }, { a: 1, target: null }), [], "null equals absent (server null)");
assert.deepEqual(paths({ a: 1 }, { a: 1, target: 0 }), ["/target"], "absent differs from a value");
assert.deepEqual(paths({ list: [1, null] }, { list: [1, null] }), [], "null array elements are kept");
assert.deepEqual(paths({ list: [1] }, { list: [1, null] }), ["/list/1"], "array length is significant");

// Fixed-point values compare int-to-int in the state-wire shape.
assert.deepEqual(
  normalizeForConvergence({ position: new Position2({ x: 1500, y: -250 }, true) }),
  { position: { v: { x: 1500, y: -250 } } },
  "Position2 normalizes to the wire shape",
);
assert.deepEqual(
  paths({ position: new Position2({ x: 1500, y: -250 }, true) }, { position: { v: { x: 1500, y: -250 } } }),
  [],
  "SDK Position2 equals the projection's raw integers",
);
assert.deepEqual(
  paths({ position: new Position2({ x: 1501, y: -250 }, true) }, { position: { v: { x: 1500, y: -250 } } }),
  ["/position/v/x"],
  "one fixed-point unit off is a mismatch",
);
assert.deepEqual(paths({ dir: new IVec2(3, 4, true), angle: new Angle(90000, true) }, { dir: { x: 3, y: 4 }, angle: { degrees: 90000 } }), [], "IVec2 and Angle");

// Key order is irrelevant.
assert.deepEqual(paths({ a: 1, b: { c: 2, d: 3 } }, { b: { d: 3, c: 2 }, a: 1 }), [], "key order");

// Other players' per-player fields are absent on both sides; a leaked one is reported.
assert.deepEqual(paths({ privateStates: { p1: { n: 1 } } }, { privateStates: { p1: { n: 1 } } }), [], "own slice only");
assert.deepEqual(
  paths({ privateStates: { p1: { n: 1 }, p2: { n: 5 } } }, { privateStates: { p1: { n: 1 } } }),
  ["/privateStates/p2"],
  "another player's slice on the client is a mismatch",
);

// Integers above 2^53: MessagePack may decode a BigInt, JSON decodes a Number.
assert.equal(normalizeForConvergence(BigInt(42)), 42, "bigint normalizes to number");
assert.deepEqual(paths({ big: BigInt(2) ** BigInt(60) }, { big: 2 ** 60 }), [], "BigInt equals JSON Number");

// Type differences are reported.
assert.deepEqual(paths({ n: "1" }, { n: 1 }), ["/n"], "string vs number");
assert.deepEqual(paths({ o: {} }, { o: [] }), ["/o"], "object vs array");

// Output: greppable marker, first N paths.
{
  const many = Object.fromEntries(Array.from({ length: 15 }, (_, i) => [`k${i}`, i]));
  const lines = formatConvergence(
    {
      label: "end",
      tickId: 7,
      membershipChanged: false,
      converged: false,
      clients: [{ name: "client-0", playerID: "p1", differences: compareStates({}, many) }],
    },
    10,
  );
  assert.ok(lines[0].startsWith(MISMATCH_MARKER), "mismatch line starts with the marker");
  assert.ok(lines[0].includes("paths=15"), "mismatch line counts paths");
  assert.equal(lines.length, 1 + 10 + 1, "first 10 paths, then a remainder line");
  const gated = formatConvergence(
    { label: "end", tickId: 7, membershipChanged: false, converged: false, clients: [{ name: "c", playerID: "p", differences: compareStates({ a: 1 }, {}) }] },
    10,
    true,
  );
  assert.ok(gated[0].startsWith(GATING_MISMATCH_MARKER), "gating mismatch has its own marker");
  const inconclusive = formatConvergence(
    { label: "end", tickId: 7, membershipChanged: true, converged: false, clients: [] },
  );
  assert.ok(inconclusive[0].startsWith(INCONCLUSIVE_MARKER), "membership change is inconclusive, not a mismatch");
}

// MARK: Debug routes against a local mock server

type Route = (req: IncomingMessage, res: ServerResponse) => void;

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

const ok = (data: unknown) => ({ success: true, data });
const fail = (message: string) => ({ success: false, error: { code: "X", message } });

async function withServer(route: Route, body: (client: DebugStateClient, calls: string[]) => Promise<void>) {
  const calls: string[] = [];
  const server = createServer((req, res) => {
    calls.push(`${req.method} ${req.url} key=${req.headers["x-api-key"] ?? ""}`);
    route(req, res);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  try {
    await body(new DebugStateClient({ adminUrl: `http://127.0.0.1:${port}`, apiKey: "k", requestTimeoutMs: 2000 }), calls);
  } finally {
    server.close();
  }
}

async function expectInfraError(promise: Promise<unknown>, status: number | undefined, message: string) {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof ConvergenceInfraError, `${message}: not a ConvergenceInfraError (${error})`);
    assert.equal((error as ConvergenceInfraError).status, status, `${message}: status`);
    return;
  }
  assert.fail(`${message}: did not throw`);
}

/** Minimal view stand-in: state, patch subscription and the private applyPatch hook. */
function fakeView(state: Record<string, unknown>) {
  const callbacks = new Set<() => void>();
  return {
    getState: () => ({ ...state }),
    onPatch: (cb: () => void) => {
      callbacks.add(cb);
      return () => callbacks.delete(cb);
    },
    applyPatch(patch: { path: string; value?: unknown }) {
      state[patch.path.slice(1)] = patch.value;
      callbacks.forEach((cb) => cb());
    },
    handleStateUpdate(update: { type: string; patches: Array<{ path: string; value?: unknown }> }) {
      update.patches.forEach((patch) => this.applyPatch(patch));
    },
  };
}

const freezeBody = { freezeToken: "tok-1", tickId: 9, freezeCount: 1, reused: false };

async function main() {
  // 401, 404 and 503 (freeze timeout) are fatal errors, not mismatches.
  for (const [status, label] of [[401, "unauthorized"], [404, "unknown land"], [503, "settle timeout"]] as const) {
    await withServer(
      (_req, res) => json(res, status, fail(label)),
      async (client) => {
        await expectInfraError(client.freeze("counter:a"), status, label);
      },
    );
  }

  // Unreachable admin URL is fatal too.
  await expectInfraError(
    new DebugStateClient({ adminUrl: "http://127.0.0.1:1", apiKey: "k", requestTimeoutMs: 1000 }).freeze("x"),
    undefined,
    "unreachable",
  );

  // Converged and mismatching checks; resume sends the freeze token and the API key.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) {
        return json(res, 200, ok({ freezeToken: "tok-1", tickId: 9, playerID: "p1", membershipChanged: false, state: { count: 1 } }));
      }
      if (req.url?.includes("/resume")) return json(res, 200, ok({ freezeCount: 0, resumed: true }));
      json(res, 404, fail("no route"));
    },
    async (client, calls) => {
      const good = await checkConvergence(client, "counter:a", [{ name: "c0", view: fakeView({ count: 1 }) as any, playerID: "p1" }], { quietMs: 30 });
      assert.equal(good.converged, true, "equal state converges");
      const bad = await checkConvergence(client, "counter:a", [{ name: "c0", view: fakeView({ count: 0 }) as any, playerID: "p1" }], { quietMs: 30 });
      assert.equal(bad.converged, false);
      assert.deepEqual(bad.clients[0].differences.map((d) => d.path), ["/count"]);
      assert.ok(calls.includes("POST /admin/lands/counter%3Aa/debug/resume?freezeToken=tok-1 key=k"), `resume with token: ${calls}`);
      assert.ok(calls.includes("GET /admin/lands/counter%3Aa/debug/projection?playerID=p1 key=k"), "projection per player");
    },
  );

  // A failed projection still resumes, and the error is fatal.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) return json(res, 500, fail("boom"));
      if (req.url?.includes("/resume")) return json(res, 200, ok({ freezeCount: 0, resumed: true }));
    },
    async (client, calls) => {
      await expectInfraError(
        checkConvergence(client, "counter:a", [{ name: "c0", view: fakeView({}) as any, playerID: "p1" }], { quietMs: 10 }),
        500,
        "projection failure",
      );
      assert.ok(calls.some((c) => c.startsWith("POST /admin/lands/counter%3Aa/debug/resume?freezeToken=tok-1")), "resume after failure");
    },
  );

  // Membership changed: inconclusive, not converged, not a mismatch.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) {
        return json(res, 200, ok({ freezeToken: "tok-1", tickId: 9, membershipChanged: true, state: {} }));
      }
      json(res, 200, ok({ freezeCount: 0, resumed: true }));
    },
    async (client) => {
      const result = await checkConvergence(client, "l:a", [{ name: "c0", view: fakeView({}) as any, playerID: "p1" }], { quietMs: 10 });
      assert.equal(result.membershipChanged, true);
      assert.equal(result.converged, false);
    },
  );

  // Barrier: the check waits until patches stop arriving after the freeze.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) {
        return json(res, 200, ok({ freezeToken: "tok-1", tickId: 9, membershipChanged: false, state: { count: 3 } }));
      }
      json(res, 200, ok({ freezeCount: 0, resumed: true }));
    },
    async (client) => {
      const view = fakeView({ count: 1 });
      // The settle frame lands shortly after freeze answers.
      const late = setTimeout(() => view.applyPatch({ path: "/count", value: 3 }), 60);
      const result = await checkConvergence(client, "l:a", [{ name: "c0", view: view as any, playerID: "p1" }], { quietMs: 150 });
      clearTimeout(late);
      assert.equal(result.converged, true, "late settle frame applied before comparing");
    },
  );

  // Fault injection drops exactly one matching diff patch and leaves firstSync intact.
  {
    const view = fakeView({});
    const dropped = injectDropOnePatch(view as any, "/count");
    view.handleStateUpdate({ type: "firstSync", patches: [{ path: "/count", value: 0 }] });
    view.handleStateUpdate({ type: "diff", patches: [{ path: "/other", value: 5 }, { path: "/count", value: 1 }] });
    view.handleStateUpdate({ type: "diff", patches: [{ path: "/count", value: 2 }] });
    assert.equal(dropped(), "/count");
    assert.deepEqual(view.getState(), { count: 2, other: 5 }, "only the first diff /count patch was dropped");
  }
  {
    const view = fakeView({});
    injectDropOnePatch(view as any, "/count");
    view.handleStateUpdate({ type: "firstSync", patches: [{ path: "/count", value: 0 }] });
    view.handleStateUpdate({ type: "diff", patches: [{ path: "/count", value: 1 }] });
    assert.deepEqual(view.getState(), { count: 0 }, "the dropped diff leaves the client behind");
  }

  console.log("✅ convergence unit tests passed");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
