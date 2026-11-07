// Records the frames a GameServer sends to a few hero-defense connections, as the fixture of the
// reconstruction's differential test (tests/reconstruction.test.ts): the server's schema and,
// per connection, every frame it received, in order.
//
//   node scripts/record-frames.mjs --url ws://localhost:8080/game/hero-defense --out <file.json.gz>
//
// Connection a joins at once, b two seconds later (its join resets a's broadcast key scope),
// c joins at three seconds and leaves at six. Each sends MoveTo events and a PlayAction every
// 300 ms, encoded as the join response says. Run it against a server started with the
// TRANSPORT_ENCODING to record; the encoding is recorded with the frames.
import fs from "node:fs";
import zlib from "node:zlib";
import { WebSocket } from "ws";
import { decode, encode } from "@msgpack/msgpack";

const args = Object.fromEntries(
    process.argv.slice(2).reduce((pairs, arg, i, all) => (arg.startsWith("--") ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs), [])
);
const url = args.url ?? "ws://localhost:8080/game/hero-defense";
const out = args.out ?? "tests/fixtures/hero-defense-frames.json.gz";
const durationMs = Number(args["duration-ms"] ?? 8000);
const land = `record-${Date.now()}`;
const httpBase = url.replace(/^ws/, "http").replace(/\/game\/.*$/, "");

const schema = await (await fetch(`${httpBase}/schema`)).json();

function connection(name, startMs, endMs) {
    const record = { name, frames: [], encoding: undefined };
    return new Promise((resolve) => {
        setTimeout(() => {
            const socket = new WebSocket(url);
            let timer;
            let seq = 0;
            const send = (message) => socket.send(record.encoding === "messagepack" ? encode(message) : JSON.stringify(message));
            socket.on("open", () => {
                socket.send(JSON.stringify({ kind: "join", payload: { join: { requestID: "join-1", landType: "hero-defense", landInstanceId: land } } }));
            });
            socket.on("message", (data, isBinary) => {
                const bytes = Buffer.from(data);
                record.frames.push({ binary: isBinary, data: bytes.toString("base64") });
                if (record.encoding === undefined) {
                    let frame;
                    // JSON text may come in a binary frame too; try both, as the load client does.
                    try {
                        frame = JSON.parse(bytes.toString("utf8"));
                    } catch {
                        try {
                            frame = decode(bytes);
                        } catch {
                            frame = undefined;
                        }
                    }
                    // The join response: `[105, requestID, success, landType, instance, slot, encoding, ...]`
                    // in the opcode encodings, `{ kind: "joinResponse", payload: { joinResponse } }` in json.
                    const encoding = Array.isArray(frame) && frame[0] === 105 ? frame[6] : frame?.payload?.joinResponse?.encoding;
                    if (encoding) {
                        record.encoding = encoding;
                        timer = setInterval(() => {
                            seq += 1;
                            const x = 20000 + ((seq * 7919) % 80000);
                            const y = 10000 + ((seq * 104729) % 50000);
                            const target = { v: { x, y } };
                            // As the load client sends them (worker.ts sendEvent / sendAction).
                            if (record.encoding === "messagepack") {
                                send([103, 0, "MoveTo", { target }]);
                                send([101, `a-${seq}`, "PlayAction", {}]);
                            } else {
                                send({ kind: "event", payload: { fromClient: { type: "MoveTo", payload: { target } } } });
                                send({ kind: "action", payload: { requestID: `a-${seq}`, typeIdentifier: "PlayAction", payload: {} } });
                            }
                        }, 300);
                    }
                }
            });
            setTimeout(() => {
                clearInterval(timer);
                socket.close(1000);
            }, endMs - startMs);
            socket.on("close", () => resolve(record));
        }, startMs);
    });
}

const connections = await Promise.all([
    connection("a", 0, durationMs),
    connection("b", 2000, durationMs),
    connection("c", 3000, 6000)
]);
fs.mkdirSync(new URL(".", `file://${process.cwd()}/${out}`).pathname, { recursive: true });
fs.writeFileSync(out, zlib.gzipSync(JSON.stringify({ url, land, schema, connections })));
console.log(`${out}: ${connections.map((c) => `${c.name} ${c.frames.length} frames (${c.encoding})`).join(", ")}`);
