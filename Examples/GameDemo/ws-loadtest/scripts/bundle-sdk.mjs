// Bundles the SDK's core (ESM, with extensionless relative imports that Node can't resolve)
// into one CommonJS file next to the compiled tool, for the per-connection state view.
import { build } from "esbuild";

await build({
    entryPoints: ["@swiftstatetree/sdk/core"],
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node20",
    outfile: "dist/sdk-core.cjs",
    external: ["ws", "@msgpack/msgpack"],
    logLevel: "warning"
});
