/// <reference types="node" />
// Unit tests for the convergence check (#79): comparison semantics, fatal route errors,
// resume on failure, the drop-one-patch fault injection, and the retry of an inconclusive
// check (#226). No server needed.

import assert from "assert";
import { createServer, IncomingMessage, ServerResponse } from "http";
import { AddressInfo } from "net";
import { IVec2, Position2, Angle } from "@swiftstatetree/sdk/core";
import {
  checkConvergence,
  compareStates,
  ConvergenceInconclusiveError,
  ConvergenceInfraError,
  ConvergenceResult,
  DebugStateClient,
  formatConvergence,
  formatInconclusiveAttempt,
  runConvergenceAttempts,
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
assert.deepEqual(paths({ big: BigInt(2) ** BigInt(40) }, { big: 2 ** 40 }), [], "safe BigInt equals JSON Number");
// Above 2^53 both decoders may round; never call that equal.
assert.deepEqual(paths({ big: BigInt(2) ** BigInt(60) }, { big: 2 ** 60 }), ["/big"], "unsafe BigInt is reported");
assert.deepEqual(paths({ big: 2 ** 60 }, { big: 2 ** 60 }), ["/big"], "unsafe JSON integer is reported");
assert.deepEqual(paths({ n: Number.MAX_SAFE_INTEGER }, { n: Number.MAX_SAFE_INTEGER }), [], "2^53 - 1 is still exact");
assert.ok(
  formatConvergence(
    { label: "x", tickId: 1, membershipChanged: false, converged: false, clients: [{ name: "c", playerID: "p", differences: compareStates({ big: BigInt(2) ** BigInt(60) }, { big: 2 ** 60 }) }] },
  )[1].includes("<unsafe integer 1152921504606846976>"),
  "unsafe integer is printed with its digits",
);

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

  // A resume failure does not hide the error that ended the check; it is logged instead.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) return json(res, 409, fail("not frozen"));
      json(res, 500, fail("resume broke"));
    },
    async (client) => {
      const logged: string[] = [];
      await expectInfraError(
        checkConvergence(client, "l:a", [{ name: "c0", view: fakeView({}) as any, playerID: "p1" }], {
          quietMs: 10,
          log: (line) => logged.push(line),
        }),
        409,
        "original projection error survives a failing resume",
      );
      assert.ok(logged.some((l) => l.includes("resume failed after an earlier error")), `resume failure logged: ${logged}`);
    },
  );

  // Without an earlier error, a resume failure is the error.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) {
        return json(res, 200, ok({ freezeToken: "tok-1", tickId: 9, membershipChanged: false, state: {} }));
      }
      json(res, 500, fail("resume broke"));
    },
    async (client) => {
      await expectInfraError(
        checkConvergence(client, "l:a", [{ name: "c0", view: fakeView({}) as any, playerID: "p1" }], { quietMs: 10, log: () => {} }),
        500,
        "resume failure is fatal on its own",
      );
    },
  );

  // A stale token (already auto-resumed) is a warning line, not an error.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) {
        return json(res, 200, ok({ freezeToken: "tok-1", tickId: 9, membershipChanged: false, state: {} }));
      }
      json(res, 200, ok({ freezeCount: 0, resumed: false }));
    },
    async (client) => {
      const logged: string[] = [];
      const result = await checkConvergence(client, "l:a", [{ name: "c0", view: fakeView({}) as any, playerID: "p1" }], {
        quietMs: 10,
        log: (line) => logged.push(line),
      });
      assert.equal(result.converged, true);
      assert.ok(logged.some((l) => l.includes("resumed=false")), `stale resume warned: ${logged}`);
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

  await retryTests();

  console.log("✅ convergence unit tests passed");
}

// MARK: Retrying an inconclusive check (#226)

type Scripted = "converged" | "mismatch" | "inconclusive" | "inconclusive-mismatch" | "error";

function scriptedResult(kind: Exclude<Scripted, "error">, tickId: number): ConvergenceResult {
  const differs = kind === "mismatch" || kind === "inconclusive-mismatch";
  const membershipChanged = kind.startsWith("inconclusive");
  return {
    label: "step",
    tickId,
    membershipChanged,
    clients: [
      {
        name: "c0",
        playerID: "p1",
        differences: differs ? [{ path: "/score", client: 1, server: 2 }, { path: "/hp", client: 3, server: 4 }] : [],
      },
    ],
    converged: !membershipChanged && !differs,
  };
}

/** A check that returns `script` in order, counting calls, and the sleeps it was asked for. */
function scriptedCheck(script: Scripted[]) {
  let calls = 0;
  const sleeps: number[] = [];
  const check = async () => {
    const kind = script[calls];
    calls += 1;
    if (kind === undefined) throw new Error("check called more often than scripted");
    if (kind === "error") throw new ConvergenceInfraError("projection failed", 500);
    return scriptedResult(kind, calls);
  };
  const sleep = async (ms: number) => {
    sleeps.push(ms);
  };
  return { check, sleep, sleeps, calls: () => calls };
}

async function expectRejects(promise: Promise<unknown>, type: Function, message: string) {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof type, `${message}: wrong error ${error}`);
    return;
  }
  assert.fail(`${message}: did not throw`);
}

