import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { getBaseUrl, getTokenPath, listRoutes } from "../src/api-client.js";

test("official and local profiles keep their credentials separate", () => {
  const original = process.env.DESIGN_CANVAS_PROFILE;
  const file = process.env.DESIGN_CANVAS_TOKEN_FILE;
  try {
    delete process.env.DESIGN_CANVAS_TOKEN_FILE;
    delete process.env.DESIGN_CANVAS_PROFILE;
    assert.equal(getTokenPath(), join(homedir(), ".designcanvas", "api_token"));
    process.env.DESIGN_CANVAS_PROFILE = "local";
    assert.equal(getTokenPath(), join(homedir(), ".designcanvas-local", "api_token"));
  } finally {
    restore("DESIGN_CANVAS_PROFILE", original);
    restore("DESIGN_CANVAS_TOKEN_FILE", file);
  }
});

test("MCP refuses remote URLs before reading or transmitting local credentials", () => {
  const original = process.env.DESIGN_CANVAS_URL;
  try {
    for (const url of ["https://example.com", "file:///tmp/app", "http://user:pass@localhost:7420"]) {
      process.env.DESIGN_CANVAS_URL = url;
      assert.throws(getBaseUrl, /loopback/);
    }
  } finally { restore("DESIGN_CANVAS_URL", original); }
});

test("a running MCP process reads rotated tokens on the next request", async () => {
  const dir = mkdtempSync(join(tmpdir(), "design-canvas-profile-"));
  const original = Object.fromEntries(["DESIGN_CANVAS_URL", "DESIGN_CANVAS_TOKEN_FILE", "DESIGN_CANVAS_TOKEN"].map(k => [k, process.env[k]]));
  const received: (string | undefined)[] = [];
  const server = createServer((req, res) => {
    received.push(req.headers.authorization);
    res.setHeader("Content-Type", "application/json");
    res.end("[]");
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const port = (server.address() as { port: number }).port;
    process.env.DESIGN_CANVAS_URL = `http://127.0.0.1:${port}`;
    process.env.DESIGN_CANVAS_TOKEN_FILE = join(dir, "token");
    delete process.env.DESIGN_CANVAS_TOKEN;
    writeFileSync(process.env.DESIGN_CANVAS_TOKEN_FILE, "fixture-one");
    await listRoutes();
    writeFileSync(process.env.DESIGN_CANVAS_TOKEN_FILE, "fixture-two");
    await listRoutes();
    assert.deepEqual(received, ["Bearer fixture-one", "Bearer fixture-two"]);
  } finally {
    for (const [k, v] of Object.entries(original)) restore(k, v);
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(dir, { recursive: true });
  }
});

function restore(key: string, value: string | undefined) {
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
}
