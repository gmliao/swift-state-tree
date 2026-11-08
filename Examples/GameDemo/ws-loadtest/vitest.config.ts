import { configDefaults, defineConfig } from "vitest/config";

/**
 * Tests that measure real time against a stub server (when sends arrive within 2 ms, when the
 * stale check runs against a read pause, join answers against the window start). Any other test
 * file running beside them is enough to fail them (#285; Notes/solutions, "A CPU-heavy test
 * makes every wall-clock test beside it fail"), so they run in a pass of their own, one file at
 * a time: `npm test` runs the other files first, then these with WS_LOADTEST_TESTS=real-time.
 */
export const REAL_TIME_TESTS = ["tests/phase-lifecycle.test.ts", "tests/join-failures.test.ts"];

const realTime = process.env.WS_LOADTEST_TESTS === "real-time";

export default defineConfig({
    test: {
        environment: "node",
        ...(realTime
            ? { include: REAL_TIME_TESTS, fileParallelism: false }
            : { exclude: [...configDefaults.exclude, ...REAL_TIME_TESTS] })
    }
});