async function retryTests() {
  // Inconclusive, then converged: success after two checks, one wait of retryDelayMs between them.
  for (const gating of [true, false]) {
    const s = scriptedCheck(["inconclusive", "converged"]);
    const step = await runConvergenceAttempts(s.check, { gating, retryDelayMs: 150, sleep: s.sleep });
    assert.equal(step.outcome, "converged", `inconclusive → converged (gating=${gating})`);
    assert.equal(s.calls(), 2);
    assert.deepEqual(s.sleeps, [150], "one wait, before the second attempt");
    assert.equal(step.result.tickId, 2, "the conclusive attempt decides");
  }

  // Inconclusive, then a mismatch: the mismatch decides, and no third attempt runs.
  for (const gating of [true, false]) {
    const s = scriptedCheck(["inconclusive", "mismatch", "converged"]);
    const step = await runConvergenceAttempts(s.check, { gating, sleep: s.sleep });
    assert.equal(step.outcome, "mismatch", `a mismatch after a retry is a mismatch (gating=${gating})`);
    assert.equal(s.calls(), 2, "no retry after a conclusive mismatch");
  }

  // Inconclusive three times: under gating the step fails after exactly three checks.
  {
    const s = scriptedCheck(["inconclusive", "inconclusive", "inconclusive", "converged"]);
    await expectRejects(runConvergenceAttempts(s.check, { gating: true, sleep: s.sleep }), ConvergenceInconclusiveError, "all inconclusive, gating");
    assert.equal(s.calls(), 3, "the default is three attempts");
    assert.equal(s.sleeps.length, 2);
  }
  // Without gating it's reported, not thrown.
  {
    const s = scriptedCheck(["inconclusive", "inconclusive", "inconclusive"]);
    const step = await runConvergenceAttempts(s.check, { gating: false, sleep: s.sleep });
    assert.equal(step.outcome, "inconclusive");
    assert.equal(step.attempts.length, 3);
  }

  // maxAttempts 1 keeps a single check.
  {
    const s = scriptedCheck(["inconclusive", "converged"]);
    await expectRejects(
      runConvergenceAttempts(s.check, { gating: true, maxAttempts: 1, sleep: s.sleep }),
      ConvergenceInconclusiveError,
      "maxAttempts 1",
    );
    assert.equal(s.calls(), 1);
    assert.deepEqual(s.sleeps, []);
  }

  // An infra error is not the membership race: rethrown at once, no retry.
  for (const script of [["error", "converged"], ["inconclusive", "error", "converged"]] as Scripted[][]) {
    const s = scriptedCheck(script);
    await expectRejects(runConvergenceAttempts(s.check, { gating: true, sleep: s.sleep }), ConvergenceInfraError, `infra error in ${script}`);
    assert.equal(s.calls(), script.indexOf("error") + 1, "no attempt after the error");
  }

  // An inconclusive attempt's line names the mismatch it saw; the plain one doesn't.
  {
    const line = formatInconclusiveAttempt(scriptedResult("inconclusive-mismatch", 4), 1, 3);
    assert.ok(line.startsWith(INCONCLUSIVE_MARKER), "the marker prefix is unchanged");
    assert.ok(line.endsWith("tick=4 attempt=1/3 mismatchedPaths=2 first=/score"), line);
    assert.ok(formatInconclusiveAttempt(scriptedResult("inconclusive", 5), 2, 3).endsWith("tick=5 attempt=2/3"));
    const s = scriptedCheck(["inconclusive-mismatch", "converged"]);
    const step = await runConvergenceAttempts(s.check, { gating: true, sleep: s.sleep });
    assert.equal(step.outcome, "converged", "a mismatch inside an inconclusive attempt doesn't count");
  }

  // Through the debug routes: a check that fails after its freeze resumes once, and no
  // retry freezes again.
  await withServer(
    (req, res) => {
      if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
      if (req.url?.includes("/projection")) return json(res, 500, fail("boom"));
      if (req.url?.includes("/resume")) return json(res, 200, ok({ freezeCount: 0, resumed: true }));
    },
    async (client, calls) => {
      const s = scriptedCheck([]);
      await expectRejects(
        runConvergenceAttempts(
          () => checkConvergence(client, "counter:a", [{ name: "c0", view: fakeView({}) as any, playerID: "p1" }], { quietMs: 10 }),
          { gating: true, sleep: s.sleep },
        ),
        ConvergenceInfraError,
        "projection failure ends the step",
      );
      assert.equal(calls.filter((c) => c.includes("/debug/freeze")).length, 1, `one freeze: ${calls}`);
      assert.equal(calls.filter((c) => c.includes("/debug/resume")).length, 1, `one resume: ${calls}`);
    },
  );

  // Through the debug routes: an inconclusive attempt resumes before the retry freezes again.
  {
    let projections = 0;
    await withServer(
      (req, res) => {
        if (req.url?.includes("/freeze")) return json(res, 200, ok(freezeBody));
        if (req.url?.includes("/projection")) {
          projections += 1;
          return json(res, 200, ok({ freezeToken: "tok-1", tickId: 9, playerID: "p1", membershipChanged: projections === 1, state: { count: 1 } }));
        }
        if (req.url?.includes("/resume")) return json(res, 200, ok({ freezeCount: 0, resumed: true }));
      },
      async (client, calls) => {
        const s = scriptedCheck([]);
        const step = await runConvergenceAttempts(
          () => checkConvergence(client, "counter:a", [{ name: "c0", view: fakeView({ count: 1 }) as any, playerID: "p1" }], { quietMs: 10 }),
          { gating: true, sleep: s.sleep },
        );
        assert.equal(step.outcome, "converged");
        const order = calls.map((c) => (c.includes("/freeze") ? "freeze" : c.includes("/resume") ? "resume" : "projection"));
        assert.deepEqual(order, ["freeze", "projection", "resume", "freeze", "projection", "resume"], `order: ${order}`);
      },
    );
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
